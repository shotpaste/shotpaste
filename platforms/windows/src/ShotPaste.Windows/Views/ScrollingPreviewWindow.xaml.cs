using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Views;

public partial class ScrollingPreviewWindow : Window
{
    private const int MaximumPreviewWidth = 220;
    private const int MaximumPreviewHeight = 420;
    private const int AnimationDurationMs = 35;

    private Drawing.Rectangle? _captureRegion;
    private readonly System.Windows.Threading.DispatcherTimer _animationTimer;
    private Drawing.Rectangle _animationFrom;
    private Drawing.Rectangle _animationTo;
    private long _animationStarted;

    public ScrollingPreviewWindow()
    {
        InitializeComponent();
        ShowInTaskbar = App.UiTestMode;
        _animationTimer = new System.Windows.Threading.DispatcherTimer(
            TimeSpan.FromMilliseconds(10),
            System.Windows.Threading.DispatcherPriority.Render,
            (_, _) => AdvancePlacementAnimation(),
            Dispatcher);
        _animationTimer.Stop();
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | toolWindowStyle | NativeMethods.WsExNoActivate | NativeMethods.WsExTransparent));
            if (!App.UiTestMode) WindowCaptureExclusionService.ExcludeCaptureControl(handle);
        };
        Closed += (_, _) => _animationTimer.Stop();
    }

    public void ShowReady(Drawing.Rectangle region)
    {
        _captureRegion = region;
        _animationTimer.Stop();
        PreviewImage.Source = null;
        if (IsVisible) Hide();
    }

    public void UpdateProgress(ScrollingCaptureProgress progress)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => UpdateProgress(progress));
            return;
        }
        if (progress.Preview is null || _captureRegion is not { } region) return;

        PreviewImage.Source = progress.Preview;
        var workingArea = Forms.Screen.FromRectangle(region).WorkingArea;
        var size = ResolvePreviewSize(
            progress.Preview.PixelWidth,
            progress.Preview.PixelHeight,
            region,
            workingArea);
        Width = Math.Max(1, size.Width);
        Height = Math.Max(1, size.Height);
        if (!IsVisible)
        {
            Show();
            ApplyPhysicalPlacement(animate: false);
        }
        else
        {
            ApplyPhysicalPlacement(animate: true);
        }
    }

    private void ApplyPhysicalPlacement(bool animate)
    {
        if (_captureRegion is not { } region || PreviewImage.Source is not System.Windows.Media.Imaging.BitmapSource image ||
            PresentationSource.FromVisual(this) is not HwndSource source) return;
        var handle = source.Handle;
        if (handle == IntPtr.Zero) return;
        var workingArea = Forms.Screen.FromRectangle(region).WorkingArea;
        var logicalSize = ResolvePreviewSize(image.PixelWidth, image.PixelHeight, region, workingArea);
        var dpi = Math.Max(96u, NativeMethods.GetDpiForWindow(handle));
        var physicalSize = new Drawing.Size(
            Math.Max(1, (int)Math.Ceiling(logicalSize.Width * dpi / 96d)),
            Math.Max(1, (int)Math.Ceiling(logicalSize.Height * dpi / 96d)));
        var target = ResolvePhysicalPlacement(region, workingArea, physicalSize);
        if (!animate || !NativeMethods.GetWindowRect(handle, out var currentBounds))
        {
            SetPhysicalFrame(handle, target);
            return;
        }

        var current = Drawing.Rectangle.FromLTRB(
            currentBounds.Left,
            currentBounds.Top,
            currentBounds.Right,
            currentBounds.Bottom);
        if (FramesAreVisuallyEqual(current, target))
        {
            SetPhysicalFrame(handle, target);
            return;
        }
        _animationFrom = current;
        _animationTo = target;
        _animationStarted = Environment.TickCount64;
        _animationTimer.Start();
    }

    private void AdvancePlacementAnimation()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            _animationTimer.Stop();
            return;
        }
        var elapsed = Math.Max(0, Environment.TickCount64 - _animationStarted);
        var progress = Math.Min(1, elapsed / (double)AnimationDurationMs);
        var eased = 1 - Math.Pow(1 - progress, 2);
        var frame = Interpolate(_animationFrom, _animationTo, eased);
        SetPhysicalFrame(handle, frame);
        if (progress >= 1) _animationTimer.Stop();
    }

    private static void SetPhysicalFrame(IntPtr handle, Drawing.Rectangle frame) =>
        NativeMethods.SetWindowPos(
            handle,
            NativeMethods.HwndTopmost,
            frame.X,
            frame.Y,
            frame.Width,
            frame.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpNoOwnerZOrder);

    internal static Drawing.Size ResolvePreviewSize(
        int imageWidth,
        int imageHeight,
        Drawing.Rectangle capture,
        Drawing.Rectangle workingArea)
    {
        if (imageWidth <= 0 || imageHeight <= 0) return Drawing.Size.Empty;
        var availableHeight = Math.Max(1, Math.Min(MaximumPreviewHeight, workingArea.Height - 24));
        var preferredWidth = Math.Max(1, Math.Min(MaximumPreviewWidth, (int)Math.Ceiling(capture.Width * 0.56)));
        var scale = Math.Min(
            preferredWidth / (double)imageWidth,
            availableHeight / (double)imageHeight);
        return new Drawing.Size(
            Math.Max(1, (int)Math.Ceiling(imageWidth * scale)),
            Math.Max(1, (int)Math.Ceiling(imageHeight * scale)));
    }

    internal static Drawing.Rectangle ResolvePhysicalPlacement(
        Drawing.Rectangle capture,
        Drawing.Rectangle workingArea,
        Drawing.Size windowSize,
        int gap = 12)
    {
        var right = capture.Right + gap;
        var left = capture.Left - windowSize.Width - gap;
        var x = right + windowSize.Width <= workingArea.Right - gap
            ? right
            : Math.Max(workingArea.Left + gap, left);
        var y = Math.Clamp(
            capture.Top,
            workingArea.Top + gap,
            Math.Max(workingArea.Top + gap, workingArea.Bottom - windowSize.Height - gap));
        return new Drawing.Rectangle(x, y, windowSize.Width, windowSize.Height);
    }

    internal static Drawing.Rectangle Interpolate(
        Drawing.Rectangle from,
        Drawing.Rectangle to,
        double progress)
    {
        var amount = Math.Clamp(progress, 0, 1);
        return new Drawing.Rectangle(
            (int)Math.Round(from.X + (to.X - from.X) * amount),
            (int)Math.Round(from.Y + (to.Y - from.Y) * amount),
            Math.Max(1, (int)Math.Round(from.Width + (to.Width - from.Width) * amount)),
            Math.Max(1, (int)Math.Round(from.Height + (to.Height - from.Height) * amount)));
    }

    private static bool FramesAreVisuallyEqual(Drawing.Rectangle left, Drawing.Rectangle right) =>
        Math.Abs(left.X - right.X) < 1 &&
        Math.Abs(left.Y - right.Y) < 1 &&
        Math.Abs(left.Width - right.Width) < 1 &&
        Math.Abs(left.Height - right.Height) < 1;
}
