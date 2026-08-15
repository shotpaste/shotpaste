using System.Windows;
using System.ComponentModel;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Drawing = System.Drawing;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Utilities;
using WpfButton = System.Windows.Controls.Button;
using WpfColor = System.Windows.Media.Color;
using WpfImage = System.Windows.Controls.Image;
using WpfPath = System.Windows.Shapes.Path;
using WpfPoint = System.Windows.Point;
using WpfRectangle = System.Windows.Shapes.Rectangle;
using WpfTextBox = System.Windows.Controls.TextBox;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using ColorConverter = System.Windows.Media.ColorConverter;
using Cursors = System.Windows.Input.Cursors;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Size = System.Windows.Size;

namespace ShotPaste.Windows.Views;

public partial class InlineAnnotateWindow : Window
{
    private enum OverlayInteraction { None, Selecting, MovingSelection, ResizingSelection }
    private enum BlurKind { Pixelated, Gaussian, Hexagonal, Crystallized, Pointillism, Halftone, Tape, Washi }
    private enum ArrowStyleKind { Straight, CurvedRight, CurvedLeft }
    private enum ArrowTypeKind { Classic, Tapered, Outlined }
    private enum ArrowBendKind { Primary, Alternate }

    private sealed class AnnotationStyle
    {
        public required string Tool { get; init; }
        public WpfColor StrokeColor { get; set; }
        public WpfColor? TextBackgroundColor { get; set; }
        public double StrokeWidth { get; set; }
        public double FontSize { get; set; }
        public double CornerRadius { get; set; }
        public BlurKind Blur { get; set; }
        public ArrowStyleKind ArrowStyle { get; set; }
        public ArrowTypeKind ArrowType { get; set; }
        public ArrowBendKind ArrowBend { get; set; }
        public AnnotationArrowGeometry.TipStyle StartHead { get; set; }
        public AnnotationArrowGeometry.TipStyle EndHead { get; set; }
        public WpfPoint Start { get; set; }
        public WpfPoint End { get; set; }

        public AnnotationStyle Copy() => new()
        {
            Tool = Tool,
            StrokeColor = StrokeColor,
            TextBackgroundColor = TextBackgroundColor,
            StrokeWidth = StrokeWidth,
            FontSize = FontSize,
            CornerRadius = CornerRadius,
            Blur = Blur,
            ArrowStyle = ArrowStyle,
            ArrowType = ArrowType,
            ArrowBend = ArrowBend,
            StartHead = StartHead,
            EndHead = EndHead,
            Start = Start,
            End = End
        };
    }

    private sealed record EditAction(Action Undo, Action Redo);

