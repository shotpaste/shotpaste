using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LiteScreen.Windows.Models;
using LiteScreen.Windows.Interop;
using WpfButton = System.Windows.Controls.Button;

namespace LiteScreen.Windows.Views;

public partial class QuickAccessWindow : Window
{
    private readonly CaptureHistoryItem _item;
    private readonly Services.AppController _controller;
    private readonly Services.SettingsStore _settings;
    private readonly DispatcherTimer _timer = new();
    private readonly DispatcherTimer _hoverProbeTimer = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private readonly Services.QuickAccessCountdown _countdown;
    private Vector _manipulationTranslation;
    private int _maximumManipulators;
    private double _horizontalWheelDistance;
    private HwndSource? _windowSource;
    private bool _isPointerOver;
    private readonly bool _isTemporary;
    private bool AutoDismissEnabled => _settings.Current.QuickAccessAutoDismissEnabled;

    public CaptureHistoryItem Item => _item;

    public QuickAccessWindow(CaptureHistoryItem item, Services.AppController controller, Services.SettingsStore settings)
    {
        App.WriteQuickAccessLog($"Initialize item kind={item.Kind} file={(string.IsNullOrWhiteSpace(item.FilePath) ? "(null)" : item.FilePath)}");
        InitializeComponent();
        ShowInTaskbar = App.UiTestMode;
        _item = item;
        _controller = controller;
        _settings = settings;
        _countdown = new Services.QuickAccessCountdown(TimeSpan.FromSeconds(
            Math.Clamp(settings.Current.QuickAccessAutoDismissSeconds, 3, 30)));
        var preview = default(System.Windows.Media.Imaging.BitmapImage);
        try
        {
            preview = item.PreviewSource;
        }
        catch
        {
            // 保持容错：缩略图加载失败时展示文字预览，不影响弹窗显示。
        }
        Preview.Source = preview;
        TitleText.Text = item.Title;
        DataContext = item;
        if (preview is null)
        {
            TextPreview.Visibility = Visibility.Visible;
            TextPreviewContent.Text = item.PreviewText;
        }
        var isTemporary = false;
        try
        {
            isTemporary = !string.IsNullOrWhiteSpace(item.FilePath) &&
                          Path.GetFullPath(item.FilePath).StartsWith(Path.GetFullPath(Services.AppPaths.Captures), StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            isTemporary = false;
        }
        _isTemporary = isTemporary;
        if (item.Duration is { } duration)
        {
            DurationBadge.Visibility = Visibility.Visible;
            DurationText.Text = duration.ToString(duration.TotalHours >= 1 ? @"hh\:mm\:ss" : @"mm\:ss");
        }
        SaveAction.Content = isTemporary ? "保存" : "打开";
        ConfigureActions(isTemporary);
        var cardScale = Math.Clamp(settings.Current.QuickAccessScale, 0.75, 1.5);
        Card.LayoutTransform = new ScaleTransform(cardScale, cardScale);
        Width = 204 * cardScale;
        Height = 128 * cardScale;
        Loaded += (_, _) =>
        {
            if (AutoDismissEnabled) ResetCountdown();
            if (_settings.Current.QuickAccessAnimationStyle.Equals("Scale", StringComparison.OrdinalIgnoreCase))
            {
                Card.Opacity = 0;
                Card.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
                var transform = new ScaleTransform(0.88, 0.88);
                Card.RenderTransform = transform;
                var duration = TimeSpan.FromMilliseconds(190);
                transform.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, duration));
                transform.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, duration));
                Card.BeginAnimation(OpacityProperty, new DoubleAnimation(1, duration));
            }
            else
            {
                Card.Opacity = 0;
                var start = Services.QuickAccessService.NormalizePosition(_settings.Current.QuickAccessPosition) == "BottomLeft"
                    ? -28d
                    : 28d;
                var transform = new TranslateTransform(start, 0);
                Card.RenderTransform = transform;
                var duration = TimeSpan.FromMilliseconds(190);
                transform.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, duration));
                Card.BeginAnimation(OpacityProperty, new DoubleAnimation(1, duration));
            }
            App.WriteQuickAccessLog($"Loaded shown={IsVisible} left={Left} top={Top} width={Width} height={Height} dpi={VisualTreeHelper.GetDpi(this).PixelsPerDip}");
        };
        _timer.Tick += (_, _) =>
        {
            _timer.Stop();
            if (_countdown.Remaining(DateTimeOffset.UtcNow) <= TimeSpan.Zero) Close();
            else ArmCountdown(_countdown.Remaining(DateTimeOffset.UtcNow));
        };
        _hoverProbeTimer.Tick += (_, _) =>
        {
            // Native ShowWindow/SetWindowPos calls can occasionally suppress the
            // WPF MouseLeave notification. Poll only while paused so the saved
            // countdown always resumes after the pointer physically leaves.
            if (IsPointerInsideWindow()) return;
            _isPointerOver = false;
            ResumeCountdown();
        };
        SourceInitialized += (_, _) =>
        {
            _windowSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
            _windowSource?.AddHook(WindowProcedure);
        };
        Closed += (_, _) =>
        {
            _timer.Stop();
            _hoverProbeTimer.Stop();
            _windowSource?.RemoveHook(WindowProcedure);
            _windowSource = null;
        };
        MouseEnter += (_, _) =>
        {
            _isPointerOver = true;
            if (_settings.Current.PauseQuickAccessOnHover) PauseCountdown();
        };
        MouseLeave += (_, _) =>
        {
            _isPointerOver = false;
            if (AutoDismissEnabled) ResumeCountdown();
        };
    }

    private void OnCardMouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
    {
        HoverOverlay.IsHitTestVisible = true;
        AnimateOpacity(HoverOverlay, 1);
        AnimateOpacity(PinButton, 1);
        AnimateOpacity(CloseButton, 1);
        TitleBadge.Opacity = 0;
        DurationBadge.Opacity = 0;
    }

    private void OnCardMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        HoverOverlay.IsHitTestVisible = false;
        AnimateOpacity(HoverOverlay, 0);
        AnimateOpacity(PinButton, 0);
        AnimateOpacity(CloseButton, 0);
        TitleBadge.Opacity = 1;
        DurationBadge.Opacity = 1;
    }

    private void AnimateOpacity(UIElement element, double value)
    {
        if (_settings.Current.QuickAccessAnimationStyle.Equals("None", StringComparison.OrdinalIgnoreCase))
        {
            element.BeginAnimation(OpacityProperty, null);
            element.Opacity = value;
            return;
        }
        var duration = _settings.Current.QuickAccessAnimationStyle.Equals("Scale", StringComparison.OrdinalIgnoreCase)
            ? TimeSpan.FromMilliseconds(190)
            : TimeSpan.FromMilliseconds(145);
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(value, duration));
    }

    public void ResetCountdown()
    {
        _timer.Stop();
        if (!AutoDismissEnabled) return;
        var now = DateTimeOffset.UtcNow;
        var remaining = _countdown.Reset(now);
        // Clipboard notifications can rediscover the same capture while the card
        // is already open. Reusing it must not silently cancel hover-to-pause.
        if (_settings.Current.PauseQuickAccessOnHover && (_isPointerOver || IsPointerInsideWindow()))
        {
            _countdown.Pause(now);
            _hoverProbeTimer.Start();
        }
        else
            ArmCountdown(remaining);
    }

    private bool IsPointerInsideWindow()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero ||
            !NativeMethods.GetCursorPos(out var cursor) ||
            !NativeMethods.GetWindowRect(handle, out var bounds))
            return false;
        return cursor.X >= bounds.Left && cursor.X < bounds.Right &&
               cursor.Y >= bounds.Top && cursor.Y < bounds.Bottom;
    }

    internal void ReconcilePointerCountdown()
    {
        if (!AutoDismissEnabled || !_settings.Current.PauseQuickAccessOnHover || !IsPointerInsideWindow()) return;
        _isPointerOver = true;
        PauseCountdown();
    }

    private void PauseCountdown()
    {
        if (!AutoDismissEnabled) return;
        _countdown.Pause(DateTimeOffset.UtcNow);
        _timer.Stop();
        _hoverProbeTimer.Start();
    }

    private void ResumeCountdown()
    {
        if (!AutoDismissEnabled) return;
        _hoverProbeTimer.Stop();
        var remaining = _countdown.Resume(DateTimeOffset.UtcNow);
        if (remaining <= TimeSpan.Zero) Close();
        else ArmCountdown(remaining);
    }

    private void ArmCountdown(TimeSpan remaining)
    {
        _timer.Stop();
        _timer.Interval = remaining < TimeSpan.FromMilliseconds(10) ? TimeSpan.FromMilliseconds(10) : remaining;
        _timer.Start();
    }

    private void ConfigureActions(bool isTemporary)
    {
        var configured = _settings.Current.QuickAccessActions ?? [];
        SaveAction.Content = isTemporary ? "保存" : "打开";
        var actions = new Dictionary<string, WpfButton>(StringComparer.OrdinalIgnoreCase)
        {
            ["Copy"] = CopyAction,
            ["SaveOrOpen"] = SaveAction,
            ["Pin"] = PinAction,
            ["Delete"] = DeleteAction,
            ["Close"] = CloseAction
        };
        Actions.Children.Clear();
        foreach (var action in configured)
        {
            if (!actions.TryGetValue(action, out var button) || Actions.Children.Contains(button)) continue;
            button.Visibility = Visibility.Visible;
            Actions.Children.Add(button);
        }
    }

    private void OnWindowMouseDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && Actions.IsAncestorOf(source)) return;
        if (e.ChangedButton == System.Windows.Input.MouseButton.Left && _settings.Current.QuickAccessEnableDrag)
        {
            try { DragMove(); } catch (InvalidOperationException) { }
        }
    }

    private void OnManipulationDelta(object sender, System.Windows.Input.ManipulationDeltaEventArgs e)
    {
        _manipulationTranslation = e.CumulativeManipulation.Translation;
        _maximumManipulators = Math.Max(_maximumManipulators, e.Manipulators.Count());
    }

    private void OnManipulationCompleted(object sender, System.Windows.Input.ManipulationCompletedEventArgs e)
    {
        var manipulatorCount = Math.Max(_maximumManipulators, e.Manipulators.Count());
        _maximumManipulators = 0;
        if (!_settings.Current.QuickAccessTwoFingerSwipeEnabled || manipulatorCount < 2) return;
        var translation = _manipulationTranslation;
        _manipulationTranslation = default;
        if (_settings.Current.QuickAccessTrackpadSwipeMode.Equals("Inverted", StringComparison.OrdinalIgnoreCase))
            translation.X *= -1;
        var threshold = 80d / Math.Max(0.5d, _settings.Current.QuickAccessSwipeSensitivity);
        if (Math.Abs(translation.X) >= threshold && Math.Abs(translation.X) > Math.Abs(translation.Y))
            _ = ExecuteConfiguredActionAsync(translation.X < 0
                ? _settings.Current.QuickAccessSwipeLeftAction
                : _settings.Current.QuickAccessSwipeRightAction);
    }
    private async Task ExecuteConfiguredActionAsync(string? action)
    {
        switch (action?.Trim().ToLowerInvariant())
        {
            case "copy": _controller.CopyHistoryItem(_item); Close(); break;
            case "saveoropen":
                if (_isTemporary) await _controller.SaveHistoryItemAsync(_item);
                else await _controller.OpenHistoryItemAsync(_item);
                Close();
                break;
            case "save": await _controller.SaveHistoryItemAsync(_item); Close(); break;
            case "open": await _controller.OpenHistoryItemAsync(_item); Close(); break;
            case "pin": _controller.PinHistoryItem(_item); break;
            case "delete": await _controller.DeleteHistoryItemAsync(_item); Close(); break;
            case "none": break;
            default: Close(); break;
        }
    }
    private void OnCopy(object sender, RoutedEventArgs e) => _ = ExecuteConfiguredActionAsync("Copy");
    private void OnSave(object sender, RoutedEventArgs e) => _ = ExecuteConfiguredActionAsync("SaveOrOpen");
    private void OnOpen(object sender, RoutedEventArgs e) => _ = ExecuteConfiguredActionAsync("Open");
    private void OnPin(object sender, RoutedEventArgs e) => _ = ExecuteConfiguredActionAsync("Pin");
    private void OnDelete(object sender, RoutedEventArgs e) => _ = ExecuteConfiguredActionAsync("Delete");
    private void OnClose(object sender, RoutedEventArgs e) => _ = ExecuteConfiguredActionAsync("Close");

    private void OnDragOut(object sender, MouseButtonEventArgs e)
    {
        var data = new System.Windows.DataObject();
        if (_item.FilePaths.Count > 0 && _item.ExistingFilePaths.Count > 0)
            data.SetData(System.Windows.DataFormats.FileDrop, _item.ExistingFilePaths.Select(Path.GetFullPath).ToArray());
        else if (!string.IsNullOrWhiteSpace(_item.FilePath) && File.Exists(_item.FilePath))
            data.SetData(System.Windows.DataFormats.FileDrop, new[] { Path.GetFullPath(_item.FilePath) });
        else if (!string.IsNullOrWhiteSpace(_item.Text))
            data.SetData(System.Windows.DataFormats.UnicodeText, _item.Text);
        else return;
        PauseCountdown();
        System.Windows.DragDrop.DoDragDrop(this, data, System.Windows.DragDropEffects.Copy);
        if (AutoDismissEnabled) ResumeCountdown();
        e.Handled = true;
    }

    public void Suspend()
    {
        PauseCountdown();
        Hide();
    }

    public void Resume()
    {
        Show();
        if (AutoDismissEnabled) ResumeCountdown();
    }

    private IntPtr WindowProcedure(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != NativeMethods.WmMouseHwheels || !_settings.Current.QuickAccessTwoFingerSwipeEnabled)
            return IntPtr.Zero;
        var delta = unchecked((short)((wParam.ToInt64() >> 16) & 0xffff));
        if (_settings.Current.QuickAccessTrackpadSwipeMode.Equals("Inverted", StringComparison.OrdinalIgnoreCase))
            delta *= -1;
        _horizontalWheelDistance += delta * Math.Max(0.5, _settings.Current.QuickAccessSwipeSensitivity);
        if (Math.Abs(_horizontalWheelDistance) >= 120)
        {
            handled = true;
            var action = _horizontalWheelDistance < 0
                ? _settings.Current.QuickAccessSwipeLeftAction
                : _settings.Current.QuickAccessSwipeRightAction;
            _horizontalWheelDistance = 0;
            Dispatcher.BeginInvoke(() => _ = ExecuteConfiguredActionAsync(action));
        }
        return IntPtr.Zero;
    }
}
