using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Drawing = System.Drawing;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfColor = System.Windows.Media.Color;
using WpfColorConverter = System.Windows.Media.ColorConverter;
using WpfKeyEventArgs = System.Windows.Input.KeyEventArgs;
using WpfMouseEventArgs = System.Windows.Input.MouseEventArgs;
using WpfPoint = System.Windows.Point;
using WpfPath = System.Windows.Shapes.Path;
using WpfRectangle = System.Windows.Shapes.Rectangle;

namespace ShotPaste.Windows.Views;

public partial class RecordingInkWindow : Window
{
    private Drawing.Rectangle _bounds;
    private readonly RecordingAnnotationState _state = new();
    private readonly DispatcherTimer _expiryTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly Dictionary<Guid, UIElement> _visuals = [];
    private readonly Dictionary<Guid, double> _baseOpacities = [];
    private readonly AppSettings? _settings;
    private readonly Action? _saveSettings;
    private readonly List<WpfPoint> _points = [];
    private WpfPoint _start;
    private UIElement? _activeVisual;
    private UIElement? _selectedVisual;
    private WpfPoint _selectionStart;
    private Vector _selectionOriginalOffset;
    private bool _dragging;
    private bool _movingSelection;
    private bool _interactionEnabled = true;
    private bool _recordingPaused;
    private DateTimeOffset? _pauseStarted;
    private TimeSpan _pausedDuration;

    public RecordingAnnotationState State => _state;
    public Drawing.Rectangle CaptureBounds => _bounds;
    public RecordingInkWindow(Drawing.Rectangle bounds, AppSettings? settings = null, Action? saveSettings = null)
    {
        InitializeComponent();
        _settings = settings;
        _saveSettings = saveSettings;
        if (settings is not null)
        {
            _state.StrokeColor = settings.RecordingAnnotationColor;
            _state.StrokeWidth = Math.Clamp(settings.RecordingAnnotationWidth, 1, 20);
            _state.ClearAfter = TimeSpan.FromSeconds(Math.Max(1, settings.RecordingAnnotationClearSeconds));
            _state.MaximumCount = Math.Clamp(settings.RecordingAnnotationMaxCount, 1, 200);
            if (Enum.TryParse(settings.RecordingAnnotationClearMode, true, out RecordingAnnotationClearMode clearMode))
                _state.ClearMode = clearMode;
            foreach (var tool in Enum.GetValues<RecordingAnnotationTool>())
            {
                if (!settings.RecordingAnnotationToolPolicies.TryGetValue(tool.ToString(), out var stored)) continue;
                var mode = Enum.TryParse(stored.ClearMode, true, out RecordingAnnotationClearMode parsed)
                    ? parsed
                    : RecordingAnnotationClearMode.Manual;
                _state.SetPolicy(tool, new RecordingAnnotationPolicy(
                    mode,
                    TimeSpan.FromSeconds(Math.Clamp(stored.ClearSeconds, 1, 3600)),
                    Math.Clamp(stored.MaximumCount, 1, 200)));
            }
            _state.FadeEnabled = settings.RecordingAnnotationFadeEnabled;
            _state.FadeDuration = TimeSpan.FromMilliseconds(Math.Clamp(settings.RecordingAnnotationFadeMilliseconds, 100, 3000));
        }
        _state.Annotations.CollectionChanged += OnAnnotationsChanged;
        _bounds = bounds;
        Left = bounds.Left;
        Top = bounds.Top;
        Width = bounds.Width;
        Height = bounds.Height;
        SourceInitialized += OnSourceInitialized;
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(ApplyCaptureBounds);
        SizeChanged += (_, _) =>
        {
            DrawingCanvas.Width = ActualWidth;
            DrawingCanvas.Height = ActualHeight;
        };
        Loaded += (_, _) =>
        {
            DrawingCanvas.Width = ActualWidth;
            DrawingCanvas.Height = ActualHeight;
            _expiryTimer.Start();
            if (_interactionEnabled) Activate();
        };
        _expiryTimer.Tick += OnExpiryTick;
        Closed += (_, _) =>
        {
            _expiryTimer.Stop();
            _state.Annotations.CollectionChanged -= OnAnnotationsChanged;
            _saveSettings?.Invoke();
        };
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        ApplyCaptureBounds();
        ApplyInteractionStyle();
    }

    public void UpdateCaptureBounds(Drawing.Rectangle bounds)
    {
        _bounds = bounds;
        ApplyCaptureBounds();
    }

