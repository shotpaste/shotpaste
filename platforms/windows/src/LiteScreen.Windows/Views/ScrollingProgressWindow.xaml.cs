using System.Windows;
using System.Windows.Interop;
using LiteScreen.Windows.Interop;
using LiteScreen.Windows.Services;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace LiteScreen.Windows.Views;

internal enum ScrollingProgressPhase { Ready, Starting, Capturing, Finalizing, Saving }

public partial class ScrollingProgressWindow : Window
{
    public event EventHandler? StartRequested;
    public event EventHandler? DoneRequested;
    public event EventHandler? CancelRequested;
    public event EventHandler? AutoScrollRequested;
    public bool IsAutoScrollEnabled { get; private set; }
    public bool IsCapturing => _phase == ScrollingProgressPhase.Capturing;
    public bool IsInteractionLocked => _phase is ScrollingProgressPhase.Finalizing or ScrollingProgressPhase.Saving;
    internal ScrollingProgressPhase Phase => _phase;
    internal string PrimaryActionText => PrimaryButton.Content?.ToString() ?? string.Empty;
    private ScrollingProgressPhase _phase = ScrollingProgressPhase.Ready;
    private Drawing.Rectangle? _captureRegion;

    public ScrollingProgressWindow(bool showHints = true)
    {
        InitializeComponent();
        GuidanceText.Visibility = showHints ? Visibility.Visible : Visibility.Collapsed;
        FooterHint.Visibility = showHints ? Visibility.Visible : Visibility.Collapsed;
        ShowInTaskbar = App.UiTestMode;
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | toolWindowStyle | NativeMethods.WsExNoActivate));
            if (!App.UiTestMode) NativeMethods.SetWindowDisplayAffinity(handle, NativeMethods.WdaExcludeFromCapture);
            ApplyPhysicalPlacement();
        };
        SizeChanged += (_, _) => ApplyPhysicalPlacement();
    }

    public void ShowReady(Drawing.Rectangle region)
    {
        _phase = ScrollingProgressPhase.Ready;
        _captureRegion = region;
        ApplyPreviewGeometry(region);
        IsAutoScrollEnabled = false;
        CancelButton.IsEnabled = true;
        PrimaryButton.IsEnabled = true;
        PrimaryButton.Content = PrimaryActionLabel(_phase);
        AutoScrollButton.Visibility = Visibility.Collapsed;
        AutoScrollButton.IsEnabled = false;
        ProgressText.Text = $"选区 {region.Width:N0} × {region.Height:N0} px";
        GuidanceText.Text = "可拖动选区或八个边缘调整范围；只框选会滚动的内容，然后点击开始。";
        TruthBadge.Text = "就绪";
        PreviewPlaceholder.Text = "开始后将在这里实时预览已确认的长图";
        ApplyPhysicalPlacement();
    }

    public void UpdateReadyRegion(Drawing.Rectangle region)
    {
        if (_phase != ScrollingProgressPhase.Ready) return;
        _captureRegion = region;
        ApplyPreviewGeometry(region);
        ProgressText.Text = $"选区 {region.Width:N0} × {region.Height:N0} px";
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
        AutoScrollButton.Visibility = Visibility.Collapsed;
        AutoScrollButton.IsEnabled = false;
        ProgressText.Text = "正在准备滚动截屏…";
        GuidanceText.Text = "正在锁定选区和首帧，请稍候。";
        TruthBadge.Text = "准备中";
    }

    public void BeginCapture(bool autoScrollAvailable)
    {
        _phase = ScrollingProgressPhase.Capturing;
        IsAutoScrollEnabled = false;
        CancelButton.IsEnabled = true;
        PrimaryButton.IsEnabled = true;
        PrimaryButton.Content = PrimaryActionLabel(_phase);
        AutoScrollButton.Content = "自动滚动";
        AutoScrollButton.Visibility = autoScrollAvailable ? Visibility.Visible : Visibility.Collapsed;
        AutoScrollButton.IsEnabled = false;
        ProgressText.Text = "正在锁定首帧…";
        GuidanceText.Text = "首帧锁定后保持单一方向平稳滚动；停下不会结束。";
        TruthBadge.Text = "同步中";
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
        IsAutoScrollEnabled = false;
        CancelButton.IsEnabled = false;
        PrimaryButton.IsEnabled = false;
        PrimaryButton.Content = PrimaryActionLabel(_phase);
        AutoScrollButton.IsEnabled = false;
        AutoScrollButton.Content = "自动滚动";
        ProgressText.Text = "正在补齐最后一屏…";
        GuidanceText.Text = "正在校验尾帧并保存已确认内容，请稍候。";
        TruthBadge.Text = "完成中";
    }

    public void BeginSaving()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(BeginSaving);
            return;
        }
        if (_phase == ScrollingProgressPhase.Saving) return;
        _phase = ScrollingProgressPhase.Saving;
        IsAutoScrollEnabled = false;
        CancelButton.IsEnabled = false;
        PrimaryButton.IsEnabled = false;
        PrimaryButton.Content = PrimaryActionLabel(_phase);
        AutoScrollButton.IsEnabled = false;
        AutoScrollButton.Content = "自动滚动";
        ProgressText.Text = "正在保存长图…";
        GuidanceText.Text = "已锁定拼接结果，正在写入文件，请稍候。";
        TruthBadge.Text = "保存中";
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
        if (progress.Height > 0) ProgressText.Text = $"已拼接 {progress.Frames} 帧 · {progress.Height:N0} px";
        GuidanceText.Text = progress.Status;
        TruthBadge.Text = progress.PreviewTruth switch
        {
            ScrollingPreviewTruth.Ready => "首帧已锁定",
            ScrollingPreviewTruth.CommittedOnly => "已捕获",
            ScrollingPreviewTruth.PausedRecovery => progress.Safety == ScrollingCaptureSafety.Unsafe ? "需减速" : "已暂停",
            ScrollingPreviewTruth.Finalizing => "完成中",
            ScrollingPreviewTruth.Saving => "保存中",
            _ => "同步中"
        };
        TruthBadge.Foreground = progress.Safety == ScrollingCaptureSafety.Unsafe
            ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Colors.Orange)
            : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(112, 229, 138));
        if (progress.Preview is null) return;
        PreviewImage.Source = progress.Preview;
        PreviewPlaceholder.Visibility = Visibility.Collapsed;
        if (_phase == ScrollingProgressPhase.Capturing && AutoScrollButton.Visibility == Visibility.Visible)
            AutoScrollButton.IsEnabled = progress.Frames > 0;
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
    private void OnAutoScroll(object sender, RoutedEventArgs e)
    {
        if (_phase != ScrollingProgressPhase.Capturing || !AutoScrollButton.IsEnabled) return;
        IsAutoScrollEnabled = !IsAutoScrollEnabled;
        AutoScrollButton.Content = IsAutoScrollEnabled ? "停止" : "自动滚动";
        AutoScrollRequested?.Invoke(this, EventArgs.Empty);
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
        var placement = ResolvePhysicalPlacement(region, Forms.Screen.FromRectangle(region).WorkingArea, size);
        NativeMethods.SetWindowPos(
            handle,
            NativeMethods.HwndTopmost,
            placement.X,
            placement.Y,
            placement.Width,
            placement.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpNoOwnerZOrder);
    }

    private void ApplyPreviewGeometry(Drawing.Rectangle region)
    {
        var width = Math.Clamp(region.Width * 0.32d, 240d, 380d);
        var aspect = region.Width / (double)Math.Max(1, region.Height);
        Width = width;
        PreviewRow.Height = new GridLength(Math.Clamp(width / Math.Max(0.45d, aspect), 210d, 420d));
    }

    internal static Drawing.Rectangle ResolvePhysicalPlacement(
        Drawing.Rectangle capture,
        Drawing.Rectangle workingArea,
        Drawing.Size windowSize,
        int gap = 12)
    {
        var right = capture.Right + gap;
        var left = capture.Left - windowSize.Width - gap;
        var x = right + windowSize.Width <= workingArea.Right
            ? right
            : Math.Max(workingArea.Left, left);
        var maxY = Math.Max(workingArea.Top, workingArea.Bottom - windowSize.Height);
        var y = Math.Clamp(capture.Top, workingArea.Top, maxY);
        return new Drawing.Rectangle(x, y, windowSize.Width, windowSize.Height);
    }

    internal static string PrimaryActionLabel(ScrollingProgressPhase phase) => phase switch
    {
        ScrollingProgressPhase.Ready => "开始截取",
        ScrollingProgressPhase.Starting => "准备中",
        ScrollingProgressPhase.Capturing => "完成",
        ScrollingProgressPhase.Finalizing => "完成中",
        ScrollingProgressPhase.Saving => "保存中",
        _ => string.Empty
    };
}
