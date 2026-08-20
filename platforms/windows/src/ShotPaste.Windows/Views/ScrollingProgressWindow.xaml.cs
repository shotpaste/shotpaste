using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Views;

internal enum ScrollingProgressPhase { Ready, Starting, Capturing, Finalizing, Saving, SaveFailed }
internal enum ScrollingSaveRecoveryAction { Retry, SaveAs, Copy, Discard, DiscardConfirmed }

public partial class ScrollingProgressWindow : Window
{
    public event EventHandler? StartRequested;
    public event EventHandler? DoneRequested;
    public event EventHandler? CancelRequested;
    public bool IsCapturing => _phase == ScrollingProgressPhase.Capturing;
    public bool IsInteractionLocked => _phase is ScrollingProgressPhase.Finalizing or ScrollingProgressPhase.Saving;
    internal ScrollingProgressPhase Phase => _phase;
    internal string PrimaryActionText => PrimaryButton.Content?.ToString() ?? string.Empty;
    private ScrollingProgressPhase _phase = ScrollingProgressPhase.Ready;
    private Drawing.Rectangle? _captureRegion;
    private TaskCompletionSource<ScrollingSaveRecoveryAction>? _saveRecovery;
    private readonly ScrollingPreviewWindow? _previewWindow;
    private bool _allowClose;

