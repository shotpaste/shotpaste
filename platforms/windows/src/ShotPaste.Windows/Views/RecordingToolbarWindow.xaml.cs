using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Forms = System.Windows.Forms;
using WpfPoint = System.Windows.Point;
using WpfSize = System.Windows.Size;

namespace ShotPaste.Windows.Views;

public partial class RecordingToolbarWindow : Window
{
    private readonly ScreenRecordingService _recording;
    private readonly MicrophoneLevelMonitor _microphone;
    private readonly Func<AppSettings> _settingsProvider;
    private readonly Action? _saveSettings;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private Storyboard? _pulse;
    private bool _positioning;
    private bool _initialPositionApplied;
    private bool? _displayedPaused;
    public event EventHandler? StopRequested;
    public event EventHandler? RestartRequested;
    public event EventHandler? DeleteRequested;
    public event EventHandler? PenRequested;
    public RecordingToolbarWindow(ScreenRecordingService recording)
        : this(recording, new AppSettings())
    {
    }

    public RecordingToolbarWindow(ScreenRecordingService recording, AppSettings settings)
        : this(recording, settings, null)
    {
    }

    public RecordingToolbarWindow(ScreenRecordingService recording, AppSettings settings, Action? saveSettings)
        : this(recording, () => settings, saveSettings)
    {
    }