    public void SetInteractionEnabled(bool enabled)
    {
        _interactionEnabled = enabled;
        IsHitTestVisible = enabled && !_recordingPaused;
        ApplyInteractionStyle();
        if (enabled && IsVisible) Activate();
    }

    public void SetPaused(bool paused)
    {
        if (_recordingPaused == paused) return;
        _recordingPaused = paused;
        if (paused)
        {
            _pauseStarted = DateTimeOffset.UtcNow;
            IsHitTestVisible = false;
        }
        else
        {
            if (_pauseStarted is { } started) _pausedDuration += DateTimeOffset.UtcNow - started;
            _pauseStarted = null;
            IsHitTestVisible = _interactionEnabled;
        }
        ApplyInteractionStyle();
    }

    private void ApplyCaptureBounds()
    {
        if (PresentationSource.FromVisual(this) is not HwndSource source) return;
        var toDip = source.CompositionTarget.TransformFromDevice;
        var origin = toDip.Transform(new WpfPoint(_bounds.Left, _bounds.Top));
        var size = toDip.Transform(new WpfPoint(_bounds.Width, _bounds.Height));
        Left = origin.X;
        Top = origin.Y;
        Width = size.X;
        Height = size.Y;
    }

    private void ApplyInteractionStyle()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
        if (_interactionEnabled && !_recordingPaused)
            style &= ~(NativeMethods.WsExTransparent | NativeMethods.WsExNoActivate);
        else
            style |= NativeMethods.WsExTransparent | NativeMethods.WsExNoActivate;
        NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, new IntPtr(style));
    }

    public void SelectTool(RecordingAnnotationTool tool)
    {
        _state.SelectedTool = tool;
        var policy = _state.GetPolicy(tool);
        _state.ClearMode = policy.ClearMode;
        _state.ClearAfter = policy.ClearAfter;
        _state.MaximumCount = policy.MaximumCount;
        SelectVisual(null);
    }

    public void SetStrokeColor(string color)
    {
        _state.StrokeColor = color;
        if (_settings is not null) _settings.RecordingAnnotationColor = color;
    }

    public void SetStrokeWidth(double width)
    {
        _state.StrokeWidth = Math.Clamp(width, 1, 20);
        if (_settings is not null) _settings.RecordingAnnotationWidth = _state.StrokeWidth;
    }

    public void SetClearMode(RecordingAnnotationClearMode mode)
    {
        var policy = _state.GetPolicy(_state.SelectedTool) with { ClearMode = mode };
        _state.SetPolicy(_state.SelectedTool, policy);
        SaveSelectedToolPolicy(policy);
    }

    public void SetClearValue(int value)
    {
        var policy = _state.GetPolicy(_state.SelectedTool);
        value = Math.Clamp(value, 1, policy.ClearMode == RecordingAnnotationClearMode.MaximumCount ? 200 : 3600);
        if (policy.ClearMode == RecordingAnnotationClearMode.AfterSeconds)
        {
            policy = policy with { ClearAfter = TimeSpan.FromSeconds(value) };
        }
        else if (policy.ClearMode == RecordingAnnotationClearMode.MaximumCount)
        {
            policy = policy with { MaximumCount = value };
        }
        _state.SetPolicy(_state.SelectedTool, policy);
        SaveSelectedToolPolicy(policy);
        _state.Tick(DateTimeOffset.UtcNow);
    }

    public int CurrentClearValue
    {
        get
        {
            var policy = _state.GetPolicy(_state.SelectedTool);
            return policy.ClearMode == RecordingAnnotationClearMode.MaximumCount
                ? policy.MaximumCount
                : Math.Max(1, (int)Math.Round(policy.ClearAfter.TotalSeconds));
        }
    }

    public RecordingAnnotationPolicy CurrentPolicy => _state.GetPolicy(_state.SelectedTool);
    public void SetFadeEnabled(bool enabled)
    {
        _state.FadeEnabled = enabled;
        if (_settings is not null) _settings.RecordingAnnotationFadeEnabled = enabled;
    }

    public void ClearAnnotations() => ClearAll();

    public void UndoLast() => Undo();

    private void OnCanvasMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (_state.SelectedTool == RecordingAnnotationTool.Selection)
        {
            var selected = FindVisual(e.OriginalSource as DependencyObject);
            SelectVisual(selected);
            if (selected is null) return;
            _movingSelection = true;
            _selectionStart = e.GetPosition(DrawingCanvas);
            var transform = selected.RenderTransform as TranslateTransform;
            _selectionOriginalOffset = new Vector(transform?.X ?? 0, transform?.Y ?? 0);
            DrawingCanvas.CaptureMouse();
            e.Handled = true;
            return;
        }
        _start = e.GetPosition(DrawingCanvas);
        _points.Clear();
        _points.Add(_start);
        _dragging = true;
        DrawingCanvas.CaptureMouse();
        _activeVisual = CreateVisual(_state.SelectedTool, _start);
        if (_activeVisual is not null) DrawingCanvas.Children.Add(_activeVisual);
    }

    private void OnCanvasMouseMove(object sender, WpfMouseEventArgs e)
    {
        if (_movingSelection && _selectedVisual is not null && e.LeftButton == MouseButtonState.Pressed)
        {
            var delta = e.GetPosition(DrawingCanvas) - _selectionStart;
            _selectedVisual.RenderTransform = new TranslateTransform(
                _selectionOriginalOffset.X + delta.X,
                _selectionOriginalOffset.Y + delta.Y);
            return;
        }
        if (!_dragging || _activeVisual is null || e.LeftButton != MouseButtonState.Pressed) return;
        var point = e.GetPosition(DrawingCanvas);
        if (_state.SelectedTool is RecordingAnnotationTool.Pencil or RecordingAnnotationTool.Highlighter)
        {
            _points.Add(point);
            if (_activeVisual is Polyline line) line.Points.Add(point);
        }
        else UpdateVisual(_activeVisual, point);
    }

    private void OnCanvasMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_movingSelection)
        {
            _movingSelection = false;
            DrawingCanvas.ReleaseMouseCapture();
            return;
        }
        if (!_dragging) return;
        _dragging = false;
        DrawingCanvas.ReleaseMouseCapture();
        var end = e.GetPosition(DrawingCanvas);
        if (_points.Count == 1) _points.Add(end);
        else if (_state.SelectedTool is not (RecordingAnnotationTool.Pencil or RecordingAnnotationTool.Highlighter)) _points.Add(end);
        var hasSize = Math.Abs(end.X - _start.X) >= 2 || Math.Abs(end.Y - _start.Y) >= 2 || _points.Count > 2;
        if (_activeVisual is not null && hasSize)
        {
            var annotation = _state.Add(_state.SelectedTool, _points, CurrentLogicalTime());
            _visuals[annotation.Id] = _activeVisual;
            _baseOpacities[annotation.Id] = _activeVisual.Opacity;
        }
        else if (_activeVisual is not null) DrawingCanvas.Children.Remove(_activeVisual);
        _activeVisual = null;
        _points.Clear();
    }

    private UIElement? CreateVisual(RecordingAnnotationTool tool, WpfPoint start)
    {
        var color = (WpfColor)WpfColorConverter.ConvertFromString(_state.StrokeColor);
        var brush = new SolidColorBrush(color);
        var width = Math.Max(1, _state.StrokeWidth);
        return tool switch
        {
            RecordingAnnotationTool.Pencil or RecordingAnnotationTool.Highlighter => new Polyline
            {
                Stroke = brush,
                StrokeThickness = tool == RecordingAnnotationTool.Highlighter ? width * 4 : width,
                Opacity = tool == RecordingAnnotationTool.Highlighter ? 0.42 : 1,
                StrokeLineJoin = PenLineJoin.Round,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                Points = new PointCollection { start }
            },
            RecordingAnnotationTool.Line => new Line
            {
                X1 = start.X, Y1 = start.Y, X2 = start.X, Y2 = start.Y,
                Stroke = brush, StrokeThickness = width,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round
            },
            RecordingAnnotationTool.Arrow => new WpfPath { Fill = brush },
            RecordingAnnotationTool.Rectangle => new WpfRectangle { Stroke = brush, StrokeThickness = width, Fill = WpfBrushes.Transparent },
            RecordingAnnotationTool.Oval => new Ellipse { Stroke = brush, StrokeThickness = width, Fill = WpfBrushes.Transparent },
            _ => null
        };
    }

    private void UpdateVisual(UIElement visual, WpfPoint point)
    {
        if (visual is Line line) { line.X2 = point.X; line.Y2 = point.Y; }
        else if (visual is WpfPath arrow) arrow.Data = AnnotationArrowGeometry.CreateTapered(_start, point, _state.StrokeWidth);
        else if (visual is Shape shape)
        {
            shape.Width = Math.Abs(point.X - _start.X);
            shape.Height = Math.Abs(point.Y - _start.Y);
            Canvas.SetLeft(shape, Math.Min(_start.X, point.X));
            Canvas.SetTop(shape, Math.Min(_start.Y, point.Y));
        }
    }

    private void OnKeyDown(object sender, WpfKeyEventArgs e)
    {
        if (e.Key == Key.Escape) { ClearAll(); e.Handled = true; }
        else if (e.Key == Key.Z && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { Undo(); e.Handled = true; }
        else if (e.Key is Key.Delete or Key.Back && _selectedVisual is not null)
        {
            RemoveSelected();
            e.Handled = true;
        }
    }

    private void Undo()
    {
        var annotation = _state.Annotations.LastOrDefault();
        if (annotation is null) return;
        _state.Annotations.Remove(annotation);
        if (_visuals.Remove(annotation.Id, out var visual)) DrawingCanvas.Children.Remove(visual);
    }

    private void ClearAll()
    {
        _state.Clear();
        SelectVisual(null);
    }

    private void OnExpiryTick(object? sender, EventArgs e)
    {
        if (_recordingPaused) return;
        var now = CurrentLogicalTime();
        foreach (var annotation in _state.Annotations)
        {
            if (_visuals.TryGetValue(annotation.Id, out var visual))
            {
                var baseOpacity = _baseOpacities.GetValueOrDefault(annotation.Id, 1d);
                visual.Opacity = baseOpacity * _state.GetOpacity(annotation, now);
            }
        }
        _state.Tick(now);
    }

    private void OnAnnotationsChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Reset)
        {
            foreach (var visual in _visuals.Values) DrawingCanvas.Children.Remove(visual);
            _visuals.Clear();
            _baseOpacities.Clear();
            SelectVisual(null);
            return;
        }
        if (e.OldItems is null) return;
        foreach (var annotation in e.OldItems.Cast<RecordingAnnotation>())
        {
            if (!_visuals.Remove(annotation.Id, out var visual)) continue;
            _baseOpacities.Remove(annotation.Id);
            if (ReferenceEquals(visual, _selectedVisual)) SelectVisual(null);
            DrawingCanvas.Children.Remove(visual);
        }
    }

    private UIElement? FindVisual(DependencyObject? source)
    {
        var current = source;
        while (current is not null && !ReferenceEquals(current, DrawingCanvas))
        {
            if (current is UIElement element && _visuals.Values.Contains(element)) return element;
            current = VisualTreeHelper.GetParent(current);
        }
        return null;
    }

    private void SelectVisual(UIElement? visual)
    {
        if (_selectedVisual is not null) _selectedVisual.Effect = null;
        _selectedVisual = visual;
        if (_selectedVisual is not null)
        {
            _selectedVisual.Effect = new DropShadowEffect
            {
                Color = WpfColor.FromRgb(10, 132, 255),
                BlurRadius = 8,
                ShadowDepth = 0,
                Opacity = 0.95
            };
            System.Windows.Controls.Panel.SetZIndex(_selectedVisual, 50);
        }
    }

    private void RemoveSelected()
    {
        if (_selectedVisual is null) return;
        var match = _visuals.FirstOrDefault(pair => ReferenceEquals(pair.Value, _selectedVisual));
        if (match.Key == Guid.Empty) return;
        var annotation = _state.Annotations.FirstOrDefault(item => item.Id == match.Key);
        if (annotation is not null) _state.Annotations.Remove(annotation);
    }

    private void SaveSelectedToolPolicy(RecordingAnnotationPolicy policy)
    {
        if (_settings is null) return;
        _settings.RecordingAnnotationToolPolicies[_state.SelectedTool.ToString()] = new RecordingAnnotationPolicySettings
        {
            ClearMode = policy.ClearMode.ToString(),
            ClearSeconds = Math.Max(1, (int)Math.Round(policy.ClearAfter.TotalSeconds)),
            MaximumCount = policy.MaximumCount
        };
        // Keep the shared defaults synchronized with the selected tool policy.
        _settings.RecordingAnnotationClearMode = policy.ClearMode.ToString();
        _settings.RecordingAnnotationClearSeconds = Math.Max(1, (int)Math.Round(policy.ClearAfter.TotalSeconds));
        _settings.RecordingAnnotationMaxCount = policy.MaximumCount;
    }

    private DateTimeOffset CurrentLogicalTime() => DateTimeOffset.UtcNow - _pausedDuration;

}