    public ScrollingProgressWindow(bool showHints = true, ScrollingPreviewWindow? previewWindow = null)
    {
        InitializeComponent();
        _previewWindow = previewWindow;
        _ = showHints;
        WindowAppearanceService.Attach(this, WindowBackdropKind.Acrylic);
        ShowInTaskbar = App.UiTestMode;
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | toolWindowStyle | NativeMethods.WsExNoActivate));
            if (!App.UiTestMode) WindowCaptureExclusionService.ExcludeCaptureControl(handle);
            ApplyPhysicalPlacement();
        };
        SizeChanged += (_, _) => ApplyPhysicalPlacement();
        Closing += OnClosing;
        Closed += (_, _) =>
        {
            _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.Discard);
        };
    }

    public void ShowReady(Drawing.Rectangle region)
    {
        _phase = ScrollingProgressPhase.Ready;
        _captureRegion = region;
        _previewWindow?.ShowReady(region);
        CompactHud.Visibility = Visibility.Visible;
        SaveRecoveryPanel.Visibility = Visibility.Collapsed;
        CancelButton.IsEnabled = true;
        PrimaryButton.IsEnabled = true;
        PrimaryButton.Content = PrimaryActionLabel(_phase);
        PrimaryButton.ContentTemplate = null;
        PrimaryButton.Padding = new Thickness(14, 5, 14, 5);
        Grid.SetColumn(PrimaryButton, 0);
        Grid.SetColumn(CancelButton, 1);
        CancelButton.Margin = new Thickness(8, 0, 0, 0);
        ApplyPhysicalPlacement();
    }

    public void UpdateReadyRegion(Drawing.Rectangle region)
    {
        if (_phase != ScrollingProgressPhase.Ready) return;
        _captureRegion = region;
        _previewWindow?.ShowReady(region);
        ApplyPhysicalPlacement();
    }

    public void BeginStarting()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(BeginStarting);
            return;
        }
        if (_phase != ScrollingProgressPhase.Ready) return;
        _phase = ScrollingProgressPhase.Starting;
        CancelButton.IsEnabled = true;
        PrimaryButton.Content = PrimaryActionLabel(_phase);
        PrimaryButton.IsEnabled = false;
        ApplyPhysicalPlacement();
    }

    public void BeginCapture(bool autoScrollAvailable)
    {
        _ = autoScrollAvailable;
        SetNoActivate(true);
        _phase = ScrollingProgressPhase.Capturing;
        CancelButton.IsEnabled = true;
        PrimaryButton.IsEnabled = true;
        PrimaryButton.Content = FindResource("Icon.Check");
        PrimaryButton.ContentTemplate = FindResource("Icon.Template") as DataTemplate;
        PrimaryButton.Padding = new Thickness(0);
        PrimaryButton.Width = 30;
        PrimaryButton.Height = 28;
        Grid.SetColumn(CancelButton, 0);
        Grid.SetColumn(PrimaryButton, 1);
        CancelButton.Margin = new Thickness(0);
        PrimaryButton.Margin = new Thickness(8, 0, 0, 0);
        ApplyPhysicalPlacement();
    }

    public void BeginFinalizing()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(BeginFinalizing);
            return;
        }
        if (_phase is ScrollingProgressPhase.Finalizing or ScrollingProgressPhase.Saving) return;
        _phase = ScrollingProgressPhase.Finalizing;
        CancelButton.IsEnabled = false;
        PrimaryButton.IsEnabled = false;
    }

    public void BeginSaving()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(BeginSaving);
            return;
        }
        if (_phase == ScrollingProgressPhase.Saving) return;
        SetNoActivate(true);
        _phase = ScrollingProgressPhase.Saving;
        CompactHud.Visibility = Visibility.Visible;
        SaveRecoveryPanel.Visibility = Visibility.Collapsed;
        CancelButton.IsEnabled = false;
        PrimaryButton.IsEnabled = false;
    }

    internal Task<ScrollingSaveRecoveryAction> WaitForSaveRecoveryActionAsync(string detail)
    {
        if (!Dispatcher.CheckAccess())
            return Dispatcher.Invoke(() => WaitForSaveRecoveryActionAsync(detail));

        _phase = ScrollingProgressPhase.SaveFailed;
        CompactHud.Visibility = Visibility.Collapsed;
        SaveRecoveryPanel.Visibility = Visibility.Visible;
        RecoveryDetail.Text = detail;
        _saveRecovery = new TaskCompletionSource<ScrollingSaveRecoveryAction>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        SetNoActivate(false);
        if (_previewWindow?.IsVisible != true) _previewWindow?.Show();
        if (!IsVisible) Show();
        Activate();
        RetrySaveButton.Focus();
        return _saveRecovery.Task;
    }

    public void PositionNear(Drawing.Rectangle region)
    {
        _captureRegion = region;
        ApplyPhysicalPlacement();
    }

    public void UpdateProgress(ScrollingCaptureProgress progress)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => UpdateProgress(progress));
            return;
        }
        if (!IsLoaded) return;
        if (progress.PreviewTruth == ScrollingPreviewTruth.Saving) BeginSaving();
        _previewWindow?.UpdateProgress(progress);
    }

    private void OnPrimary(object sender, RoutedEventArgs e)
    {
        if (_phase is ScrollingProgressPhase.Starting or ScrollingProgressPhase.Finalizing) return;
        if (_phase == ScrollingProgressPhase.Capturing)
        {
            DoneRequested?.Invoke(this, EventArgs.Empty);
            return;
        }
        if (_phase != ScrollingProgressPhase.Ready) return;

        // Leave the ready state synchronously with the click. Even if capture setup
        // takes a dispatcher turn, the UI must never continue to advertise “开始”.
        BeginStarting();
        StartRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnCancel(object sender, RoutedEventArgs e)
    {
        if (IsInteractionLocked) return;
        CancelRequested?.Invoke(this, EventArgs.Empty);
    }
    private void OnRetrySave(object sender, RoutedEventArgs e) =>
        _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.Retry);

    private void OnSaveAs(object sender, RoutedEventArgs e) =>
        _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.SaveAs);

    private void OnCopyResult(object sender, RoutedEventArgs e) =>
        _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.Copy);

    private void OnDiscardResult(object sender, RoutedEventArgs e) =>
        _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.Discard);

    internal bool RequestCloseForExit()
    {
        switch (_phase)
        {
            case ScrollingProgressPhase.Ready:
                CancelRequested?.Invoke(this, EventArgs.Empty);
                return true;
            case ScrollingProgressPhase.Starting:
            case ScrollingProgressPhase.Capturing:
            {
                var decision = LocalizedDialogService.ShowCustom(
                    this,
                    "滚动截屏尚未完成。确定丢弃当前捕获并退出吗？",
                    "退出滚动截屏？",
                    "丢弃并退出",
                    "返回",
                    MessageBoxImage.Warning);
                if (decision != MessageBoxResult.Yes) return false;
                CancelRequested?.Invoke(this, EventArgs.Empty);
                return true;
            }
            case ScrollingProgressPhase.Finalizing:
            case ScrollingProgressPhase.Saving:
                // The controller waits for the protected write/finalization workflow
                // before it is allowed to shut the application down.
                return true;
            case ScrollingProgressPhase.SaveFailed:
            {
                var decision = LocalizedDialogService.ShowCustom(
                    this,
                    "长图尚未保存。确定丢弃当前合并成果并退出吗？此操作无法恢复。",
                    "退出并丢弃长图？",
                    "丢弃并退出",
                    "返回",
                    MessageBoxImage.Warning);
                if (decision != MessageBoxResult.Yes) return false;
                _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.DiscardConfirmed);
                return true;
            }
            default:
                return false;
        }
    }

    internal void CloseAfterWorkflow()
    {
        _allowClose = true;
        Close();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        switch (_phase)
        {
            case ScrollingProgressPhase.Ready:
            case ScrollingProgressPhase.Starting:
            case ScrollingProgressPhase.Capturing:
                CancelRequested?.Invoke(this, EventArgs.Empty);
                break;
            case ScrollingProgressPhase.SaveFailed:
                // Route Alt+F4, WM_CLOSE and UIA WindowPattern.Close through the same
                // discard confirmation as the visible recovery action. Keeping the
                // window alive also keeps the in-memory merged bitmap reachable.
                _saveRecovery?.TrySetResult(ScrollingSaveRecoveryAction.Discard);
                break;
        }
    }

    private void ApplyPhysicalPlacement()
    {
        if (_captureRegion is null || ActualWidth <= 0 || ActualHeight <= 0) return;
        var region = _captureRegion.Value;
        if (PresentationSource.FromVisual(this) is not HwndSource source) return;

        var handle = source.Handle;
        if (handle == IntPtr.Zero) return;
        var dpi = NativeMethods.GetDpiForWindow(handle);
        if (dpi == 0) dpi = 96;
        var size = new Drawing.Size(
            Math.Max(1, (int)Math.Ceiling(ActualWidth * dpi / 96d)),
            Math.Max(1, (int)Math.Ceiling(ActualHeight * dpi / 96d)));
        var placement = ResolvePhysicalPlacement(
            region,
            Forms.Screen.FromRectangle(region).WorkingArea,
            size,
            alignTrailing: _phase is not (ScrollingProgressPhase.Ready or ScrollingProgressPhase.Starting));
        NativeMethods.SetWindowPos(
            handle,
            NativeMethods.HwndTopmost,
            placement.X,
            placement.Y,
            placement.Width,
            placement.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpNoOwnerZOrder);
    }

    private void SetNoActivate(bool enabled)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
        var updated = enabled
            ? style | NativeMethods.WsExNoActivate
            : style & ~(long)NativeMethods.WsExNoActivate;
        if (updated != style)
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, new IntPtr(updated));
    }

    internal static Drawing.Rectangle ResolvePhysicalPlacement(
        Drawing.Rectangle capture,
        Drawing.Rectangle workingArea,
        Drawing.Size windowSize,
        int gap = 12,
        bool alignTrailing = false)
    {
        var preferredX = alignTrailing
            ? capture.Right - windowSize.Width
            : capture.Left + (capture.Width - windowSize.Width) / 2;
        var x = Math.Clamp(
            preferredX,
            workingArea.Left + gap,
            Math.Max(workingArea.Left + gap, workingArea.Right - windowSize.Width - gap));
        var below = capture.Bottom + gap;
        var above = capture.Top - windowSize.Height - gap;
        var y = below + windowSize.Height <= workingArea.Bottom
            ? below
            : Math.Max(workingArea.Top + gap, above);
        return new Drawing.Rectangle(x, y, windowSize.Width, windowSize.Height);
    }

    internal static string PrimaryActionLabel(ScrollingProgressPhase phase) => phase switch
    {
        ScrollingProgressPhase.Ready => "开始截取",
        ScrollingProgressPhase.Starting => "准备中",
        ScrollingProgressPhase.Capturing => "完成",
        ScrollingProgressPhase.Finalizing => "完成中",
        ScrollingProgressPhase.Saving => "保存中",
        ScrollingProgressPhase.SaveFailed => "等待重试",
        _ => string.Empty
    };
}