    private readonly BitmapSource _backdropSource;
    private readonly Drawing.Rectangle _physicalBounds;
    private readonly Func<Window, Drawing.Bitmap, bool, Task<bool>>? _screenshotCommit;
    private readonly AppSettings? _settings;
    private readonly Action? _saveSettings;
    private readonly Stack<EditAction> _undo = new();
    private readonly Stack<EditAction> _redo = new();
    private readonly Dictionary<UIElement, string> _elementTools = new();
    private readonly Dictionary<UIElement, AnnotationStyle> _elementStyles = new();
    private readonly Dictionary<string, string> _toolNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Selection"] = "选择", ["Rectangle"] = "矩形", ["FilledRectangle"] = "填充矩形",
        ["Oval"] = "椭圆形", ["Arrow"] = "箭头", ["Line"] = "直线", ["Text"] = "文字",
        ["Highlighter"] = "荧光笔", ["Blur"] = "模糊", ["Spotlight"] = "聚光灯",
        ["Counter"] = "计数器", ["Pencil"] = "铅笔"
    };

    private OverlayInteraction _interaction = OverlayInteraction.None;
    private Rect _selectionRect;
    private Rect _interactionStartRect;
    private Drawing.Rectangle _selectionEditStartPixels;
    private WpfPoint _pointerStart;
    private string _resizeHandle = string.Empty;
    private string _tool = "Selection";
    private WpfColor _color;
    private WpfColor? _textBackgroundColor;
    private double _fontSize = 20;
    private double _cornerRadius;
    private BlurKind _blurKind = BlurKind.Pixelated;
    private ArrowStyleKind _arrowStyle = ArrowStyleKind.Straight;
    private ArrowTypeKind _arrowType = ArrowTypeKind.Tapered;
    private ArrowBendKind _arrowBend = ArrowBendKind.Primary;
    private AnnotationArrowGeometry.TipStyle _arrowStartHead = AnnotationArrowGeometry.TipStyle.None;
    private AnnotationArrowGeometry.TipStyle _arrowEndHead = AnnotationArrowGeometry.TipStyle.Arrow;
    private BitmapSource? _selectionSource;
    private UIElement? _activeElement;
    private AnnotationStyle? _activeStyle;
    private WpfPoint _drawStart;
    private bool _annotating;
    private int _counter = 1;
    private UIElement? _selectedElement;
    private readonly HashSet<UIElement> _selectedElements = [];
    private bool _draggingElement;
    private WpfPoint _elementDragStart;
    private Matrix _elementOriginalTransform = Matrix.Identity;
    private Dictionary<UIElement, Matrix> _elementOriginalTransforms = [];
    private Dictionary<UIElement, AnnotationStyle> _elementOriginalStyles = [];
    private bool _resizingElement;
    private string _elementResizeHandle = string.Empty;
    private WpfPoint _elementResizeStart;
    private Rect _elementResizeStartBounds;
    private double _elementLayoutLeft;
    private double _elementLayoutTop;
    private bool _selectingElements;
    private WpfPoint _elementSelectionStart;
    private bool _isCompleting;
    private bool _allowClose;
    private bool _discardingEmptyText;
    private bool _hexMagnifier = true;
    private string? _magnifierHex;
    private string? _magnifierRgb;
    private double _canvasZoom = 1d;
    private bool _panToolActive;
    private bool _spacePanActive;
    private bool _panningCanvas;
    private WpfPoint _panPointerStart;
    private Vector _panTransformStart;
    private WpfTextBox? _editingTextBox;
    private string? _editingTextOriginalValue;
    private bool _suppressPropertyUpdates;
    private Dictionary<UIElement, AnnotationStyle>? _propertyEditBefore;
    private OneShotMode _oneShotMode = OneShotMode.Screenshot;
    private OneShotRecordingOptions _oneShotRecordingOptions;
    private bool _oneShotCommitted;
    private bool _oneShotControlsInitializing;
    private bool _draggingOneShotSwitcher;
    private double _oneShotSwitcherDragStart;
    private WpfPoint _oneShotPointerStart;
    private bool _draggingOneShotToolbar;
    private WpfPoint _oneShotToolbarPointerStart;
    private double? _oneShotToolbarLeft;
    private double? _oneShotToolbarTop;
    private bool _selectingOneShotOcr;
    private readonly bool _startWithOcr;
    private WpfPoint _oneShotOcrStart;
    private Rect _oneShotOcrRect;
    private readonly System.Windows.Threading.DispatcherTimer _statusTimer = new()
    {
        Interval = TimeSpan.FromSeconds(2)
    };

    public Drawing.Bitmap? ResultImage { get; private set; }
    public bool PinRequested { get; private set; }
    public OneShotMode? OneShotAction { get; private set; }
    internal OneShotMode CurrentOneShotMode => _startWithOcr ? OneShotMode.Ocr : _oneShotMode;
    public Drawing.Rectangle OneShotRectangle { get; private set; }
    public OneShotRecordingOptions? OneShotOptions { get; private set; }
    public bool ScreenshotCommitted { get; private set; }

    public InlineAnnotateWindow(
        BitmapSource backdrop,
        Drawing.Rectangle physicalBounds,
        OneShotRecordingOptions oneShotRecordingOptions,
        Func<Window, Drawing.Bitmap, bool, Task<bool>>? screenshotCommit = null,
        AppSettings? settings = null,
        Action? saveSettings = null,
        OneShotMode initialMode = OneShotMode.Screenshot)
    {
        InitializeComponent();
        _color = ((SolidColorBrush)FindResource("Annotation.RedBrush")).Color;
        ShowInTaskbar = App.UiTestMode;
        _backdropSource = backdrop;
        _physicalBounds = physicalBounds;
        _oneShotRecordingOptions = oneShotRecordingOptions;
        _screenshotCommit = screenshotCommit;
        _settings = settings;
        _saveSettings = saveSettings;
        _startWithOcr = initialMode == OneShotMode.Ocr;
        _oneShotMode = initialMode is OneShotMode.Screenshot or OneShotMode.Scrolling or OneShotMode.Recording
            ? initialMode
            : OneShotMode.Screenshot;
        ApplyPersistedAnnotationSettings();
        BackdropImage.Source = _backdropSource;
        Left = physicalBounds.Left;
        Top = physicalBounds.Top;
        Width = physicalBounds.Width;
        Height = physicalBounds.Height;
        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        Closed += (_, _) => PersistAnnotationSettings();
        _statusTimer.Tick += (_, _) =>
        {
            _statusTimer.Stop();
            StatusBadge.Visibility = Visibility.Collapsed;
        };
    }

    private double StrokeWidth => StrokeSlider.Value;
    private bool IsDrawing => _activeElement is not null;

    private void ApplyPersistedAnnotationSettings()
    {
        if (_settings is null) return;
        try { _color = (WpfColor)ColorConverter.ConvertFromString(_settings.AnnotationPrimaryColor); }
        catch (FormatException) { }
        _fontSize = Math.Clamp(_settings.AnnotationFontSize, 8d, 96d);
        _cornerRadius = Math.Clamp(_settings.AnnotationCornerRadius, 0d, 64d);
        if (StrokeSlider is not null) StrokeSlider.Value = Math.Clamp(_settings.AnnotationStrokeWidth, 1d, 40d);
        if (FontSizeSlider is not null) FontSizeSlider.Value = _fontSize;
        if (CornerRadiusSlider is not null) CornerRadiusSlider.Value = _cornerRadius;
    }

    private void ApplyPersistedToolSettings(string tool)
    {
        var settings = _settings;
        if (settings is null || !settings.AnnotationToolSettings.TryGetValue(tool, out var stored)) return;
        _suppressPropertyUpdates = true;
        try
        {
            _color = (WpfColor)ColorConverter.ConvertFromString(stored.Color);
            _textBackgroundColor = string.IsNullOrWhiteSpace(stored.TextBackgroundColor)
                ? null
                : (WpfColor)ColorConverter.ConvertFromString(stored.TextBackgroundColor);
            StrokeSlider.Value = Math.Clamp(stored.StrokeWidth, 1d, 40d);
            FontSizeSlider.Value = _fontSize = Math.Clamp(stored.FontSize, 8d, 96d);
            CornerRadiusSlider.Value = _cornerRadius = Math.Clamp(stored.CornerRadius, 0d, 64d);
            Enum.TryParse(stored.BlurKind, true, out _blurKind);
            Enum.TryParse(stored.ArrowStyle, true, out _arrowStyle);
            Enum.TryParse(stored.ArrowType, true, out _arrowType);
            Enum.TryParse(stored.ArrowBend, true, out _arrowBend);
            Enum.TryParse(stored.ArrowStartHead, true, out _arrowStartHead);
            Enum.TryParse(stored.ArrowEndHead, true, out _arrowEndHead);
        }
        catch (FormatException) { }
        finally { _suppressPropertyUpdates = false; }
    }

    private void PersistAnnotationSettings()
    {
        if (_settings is null) return;
        _settings.AnnotationPrimaryColor = _color.ToString();
        _settings.AnnotationStrokeWidth = Math.Clamp(StrokeWidth, 1d, 40d);
        _settings.AnnotationFontSize = Math.Clamp(_fontSize, 8d, 96d);
        _settings.AnnotationCornerRadius = Math.Clamp(_cornerRadius, 0d, 64d);
        PersistCurrentToolSettings();
        _saveSettings?.Invoke();
    }

    private void PersistCurrentToolSettings()
    {
        if (_settings is null || _tool is "Selection" or "Pan") return;
        _settings.AnnotationToolSettings[_tool] = new AnnotationToolSettings
        {
            Color = _color.ToString(),
            TextBackgroundColor = _textBackgroundColor?.ToString(),
            StrokeWidth = Math.Clamp(StrokeWidth, 1d, 40d),
            FontSize = Math.Clamp(_fontSize, 8d, 96d),
            CornerRadius = Math.Clamp(_cornerRadius, 0d, 64d),
            BlurKind = _blurKind.ToString(),
            ArrowStyle = _arrowStyle.ToString(),
            ArrowType = _arrowType.ToString(),
            ArrowBend = _arrowBend.ToString(),
            ArrowStartHead = _arrowStartHead.ToString(),
            ArrowEndHead = _arrowEndHead.ToString()
        };
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var source = (HwndSource)PresentationSource.FromVisual(this);
        var toDip = source.CompositionTarget.TransformFromDevice;
        var origin = toDip.Transform(new WpfPoint(_physicalBounds.Left, _physicalBounds.Top));
        var size = toDip.Transform(new WpfPoint(_physicalBounds.Width, _physicalBounds.Height));
        Left = origin.X;
        Top = origin.Y;
        Width = size.X;
        Height = size.Y;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        DimCanvas.Width = ActualWidth;
        DimCanvas.Height = ActualHeight;
        OverlayCanvas.Width = ActualWidth;
        OverlayCanvas.Height = ActualHeight;
        InstructionBadge.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(InstructionBadge, Math.Max(16, (ActualWidth - InstructionBadge.DesiredSize.Width) / 2));
        Canvas.SetTop(InstructionBadge, 24);
        UpdateDimLayer(null);
        _oneShotControlsInitializing = true;
        Canvas.SetTop(InstructionBadge, 80);
        ApplyOneShotGuideVisibility();
        OneShotVideo.IsChecked = _oneShotRecordingOptions.OutputMode != RecordingOutputMode.Gif;
        OneShotGif.IsChecked = _oneShotRecordingOptions.OutputMode == RecordingOutputMode.Gif;
        OneShotRecordingCursor.IsChecked = _oneShotRecordingOptions.IncludeCursor;
        OneShotSystemAudio.IsChecked = _oneShotRecordingOptions.SystemAudio;
        OneShotMicrophone.IsChecked = _oneShotRecordingOptions.Microphone;
        MoveIcon.ContentTemplate = (DataTemplate)FindResource("AnnotationToolbarDragIcon");
        MoveButton.ToolTip = "拖动以移动工具栏";
        _oneShotControlsInitializing = false;
        UpdateOneShotModeControls();
        SelectTool("Selection", commitOneShot: false);
        Activate();
        Focus();
    }

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        UpdateMagnifier(e.GetPosition(Root));
        if (_annotating && (_panToolActive || _spacePanActive) && e.ChangedButton == MouseButton.Left &&
            !IsWithin(Toolbar, e.OriginalSource) && !IsWithin(PropertiesBar, e.OriginalSource) &&
            !IsWithin(OneShotModePanel, e.OriginalSource))
        {
            BeginCanvasPan(e.GetPosition(SelectionHost));
            e.Handled = true;
            return;
        }
        if (_annotating || e.ChangedButton != MouseButton.Left ||
            IsWithin(OneShotSwitcher, e.OriginalSource) || IsWithin(OneShotModePanel, e.OriginalSource)) return;
        _pointerStart = ClampPoint(e.GetPosition(Root));
        _selectionRect = new Rect(_pointerStart, _pointerStart);
        _interaction = OverlayInteraction.Selecting;
        UpdateOneShotSwitcherVisibility();
        SelectionHost.Visibility = Visibility.Visible;
        SizeBadge.Visibility = Visibility.Visible;
        CaptureMouse();
        UpdateOverlayLayout();
        e.Handled = true;
    }

    private void OnWindowMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        UpdateMagnifier(e.GetPosition(Root));
        if (_panningCanvas)
        {
            var panPoint = e.GetPosition(SelectionHost);
            var panDelta = panPoint - _panPointerStart;
            SetCanvasPan(_panTransformStart.X + panDelta.X, _panTransformStart.Y + panDelta.Y);
            e.Handled = true;
            return;
        }
        if (_draggingOneShotToolbar)
        {
            if (e.LeftButton == MouseButtonState.Pressed)
                MoveOneShotToolbar(e.GetPosition(OverlayCanvas));
            e.Handled = true;
            return;
        }
        if (_draggingOneShotSwitcher)
        {
            if (e.LeftButton == MouseButtonState.Pressed)
                MoveOneShotSwitcher(e.GetPosition(OverlayCanvas));
            e.Handled = true;
            return;
        }
        if (_interaction == OverlayInteraction.None || e.LeftButton != MouseButtonState.Pressed) return;
        var point = ClampPoint(e.GetPosition(Root));
        switch (_interaction)
        {
            case OverlayInteraction.Selecting:
                _selectionRect = InlineAreaGeometry.Normalize(_pointerStart, point);
                break;
            case OverlayInteraction.MovingSelection:
                var delta = point - _pointerStart;
                _selectionRect = InlineAreaGeometry.Clamp(new Rect(
                    _interactionStartRect.X + delta.X,
                    _interactionStartRect.Y + delta.Y,
                    _interactionStartRect.Width,
                    _interactionStartRect.Height), new Size(ActualWidth, ActualHeight));
                break;
            case OverlayInteraction.ResizingSelection:
                _selectionRect = InlineAreaGeometry.Resize(_interactionStartRect, _resizeHandle, point - _pointerStart, new Size(ActualWidth, ActualHeight));
                break;
        }
        UpdateOverlayLayout();
        e.Handled = true;
    }

    private void OnWindowMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_panningCanvas && e.ChangedButton == MouseButton.Left)
        {
            _panningCanvas = false;
            SelectionHost.ReleaseMouseCapture();
            e.Handled = true;
            return;
        }
        if (_draggingOneShotToolbar && e.ChangedButton == MouseButton.Left)
        {
            EndOneShotToolbarDrag();
            e.Handled = true;
            return;
        }
        if (_draggingOneShotSwitcher && e.ChangedButton == MouseButton.Left)
        {
            EndOneShotSwitcherDrag();
            e.Handled = true;
            return;
        }
        if (_interaction == OverlayInteraction.None || e.ChangedButton != MouseButton.Left) return;
        var completedInteraction = _interaction;
        _interaction = OverlayInteraction.None;
        UpdateOneShotSwitcherVisibility();
        ReleaseMouseCapture();
        if (completedInteraction == OverlayInteraction.Selecting)
        {
            if (_selectionRect.Width < InlineAreaGeometry.MinimumSelectionSize ||
                _selectionRect.Height < InlineAreaGeometry.MinimumSelectionSize)
            {
                SelectionHost.Visibility = Visibility.Collapsed;
                SizeBadge.Visibility = Visibility.Collapsed;
                UpdateDimLayer(null);
                return;
            }
            if (_startWithOcr)
                CompleteDirectOcrSelection();
            else
                BeginAnnotating();
        }
        else
        {
            OffsetAnnotationsForSelectionChange(_selectionEditStartPixels, SelectionPixelRect());
            RefreshSelectionImage();
            SetSelectionEditingVisuals(true);
            SizeBadge.Visibility = Visibility.Collapsed;
            UpdateOverlayLayout();
        }
        e.Handled = true;
    }

    private void BeginAnnotating()
    {
        _annotating = true;
        Cursor = Cursors.Arrow;
        InstructionBadge.Visibility = Visibility.Collapsed;
        SizeBadge.Visibility = Visibility.Collapsed;
        ResizeChrome.Visibility = Visibility.Visible;
        ElementSelectionChrome.Visibility = Visibility.Visible;
        Toolbar.Visibility = _oneShotMode == OneShotMode.Screenshot ? Visibility.Visible : Visibility.Collapsed;
        PropertiesBar.Visibility = _oneShotMode == OneShotMode.Screenshot && _tool != "Selection"
            ? Visibility.Visible
            : Visibility.Collapsed;
        OneShotToolbarActions.Visibility = _oneShotMode == OneShotMode.Screenshot
            ? Visibility.Visible
            : Visibility.Collapsed;
        RefreshSelectionImage();
        UpdateOneShotModeControls();
        UpdatePropertiesBar();
        UpdateOverlayLayout();
        Magnifier.Visibility = Visibility.Collapsed;
    }

    private void CompleteDirectOcrSelection()
    {
        var crop = SelectionPixelRect();
        if (crop.Width <= 0 || crop.Height <= 0) return;
        var source = new CroppedBitmap(_backdropSource,
            new Int32Rect(crop.X, crop.Y, crop.Width, crop.Height));
        source.Freeze();
        ResultImage = BitmapSourceFactory.ToBitmap(source);
        OneShotAction = OneShotMode.Ocr;
        OneShotRectangle = OneShotPhysicalRectangle();
        _allowClose = true;
        DialogResult = true;
    }

    private void RefreshSelectionImage()
    {
        var crop = SelectionPixelRect();
        if (crop.Width <= 0 || crop.Height <= 0) return;
        _selectionRect = SelectionOverlayGeometry.ToLogical(
            crop,
            new Size(ActualWidth, ActualHeight),
            new Drawing.Rectangle(0, 0, _backdropSource.PixelWidth, _backdropSource.PixelHeight));
        _selectionSource = new CroppedBitmap(
            _backdropSource,
            new Int32Rect(crop.X, crop.Y, crop.Width, crop.Height));
        _selectionSource.Freeze();
        SelectionImage.Source = _selectionSource;
        EditorSurface.Width = crop.Width;
        EditorSurface.Height = crop.Height;
        AnnotationCanvas.Width = crop.Width;
        AnnotationCanvas.Height = crop.Height;
        ElementSelectionChrome.Width = _selectionRect.Width;
        ElementSelectionChrome.Height = _selectionRect.Height;
        UpdateElementSelectionChrome();
    }

    private Drawing.Rectangle SelectionPixelRect()
    {
        return SelectionOverlayGeometry.ToPhysical(
            _selectionRect,
            new Size(ActualWidth, ActualHeight),
            new Drawing.Rectangle(0, 0, _backdropSource.PixelWidth, _backdropSource.PixelHeight));
    }

    private void UpdateOverlayLayout()
    {
        PositionOneShotSwitcher();
        var rect = _selectionRect;
        Canvas.SetLeft(SelectionHost, rect.Left);
        Canvas.SetTop(SelectionHost, rect.Top);
        SelectionHost.Width = rect.Width;
        SelectionHost.Height = rect.Height;
        UpdateDimLayer(rect);

        var pixelRect = SelectionPixelRect();
        SizeText.Text = $"{pixelRect.Width} × {pixelRect.Height}";
        if (SizeBadge.Visibility == Visibility.Visible)
        {
            SizeBadge.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var screenBounds = GetSelectionScreenBounds(pixelRect);
            var placement = SelectionOverlayGeometry.GetSizeBadgePlacement(
                rect,
                SizeBadge.DesiredSize,
                screenBounds);
            Canvas.SetLeft(SizeBadge, placement.Origin.X);
            Canvas.SetTop(SizeBadge, placement.Origin.Y);
        }
        if (!_annotating) return;

        PositionHandle(HandleTopLeft, rect.Left, rect.Top);
        PositionHandle(HandleTop, rect.Left + rect.Width / 2, rect.Top);
        PositionHandle(HandleTopRight, rect.Right, rect.Top);
        PositionHandle(HandleRight, rect.Right, rect.Top + rect.Height / 2);
        PositionHandle(HandleBottomRight, rect.Right, rect.Bottom);
        PositionHandle(HandleBottom, rect.Left + rect.Width / 2, rect.Bottom);
        PositionHandle(HandleBottomLeft, rect.Left, rect.Bottom);
        PositionHandle(HandleLeft, rect.Left, rect.Top + rect.Height / 2);
        PositionHandle(VisualTopLeft, rect.Left, rect.Top);
        PositionHandle(VisualTop, rect.Left + rect.Width / 2, rect.Top);
        PositionHandle(VisualTopRight, rect.Right, rect.Top);
        PositionHandle(VisualRight, rect.Right, rect.Top + rect.Height / 2);
        PositionHandle(VisualBottomRight, rect.Right, rect.Bottom);
        PositionHandle(VisualBottom, rect.Left + rect.Width / 2, rect.Bottom);
        PositionHandle(VisualBottomLeft, rect.Left, rect.Bottom);
        PositionHandle(VisualLeft, rect.Left, rect.Top + rect.Height / 2);

        const double gap = 12;
        var availableWidth = Math.Max(1, ActualWidth - 32);
        ToolbarContent.Measure(new Size(double.PositiveInfinity, Toolbar.Height));
        var toolbarWidth = Math.Min(
            Math.Max(320, ToolbarContent.DesiredSize.Width + 16),
            Math.Min(900, availableWidth));
        Toolbar.Width = toolbarWidth;
        PropertiesContent.Measure(new Size(double.PositiveInfinity, PropertiesBar.Height));
        var propertiesWidth = Math.Min(
            Math.Max(320, PropertiesContent.DesiredSize.Width + 20),
            availableWidth);
        PropertiesBar.Width = propertiesWidth;
        var propertiesVisible = PropertiesBar.Visibility == Visibility.Visible;
        var stackedHeight = Toolbar.Height + (propertiesVisible ? 6 + PropertiesBar.Height : 0);
        var placeBelow = rect.Bottom + gap + stackedHeight <= ActualHeight - 16;
        var toolbarTop = placeBelow ? rect.Bottom + gap : rect.Top - stackedHeight - gap;
        toolbarTop = Math.Clamp(toolbarTop, 16, Math.Max(16, ActualHeight - stackedHeight - 16));
        var center = Math.Clamp(rect.Left + rect.Width / 2, toolbarWidth / 2 + 16, ActualWidth - toolbarWidth / 2 - 16);
        var toolbarLeft = center - toolbarWidth / 2;
        if (_oneShotToolbarLeft is { } storedLeft && _oneShotToolbarTop is { } storedTop)
        {
            toolbarLeft = Math.Clamp(storedLeft, 12, Math.Max(12, ActualWidth - toolbarWidth - 12));
            toolbarTop = Math.Clamp(storedTop, 12, Math.Max(12, ActualHeight - stackedHeight - 12));
            _oneShotToolbarLeft = toolbarLeft;
            _oneShotToolbarTop = toolbarTop;
        }
        Canvas.SetLeft(Toolbar, toolbarLeft);
        Canvas.SetTop(Toolbar, toolbarTop);
        if (propertiesVisible)
        {
            Canvas.SetLeft(PropertiesBar, Math.Clamp(center - propertiesWidth / 2, 16, Math.Max(16, ActualWidth - propertiesWidth - 16)));
            Canvas.SetTop(PropertiesBar, toolbarTop + Toolbar.Height + 6);
        }

        PositionOneShotModePanel();
    }

    private void PositionOneShotSwitcher()
    {
        if (OneShotSwitcher.Visibility != Visibility.Visible) return;
        OneShotSwitcher.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var width = Math.Min(520, Math.Max(320, ActualWidth - 24));
        OneShotSwitcher.Width = width;
        var currentLeft = Canvas.GetLeft(OneShotSwitcher);
        if (double.IsNaN(currentLeft)) currentLeft = (ActualWidth - width) / 2;
        Canvas.SetLeft(OneShotSwitcher, Math.Clamp(currentLeft, 12, Math.Max(12, ActualWidth - width - 12)));
        Canvas.SetTop(OneShotSwitcher, 12);
    }

    private void PositionOneShotModePanel()
    {
        if (OneShotModePanel.Visibility != Visibility.Visible || _selectionRect.IsEmpty) return;
        OneShotModePanel.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var width = OneShotModePanel.DesiredSize.Width;
        var height = OneShotModePanel.DesiredSize.Height;
        var left = _selectionRect.Left + (_selectionRect.Width - width) / 2;
        var top = _oneShotMode == OneShotMode.Recording
            ? _selectionRect.Top + (_selectionRect.Height - height) / 2
            : _selectionRect.Bottom + 12;
        if (_oneShotMode != OneShotMode.Recording && top + height > ActualHeight - 12)
            top = _selectionRect.Top - height - 12;
        Canvas.SetLeft(OneShotModePanel, Math.Clamp(left, 12, Math.Max(12, ActualWidth - width - 12)));
        Canvas.SetTop(OneShotModePanel, Math.Clamp(top, 12, Math.Max(12, ActualHeight - height - 12)));
    }

    private void UpdateOneShotModeControls()
    {
        UpdateOneShotSwitcherVisibility();
        foreach (var button in new[]
                 {
                     OneShotScreenshotButton, OneShotScrollingButton,
                     OneShotRecordingButton, OneShotClipboardButton
                 })
        {
            var selected = string.Equals(button.Tag?.ToString(), _oneShotMode.ToString(), StringComparison.Ordinal);
            button.Background = selected ? (Brush)FindResource("Annotation.WhiteBrush") : Brushes.Transparent;
            button.Foreground = selected ? (Brush)FindResource("Annotation.BlackBrush") : (Brush)FindResource("HudTextBrush");
            button.IsEnabled = !_oneShotCommitted || selected;
            button.Opacity = button.IsEnabled ? 1 : 0.42;
            button.ToolTip = button.IsEnabled
                ? OneShotModeTitle(button.Tag?.ToString())
                : "已开始使用当前模式，无法再切换。";
        }

        if (!_annotating)
        {
            OneShotModePanel.Visibility = Visibility.Collapsed;
            return;
        }

        var screenshot = _oneShotMode == OneShotMode.Screenshot;
        Toolbar.Visibility = screenshot ? Visibility.Visible : Visibility.Collapsed;
        OneShotToolbarActions.Visibility = screenshot ? Visibility.Visible : Visibility.Collapsed;
        UpdatePropertiesBar();
        OneShotModePanel.Visibility = screenshot ? Visibility.Collapsed : Visibility.Visible;
        OneShotScrollingPanel.Visibility = _oneShotMode == OneShotMode.Scrolling ? Visibility.Visible : Visibility.Collapsed;
        OneShotRecordingPanel.Visibility = _oneShotMode == OneShotMode.Recording ? Visibility.Visible : Visibility.Collapsed;
        if (_oneShotMode == OneShotMode.Recording)
        {
            OneShotModePanel.Width = 410;
            OneShotModePanel.Height = 206;
            OneShotModePanel.Padding = new Thickness(18);
        }
        else
        {
            OneShotModePanel.ClearValue(FrameworkElement.WidthProperty);
            OneShotModePanel.ClearValue(FrameworkElement.HeightProperty);
            OneShotModePanel.Padding = new Thickness(12);
        }
        PositionOneShotModePanel();
    }

    private static string OneShotModeTitle(string? mode) => mode switch
    {
        nameof(OneShotMode.Screenshot) => "截图",
        nameof(OneShotMode.Scrolling) => "滚动截屏",
        nameof(OneShotMode.Recording) => "录屏",
        nameof(OneShotMode.Clipboard) => "剪贴板历史",
        _ => "One Shot"
    };

    private void OnOneShotMode(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton button ||
            !Enum.TryParse(button.Tag?.ToString(), out OneShotMode requested)) return;
        if (_oneShotCommitted && requested != _oneShotMode)
        {
            ShowStatus("已开始使用当前模式，无法再切换。");
            return;
        }
        if (requested == OneShotMode.Clipboard)
        {
            OneShotAction = OneShotMode.Clipboard;
            DialogResult = true;
            return;
        }
        _oneShotMode = requested;
        UpdateOneShotModeControls();
        UpdateOverlayLayout();
    }

    private void OnOneShotDragMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || OneShotSwitcher.Visibility != Visibility.Visible) return;
        _draggingOneShotSwitcher = true;
        _oneShotPointerStart = e.GetPosition(OverlayCanvas);
        _oneShotSwitcherDragStart = Canvas.GetLeft(OneShotSwitcher);
        CaptureMouse();
        e.Handled = true;
    }

    private void OnOneShotDragMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_draggingOneShotSwitcher || e.LeftButton != MouseButtonState.Pressed) return;
        MoveOneShotSwitcher(e.GetPosition(OverlayCanvas));
        e.Handled = true;
    }

    private void OnOneShotDragMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_draggingOneShotSwitcher) return;
        EndOneShotSwitcherDrag();
        e.Handled = true;
    }

    private void MoveOneShotSwitcher(WpfPoint point)
    {
        var x = _oneShotSwitcherDragStart + point.X - _oneShotPointerStart.X;
        Canvas.SetLeft(OneShotSwitcher, Math.Clamp(x, 12, Math.Max(12, ActualWidth - OneShotSwitcher.Width - 12)));
    }

    private void EndOneShotSwitcherDrag()
    {
        if (!_draggingOneShotSwitcher) return;
        _draggingOneShotSwitcher = false;
        ReleaseMouseCapture();
    }

    internal static bool ShouldShowOneShotSwitcher(bool isCommitted, bool isDrawingSelection) =>
        !isCommitted && !isDrawingSelection;

    internal static bool ShouldMoveSelectionOnCanvasDrag(OneShotMode mode, bool isCommitted) =>
        !isCommitted && mode is OneShotMode.Screenshot or OneShotMode.Scrolling or OneShotMode.Recording;

    private void UpdateOneShotSwitcherVisibility()
    {
        var isDrawingSelection = _interaction == OverlayInteraction.Selecting;
        OneShotSwitcher.Visibility = ShouldShowOneShotSwitcher(_oneShotCommitted, isDrawingSelection)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private bool CommitOneShotMode()
    {
        if (!_annotating || _oneShotMode == OneShotMode.Clipboard) return false;
        _oneShotCommitted = true;
        UpdateOneShotModeControls();
        return true;
    }

    private Drawing.Rectangle OneShotPhysicalRectangle()
    {
        var relative = SelectionPixelRect();
        return new Drawing.Rectangle(
            _physicalBounds.Left + relative.Left,
            _physicalBounds.Top + relative.Top,
            relative.Width,
            relative.Height);
    }

    private void OnOneShotToggleScrollingHelp(object sender, RoutedEventArgs e)
    {
        OneShotScrollingHelpText.Visibility = OneShotScrollingHelpText.Visibility == Visibility.Visible
            ? Visibility.Collapsed
            : Visibility.Visible;
        PositionOneShotModePanel();
    }

    private void OnOneShotStartScrolling(object sender, RoutedEventArgs e)
    {
        if (_oneShotMode != OneShotMode.Scrolling || !CommitOneShotMode()) return;
        OneShotAction = OneShotMode.Scrolling;
        OneShotRectangle = OneShotPhysicalRectangle();
        DialogResult = true;
    }

    private void OnOneShotRecordingOptionChanged(object sender, RoutedEventArgs e)
    {
        if (_oneShotControlsInitializing || !IsLoaded || _oneShotMode != OneShotMode.Recording) return;
        CommitOneShotMode();
        _oneShotRecordingOptions = ReadOneShotRecordingOptions();
    }

    private OneShotRecordingOptions ReadOneShotRecordingOptions() => new(
        OneShotGif.IsChecked == true ? RecordingOutputMode.Gif : RecordingOutputMode.Video,
        OneShotRecordingCursor.IsChecked == true,
        OneShotSystemAudio.IsChecked == true,
        OneShotMicrophone.IsChecked == true);

    private void OnOneShotStartRecording(object sender, RoutedEventArgs e)
    {
        if (_oneShotMode != OneShotMode.Recording || !CommitOneShotMode()) return;
        OneShotAction = OneShotMode.Recording;
        OneShotRectangle = OneShotPhysicalRectangle();
        OneShotOptions = ReadOneShotRecordingOptions();
        DialogResult = true;
    }

    private void OnOneShotOcr(object sender, RoutedEventArgs e)
    {
        if (_oneShotMode != OneShotMode.Screenshot || !CommitOneShotMode()) return;
        FindVisualChildren<WpfTextBox>(AnnotationCanvas).ToList().ForEach(EndTextEditing);
        ClearElementSelection();
        _selectingOneShotOcr = true;
        _oneShotOcrRect = Rect.Empty;
        Toolbar.Visibility = Visibility.Collapsed;
        PropertiesBar.Visibility = Visibility.Collapsed;
        ResizeChrome.Visibility = Visibility.Collapsed;
        ElementSelectionChrome.Visibility = Visibility.Collapsed;
        OneShotOcrOverlay.Visibility = Visibility.Visible;
        UpdateOneShotOcrOverlay(null);
        Cursor = Cursors.Cross;
    }

    private void OnOneShotOcrMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!_selectingOneShotOcr || e.ChangedButton != MouseButton.Left) return;
        _oneShotOcrStart = ClampOneShotOcrPoint(e.GetPosition(OneShotOcrOverlay));
        _oneShotOcrRect = new Rect(_oneShotOcrStart, _oneShotOcrStart);
        OcrSelectionMarquee.Visibility = Visibility.Visible;
        OneShotOcrOverlay.CaptureMouse();
        UpdateOneShotOcrOverlay(_oneShotOcrRect);
        e.Handled = true;
    }

    private void OnOneShotOcrMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_selectingOneShotOcr || !OneShotOcrOverlay.IsMouseCaptured ||
            e.LeftButton != MouseButtonState.Pressed) return;
        _oneShotOcrRect = Normalize(_oneShotOcrStart, ClampOneShotOcrPoint(e.GetPosition(OneShotOcrOverlay)));
        UpdateOneShotOcrOverlay(_oneShotOcrRect);
        e.Handled = true;
    }

    private void OnOneShotOcrMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_selectingOneShotOcr || !OneShotOcrOverlay.IsMouseCaptured || e.ChangedButton != MouseButton.Left) return;
        _oneShotOcrRect = Normalize(_oneShotOcrStart, ClampOneShotOcrPoint(e.GetPosition(OneShotOcrOverlay)));
        OneShotOcrOverlay.ReleaseMouseCapture();
        e.Handled = true;
        if (_oneShotOcrRect.Width < 6 || _oneShotOcrRect.Height < 6)
        {
            _oneShotOcrRect = Rect.Empty;
            UpdateOneShotOcrOverlay(null);
            return;
        }

        if (_selectionSource is null || _isCompleting) return;
        _isCompleting = true;
        try
        {
            var sourceRect = OneShotOcrPixelRect(_oneShotOcrRect, _selectionSource);
            var crop = new CroppedBitmap(_selectionSource, sourceRect);
            crop.Freeze();
            ResultImage = BitmapSourceFactory.ToBitmap(crop);
            var selectionPixels = SelectionPixelRect();
            OneShotRectangle = new Drawing.Rectangle(
                _physicalBounds.Left + selectionPixels.Left + sourceRect.X,
                _physicalBounds.Top + selectionPixels.Top + sourceRect.Y,
                sourceRect.Width,
                sourceRect.Height);
            OneShotAction = OneShotMode.Ocr;
            DialogResult = true;
        }
        catch
        {
            _isCompleting = false;
            throw;
        }
    }

    private WpfPoint ClampOneShotOcrPoint(WpfPoint point) => new(
        Math.Clamp(point.X, 0, Math.Max(0, SelectionHost.ActualWidth)),
        Math.Clamp(point.Y, 0, Math.Max(0, SelectionHost.ActualHeight)));

    private void UpdateOneShotOcrOverlay(Rect? selection)
    {
        var bounds = new Size(SelectionHost.ActualWidth, SelectionHost.ActualHeight);
        var regions = SelectionOverlayGeometry.CreateDimRegions(selection, bounds);
        SetCanvasRect(OcrDimTop, regions.Top);
        SetCanvasRect(OcrDimLeft, regions.Left);
        SetCanvasRect(OcrDimRight, regions.Right);
        SetCanvasRect(OcrDimBottom, regions.Bottom);
        if (selection is { } rect && !rect.IsEmpty)
        {
            SetCanvasRect(OcrSelectionMarquee, rect);
            OcrSelectionMarquee.Visibility = Visibility.Visible;
        }
        else
        {
            OcrSelectionMarquee.Visibility = Visibility.Collapsed;
        }
    }

    private Int32Rect OneShotOcrPixelRect(Rect logicalRect, BitmapSource source)
    {
        var logicalWidth = Math.Max(1, SelectionHost.ActualWidth);
        var logicalHeight = Math.Max(1, SelectionHost.ActualHeight);
        var left = Math.Clamp((int)Math.Floor(logicalRect.Left / logicalWidth * source.PixelWidth), 0, source.PixelWidth - 1);
        var top = Math.Clamp((int)Math.Floor(logicalRect.Top / logicalHeight * source.PixelHeight), 0, source.PixelHeight - 1);
        var right = Math.Clamp((int)Math.Ceiling(logicalRect.Right / logicalWidth * source.PixelWidth), left + 1, source.PixelWidth);
        var bottom = Math.Clamp((int)Math.Ceiling(logicalRect.Bottom / logicalHeight * source.PixelHeight), top + 1, source.PixelHeight);
        return new Int32Rect(left, top, right - left, bottom - top);
    }

    private void UpdateDimLayer(Rect? selection)
    {
        var regions = SelectionOverlayGeometry.CreateDimRegions(selection, new Size(ActualWidth, ActualHeight));
        SetCanvasRect(DimTop, regions.Top);
        SetCanvasRect(DimLeft, regions.Left);
        SetCanvasRect(DimRight, regions.Right);
        SetCanvasRect(DimBottom, regions.Bottom);
    }

    private static void SetCanvasRect(FrameworkElement element, Rect rect)
    {
        if (rect.IsEmpty)
        {
            Canvas.SetLeft(element, 0); Canvas.SetTop(element, 0);
            element.Width = 0; element.Height = 0;
            return;
        }
        Canvas.SetLeft(element, rect.X); Canvas.SetTop(element, rect.Y);
        element.Width = Math.Max(0, rect.Width); element.Height = Math.Max(0, rect.Height);
    }

    private static void PositionHandle(FrameworkElement handle, double x, double y)
    {
        Canvas.SetLeft(handle, x - handle.Width / 2);
        Canvas.SetTop(handle, y - handle.Height / 2);
    }

    private void OnResizeMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement element) return;
        _resizeHandle = element.Tag?.ToString() ?? string.Empty;
        _interaction = OverlayInteraction.ResizingSelection;
        _interactionStartRect = _selectionRect;
        _selectionEditStartPixels = SelectionPixelRect();
        _pointerStart = e.GetPosition(Root);
        SetSelectionEditingVisuals(false);
        SizeBadge.Visibility = Visibility.Visible;
        UpdateOverlayLayout();
        CaptureMouse();
        e.Handled = true;
    }

    private void OnMoveMouseDown(object sender, MouseButtonEventArgs e)
    {
        _draggingOneShotToolbar = true;
        _oneShotToolbarPointerStart = e.GetPosition(OverlayCanvas);
        _oneShotToolbarLeft = Canvas.GetLeft(Toolbar);
        _oneShotToolbarTop = Canvas.GetTop(Toolbar);
        CaptureMouse();
        e.Handled = true;
    }

    private void OnToolbarMoveMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_draggingOneShotToolbar || e.LeftButton != MouseButtonState.Pressed) return;
        MoveOneShotToolbar(e.GetPosition(OverlayCanvas));
        e.Handled = true;
    }

    private void MoveOneShotToolbar(WpfPoint point)
    {
        var startLeft = _oneShotToolbarLeft ?? Canvas.GetLeft(Toolbar);
        var startTop = _oneShotToolbarTop ?? Canvas.GetTop(Toolbar);
        var left = startLeft + point.X - _oneShotToolbarPointerStart.X;
        var top = startTop + point.Y - _oneShotToolbarPointerStart.Y;
        left = Math.Clamp(left, 12, Math.Max(12, ActualWidth - Toolbar.ActualWidth - 12));
        top = Math.Clamp(top, 12, Math.Max(12, ActualHeight - Toolbar.ActualHeight - 12));
        Canvas.SetLeft(Toolbar, left);
        Canvas.SetTop(Toolbar, top);
    }

    private void OnToolbarMoveMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_draggingOneShotToolbar) return;
        EndOneShotToolbarDrag();
        e.Handled = true;
    }

    private void EndOneShotToolbarDrag()
    {
        if (!_draggingOneShotToolbar) return;
        _draggingOneShotToolbar = false;
        _oneShotToolbarLeft = Canvas.GetLeft(Toolbar);
        _oneShotToolbarTop = Canvas.GetTop(Toolbar);
        ReleaseMouseCapture();
    }

    private void BeginMoveSelection(WpfPoint point)
    {
        _interaction = OverlayInteraction.MovingSelection;
        _interactionStartRect = _selectionRect;
        _selectionEditStartPixels = SelectionPixelRect();
        _pointerStart = point;
        SetSelectionEditingVisuals(false);
        SizeBadge.Visibility = Visibility.Visible;
        UpdateOverlayLayout();
        CaptureMouse();
    }

    private Rect GetSelectionScreenBounds(Drawing.Rectangle relativePixelRect)
    {
        var physicalSelection = new Drawing.Rectangle(
            _physicalBounds.Left + relativePixelRect.Left,
            _physicalBounds.Top + relativePixelRect.Top,
            relativePixelRect.Width,
            relativePixelRect.Height);
        var physicalScreen = System.Windows.Forms.Screen.FromRectangle(physicalSelection).Bounds;
        var relativeScreen = new Drawing.Rectangle(
            physicalScreen.Left - _physicalBounds.Left,
            physicalScreen.Top - _physicalBounds.Top,
            physicalScreen.Width,
            physicalScreen.Height);
        var logicalScreen = SelectionOverlayGeometry.ToLogical(
            relativeScreen,
            new Size(ActualWidth, ActualHeight),
            new Drawing.Rectangle(0, 0, _backdropSource.PixelWidth, _backdropSource.PixelHeight));
        return logicalScreen.IsEmpty ? new Rect(0, 0, ActualWidth, ActualHeight) : logicalScreen;
    }

    private void SetSelectionEditingVisuals(bool visible)
    {
        var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        EditorViewbox.Visibility = visibility;
        ElementSelectionChrome.Visibility = visibility;
        ResizeChrome.Visibility = visibility;
        var screenshotToolsVisible = visible && _oneShotMode == OneShotMode.Screenshot;
        Toolbar.Visibility = screenshotToolsVisible ? Visibility.Visible : Visibility.Collapsed;
        OneShotToolbarActions.Visibility = screenshotToolsVisible ? Visibility.Visible : Visibility.Collapsed;
        if (visible) UpdatePropertiesBar();
        else PropertiesBar.Visibility = Visibility.Collapsed;
    }

    private WpfPoint ClampPoint(WpfPoint point) => new(Math.Clamp(point.X, 0, ActualWidth), Math.Clamp(point.Y, 0, ActualHeight));
    private static Rect Normalize(WpfPoint a, WpfPoint b) => InlineAreaGeometry.Normalize(a, b);

    private void UpdateMagnifier(WpfPoint point)
    {
        if (_annotating || _selectingOneShotOcr || _settings?.ScreenshotMagnifierEnabled == false ||
            _backdropSource.PixelWidth <= 0 || _backdropSource.PixelHeight <= 0)
        {
            Magnifier.Visibility = Visibility.Collapsed;
            return;
        }

        var x = Math.Clamp((int)Math.Floor(point.X / Math.Max(1d, ActualWidth) * _backdropSource.PixelWidth),
            0, _backdropSource.PixelWidth - 1);
        var y = Math.Clamp((int)Math.Floor(point.Y / Math.Max(1d, ActualHeight) * _backdropSource.PixelHeight),
            0, _backdropSource.PixelHeight - 1);
        var zoom = Math.Clamp(_settings?.ScreenshotMagnifierZoom ?? 1, 1, 20);
        var radius = Math.Max(2, 8 - zoom / 3);
        var left = Math.Max(0, x - radius);
        var top = Math.Max(0, y - radius);
        var width = Math.Min(_backdropSource.PixelWidth - left, radius * 2 + 1);
        var height = Math.Min(_backdropSource.PixelHeight - top, radius * 2 + 1);
        var crop = new CroppedBitmap(_backdropSource, new Int32Rect(left, top, width, height));
        crop.Freeze();
        MagnifierImage.Source = crop;

        var pixel = new CroppedBitmap(_backdropSource, new Int32Rect(x, y, 1, 1));
        var bytes = new byte[Math.Max(4, (pixel.Format.BitsPerPixel + 7) / 8)];
        pixel.CopyPixels(bytes, bytes.Length, 0);
        var b = bytes[0];
        var g = bytes.Length > 1 ? bytes[1] : b;
        var r = bytes.Length > 2 ? bytes[2] : b;
        _magnifierHex = $"#{r:X2}{g:X2}{b:X2}";
        _magnifierRgb = $"RGB({r}, {g}, {b})";
        MagnifierCoordinateText.Text = $"X {x + _physicalBounds.Left}  Y {y + _physicalBounds.Top}";
        MagnifierColorText.Text = _hexMagnifier ? $"HEX: {_magnifierHex}" : $"RGB: {_magnifierRgb}";

        Magnifier.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        const double gap = 18;
        var magnifierLeft = point.X + gap;
        var magnifierTop = point.Y + gap;
        if (magnifierLeft + Magnifier.Width > ActualWidth - 8) magnifierLeft = point.X - gap - Magnifier.Width;
        if (magnifierTop + Magnifier.Height > ActualHeight - 8) magnifierTop = point.Y - gap - Magnifier.Height;
        Canvas.SetLeft(Magnifier, Math.Clamp(magnifierLeft, 8, Math.Max(8, ActualWidth - Magnifier.Width - 8)));
        Canvas.SetTop(Magnifier, Math.Clamp(magnifierTop, 8, Math.Max(8, ActualHeight - Magnifier.Height - 8)));
        Magnifier.Visibility = Visibility.Visible;
    }

    private void ApplyOneShotGuideVisibility()
    {
        if (_settings is null) return;
        var guideVersion = typeof(InlineAnnotateWindow).Assembly.GetName().Version?.ToString(2) ?? "1.0";
        if (string.Equals(_settings.LastOneShotGuideVersion, guideVersion, StringComparison.Ordinal))
        {
            InstructionBadge.Visibility = Visibility.Collapsed;
            return;
        }
        InstructionBadge.Visibility = Visibility.Visible;
        _settings.LastOneShotGuideVersion = guideVersion;
        _saveSettings?.Invoke();
    }

    private async void OnShowOneShotGuide(object sender, RoutedEventArgs e)
    {
        InstructionBadge.Visibility = Visibility.Visible;
        await Task.Delay(TimeSpan.FromSeconds(6));
        if (IsLoaded) InstructionBadge.Visibility = Visibility.Collapsed;
    }

    private void OffsetAnnotationsForSelectionChange(Drawing.Rectangle previous, Drawing.Rectangle current)
    {
        if (previous.Width <= 0 || previous.Height <= 0) return;
        var deltaX = previous.Left - current.Left;
        var deltaY = previous.Top - current.Top;
        if (deltaX == 0 && deltaY == 0) return;
        foreach (UIElement element in AnnotationCanvas.Children)
        {
            if (_elementStyles.TryGetValue(element, out var style) && style.Tool == "Spotlight")
            {
                var moved = style.Copy();
                moved.Start += new Vector(deltaX, deltaY);
                moved.End += new Vector(deltaX, deltaY);
                ApplyElementStyle(element, moved);
                continue;
            }
            var matrix = element.RenderTransform?.Value ?? Matrix.Identity;
            matrix.Translate(deltaX, deltaY);
            element.RenderTransform = new MatrixTransform(matrix);
        }
    }

    private void OnSelectTool(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton button) return;
        var tool = button.Tag?.ToString() ?? "Selection";
        if (tool == "Pan")
        {
            _panToolActive = true;
            PanButton.Background = (Brush)FindResource("HudSelectedBrush");
            AnnotationCanvas.Cursor = Cursors.Hand;
            return;
        }
        _panToolActive = false;
        PanButton.Background = Brushes.Transparent;
        SelectTool(tool);
    }

    private void SelectTool(string tool, bool commitOneShot = true)
    {
        if (commitOneShot && _oneShotMode == OneShotMode.Screenshot && !CommitOneShotMode()) return;
        PersistCurrentToolSettings();
        _tool = tool;
        ApplyPersistedToolSettings(tool);
        foreach (var button in FindVisualChildren<WpfButton>(Toolbar).Where(x => _toolNames.ContainsKey(x.Tag?.ToString() ?? string.Empty)))
            button.Background = button.Tag?.ToString() == tool ? (Brush)FindResource("HudSelectedBrush") : Brushes.Transparent;
        ContextPillText.Text = _toolNames.GetValueOrDefault(tool, tool);
        AnnotationCanvas.Cursor = tool switch
        {
            "Text" => Cursors.IBeam,
            "Selection" => Cursors.Arrow,
            _ => Cursors.Cross
        };
        UpdateAnnotationCursors();
        UpdateElementSelectionChrome();
        UpdatePropertiesBar();
        UpdateOverlayLayout();
    }

    private void OnZoomPresetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CanvasZoomPicker?.SelectedItem is ComboBoxItem { Tag: string tag } &&
            double.TryParse(tag, System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var zoom))
            SetCanvasZoom(zoom, new WpfPoint(SelectionHost.ActualWidth / 2, SelectionHost.ActualHeight / 2));
    }

    private void OnZoomFit(object sender, RoutedEventArgs e) =>
        SetCanvasZoom(1d, new WpfPoint(SelectionHost.ActualWidth / 2, SelectionHost.ActualHeight / 2), resetPan: true);

    private void OnZoomOut(object sender, RoutedEventArgs e) => ZoomBy(1d / 1.25d);
    private void OnZoomIn(object sender, RoutedEventArgs e) => ZoomBy(1.25d);

    private void ZoomBy(double factor) => SetCanvasZoom(
        _canvasZoom * factor,
        new WpfPoint(SelectionHost.ActualWidth / 2, SelectionHost.ActualHeight / 2));

    private void OnEditorMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (!_annotating) return;
        var factor = e.Delta > 0 ? 1.15d : 1d / 1.15d;
        SetCanvasZoom(_canvasZoom * factor, e.GetPosition(SelectionHost));
        e.Handled = true;
    }

    private void OnEditorManipulationDelta(object sender, ManipulationDeltaEventArgs e)
    {
        if (!_annotating) return;
        SetCanvasZoom(_canvasZoom * e.DeltaManipulation.Scale.X, e.ManipulationOrigin);
        SetCanvasPan(
            EditorPanTransform.X + e.DeltaManipulation.Translation.X,
            EditorPanTransform.Y + e.DeltaManipulation.Translation.Y);
        e.Handled = true;
    }

    private void SetCanvasZoom(double requested, WpfPoint center, bool resetPan = false)
    {
        var next = Math.Clamp(requested, 0.25d, 8d);
        if (resetPan)
        {
            EditorPanTransform.X = 0;
            EditorPanTransform.Y = 0;
        }
        else if (Math.Abs(next - _canvasZoom) > 0.0001)
        {
            var ratio = next / _canvasZoom;
            EditorPanTransform.X = center.X - (center.X - EditorPanTransform.X) * ratio;
            EditorPanTransform.Y = center.Y - (center.Y - EditorPanTransform.Y) * ratio;
        }
        _canvasZoom = next;
        EditorZoomTransform.ScaleX = next;
        EditorZoomTransform.ScaleY = next;
        if (CanvasZoomPicker is not null) CanvasZoomPicker.Text = $"{next * 100:0}%";
        ClampCanvasPan();
        UpdateElementSelectionChrome();
    }

    private void SetCanvasPan(double x, double y)
    {
        EditorPanTransform.X = x;
        EditorPanTransform.Y = y;
        ClampCanvasPan();
        UpdateElementSelectionChrome();
    }

    private void ClampCanvasPan()
    {
        var overflowX = Math.Max(0d, SelectionHost.ActualWidth * (_canvasZoom - 1d));
        var overflowY = Math.Max(0d, SelectionHost.ActualHeight * (_canvasZoom - 1d));
        EditorPanTransform.X = Math.Clamp(EditorPanTransform.X, -overflowX, 0d);
        EditorPanTransform.Y = Math.Clamp(EditorPanTransform.Y, -overflowY, 0d);
    }

    private void BeginCanvasPan(WpfPoint point)
    {
        _panningCanvas = true;
        _panPointerStart = point;
        _panTransformStart = new Vector(EditorPanTransform.X, EditorPanTransform.Y);
        SelectionHost.CaptureMouse();
    }

    private void UpdateAnnotationCursors()
    {
        foreach (var element in _elementTools.Keys.OfType<FrameworkElement>())
        {
            if (_tool == "Selection") element.Cursor = Cursors.SizeAll;
            else element.ClearValue(FrameworkElement.CursorProperty);
        }
    }

    private AnnotationStyle CreateCurrentStyle(string tool) => new()
    {
        Tool = tool,
        StrokeColor = _color,
        TextBackgroundColor = _textBackgroundColor,
        StrokeWidth = StrokeWidth,
        FontSize = _fontSize,
        CornerRadius = _cornerRadius,
        Blur = _blurKind,
        ArrowStyle = _arrowStyle,
        ArrowType = _arrowType,
        ArrowBend = _arrowBend,
        StartHead = _arrowStartHead,
        EndHead = _arrowEndHead,
        Start = _drawStart,
        End = _drawStart
    };

    private void ApplyElementStyle(UIElement element, AnnotationStyle style)
    {
        _elementStyles[element] = style.Copy();
        _elementTools[element] = style.Tool;
        var stroke = new SolidColorBrush(style.StrokeColor);

        switch (element)
        {
            case Border textHost when style.Tool == "Text" && textHost.Child is WpfTextBox textBox:
                textBox.Foreground = stroke;
                textBox.FontSize = style.FontSize;
                textBox.Background = Brushes.Transparent;
                textHost.Background = style.TextBackgroundColor is { } background
                    ? new SolidColorBrush(background)
                    : Brushes.Transparent;
                textHost.CornerRadius = new CornerRadius(style.CornerRadius);
                break;
            case Border counter when style.Tool == "Counter":
                counter.Background = stroke;
                var diameter = Math.Clamp(18 + style.StrokeWidth * 3, 24, 72);
                counter.Width = diameter;
                counter.Height = diameter;
                counter.CornerRadius = new CornerRadius(diameter / 2);
                if (counter.Child is TextBlock label) label.FontSize = Math.Clamp(diameter * 0.46, 12, 30);
                break;
            case WpfPath arrow when style.Tool == "Arrow":
                ApplyArrowStyle(arrow, style);
                break;
            case WpfPath spotlight when style.Tool == "Spotlight":
                ApplySpotlightStyle(spotlight, style);
                break;
            case Grid blur when style.Tool == "Blur":
                RebuildBlurEffect(blur, style);
                break;
            case Polyline freehand:
                freehand.Stroke = stroke;
                freehand.StrokeThickness = style.Tool == "Highlighter"
                    ? style.StrokeWidth * 4
                    : style.StrokeWidth;
                break;
            case Line line:
                line.Stroke = stroke;
                line.StrokeThickness = style.StrokeWidth;
                line.X1 = style.Start.X;
                line.Y1 = style.Start.Y;
                line.X2 = style.End.X;
                line.Y2 = style.End.Y;
                break;
            case WpfRectangle rectangle:
                rectangle.Stroke = stroke;
                rectangle.StrokeThickness = style.StrokeWidth;
                rectangle.RadiusX = style.CornerRadius;
                rectangle.RadiusY = style.CornerRadius;
                rectangle.Fill = style.Tool == "FilledRectangle" ? stroke : Brushes.Transparent;
                break;
            case Ellipse ellipse:
                ellipse.Stroke = stroke;
                ellipse.StrokeThickness = style.StrokeWidth;
                break;
        }
    }

    private void ApplyArrowStyle(WpfPath arrow, AnnotationStyle style)
    {
        var control = ArrowControlPoint(style);
        var color = new SolidColorBrush(style.StrokeColor);
        arrow.Effect = new System.Windows.Media.Effects.DropShadowEffect
        {
            Color = (WpfColor)FindResource("ShadowColor"),
            BlurRadius = style.ArrowType == ArrowTypeKind.Classic ? 2 : 4.5,
            ShadowDepth = style.ArrowType == ArrowTypeKind.Classic ? 1 : 2,
            Opacity = style.ArrowType == ArrowTypeKind.Classic ? 0.2 : 0.3,
            RenderingBias = System.Windows.Media.Effects.RenderingBias.Quality
        };
        if (style.ArrowType == ArrowTypeKind.Classic)
        {
            arrow.Data = AnnotationArrowGeometry.CreateClassic(
                style.Start,
                style.End,
                control,
                style.StrokeWidth,
                style.StartHead,
                style.EndHead);
            arrow.Fill = color;
            arrow.Stroke = color;
            arrow.StrokeThickness = style.StrokeWidth;
            arrow.StrokeStartLineCap = PenLineCap.Round;
            arrow.StrokeEndLineCap = PenLineCap.Round;
            return;
        }

        arrow.Data = AnnotationArrowGeometry.CreateCurved(
            style.Start,
            style.End,
            control,
            style.StrokeWidth,
            style.StartHead,
            style.EndHead);
        arrow.Fill = color;
        if (style.ArrowType == ArrowTypeKind.Outlined)
        {
            arrow.Stroke = (Brush)FindResource("Annotation.WhiteBrush");
            arrow.StrokeThickness = Math.Max(1.5, 1.1 + style.StrokeWidth * 0.32);
            arrow.StrokeLineJoin = PenLineJoin.Round;
        }
        else
        {
            arrow.Stroke = null;
            arrow.StrokeThickness = 0;
        }
    }

    private static WpfPoint ArrowControlPoint(AnnotationStyle style)
    {
        var midpoint = new WpfPoint(
            (style.Start.X + style.End.X) / 2,
            (style.Start.Y + style.End.Y) / 2);
        if (style.ArrowStyle == ArrowStyleKind.Straight) return midpoint;
        var chord = style.End - style.Start;
        if (chord.Length < 0.5) return midpoint;
        var normal = new Vector(-chord.Y, chord.X);
        normal.Normalize();
        var direction = style.ArrowStyle == ArrowStyleKind.CurvedRight ? 1d : -1d;
        if (style.ArrowBend == ArrowBendKind.Alternate) direction *= -1;
        return midpoint + normal * Math.Clamp(chord.Length * 0.28, 18, 180) * direction;
    }

    private void ApplySpotlightStyle(WpfPath spotlight, AnnotationStyle style)
    {
        var aperture = Normalize(style.Start, style.End);
        var geometry = new GeometryGroup { FillRule = FillRule.EvenOdd };
        geometry.Children.Add(new RectangleGeometry(new Rect(0, 0, AnnotationCanvas.Width, AnnotationCanvas.Height)));
        geometry.Children.Add(new RectangleGeometry(aperture, style.CornerRadius, style.CornerRadius));
        spotlight.Data = geometry;
    }

    private Grid? MakeBlurEffect(Rect bounds, AnnotationStyle style)
    {
        if (_selectionSource is null || bounds.Width < 2 || bounds.Height < 2) return null;
        var host = new Grid
        {
            Width = bounds.Width,
            Height = bounds.Height,
            ClipToBounds = true,
            IsHitTestVisible = true
        };
        Canvas.SetLeft(host, bounds.X);
        Canvas.SetTop(host, bounds.Y);
        RebuildBlurEffect(host, style);
        return host;
    }

    private void RebuildBlurEffect(Grid host, AnnotationStyle style)
    {
        if (_selectionSource is null) return;
        var sampleBounds = GetElementBounds(host);
        var x = Math.Clamp((int)Math.Floor(sampleBounds.Left), 0, _selectionSource.PixelWidth - 1);
        var y = Math.Clamp((int)Math.Floor(sampleBounds.Top), 0, _selectionSource.PixelHeight - 1);
        var width = Math.Clamp((int)Math.Ceiling(sampleBounds.Width), 1, _selectionSource.PixelWidth - x);
        var height = Math.Clamp((int)Math.Ceiling(sampleBounds.Height), 1, _selectionSource.PixelHeight - y);
        var cropped = new CroppedBitmap(_selectionSource, new Int32Rect(x, y, width, height));
        cropped.Freeze();

        var image = new WpfImage { Width = host.Width, Height = host.Height, Stretch = Stretch.Fill };
        if (style.Blur == BlurKind.Gaussian)
        {
            image.Source = cropped;
            image.Effect = new System.Windows.Media.Effects.BlurEffect
            {
                Radius = Math.Clamp(2 + style.StrokeWidth * 1.5, 3, 32),
                KernelType = System.Windows.Media.Effects.KernelType.Gaussian,
                RenderingBias = System.Windows.Media.Effects.RenderingBias.Quality
            };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
        }
        else
        {
            var factor = Math.Clamp(3 + style.StrokeWidth * 1.6, 4, Math.Max(4, Math.Min(width, height)));
            var tiny = new TransformedBitmap(cropped, new ScaleTransform(1d / factor, 1d / factor));
            tiny.Freeze();
            image.Source = tiny;
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        }

        host.Children.Clear();
        host.Children.Add(image);
        if (style.Blur is not (BlurKind.Pixelated or BlurKind.Gaussian))
            host.Children.Add(CreateBlurPattern(style));
    }

    private static WpfRectangle CreateBlurPattern(AnnotationStyle style)
    {
        var spacing = Math.Clamp(5 + style.StrokeWidth, 6, 24);
        var group = new DrawingGroup();
        var pen = new System.Windows.Media.Pen(new SolidColorBrush(WpfColor.FromArgb(92, 255, 255, 255)), 1);
        var fill = new SolidColorBrush(WpfColor.FromArgb(72, 0, 0, 0));
        switch (style.Blur)
        {
            case BlurKind.Hexagonal:
                group.Children.Add(new GeometryDrawing(null, pen,
                    Geometry.Parse($"M {spacing * .25},0 L {spacing * .75},0 {spacing},{spacing * .5} {spacing * .75},{spacing} {spacing * .25},{spacing} 0,{spacing * .5} Z")));
                break;
            case BlurKind.Crystallized:
                group.Children.Add(new GeometryDrawing(null, pen,
                    Geometry.Parse($"M 0,0 L {spacing},{spacing} M {spacing},0 L 0,{spacing}")));
                break;
            case BlurKind.Pointillism:
                group.Children.Add(new GeometryDrawing(fill, null,
                    new EllipseGeometry(new WpfPoint(spacing / 2, spacing / 2), spacing * .22, spacing * .22)));
                break;
            case BlurKind.Halftone:
                group.Children.Add(new GeometryDrawing(fill, null,
                    new EllipseGeometry(new WpfPoint(spacing * .35, spacing * .35), spacing * .27, spacing * .27)));
                group.Children.Add(new GeometryDrawing(fill, null,
                    new EllipseGeometry(new WpfPoint(spacing * .82, spacing * .82), spacing * .12, spacing * .12)));
                break;
            case BlurKind.Tape:
                group.Children.Add(new GeometryDrawing(fill, null,
                    Geometry.Parse($"M 0,{spacing * .25} L {spacing * .75},{spacing} {spacing},{spacing * .75} {spacing * .25},0 Z")));
                break;
            case BlurKind.Washi:
                group.Children.Add(new GeometryDrawing(null, pen,
                    Geometry.Parse($"M 0,{spacing * .25} C {spacing * .25},0 {spacing * .75},{spacing} {spacing},{spacing * .7}")));
                break;
        }
        var brush = new DrawingBrush(group)
        {
            TileMode = TileMode.Tile,
            ViewportUnits = BrushMappingMode.Absolute,
            Viewport = new Rect(0, 0, spacing, spacing),
            Stretch = Stretch.None
        };
        return new WpfRectangle { Fill = brush, IsHitTestVisible = false, Opacity = 0.85 };
    }

    private void OnColorSelected(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton button || button.Tag is not string tag) return;
        if (IsLoaded && _annotating && _oneShotMode == OneShotMode.Screenshot && !CommitOneShotMode()) return;
        var parts = tag.Split(':', 2);
        if (parts.Length != 2) return;
        var color = parts[1].Equals("Clear", StringComparison.OrdinalIgnoreCase)
            ? (WpfColor?)null
            : (WpfColor)ColorConverter.ConvertFromString(parts[1]);

        switch (parts[0])
        {
            case "Stroke" when color is { } stroke:
                if (!MutateSelectedStyles(SupportsStrokeColor, style => style.StrokeColor = stroke))
                    _color = stroke;
                PersistCurrentToolSettings();
                break;
            case "TextBackground":
                if (!MutateSelectedStyles(style => style.Tool == "Text", style => style.TextBackgroundColor = color))
                    _textBackgroundColor = color;
                PersistCurrentToolSettings();
                break;
        }
        UpdatePropertiesBar();
    }

    private void OnStrokeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (StrokeValue is not null) StrokeValue.Text = Math.Round(e.NewValue).ToString();
        if (_suppressPropertyUpdates || !IsLoaded) return;
        if (IsLoaded && _annotating && _oneShotMode == OneShotMode.Screenshot)
            CommitOneShotMode();
        if (!MutateSelectedStyles(SupportsStrokeWidth, style => style.StrokeWidth = e.NewValue,
                recordHistory: _propertyEditBefore is null))
            PersistCurrentToolSettings();
    }

    private void OnFontSizeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (FontSizeValue is not null) FontSizeValue.Text = Math.Round(e.NewValue).ToString();
        if (_suppressPropertyUpdates || !IsLoaded) return;
        if (!MutateSelectedStyles(style => style.Tool == "Text", style => style.FontSize = e.NewValue,
                recordHistory: _propertyEditBefore is null))
            _fontSize = e.NewValue;
        PersistCurrentToolSettings();
    }

    private void OnCornerRadiusChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (CornerRadiusValue is not null) CornerRadiusValue.Text = Math.Round(e.NewValue).ToString();
        if (_suppressPropertyUpdates || !IsLoaded) return;
        if (!MutateSelectedStyles(SupportsCornerRadius, style => style.CornerRadius = e.NewValue,
                recordHistory: _propertyEditBefore is null))
            _cornerRadius = e.NewValue;
        PersistCurrentToolSettings();
    }

    private void OnPropertySliderStarted(object sender, MouseButtonEventArgs e)
    {
        _propertyEditBefore = SnapshotStyles(_selectedElements);
    }

    private void OnPropertySliderCompleted(object sender, MouseButtonEventArgs e)
    {
        if (_propertyEditBefore is not { Count: > 0 } before)
        {
            _propertyEditBefore = null;
            return;
        }
        var after = SnapshotStyles(before.Keys);
        _propertyEditBefore = null;
        PushStyleEdit(before, after);
    }

    private void OnPropertyOptionSelected(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton { Tag: string tag }) return;
        if (!CommitOneShotMode()) return;
        var parts = tag.Split(':', 2);
        if (parts.Length != 2) return;
        switch (parts[0])
        {
            case "Blur" when Enum.TryParse(parts[1], true, out BlurKind blur):
                if (!MutateSelectedStyles(style => style.Tool == "Blur", style => style.Blur = blur))
                    _blurKind = blur;
                break;
            case "ArrowStyle" when Enum.TryParse(parts[1], true, out ArrowStyleKind arrowStyle):
                if (!MutateSelectedStyles(style => style.Tool == "Arrow", style => style.ArrowStyle = arrowStyle))
                    _arrowStyle = arrowStyle;
                break;
            case "ArrowType" when Enum.TryParse(parts[1], true, out ArrowTypeKind arrowType):
                if (!MutateSelectedStyles(style => style.Tool == "Arrow", style => style.ArrowType = arrowType))
                    _arrowType = arrowType;
                break;
            case "ArrowBend" when Enum.TryParse(parts[1], true, out ArrowBendKind bend):
                if (!MutateSelectedStyles(style => style.Tool == "Arrow", style => style.ArrowBend = bend))
                    _arrowBend = bend;
                break;
            case "StartHead" when Enum.TryParse(parts[1], true, out AnnotationArrowGeometry.TipStyle startHead):
                if (!MutateSelectedStyles(style => style.Tool == "Arrow", style => style.StartHead = startHead))
                    _arrowStartHead = startHead;
                break;
            case "EndHead" when Enum.TryParse(parts[1], true, out AnnotationArrowGeometry.TipStyle endHead):
                if (!MutateSelectedStyles(style => style.Tool == "Arrow", style => style.EndHead = endHead))
                    _arrowEndHead = endHead;
                break;
        }
        PersistCurrentToolSettings();
        UpdatePropertiesBar();
    }

    private bool MutateSelectedStyles(
        Func<AnnotationStyle, bool> predicate,
        Action<AnnotationStyle> mutation,
        bool recordHistory = true)
    {
        var targets = _selectedElements
            .Where(element => _elementStyles.TryGetValue(element, out var style) && predicate(style))
            .ToArray();
        if (targets.Length == 0) return false;
        var before = SnapshotStyles(targets);
        foreach (var element in targets)
        {
            var style = _elementStyles[element].Copy();
            mutation(style);
            ApplyElementStyle(element, style);
        }
        if (recordHistory) PushStyleEdit(before, SnapshotStyles(targets));
        UpdateElementSelectionChrome();
        return true;
    }

    private Dictionary<UIElement, AnnotationStyle> SnapshotStyles(IEnumerable<UIElement> elements) =>
        elements.Where(_elementStyles.ContainsKey)
            .ToDictionary(element => element, element => _elementStyles[element].Copy());

    private void PushStyleEdit(
        Dictionary<UIElement, AnnotationStyle> before,
        Dictionary<UIElement, AnnotationStyle> after)
    {
        if (before.Count == 0 || after.Count == 0) return;
        PushEdit(
            () => RestoreStyles(before),
            () => RestoreStyles(after));
    }

    private void RestoreStyles(IReadOnlyDictionary<UIElement, AnnotationStyle> styles)
    {
        foreach (var (element, style) in styles)
            if (AnnotationCanvas.Children.Contains(element)) ApplyElementStyle(element, style);
        UpdatePropertiesBar();
        UpdateElementSelectionChrome();
    }

    private static bool SupportsStrokeColor(AnnotationStyle style) => style.Tool is
        "Rectangle" or "FilledRectangle" or "Oval" or "Arrow" or "Line" or "Text" or
        "Highlighter" or "Counter" or "Pencil";

    private static bool SupportsStrokeWidth(AnnotationStyle style) => style.Tool is
        "Rectangle" or "FilledRectangle" or "Oval" or "Arrow" or "Line" or "Highlighter" or
        "Blur" or "Counter" or "Pencil";

    private static bool SupportsCornerRadius(AnnotationStyle style) => style.Tool is
        "Rectangle" or "FilledRectangle" or "Text" or "Spotlight";

    private void UpdatePropertiesBar()
    {
        if (PropertiesBar is null) return;
        var selectedStyles = _selectedElements
            .Where(_elementStyles.ContainsKey)
            .Select(element => _elementStyles[element])
            .ToArray();
        var style = selectedStyles.FirstOrDefault() ?? CreateCurrentStyle(_tool);
        var contextTool = selectedStyles.Length == 1 ? style.Tool : _tool;
        ContextPillText.Text = selectedStyles.Length switch
        {
            > 1 => $"已选择 {selectedStyles.Length} 个",
            1 => _toolNames.GetValueOrDefault(style.Tool, style.Tool),
            _ => _toolNames.GetValueOrDefault(_tool, _tool)
        };

        var any = selectedStyles.Length > 0;
        bool Supports(Func<AnnotationStyle, bool> predicate) =>
            any ? selectedStyles.Any(predicate) : predicate(style);

        StrokeColorGroup.Visibility = Supports(SupportsStrokeColor) ? Visibility.Visible : Visibility.Collapsed;
        TextBackgroundGroup.Visibility = Supports(candidate => candidate.Tool == "Text") ? Visibility.Visible : Visibility.Collapsed;
        BlurTypeGroup.Visibility = Supports(candidate => candidate.Tool == "Blur") ? Visibility.Visible : Visibility.Collapsed;
        ArrowStyleGroup.Visibility = Supports(candidate => candidate.Tool == "Arrow") ? Visibility.Visible : Visibility.Collapsed;
        var arrowStyle = selectedStyles.FirstOrDefault(candidate => candidate.Tool == "Arrow") ?? style;
        ArrowBendGroup.Visibility = ArrowStyleGroup.Visibility == Visibility.Visible && arrowStyle.ArrowStyle != ArrowStyleKind.Straight
            ? Visibility.Visible
            : Visibility.Collapsed;
        ArrowEndpointGroup.Visibility = ArrowStyleGroup.Visibility == Visibility.Visible && arrowStyle.ArrowType == ArrowTypeKind.Classic
            ? Visibility.Visible
            : Visibility.Collapsed;
        StrokeWidthGroup.Visibility = Supports(SupportsStrokeWidth) ? Visibility.Visible : Visibility.Collapsed;
        FontSizeGroup.Visibility = Supports(candidate => candidate.Tool == "Text") ? Visibility.Visible : Visibility.Collapsed;
        CornerRadiusGroup.Visibility = Supports(SupportsCornerRadius) ? Visibility.Visible : Visibility.Collapsed;
        StrokeColorLabel.Text = contextTool == "Text" ? "文字" : "颜色";
        StrokeWidthLabel.Text = contextTool is "Blur" or "Counter" ? "大小" : "描边";

        _suppressPropertyUpdates = true;
        _color = style.StrokeColor;
        _textBackgroundColor = style.TextBackgroundColor;
        _fontSize = style.FontSize;
        _cornerRadius = style.CornerRadius;
        _blurKind = style.Blur;
        _arrowStyle = arrowStyle.ArrowStyle;
        _arrowType = arrowStyle.ArrowType;
        _arrowBend = arrowStyle.ArrowBend;
        _arrowStartHead = arrowStyle.StartHead;
        _arrowEndHead = arrowStyle.EndHead;
        StrokeSlider.Value = style.StrokeWidth;
        FontSizeSlider.Value = style.FontSize;
        CornerRadiusSlider.Value = style.CornerRadius;
        _suppressPropertyUpdates = false;

        UpdatePropertyButtonStates(style, arrowStyle);
        PropertiesBar.Visibility = _annotating && _oneShotMode == OneShotMode.Screenshot &&
                                   (_tool != "Selection" || selectedStyles.Length > 0)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void UpdatePropertyButtonStates(AnnotationStyle style, AnnotationStyle arrowStyle)
    {
        var colorBorder = new SolidColorBrush(WpfColor.FromArgb(82, 255, 255, 255));
        colorBorder.Freeze();
        var accent = (Brush)FindResource("AccentBrush");
        var selectedBackground = (Brush)FindResource("HudSelectedBrush");
        var primaryText = (Brush)FindResource("HudTextBrush");
        var secondaryText = (Brush)FindResource("HudSecondaryTextBrush");
        foreach (var button in FindVisualChildren<WpfButton>(PropertiesBar))
        {
            if (button.Tag is not string tag || !tag.Contains(':')) continue;
            var parts = tag.Split(':', 2);
            var selected = parts[0] switch
            {
                "Stroke" => ColorTagMatches(parts[1], style.StrokeColor),
                "TextBackground" => style.TextBackgroundColor is { } background
                    ? ColorTagMatches(parts[1], background)
                    : parts[1] == "Clear",
                "Blur" => parts[1].Equals(style.Blur.ToString(), StringComparison.OrdinalIgnoreCase),
                "ArrowStyle" => parts[1].Equals(arrowStyle.ArrowStyle.ToString(), StringComparison.OrdinalIgnoreCase),
                "ArrowType" => parts[1].Equals(arrowStyle.ArrowType.ToString(), StringComparison.OrdinalIgnoreCase),
                "ArrowBend" => parts[1].Equals(arrowStyle.ArrowBend.ToString(), StringComparison.OrdinalIgnoreCase),
                "StartHead" => parts[1].Equals(arrowStyle.StartHead.ToString(), StringComparison.OrdinalIgnoreCase),
                "EndHead" => parts[1].Equals(arrowStyle.EndHead.ToString(), StringComparison.OrdinalIgnoreCase),
                _ => false
            };
            var colorSwatch = parts[0] is "Stroke" or "TextBackground";
            button.BorderBrush = selected ? accent : colorSwatch ? colorBorder : Brushes.Transparent;
            button.BorderThickness = selected ? new Thickness(2) : colorSwatch ? new Thickness(1) : new Thickness(0);
            if (!colorSwatch)
                button.Background = selected ? selectedBackground : Brushes.Transparent;
            button.Foreground = selected ? primaryText : secondaryText;
            button.Opacity = selected ? 1 : 0.88;
        }
    }

    private static bool ColorTagMatches(string value, WpfColor color) =>
        !value.Equals("Clear", StringComparison.OrdinalIgnoreCase) &&
        (WpfColor)ColorConverter.ConvertFromString(value) == color;

    private void OnCanvasMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (ShouldMoveSelectionOnCanvasDrag(_oneShotMode, _oneShotCommitted))
        {
            BeginMoveSelection(e.GetPosition(Root));
            e.Handled = true;
            return;
        }
        if (_oneShotMode != OneShotMode.Screenshot) return;
        if (!CommitOneShotMode()) return;
        _drawStart = e.GetPosition(AnnotationCanvas);
        var clickedElement = HitTestAnnotation(_drawStart, e.OriginalSource as DependencyObject);
        if (_tool != "Selection" && clickedElement is not null)
        {
            SelectElement(clickedElement);
            if (_elementTools.TryGetValue(clickedElement, out var clickedTool))
                SelectTool(clickedTool, commitOneShot: false);
            _draggingElement = true;
            _elementDragStart = _drawStart;
            _elementOriginalTransforms = SnapshotTransforms(_selectedElements);
            _elementOriginalStyles = SnapshotStyles(_selectedElements);
            AnnotationCanvas.CaptureMouse();
            e.Handled = true;
            return;
        }
        if (_tool == "Selection")
        {
            var hit = e.OriginalSource as DependencyObject;
            var selected = FindAnnotationElement(hit);
            if (selected is not null)
            {
                var extend = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
                SelectElement(selected, extend);
                if (_selectedElements.Contains(selected))
                {
                    _draggingElement = true;
                    _elementDragStart = _drawStart;
                    _elementOriginalTransforms = SnapshotTransforms(_selectedElements);
                    _elementOriginalStyles = SnapshotStyles(_selectedElements);
                    AnnotationCanvas.CaptureMouse();
                }
            }
            else
            {
                if ((Keyboard.Modifiers & ModifierKeys.Shift) == 0) ClearElementSelection();
                _selectingElements = true;
                _elementSelectionStart = _drawStart;
                SelectionMarquee.Visibility = Visibility.Visible;
                SetChromeRect(SelectionMarquee, ToDisplayRect(new Rect(_drawStart, _drawStart)));
                AnnotationCanvas.CaptureMouse();
            }
            return;
        }

        ClearElementSelection();

        _activeStyle = CreateCurrentStyle(_tool);
        _activeStyle.Start = _drawStart;
        _activeStyle.End = _drawStart;
        var brush = new SolidColorBrush(_activeStyle.StrokeColor);
        switch (_tool)
        {
            case "Pencil":
            case "Highlighter":
                var polyline = new Polyline
                {
                    Stroke = brush,
                    StrokeThickness = _tool == "Highlighter" ? _activeStyle.StrokeWidth * 4 : _activeStyle.StrokeWidth,
                    Opacity = _tool == "Highlighter" ? 0.45 : 1,
                    StrokeLineJoin = PenLineJoin.Round,
                    StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round
                };
                polyline.Points.Add(_drawStart);
                _activeElement = polyline;
                break;
            case "Line":
                _activeElement = new Line
                {
                    X1 = _drawStart.X, Y1 = _drawStart.Y, X2 = _drawStart.X, Y2 = _drawStart.Y,
                    Stroke = brush, StrokeThickness = _activeStyle.StrokeWidth, StrokeStartLineCap = PenLineCap.Round,
                    StrokeEndLineCap = PenLineCap.Round
                };
                break;
            case "Arrow":
                _activeElement = new WpfPath
                {
                    Fill = brush,
                    Data = AnnotationArrowGeometry.CreateTapered(_drawStart, _drawStart, _activeStyle.StrokeWidth)
                };
                break;
            case "Rectangle":
                _activeElement = new WpfRectangle
                {
                    Stroke = brush, StrokeThickness = _activeStyle.StrokeWidth, Fill = Brushes.Transparent,
                    RadiusX = _activeStyle.CornerRadius, RadiusY = _activeStyle.CornerRadius
                };
                break;
            case "FilledRectangle":
                _activeElement = new WpfRectangle
                {
                    Stroke = brush, StrokeThickness = _activeStyle.StrokeWidth, Fill = brush,
                    RadiusX = _activeStyle.CornerRadius, RadiusY = _activeStyle.CornerRadius
                };
                break;
            case "Oval":
                _activeElement = new Ellipse { Stroke = brush, StrokeThickness = _activeStyle.StrokeWidth, Fill = Brushes.Transparent };
                break;
            case "Spotlight":
                _activeElement = new WpfPath
                {
                    Fill = (Brush)FindResource("Annotation.SpotlightBrush"),
                    IsHitTestVisible = false
                };
                break;
            case "Blur":
                _activeElement = new WpfRectangle { Stroke = (Brush)FindResource("Annotation.WhiteBrush"), StrokeThickness = 2, StrokeDashArray = [5, 3], Fill = (Brush)FindResource("Annotation.BlurSelectionBrush") };
                break;
            case "Text":
                AddText(string.Empty, _drawStart, _activeStyle);
                _activeStyle = null;
                return;
            case "Counter":
                AddCounter(_drawStart, _activeStyle);
                _activeStyle = null;
                return;
        }
        if (_activeElement is not null)
        {
            AnnotationCanvas.Children.Add(_activeElement);
            AnnotationCanvas.CaptureMouse();
            e.Handled = true;
        }
    }

    private void OnCanvasMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        var point = e.GetPosition(AnnotationCanvas);
        if (_draggingElement && _selectedElements.Count > 0 && e.LeftButton == MouseButtonState.Pressed)
        {
            var delta = point - _elementDragStart;
            ApplySelectionTranslation(delta, _elementOriginalTransforms, _elementOriginalStyles);
            UpdateElementSelectionChrome();
            return;
        }
        if (_tool == "Selection" && _selectingElements && e.LeftButton == MouseButtonState.Pressed)
        {
            SetChromeRect(SelectionMarquee, ToDisplayRect(Normalize(_elementSelectionStart, point)));
            return;
        }
        if (!IsDrawing || e.LeftButton != MouseButtonState.Pressed) return;
        if (_activeElement is Polyline polyline) { polyline.Points.Add(point); return; }
        if (_activeElement is Line line)
        {
            if (_activeStyle is not null)
            {
                _activeStyle.End = point;
                ApplyElementStyle(line, _activeStyle);
            }
            return;
        }
        if (_tool == "Arrow" && _activeElement is WpfPath arrow)
        {
            if (_activeStyle is not null)
            {
                _activeStyle.End = point;
                ApplyArrowStyle(arrow, _activeStyle);
            }
            return;
        }
        if (_activeElement is WpfPath spotlight)
        {
            var aperture = Normalize(_drawStart, point);
            if (_activeStyle is not null) _activeStyle.End = point;
            var geometry = new GeometryGroup { FillRule = FillRule.EvenOdd };
            geometry.Children.Add(new RectangleGeometry(new Rect(0, 0, AnnotationCanvas.Width, AnnotationCanvas.Height)));
            var radius = _activeStyle?.CornerRadius ?? 0;
            geometry.Children.Add(new RectangleGeometry(aperture, radius, radius));
            spotlight.Data = geometry;
            return;
        }
        if (_activeElement is Shape shape)
        {
            var bounds = Normalize(_drawStart, point);
            shape.Width = bounds.Width; shape.Height = bounds.Height;
            Canvas.SetLeft(shape, bounds.Left); Canvas.SetTop(shape, bounds.Top);
        }
    }

    private void OnCanvasMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_tool == "Selection" || _draggingElement || _selectingElements)
        {
            AnnotationCanvas.ReleaseMouseCapture();
            if (_draggingElement)
            {
                _draggingElement = false;
                PushManipulationEdit(
                    _elementOriginalTransforms,
                    SnapshotTransforms(_selectedElements),
                    _elementOriginalStyles,
                    SnapshotStyles(_selectedElements));
                _elementOriginalTransforms = [];
                _elementOriginalStyles = [];
            }
            if (_selectingElements)
            {
                var marquee = Normalize(_elementSelectionStart, e.GetPosition(AnnotationCanvas));
                _selectingElements = false;
                SelectionMarquee.Visibility = Visibility.Collapsed;
                var selected = AnnotationCanvas.Children.Cast<UIElement>()
                    .Where(_elementTools.ContainsKey)
                    .Where(element => marquee.IntersectsWith(GetElementBounds(element)))
                    .ToArray();
                SelectElements(selected, (Keyboard.Modifiers & ModifierKeys.Shift) != 0);
            }
            UpdateElementSelectionChrome();
            return;
        }
        AnnotationCanvas.ReleaseMouseCapture();
        if (_activeElement is null) return;
        UIElement? committedElement = _activeElement;
        if (_tool == "Blur" && _activeElement is WpfRectangle preview)
        {
            var bounds = GetElementBounds(preview);
            AnnotationCanvas.Children.Remove(preview);
            var blurEffect = MakeBlurEffect(bounds, _activeStyle ?? CreateCurrentStyle("Blur"));
            if (blurEffect is not null)
            {
                AnnotationCanvas.Children.Add(blurEffect);
                Register([blurEffect], _activeStyle);
                committedElement = blurEffect;
            }
            else committedElement = null;
        }
        else Register([_activeElement], _activeStyle);
        if (committedElement is not null) SelectElement(committedElement);
        _activeElement = null;
        _activeStyle = null;
    }

    private void AddText(string text, WpfPoint point, AnnotationStyle style)
    {
        var box = new WpfTextBox
        {
            Text = text,
            FontSize = style.FontSize,
            FontStyle = FontStyles.Normal,
            FontWeight = FontWeights.Normal,
            Foreground = new SolidColorBrush(style.StrokeColor),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0), MinWidth = 130, Padding = new Thickness(4),
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            ToolTip = "双击编辑文字"
        };
        var host = new Border
        {
            Background = style.TextBackgroundColor is { } background
                ? new SolidColorBrush(background)
                : Brushes.Transparent,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(style.CornerRadius),
            Child = box,
            ToolTip = "双击编辑文字"
        };
        box.LostKeyboardFocus += OnTextBoxLostKeyboardFocus;
        box.MouseDoubleClick += OnTextBoxMouseDoubleClick;
        box.PreviewKeyDown += OnTextBoxPreviewKeyDown;
        box.TextChanged += (_, _) => UpdateElementSelectionChrome();
        Canvas.SetLeft(host, point.X); Canvas.SetTop(host, point.Y);
        AnnotationCanvas.Children.Add(host);
        Register([host], style);
        SelectElement(host);
        BeginTextEditing(box);
    }

    private void OnCanvasPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_editingTextBox is null || IsWithin(_editingTextBox, e.OriginalSource)) return;
        EndTextEditing(_editingTextBox);
        Keyboard.ClearFocus();
        e.Handled = true;
    }

    private void BeginTextEditing(WpfTextBox box)
    {
        if (_editingTextBox is not null && !ReferenceEquals(_editingTextBox, box))
            EndTextEditing(_editingTextBox);
        _editingTextBox = box;
        _editingTextOriginalValue = box.Text;
        box.IsReadOnly = false;
        if (box.Parent is Border host)
        {
            host.BorderBrush = (Brush)FindResource("AccentBrush");
            host.BorderThickness = new Thickness(1.5);
        }
        box.Focus();
        Keyboard.Focus(box);
        box.SelectAll();
    }

    private void EndTextEditing(WpfTextBox box)
    {
        var original = ReferenceEquals(_editingTextBox, box) ? _editingTextOriginalValue : null;
        var current = box.Text;
        box.IsReadOnly = true;
        box.BorderThickness = new Thickness(0);
        box.Background = Brushes.Transparent;
        if (box.Parent is Border host)
        {
            host.BorderThickness = new Thickness(0);
            if (_elementStyles.TryGetValue(host, out var style)) ApplyElementStyle(host, style);
        }
        box.SelectionLength = 0;
        if (ReferenceEquals(_editingTextBox, box))
        {
            _editingTextBox = null;
            _editingTextOriginalValue = null;
        }
        if (box.Parent is Border textHost && string.IsNullOrWhiteSpace(current))
        {
            DiscardEmptyText(textHost, original);
            return;
        }
        if (original is not null && original != current)
        {
            PushEdit(
                () => { box.Text = original; UpdateElementSelectionChrome(); },
                () => { box.Text = current; UpdateElementSelectionChrome(); });
        }
    }

    private void DiscardEmptyText(Border host, string? original)
    {
        if (_discardingEmptyText || !AnnotationCanvas.Children.Contains(host)) return;
        _discardingEmptyText = true;
        try
        {
            var index = AnnotationCanvas.Children.IndexOf(host);
            AnnotationCanvas.Children.Remove(host);
            ClearElementSelection();
            if (string.IsNullOrWhiteSpace(original))
            {
                if (_undo.Count > 0) _undo.Pop();
                _redo.Clear();
                UpdateHistoryButtons();
                return;
            }

            PushEdit(
                () =>
                {
                    if (!AnnotationCanvas.Children.Contains(host))
                        AnnotationCanvas.Children.Insert(Math.Clamp(index, 0, AnnotationCanvas.Children.Count), host);
                    if (host.Child is WpfTextBox restored) restored.Text = original;
                },
                () =>
                {
                    if (AnnotationCanvas.Children.Contains(host)) AnnotationCanvas.Children.Remove(host);
                    ClearElementSelection();
                });
        }
        finally
        {
            _discardingEmptyText = false;
        }
    }

    private static bool IsWithin(UIElement parent, object source) =>
        ReferenceEquals(parent, source) || source is DependencyObject child && parent.IsAncestorOf(child);

    private void OnTextBoxLostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (sender is WpfTextBox box) EndTextEditing(box);
    }

    private void OnTextBoxMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not WpfTextBox box) return;
        BeginTextEditing(box);
        e.Handled = true;
    }

    private void OnTextBoxPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (sender is not WpfTextBox box || e.Key != Key.Escape &&
            !(e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Control) != 0)) return;
        EndTextEditing(box);
        AnnotationCanvas.Focus();
        e.Handled = true;
    }

    private void AddCounter(WpfPoint point, AnnotationStyle style)
    {
        var badge = new Border
        {
            Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Background = new SolidColorBrush(style.StrokeColor),
            Child = new TextBlock { Text = (_counter++).ToString(), Foreground = (Brush)FindResource("Annotation.WhiteBrush"), FontWeight = FontWeights.Bold, FontSize = 14, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
        };
        Canvas.SetLeft(badge, point.X - 15); Canvas.SetTop(badge, point.Y - 15);
        AnnotationCanvas.Children.Add(badge);
        Register([badge], style);
        SelectElement(badge);
    }

    private UIElement? FindAnnotationElement(DependencyObject? value)
    {
        while (value is not null && value != AnnotationCanvas)
        {
            if (value is UIElement element && AnnotationCanvas.Children.Contains(element)) return element;
            value = VisualTreeHelper.GetParent(value);
        }
        return null;
    }

    private UIElement? HitTestAnnotation(WpfPoint point, DependencyObject? directSource = null)
    {
        var direct = FindAnnotationElement(directSource);
        if (direct is not null) return direct;
        return AnnotationCanvas.Children.Cast<UIElement>()
            .Reverse()
            .FirstOrDefault(element => _elementTools.ContainsKey(element) && GetElementBounds(element).Contains(point));
    }

    private void SelectElement(UIElement element, bool extend = false)
    {
        if (!AnnotationCanvas.Children.Contains(element)) return;
        if (!extend) ClearElementSelection();
        if (extend && _selectedElements.Remove(element))
        {
            if (element is FrameworkElement removed) removed.ClearValue(FrameworkElement.CursorProperty);
            _selectedElement = _selectedElements.LastOrDefault();
        }
        else
        {
            _selectedElements.Add(element);
            _selectedElement = element;
            if (element is FrameworkElement framework)
            {
                if (_tool == "Selection") framework.Cursor = Cursors.SizeAll;
                else framework.ClearValue(FrameworkElement.CursorProperty);
            }
        }
        UpdateElementSelectionChrome();
        UpdatePropertiesBar();
    }

    private void SelectElements(IEnumerable<UIElement> elements, bool extend)
    {
        if (!extend) ClearElementSelection();
        foreach (var element in elements.Where(AnnotationCanvas.Children.Contains))
        {
            if (extend && _selectedElements.Contains(element))
            {
                _selectedElements.Remove(element);
                if (element is FrameworkElement removed) removed.ClearValue(FrameworkElement.CursorProperty);
                continue;
            }
            _selectedElements.Add(element);
            if (element is FrameworkElement framework && _tool == "Selection") framework.Cursor = Cursors.SizeAll;
        }
        _selectedElement = _selectedElements.LastOrDefault();
        UpdateElementSelectionChrome();
        UpdatePropertiesBar();
    }

    private void ClearElementSelection()
    {
        foreach (var framework in _selectedElements.OfType<FrameworkElement>())
            framework.ClearValue(FrameworkElement.CursorProperty);
        _selectedElements.Clear();
        _selectedElement = null;
        ElementMoveHitTarget.Visibility = Visibility.Collapsed;
        ElementSelectionBorder.Visibility = Visibility.Collapsed;
        ElementHandleTopLeft.Visibility = Visibility.Collapsed;
        ElementHandleTopRight.Visibility = Visibility.Collapsed;
        ElementHandleBottomRight.Visibility = Visibility.Collapsed;
        ElementHandleBottomLeft.Visibility = Visibility.Collapsed;
        UpdatePropertiesBar();
    }

    private Rect GetElementBounds(UIElement element)
    {
        AnnotationCanvas.UpdateLayout();
        Rect localBounds;
        if (element is Line line)
        {
            localBounds = new Rect(
                new WpfPoint(Math.Min(line.X1, line.X2), Math.Min(line.Y1, line.Y2)),
                new WpfPoint(Math.Max(line.X1, line.X2), Math.Max(line.Y1, line.Y2)));
        }
        else if (element is Polyline polyline && polyline.Points.Count > 0)
        {
            var left = polyline.Points.Min(point => point.X);
            var top = polyline.Points.Min(point => point.Y);
            var right = polyline.Points.Max(point => point.X);
            var bottom = polyline.Points.Max(point => point.Y);
            localBounds = new Rect(new WpfPoint(left, top), new WpfPoint(right, bottom));
        }
        else if (element is WpfPath path && _elementTools.GetValueOrDefault(element) == "Spotlight" &&
                 path.Data is GeometryGroup { Children.Count: > 1 } group)
        {
            localBounds = group.Children[1].Bounds;
        }
        else if (element is WpfPath geometryPath && geometryPath.Data is not null)
        {
            localBounds = geometryPath.Data.Bounds;
        }
        else if (element is FrameworkElement framework)
        {
            var width = double.IsNaN(framework.Width) ? framework.ActualWidth : framework.Width;
            var height = double.IsNaN(framework.Height) ? framework.ActualHeight : framework.Height;
            localBounds = new Rect(0, 0, Math.Max(1, width), Math.Max(1, height));
        }
        else return Rect.Empty;

        var transformed = (element.RenderTransform ?? Transform.Identity).TransformBounds(localBounds);
        if (element is FrameworkElement positioned)
        {
            var left = Canvas.GetLeft(positioned);
            var top = Canvas.GetTop(positioned);
            transformed.Offset(double.IsNaN(left) ? 0 : left, double.IsNaN(top) ? 0 : top);
        }
        return transformed;
    }

    private Rect ToDisplayRect(Rect annotationRect)
    {
        var scaleX = AnnotationCanvas.Width > 0 ? SelectionHost.Width / AnnotationCanvas.Width : 1;
        var scaleY = AnnotationCanvas.Height > 0 ? SelectionHost.Height / AnnotationCanvas.Height : 1;
        return new Rect(
            annotationRect.X * scaleX * _canvasZoom + EditorPanTransform.X,
            annotationRect.Y * scaleY * _canvasZoom + EditorPanTransform.Y,
            annotationRect.Width * scaleX * _canvasZoom,
            annotationRect.Height * scaleY * _canvasZoom);
    }

    private WpfPoint ToAnnotationPoint(WpfPoint displayPoint)
    {
        var scaleX = SelectionHost.Width > 0 ? AnnotationCanvas.Width / SelectionHost.Width : 1;
        var scaleY = SelectionHost.Height > 0 ? AnnotationCanvas.Height / SelectionHost.Height : 1;
        return new WpfPoint(
            (displayPoint.X - EditorPanTransform.X) * scaleX / _canvasZoom,
            (displayPoint.Y - EditorPanTransform.Y) * scaleY / _canvasZoom);
    }

    private void UpdateElementSelectionChrome()
    {
        _selectedElements.RemoveWhere(element => !AnnotationCanvas.Children.Contains(element));
        if (_selectedElement is null || !_selectedElements.Contains(_selectedElement))
            _selectedElement = _selectedElements.LastOrDefault();
        if (!_annotating || _selectedElements.Count == 0)
        {
            ElementMoveHitTarget.Visibility = Visibility.Collapsed;
            ElementSelectionBorder.Visibility = Visibility.Collapsed;
            ElementHandleTopLeft.Visibility = Visibility.Collapsed;
            ElementHandleTopRight.Visibility = Visibility.Collapsed;
            ElementHandleBottomRight.Visibility = Visibility.Collapsed;
            ElementHandleBottomLeft.Visibility = Visibility.Collapsed;
            return;
        }

        var union = _selectedElements.Select(GetElementBounds)
            .Aggregate((current, next) => Rect.Union(current, next));
        var bounds = ToDisplayRect(union);
        if (bounds.IsEmpty) return;
        SetChromeRect(ElementMoveHitTarget, bounds);
        ElementMoveHitTarget.Visibility = Visibility.Visible;
        SetChromeRect(ElementSelectionBorder, bounds);
        ElementSelectionBorder.Visibility = Visibility.Visible;

        var supportsResize = _selectedElements.Count == 1 &&
                             _elementTools.GetValueOrDefault(_selectedElement!) is not ("Pencil" or "Highlighter");
        var selectedStyle = _selectedElement is not null && _elementStyles.TryGetValue(_selectedElement, out var resolvedStyle)
            ? resolvedStyle
            : null;
        var endpointResize = supportsResize && (selectedStyle?.Tool is "Line" or "Arrow");
        ElementHandleTopLeft.Tag = endpointResize ? "LineStart" : "TopLeft";
        ElementHandleBottomRight.Tag = endpointResize ? "LineEnd" : "BottomRight";
        ElementHandleTopLeft.Cursor = endpointResize ? Cursors.Cross : Cursors.SizeNWSE;
        ElementHandleBottomRight.Cursor = endpointResize ? Cursors.Cross : Cursors.SizeNWSE;
        var handleVisibility = supportsResize ? Visibility.Visible : Visibility.Collapsed;
        ElementHandleTopLeft.Visibility = handleVisibility;
        ElementHandleTopRight.Visibility = endpointResize ? Visibility.Collapsed : handleVisibility;
        ElementHandleBottomRight.Visibility = handleVisibility;
        ElementHandleBottomLeft.Visibility = endpointResize ? Visibility.Collapsed : handleVisibility;
        if (!supportsResize) return;
        if (endpointResize)
        {
            var start = ToDisplayPoint(TransformElementPoint(_selectedElement!, selectedStyle!.Start));
            var end = ToDisplayPoint(TransformElementPoint(_selectedElement!, selectedStyle.End));
            PositionHandle(ElementHandleTopLeft, start.X, start.Y);
            PositionHandle(ElementHandleBottomRight, end.X, end.Y);
            return;
        }
        PositionHandle(ElementHandleTopLeft, bounds.Left, bounds.Top);
        PositionHandle(ElementHandleTopRight, bounds.Right, bounds.Top);
        PositionHandle(ElementHandleBottomRight, bounds.Right, bounds.Bottom);
        PositionHandle(ElementHandleBottomLeft, bounds.Left, bounds.Bottom);
    }

    private static void SetChromeRect(FrameworkElement element, Rect rect)
    {
        Canvas.SetLeft(element, rect.Left);
        Canvas.SetTop(element, rect.Top);
        element.Width = Math.Max(0, rect.Width);
        element.Height = Math.Max(0, rect.Height);
    }

    private WpfPoint ToDisplayPoint(WpfPoint annotationPoint)
    {
        var scaleX = AnnotationCanvas.Width > 0 ? SelectionHost.Width / AnnotationCanvas.Width : 1;
        var scaleY = AnnotationCanvas.Height > 0 ? SelectionHost.Height / AnnotationCanvas.Height : 1;
        return new WpfPoint(annotationPoint.X * scaleX, annotationPoint.Y * scaleY);
    }

    private static WpfPoint TransformElementPoint(UIElement element, WpfPoint localPoint)
    {
        var transformed = (element.RenderTransform ?? Transform.Identity).Transform(localPoint);
        if (element is FrameworkElement positioned)
        {
            var left = Canvas.GetLeft(positioned);
            var top = Canvas.GetTop(positioned);
            transformed.Offset(double.IsNaN(left) ? 0 : left, double.IsNaN(top) ? 0 : top);
        }
        return transformed;
    }

    private static WpfPoint ToElementLocalPoint(UIElement element, WpfPoint canvasPoint)
    {
        var local = canvasPoint;
        if (element is FrameworkElement positioned)
        {
            var left = Canvas.GetLeft(positioned);
            var top = Canvas.GetTop(positioned);
            local.Offset(-(double.IsNaN(left) ? 0 : left), -(double.IsNaN(top) ? 0 : top));
        }
        var matrix = element.RenderTransform?.Value ?? Matrix.Identity;
        if (!matrix.HasInverse) return local;
        matrix.Invert();
        return matrix.Transform(local);
    }

    private void OnElementResizeMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_selectedElements.Count != 1 || _selectedElement is null || sender is not FrameworkElement handle) return;
        _elementResizeHandle = handle.Tag?.ToString() ?? string.Empty;
        _elementResizeStart = ToAnnotationPoint(e.GetPosition(ElementSelectionChrome));
        _elementResizeStartBounds = GetElementBounds(_selectedElement);
        _elementOriginalTransform = _selectedElement.RenderTransform?.Value ?? Matrix.Identity;
        _elementOriginalTransforms = new Dictionary<UIElement, Matrix>
        {
            [_selectedElement] = _elementOriginalTransform
        };
        _elementOriginalStyles = SnapshotStyles([_selectedElement]);
        if (_selectedElement is FrameworkElement positioned)
        {
            _elementLayoutLeft = Canvas.GetLeft(positioned);
            _elementLayoutTop = Canvas.GetTop(positioned);
            if (double.IsNaN(_elementLayoutLeft)) _elementLayoutLeft = 0;
            if (double.IsNaN(_elementLayoutTop)) _elementLayoutTop = 0;
        }
        else _elementLayoutLeft = _elementLayoutTop = 0;
        _resizingElement = true;
        ElementSelectionChrome.CaptureMouse();
        e.Handled = true;
    }

    private void OnElementMoveMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_selectedElements.Count == 0 || e.ChangedButton != MouseButton.Left) return;
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0)
        {
            var annotationPoint = ToAnnotationPoint(e.GetPosition(ElementSelectionChrome));
            var hit = AnnotationCanvas.InputHitTest(annotationPoint) as DependencyObject;
            var element = HitTestAnnotation(annotationPoint, hit);
            if (element is not null) SelectElement(element, extend: true);
            e.Handled = true;
            return;
        }
        _draggingElement = true;
        _elementDragStart = ToAnnotationPoint(e.GetPosition(ElementSelectionChrome));
        _elementOriginalTransforms = SnapshotTransforms(_selectedElements);
        _elementOriginalStyles = SnapshotStyles(_selectedElements);
        ElementSelectionChrome.CaptureMouse();
        e.Handled = true;
    }

    private void OnElementSelectionMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (_draggingElement && _selectedElements.Count > 0 && e.LeftButton == MouseButtonState.Pressed)
        {
            var dragPoint = ToAnnotationPoint(e.GetPosition(ElementSelectionChrome));
            var delta = dragPoint - _elementDragStart;
            ApplySelectionTranslation(delta, _elementOriginalTransforms, _elementOriginalStyles);
            UpdateElementSelectionChrome();
            e.Handled = true;
            return;
        }
        if (!_resizingElement || _selectedElement is null || e.LeftButton != MouseButtonState.Pressed) return;
        var point = ToAnnotationPoint(e.GetPosition(ElementSelectionChrome));
        if (_elementResizeHandle is "LineStart" or "LineEnd" &&
            _elementOriginalStyles.TryGetValue(_selectedElement, out var endpointStyle))
        {
            var resized = endpointStyle.Copy();
            var localPoint = ToElementLocalPoint(_selectedElement, point);
            if (_elementResizeHandle == "LineStart") resized.Start = localPoint;
            else resized.End = localPoint;
            ApplyElementStyle(_selectedElement, resized);
            UpdateElementSelectionChrome();
            e.Handled = true;
            return;
        }
        var targetBounds = InlineAreaGeometry.Resize(_elementResizeStartBounds, _elementResizeHandle,
            point - _elementResizeStart, new Size(AnnotationCanvas.Width, AnnotationCanvas.Height));
        ApplyElementResize(targetBounds);
        UpdateElementSelectionChrome();
        e.Handled = true;
    }

    private void ApplyElementResize(Rect targetBounds)
    {
        if (_selectedElement is null || _elementResizeStartBounds.Width <= 0 || _elementResizeStartBounds.Height <= 0) return;
        if (_elementStyles.TryGetValue(_selectedElement, out var style) && style.Tool == "Spotlight")
        {
            var resized = style.Copy();
            resized.Start = targetBounds.TopLeft;
            resized.End = targetBounds.BottomRight;
            ApplyElementStyle(_selectedElement, resized);
            return;
        }
        var canvasMapping = Matrix.Identity;
        canvasMapping.Translate(-_elementResizeStartBounds.Left, -_elementResizeStartBounds.Top);
        canvasMapping.Scale(targetBounds.Width / _elementResizeStartBounds.Width,
            targetBounds.Height / _elementResizeStartBounds.Height);
        canvasMapping.Translate(targetBounds.Left, targetBounds.Top);

        var result = _elementOriginalTransform;
        result.Translate(_elementLayoutLeft, _elementLayoutTop);
        result.Append(canvasMapping);
        result.Translate(-_elementLayoutLeft, -_elementLayoutTop);
        _selectedElement.RenderTransform = new MatrixTransform(result);
    }

    private void OnElementSelectionMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_draggingElement)
        {
            _draggingElement = false;
            ElementSelectionChrome.ReleaseMouseCapture();
            PushManipulationEdit(
                _elementOriginalTransforms,
                SnapshotTransforms(_selectedElements),
                _elementOriginalStyles,
                SnapshotStyles(_selectedElements));
            _elementOriginalTransforms = [];
            _elementOriginalStyles = [];
            UpdateElementSelectionChrome();
            e.Handled = true;
            return;
        }
        if (!_resizingElement) return;
        _resizingElement = false;
        ElementSelectionChrome.ReleaseMouseCapture();
        PushManipulationEdit(
            _elementOriginalTransforms,
            SnapshotTransforms(_selectedElements),
            _elementOriginalStyles,
            SnapshotStyles(_selectedElements));
        _elementOriginalTransforms = [];
        _elementOriginalStyles = [];
        UpdateElementSelectionChrome();
        e.Handled = true;
    }

    private void Register(List<UIElement> elements, AnnotationStyle? style = null)
    {
        foreach (var element in elements)
        {
            var elementStyle = (style ?? CreateCurrentStyle(_tool)).Copy();
            _elementTools[element] = elementStyle.Tool;
            _elementStyles[element] = elementStyle;
            ApplyElementStyle(element, elementStyle);
            if (element is FrameworkElement framework && _tool == "Selection") framework.Cursor = Cursors.SizeAll;
        }
        PushEdit(
            () =>
            {
                foreach (var element in elements) AnnotationCanvas.Children.Remove(element);
                SelectElements(_selectedElements.Except(elements).ToArray(), extend: false);
            },
            () =>
            {
                foreach (var element in elements)
                    if (!AnnotationCanvas.Children.Contains(element)) AnnotationCanvas.Children.Add(element);
            });
    }

    private void PushEdit(Action undo, Action redo)
    {
        _undo.Push(new EditAction(undo, redo));
        _redo.Clear();
        UpdateHistoryButtons();
    }

    private Dictionary<UIElement, Matrix> SnapshotTransforms(IEnumerable<UIElement> elements) =>
        elements.Where(AnnotationCanvas.Children.Contains)
            .ToDictionary(element => element, element => element.RenderTransform?.Value ?? Matrix.Identity);

    private void PushTransformEdit(
        IReadOnlyDictionary<UIElement, Matrix> before,
        IReadOnlyDictionary<UIElement, Matrix> after)
        => PushManipulationEdit(before, after, new Dictionary<UIElement, AnnotationStyle>(),
            new Dictionary<UIElement, AnnotationStyle>());

    private void PushManipulationEdit(
        IReadOnlyDictionary<UIElement, Matrix> beforeTransforms,
        IReadOnlyDictionary<UIElement, Matrix> afterTransforms,
        IReadOnlyDictionary<UIElement, AnnotationStyle> beforeStyles,
        IReadOnlyDictionary<UIElement, AnnotationStyle> afterStyles)
    {
        var transformChanged = beforeTransforms.Any(pair =>
            !afterTransforms.TryGetValue(pair.Key, out var matrix) || matrix != pair.Value);
        var styleChanged = beforeStyles.Any(pair =>
            afterStyles.TryGetValue(pair.Key, out var style) &&
            (style.Start != pair.Value.Start || style.End != pair.Value.End));
        if (!transformChanged && !styleChanged)
            return;
        void Restore(
            IReadOnlyDictionary<UIElement, Matrix> transforms,
            IReadOnlyDictionary<UIElement, AnnotationStyle> styles)
        {
            foreach (var (element, matrix) in transforms)
                if (AnnotationCanvas.Children.Contains(element)) element.RenderTransform = new MatrixTransform(matrix);
            foreach (var (element, style) in styles)
                if (AnnotationCanvas.Children.Contains(element)) ApplyElementStyle(element, style);
            UpdateElementSelectionChrome();
        }
        PushEdit(
            () => Restore(beforeTransforms, beforeStyles),
            () => Restore(afterTransforms, afterStyles));
    }

    private void ApplySelectionTranslation(
        Vector delta,
        IReadOnlyDictionary<UIElement, Matrix> originalTransforms,
        IReadOnlyDictionary<UIElement, AnnotationStyle> originalStyles)
    {
        foreach (var element in _selectedElements)
        {
            if (originalStyles.TryGetValue(element, out var style) && style.Tool == "Spotlight")
            {
                var moved = style.Copy();
                moved.Start += delta;
                moved.End += delta;
                ApplyElementStyle(element, moved);
                continue;
            }
            var matrix = originalTransforms.GetValueOrDefault(
                element,
                element.RenderTransform?.Value ?? Matrix.Identity);
            matrix.Translate(delta.X, delta.Y);
            element.RenderTransform = new MatrixTransform(matrix);
        }
    }

    private void RemoveSelectedElements()
    {
        var elements = _selectedElements.Where(AnnotationCanvas.Children.Contains).ToArray();
        if (elements.Length == 0) return;
        var indices = elements.ToDictionary(element => element, element => AnnotationCanvas.Children.IndexOf(element));
        foreach (var element in elements) AnnotationCanvas.Children.Remove(element);
        ClearElementSelection();
        PushEdit(
            () =>
            {
                foreach (var element in elements.OrderBy(element => indices[element]))
                    AnnotationCanvas.Children.Insert(Math.Clamp(indices[element], 0, AnnotationCanvas.Children.Count), element);
                SelectElements(elements, extend: false);
            },
            () =>
            {
                foreach (var element in elements) AnnotationCanvas.Children.Remove(element);
                ClearElementSelection();
            });
    }

    private void OnUndo(object sender, RoutedEventArgs e) => Undo();
    private void OnRedo(object sender, RoutedEventArgs e) => Redo();

    private void Undo()
    {
        if (_oneShotMode == OneShotMode.Screenshot && !CommitOneShotMode()) return;
        if (_undo.Count == 0) return;
        var action = _undo.Pop();
        action.Undo();
        _redo.Push(action);
        UpdateHistoryButtons();
        UpdateElementSelectionChrome();
    }

    private void Redo()
    {
        if (_oneShotMode == OneShotMode.Screenshot && !CommitOneShotMode()) return;
        if (_redo.Count == 0) return;
        var action = _redo.Pop();
        action.Redo();
        _undo.Push(action);
        UpdateHistoryButtons();
        UpdateElementSelectionChrome();
    }

    private void UpdateHistoryButtons()
    {
        UndoButton.IsEnabled = _undo.Count > 0;
        RedoButton.IsEnabled = _redo.Count > 0;
    }

    private Drawing.Bitmap RenderSelection()
    {
        FocusManager.SetFocusedElement(this, null);
        FindVisualChildren<WpfTextBox>(AnnotationCanvas).ToList().ForEach(EndTextEditing);
        var crop = SelectionPixelRect();
        EditorSurface.Measure(new Size(crop.Width, crop.Height));
        EditorSurface.Arrange(new Rect(0, 0, crop.Width, crop.Height));
        var rendered = new RenderTargetBitmap(crop.Width, crop.Height, 96, 96, PixelFormats.Pbgra32);
        rendered.Render(EditorSurface);
        return BitmapSourceFactory.ToBitmap(rendered);
    }

    private void OnDone(object sender, RoutedEventArgs e) => Finish(false);
    private void OnPin(object sender, RoutedEventArgs e) => Finish(true);

    private async void Finish(bool pin) => await FinishAsync(pin);

    private async Task<bool> FinishAsync(bool pin)
    {
        if (_isCompleting) return false;
        if (_oneShotMode != OneShotMode.Screenshot || !CommitOneShotMode()) return false;
        _isCompleting = true;
        try
        {
            var rendered = RenderSelection();
            if (_screenshotCommit is not null)
            {
                var committed = await _screenshotCommit(this, rendered, pin);
                if (!committed)
                {
                    rendered.Dispose();
                    _isCompleting = false;
                    ShowStatus("保存失败，成果仍保留；可重试、另存或复制");
                    return false;
                }
                ScreenshotCommitted = true;
            }
            ResultImage = rendered;
            PinRequested = pin;
            OneShotAction = OneShotMode.Screenshot;
            OneShotRectangle = OneShotPhysicalRectangle();
            _allowClose = true;
            DialogResult = true;
            return true;
        }
        catch
        {
            _isCompleting = false;
            throw;
        }
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (_oneShotMode == OneShotMode.Screenshot && !CommitOneShotMode()) return;
        try
        {
            using var bitmap = RenderSelection();
            ClipboardWriter.SetImage(BitmapSourceFactory.FromBitmap(bitmap));
            ContextPillText.Text = "已复制到剪贴板";
            ShowStatus("已复制到剪贴板");
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            ContextPillText.Text = "剪贴板正忙，请重试";
            ShowStatus("剪贴板正忙，请重试");
        }
    }

    private void ShowStatus(string message)
    {
        InlineStatusText.Text = message;
        StatusBadge.Visibility = Visibility.Visible;
        StatusBadge.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var left = _selectionRect.IsEmpty
            ? (ActualWidth - StatusBadge.DesiredSize.Width) / 2
            : _selectionRect.Left + (_selectionRect.Width - StatusBadge.DesiredSize.Width) / 2;
        var top = _selectionRect.IsEmpty
            ? ActualHeight - StatusBadge.DesiredSize.Height - 24
            : _selectionRect.Bottom + 12;
        if (top + StatusBadge.DesiredSize.Height > ActualHeight - 12)
            top = _selectionRect.Top - StatusBadge.DesiredSize.Height - 12;
        Canvas.SetLeft(StatusBadge, Math.Clamp(left, 12, Math.Max(12, ActualWidth - StatusBadge.DesiredSize.Width - 12)));
        Canvas.SetTop(StatusBadge, Math.Clamp(top, 12, Math.Max(12, ActualHeight - StatusBadge.DesiredSize.Height - 12)));
        _statusTimer.Stop();
        _statusTimer.Start();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => RequestCancel();

    internal bool HasUnsavedAnnotations => _annotating && AnnotationCanvas.Children.Count > 0;

    private async void RequestCancel() => await RequestCancelAsync();

    private async Task<bool> RequestCancelAsync()
    {
        if (!HasUnsavedAnnotations)
        {
            _allowClose = true;
            DialogResult = false;
            return true;
        }

        var decision = LocalizedDialogService.ShowCustom(
            this,
            "您有未保存的更改。您想在关闭前保存吗？",
            "未保存的更改",
            "保存",
            "不要保存",
            "取消",
            MessageBoxImage.Warning);
        if (decision == MessageBoxResult.Yes)
        {
            return await FinishAsync(false);
        }
        if (decision != MessageBoxResult.No) return false;
        _allowClose = true;
        DialogResult = false;
        return true;
    }

    internal void RequestExternalCancel() => RequestCancel();

    internal Task<bool> RequestCloseForExitAsync() => RequestCancelAsync();

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_allowClose || !HasUnsavedAnnotations) return;
        e.Cancel = true;
        Dispatcher.BeginInvoke(RequestCancel);
    }

    private void OnPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key is Key.LeftShift or Key.RightShift && !_annotating && Magnifier.Visibility == Visibility.Visible)
        {
            _hexMagnifier = !_hexMagnifier;
            MagnifierColorText.Text = _hexMagnifier ? $"HEX: {_magnifierHex}" : $"RGB: {_magnifierRgb}";
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Space && _annotating && e.OriginalSource is not WpfTextBox)
        {
            _spacePanActive = true;
            AnnotationCanvas.Cursor = Cursors.Hand;
            e.Handled = true;
            return;
        }
        if (_selectingOneShotOcr)
        {
            if (e.Key == Key.Escape) RequestCancel();
            e.Handled = true;
            return;
        }
        if (e.OriginalSource is WpfTextBox { IsReadOnly: false }) return;
        if (e.Key == Key.Escape && _selectedElements.Count > 0)
        {
            ClearElementSelection();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape) { RequestCancel(); e.Handled = true; return; }
        if (e.Key == Key.Enter)
        {
            if (_annotating && _oneShotMode == OneShotMode.Scrolling)
                OnOneShotStartScrolling(this, new RoutedEventArgs());
            else if (_annotating && _oneShotMode == OneShotMode.Recording)
                OnOneShotStartRecording(this, new RoutedEventArgs());
            else if (_annotating) Finish(false);
            e.Handled = _annotating;
            return;
        }
        var modifiers = System.Windows.Input.Keyboard.Modifiers;
        if ((modifiers & ModifierKeys.Control) != 0)
        {
            if (e.Key is Key.OemMinus or Key.Subtract)
            {
                ZoomBy(1d / 1.25d);
                e.Handled = true;
            }
            else if (e.Key is Key.OemPlus or Key.Add)
            {
                ZoomBy(1.25d);
                e.Handled = true;
            }
            else if (e.Key is Key.D0 or Key.NumPad0)
            {
                OnZoomFit(this, new RoutedEventArgs());
                e.Handled = true;
            }
            else if (e.Key == Key.C && !_annotating && Magnifier.Visibility == Visibility.Visible &&
                (_hexMagnifier ? _magnifierHex : _magnifierRgb) is { } colorValue)
            {
                try
                {
                    System.Windows.Clipboard.SetText(colorValue);
                    ShowStatus("颜色值已复制");
                }
                catch (System.Runtime.InteropServices.ExternalException)
                {
                    ShowStatus("剪贴板正忙，请重试");
                }
                e.Handled = true;
            }
            else if (e.Key == Key.S) { Finish(false); e.Handled = true; }
            else if (e.Key == Key.C) { OnCopy(this, new RoutedEventArgs()); e.Handled = true; }
            else if (e.Key == Key.Z && (modifiers & ModifierKeys.Shift) != 0) { Redo(); e.Handled = true; }
            else if (e.Key == Key.Z) { Undo(); e.Handled = true; }
            else if (e.Key == Key.Y) { Redo(); e.Handled = true; }
            return;
        }
        if (!_annotating || e.OriginalSource is WpfTextBox || _oneShotMode != OneShotMode.Screenshot) return;
        if (e.Key is Key.Left or Key.Right or Key.Up or Key.Down && _selectedElements.Count > 0)
        {
            if (!CommitOneShotMode()) return;
            var distance = (modifiers & ModifierKeys.Shift) != 0 ? 10d : 1d;
            var delta = e.Key switch
            {
                Key.Left => new Vector(-distance, 0),
                Key.Right => new Vector(distance, 0),
                Key.Up => new Vector(0, -distance),
                _ => new Vector(0, distance)
            };
            var before = SnapshotTransforms(_selectedElements);
            var beforeStyles = SnapshotStyles(_selectedElements);
            ApplySelectionTranslation(delta, before, beforeStyles);
            PushManipulationEdit(
                before,
                SnapshotTransforms(_selectedElements),
                beforeStyles,
                SnapshotStyles(_selectedElements));
            UpdateElementSelectionChrome();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Delete && _selectedElements.Count > 0)
        {
            if (!CommitOneShotMode()) return;
            RemoveSelectedElements();
            e.Handled = true;
        }
    }

    private void OnPreviewKeyUp(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != Key.Space || !_spacePanActive) return;
        _spacePanActive = false;
        if (!_panToolActive) AnnotationCanvas.Cursor = _tool == "Text" ? Cursors.IBeam : _tool == "Selection" ? Cursors.Arrow : Cursors.Cross;
        e.Handled = true;
    }

    private static IEnumerable<T> FindVisualChildren<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match) yield return match;
            foreach (var descendant in FindVisualChildren<T>(child)) yield return descendant;
        }
    }
}
