using System.Windows;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Utilities;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Services;

public sealed class RegionSelectionService(
    ScreenCaptureService screenCapture,
    Func<ScreenCaptureOptions>? optionsProvider = null,
    Func<AppSettings>? settingsProvider = null,
    Action? saveSettings = null)
{
    public async Task<OneShotResult?> SelectOneShotAsync(
        OneShotRecordingOptions recordingOptions,
        Func<Window, Drawing.Bitmap, bool, Task<bool>>? screenshotCommit = null,
        OneShotMode initialMode = OneShotMode.Screenshot)
    {
        var options = optionsProvider?.Invoke();
        using var trace = SelectionPerformanceTrace.Start("OneShot", screenCapture.VirtualBounds);
        using var visibility = options?.ExcludeOwnApplication == false
            ? WindowVisibilityScope.Empty()
            : WindowVisibilityScope.HideApplicationWindows();
        var backdrop = await CaptureFrozenBackdropAsync(options, trace)
            ?? throw new InvalidOperationException("无法准备一键 Shot 的冻结桌面帧。");
        var overlay = new InlineAnnotateWindow(
            backdrop.Source,
            backdrop.Bounds,
            recordingOptions,
            screenshotCommit,
            settingsProvider?.Invoke(),
            saveSettings,
            initialMode);
        overlay.SourceInitialized += (_, _) => trace.MarkOverlayInitialized();
        overlay.ContentRendered += (_, _) => trace.MarkFirstFrame();
        if (overlay.ShowDialog() != true || overlay.OneShotAction is not { } action)
        {
            trace.Complete("Cancelled");
            return null;
        }

        trace.Complete(action.ToString());
        return new OneShotResult(
            action,
            overlay.OneShotRectangle,
            overlay.ResultImage,
            overlay.PinRequested,
            overlay.OneShotOptions,
            overlay.ScreenshotCommitted);
    }

    private async Task<FrozenSelectionBackdrop?> CaptureFrozenBackdropAsync(
        ScreenCaptureOptions? options,
        SelectionPerformanceTrace trace)
    {
        var bounds = screenCapture.VirtualBounds;
        return await Task.Run(() =>
        {
            var started = System.Diagnostics.Stopwatch.GetTimestamp();
            using var bitmap = screenCapture.CaptureRectangle(bounds, options);
            var result = new FrozenSelectionBackdrop(bounds, BitmapSourceFactory.FromBitmap(bitmap));
            trace.MarkCaptureCompleted(
                System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds,
                Environment.CurrentManagedThreadId);
            return result;
        });
    }

    private sealed class WindowVisibilityScope : IDisposable
    {
        private readonly List<Window> _visibleWindows;

        private WindowVisibilityScope(List<Window> windows) => _visibleWindows = windows;

        public static WindowVisibilityScope Empty() => new([]);

        public static WindowVisibilityScope HideApplicationWindows(Window? keepVisible = null)
        {
            var windows = System.Windows.Application.Current.Windows.Cast<Window>()
                .Where(x => x.IsVisible && !ReferenceEquals(x, keepVisible))
                .ToList();
            foreach (var window in windows) window.Hide();
            // Wait for one DWM composition boundary instead of imposing a fixed
            // 90 ms delay on every selection, including fast single-monitor paths.
            NativeMethods.DwmFlush();
            return new WindowVisibilityScope(windows);
        }

        public void Dispose()
        {
            foreach (var window in _visibleWindows.Where(x => !x.IsVisible)) window.Show();
        }
    }
}

internal sealed class FrozenSelectionBackdrop(Drawing.Rectangle bounds, BitmapSource source)
{
    public Drawing.Rectangle Bounds { get; } = bounds;
    public BitmapSource Source { get; } = source;

    public Drawing.Bitmap Crop(Drawing.Rectangle physicalRectangle)
    {
        var clipped = Drawing.Rectangle.Intersect(Bounds, physicalRectangle);
        if (clipped.Width <= 0 || clipped.Height <= 0)
            throw new ArgumentOutOfRangeException(nameof(physicalRectangle));
        var crop = new CroppedBitmap(Source, new Int32Rect(
            clipped.Left - Bounds.Left,
            clipped.Top - Bounds.Top,
            clipped.Width,
            clipped.Height));
        crop.Freeze();
        return BitmapSourceFactory.ToBitmap(crop);
    }
}