    internal RecordingToolbarWindow(ScreenRecordingService recording, Func<AppSettings> settingsProvider, Action? saveSettings)
    {
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Acrylic);
        ShowInTaskbar = App.UiTestMode;
        _recording = recording;
        _settingsProvider = settingsProvider;
        _saveSettings = saveSettings;
        var settings = settingsProvider();
        _microphone = new MicrophoneLevelMonitor(settings);
        MicrophonePanel.Visibility = settings.RecordMicrophone ? Visibility.Visible : Visibility.Collapsed;
        _timer.Tick += (_, _) =>
        {
            var processing = _recording.IsPostProcessing;
            TimerText.Text = processing
                ? $"GIF {Math.Round(_recording.PostProcessingProgress * 100):0}%"
                : FormatElapsed(_recording.Elapsed);
            PauseButton.IsEnabled = !processing;
            PenButton.IsEnabled = !processing;
            UpdateMicrophoneFeedback(_microphone.Read());
            RefreshRecordingState();
        };
        _recording.StateChanged += OnRecordingStateChanged;
        _timer.Start();
        Loaded += (_, _) =>
        {
            ApplyInitialPosition();
            EnsureTopmost();
            StartPulse();
        };
        SizeChanged += (_, _) => { if (!_initialPositionApplied) ApplyInitialPosition(); };
        Closed += (_, _) =>
        {
            _pulse?.Stop(this);
            _timer.Stop();
            _recording.StateChanged -= OnRecordingStateChanged;
            _microphone.Dispose();
        };
    }

    private void ApplyInitialPosition()
    {
        if (_initialPositionApplied || !IsLoaded || ActualWidth <= 0 || ActualHeight <= 0) return;
        var settings = _settingsProvider();
        if (settings.RecordingToolbarLeft is { } left && settings.RecordingToolbarTop is { } top &&
            double.IsFinite(left) && double.IsFinite(top) && IsVisibleOnAnyScreen(left, top, ActualWidth, ActualHeight))
        {
            Left = left;
            Top = top;
        }
        else
        {
            PositionNearSelection();
        }
        _initialPositionApplied = true;
    }

    private static bool IsVisibleOnAnyScreen(double left, double top, double width, double height)
    {
        var candidate = new Rect(left, top, Math.Max(1, width), Math.Max(1, height));
        var virtualScreen = new Rect(
            SystemParameters.VirtualScreenLeft,
            SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenWidth,
            SystemParameters.VirtualScreenHeight);
        return candidate.IntersectsWith(virtualScreen);
    }

    private void UpdateMicrophoneFeedback(MicrophoneLevelSnapshot snapshot)
    {
        MicrophoneMeter.Value = snapshot.Level;
        var (text, brushKey) = snapshot.State switch
        {
            MicrophoneFeedbackState.Active => ("麦克风", "SuccessBrush"),
            MicrophoneFeedbackState.NoInput => ("无输入", "WarningBrush"),
            MicrophoneFeedbackState.Muted => ("已静音", "WarningBrush"),
            MicrophoneFeedbackState.Disconnected => ("设备断开", "DangerBrush"),
            _ => ("未启用", "HudSecondaryTextBrush")
        };
        MicrophoneStateText.Text = LocalizationService.TranslatePhrase(text);
        var brush = (System.Windows.Media.Brush)FindResource(brushKey);
        MicrophoneDot.Fill = brush;
        MicrophoneMeter.Foreground = brush;
        MicrophonePanel.ToolTip = LocalizationService.TranslatePhrase(text);
    }

    private void PositionNearSelection()
    {
        if (_positioning || !IsLoaded || ActualWidth <= 0 || ActualHeight <= 0) return;
        _positioning = true;
        try
        {
            var region = _recording.CurrentRegion;
            var screen = Forms.Screen.FromRectangle(region);
            var transform = (PresentationSource.FromVisual(this) as HwndSource)?
                .CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
            var selectionTopLeft = transform.Transform(new WpfPoint(region.Left, region.Top));
            var selectionBottomRight = transform.Transform(new WpfPoint(region.Right, region.Bottom));
            var workTopLeft = transform.Transform(new WpfPoint(screen.WorkingArea.Left, screen.WorkingArea.Top));
            var workBottomRight = transform.Transform(new WpfPoint(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
            var origin = HudPlacement.GetToolbarOrigin(
                new Rect(selectionTopLeft, selectionBottomRight),
                new WpfSize(ActualWidth, ActualHeight),
                new Rect(workTopLeft, workBottomRight));
            Left = origin.X;
            Top = origin.Y;
        }
        finally
        {
            _positioning = false;
        }
    }

    private void EnsureTopmost()
    {
        var handle = new WindowInteropHelper(this).Handle;
        NativeMethods.SetWindowPos(handle, NativeMethods.HwndTopmost, 0, 0, 0, 0,
            NativeMethods.SwpNoMove | NativeMethods.SwpNoSize | NativeMethods.SwpNoActivate);
    }

    private void StartPulse()
    {
        _pulse ??= (Storyboard)FindResource("RecordingPulseStoryboard");
        _pulse.Stop(this);
        StatusDot.Opacity = 1;
        if (AccessibilityPreferences.ReduceMotion) return;
        _pulse.Begin(this, true);
    }

    private void OnPause(object sender, RoutedEventArgs e)
    {
        _recording.TogglePause();
        RefreshRecordingState();
    }

    private void OnRecordingStateChanged(object? sender, EventArgs e)
    {
        if (Dispatcher.CheckAccess()) RefreshRecordingState();
        else Dispatcher.BeginInvoke(RefreshRecordingState);
    }

    private void RefreshRecordingState()
    {
        var paused = _recording.IsPaused;
        if (_displayedPaused == paused) return;
        _displayedPaused = paused;
        PauseGlyph.Content = FindResource(paused ? "Icon.Resume" : "Icon.Pause");
        PauseButton.ToolTip = paused ? "继续录制" : "暂停录制";
        AutomationProperties.SetName(PauseButton,
            LocalizationService.TranslatePhrase(paused ? "继续录制" : "暂停录制"));
        StatusDot.Fill = (System.Windows.Media.Brush)FindResource(paused ? "WarningBrush" : "Annotation.RedBrush");
        if (paused) _pulse?.Stop(this);
        StatusDot.Opacity = paused ? 0.55 : 1;
        if (!paused) StartPulse();
    }
    public void SetPenActive(bool active)
    {
        PenButton.Background = (System.Windows.Media.Brush)FindResource(active ? "HudSelectedBrush" : "HudInputBrush");
        PenButton.ToolTip = active ? "关闭标注" : "在录制画面上标注";
        AutomationProperties.SetName(PenButton,
            LocalizationService.TranslatePhrase(active ? "关闭录屏标注" : "打开录屏标注"));
    }
    internal Rect GetPenAnchorBounds()
    {
        if (!PenButton.IsLoaded) return new Rect(Left, Top, 0, 0);
        var topLeft = PenButton.PointToScreen(new WpfPoint(0, 0));
        var bottomRight = PenButton.PointToScreen(new WpfPoint(PenButton.ActualWidth, PenButton.ActualHeight));
        if (PresentationSource.FromVisual(this) is HwndSource source)
        {
            topLeft = source.CompositionTarget.TransformFromDevice.Transform(topLeft);
            bottomRight = source.CompositionTarget.TransformFromDevice.Transform(bottomRight);
        }
        return new Rect(topLeft, bottomRight);
    }
    internal Rect GetMonitorWorkingAreaInDips()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var screen = handle == IntPtr.Zero ? Forms.Screen.FromPoint(Forms.Cursor.Position) : Forms.Screen.FromHandle(handle);
        var transform = (PresentationSource.FromVisual(this) as HwndSource)?
            .CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = transform.Transform(new WpfPoint(screen.WorkingArea.Left, screen.WorkingArea.Top));
        var bottomRight = transform.Transform(new WpfPoint(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
        return new Rect(topLeft, bottomRight);
    }
    private void OnWindowMouseDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton != System.Windows.Input.MouseButton.Left) return;
        try
        {
            DragMove();
            _initialPositionApplied = true;
            var settings = _settingsProvider();
            settings.RecordingToolbarLeft = Left;
            settings.RecordingToolbarTop = Top;
            _saveSettings?.Invoke();
        }
        catch (InvalidOperationException) { }
    }
    private void OnStop(object sender, RoutedEventArgs e) => StopRequested?.Invoke(this, EventArgs.Empty);
    private void OnRestart(object sender, RoutedEventArgs e) => RestartRequested?.Invoke(this, EventArgs.Empty);
    private void OnDelete(object sender, RoutedEventArgs e) => DeleteRequested?.Invoke(this, EventArgs.Empty);
    private void OnPen(object sender, RoutedEventArgs e) => PenRequested?.Invoke(this, EventArgs.Empty);

    private static string FormatElapsed(TimeSpan elapsed) => elapsed.TotalHours >= 1
        ? elapsed.ToString(@"hh\:mm\:ss")
        : elapsed.ToString(@"mm\:ss");
}
