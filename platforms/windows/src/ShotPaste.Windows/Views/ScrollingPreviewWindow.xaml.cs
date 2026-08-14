using System.Windows;
using System.Windows.Interop;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Views;

public partial class ScrollingPreviewWindow : Window
{
    private Drawing.Rectangle? _captureRegion;

    public ScrollingPreviewWindow()
    {
        InitializeComponent();
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
        _captureRegion = region;
        PreviewImage.Source = null;
        PreviewPlaceholder.Visibility = Visibility.Visible;
        HeightText.Text = "0 px";
        TruthText.Text = "仅预览已确认帧";
        ApplyPhysicalPlacement();
    }

    public void UpdateProgress(ScrollingCaptureProgress progress)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => UpdateProgress(progress));
            return;
        }
        HeightText.Text = $"{progress.Height:N0} px";
        TruthText.Text = progress.PreviewTruth switch
        {
            ScrollingPreviewTruth.PausedRecovery => "已暂停 · 成果保留",
            ScrollingPreviewTruth.Finalizing => "正在补齐尾帧",
            ScrollingPreviewTruth.Saving => "结果已锁定",
            _ => "仅预览已确认帧"
        };
        if (progress.Preview is null) return;
        PreviewImage.Source = progress.Preview;
        PreviewPlaceholder.Visibility = Visibility.Collapsed;
    }

    private void ApplyPhysicalPlacement()
    {
        if (_captureRegion is not { } region || ActualWidth <= 0 || ActualHeight <= 0 ||
            PresentationSource.FromVisual(this) is not HwndSource source) return;
        var handle = source.Handle;
        var dpi = Math.Max(96u, NativeMethods.GetDpiForWindow(handle));
        var size = new Drawing.Size(
            Math.Max(1, (int)Math.Ceiling(ActualWidth * dpi / 96d)),
            Math.Max(1, (int)Math.Ceiling(ActualHeight * dpi / 96d)));
        var placement = ResolvePhysicalPlacement(region, Forms.Screen.FromRectangle(region).WorkingArea, size);
        NativeMethods.SetWindowPos(handle, NativeMethods.HwndTopmost, placement.X, placement.Y,
            placement.Width, placement.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpNoOwnerZOrder);
    }

    internal static Drawing.Rectangle ResolvePhysicalPlacement(
        Drawing.Rectangle capture,
        Drawing.Rectangle workingArea,
        Drawing.Size windowSize,
        int gap = 12)
    {
        var left = capture.Left - windowSize.Width - gap;
        var right = capture.Right + gap;
        var x = left >= workingArea.Left
            ? left
            : right + windowSize.Width <= workingArea.Right
                ? right
                : Math.Max(workingArea.Left, workingArea.Right - windowSize.Width - gap);
        var y = Math.Clamp(capture.Top, workingArea.Top, Math.Max(workingArea.Top, workingArea.Bottom - windowSize.Height));
        return new Drawing.Rectangle(x, y, windowSize.Width, windowSize.Height);
    }
}
