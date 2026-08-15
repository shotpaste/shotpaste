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
        var excludeOwnApplication = options?.ExcludeOwnApplication == true;
        using var trace = SelectionPerformanceTrace.Start("OneShot", screenCapture.VirtualBounds);
        using var visibility = excludeOwnApplication
            ? WindowVisibilityScope.HideAndExcludeApplicationWindows()
            : WindowVisibilityScope.Empty();
        if (excludeOwnApplication)
        {
            var readiness = await CaptureReadinessService.WaitAsync(
                "OneShotFrozenBackdrop",
                visibility.HiddenState,
                visibility.NativeExclusionAppliedToAll);
            if (App.UiTestMode || settingsProvider?.Invoke().DiagnosticsEnabled == true)
                CaptureReadinessService.AppendEvidence(readiness);
            if (!readiness.IsReady)
                throw new InvalidOperationException(
                    LocalizationService.TranslatePhrase("无法准备一键 Shot 的冻结桌面帧。"));
        }
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
        private readonly WindowCaptureExclusionService? _captureExclusion;

        private WindowVisibilityScope(
            List<Window> windows,
            CaptureHideState hiddenState,
            WindowCaptureExclusionService? captureExclusion = null)
        {
            _visibleWindows = windows;
            HiddenState = hiddenState;
            _captureExclusion = captureExclusion;
        }

        public CaptureHideState HiddenState { get; }
        public bool NativeExclusionAppliedToAll { get; private init; }

        public static WindowVisibilityScope Empty() => new([], CaptureHideState.Empty);

        public static WindowVisibilityScope HideAndExcludeApplicationWindows(Window? keepVisible = null)
        {
            var windows = System.Windows.Application.Current.Windows.Cast<Window>()
                .Where(x => x.IsVisible && !ReferenceEquals(x, keepVisible))
                .ToList();
            var probes = windows.Select(CreateProbe).Where(probe => probe is not null).Cast<CaptureHideProbe>().ToArray();
            var exclusion = new WindowCaptureExclusionService();
            try
            {
                // Apply the native capture filter before hiding. If the compositor
                // still exposes a cached frame, CaptureReadinessService below
                // detects it using the probes recorded before this transition.
                exclusion.SetEnabled(true);
                var nativeExclusionApplied = probes.Length > 0 &&
                                             probes.All(probe => exclusion.IsHandleExcluded(probe.Handle));
                foreach (var window in windows) window.Hide();
                return new WindowVisibilityScope(windows, new CaptureHideState(probes), exclusion)
                {
                    NativeExclusionAppliedToAll = nativeExclusionApplied
                };
            }
            catch
            {
                exclusion.Dispose();
                foreach (var window in windows.Where(window => !window.IsVisible)) window.Show();
                throw;
            }
        }

        private static CaptureHideProbe? CreateProbe(Window window)
        {
            var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero || !NativeMethods.GetWindowRect(handle, out var bounds)) return null;
            var rectangle = Drawing.Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
            return rectangle.Width > 0 && rectangle.Height > 0
                ? CaptureReadinessService.CreateProbe(handle, rectangle)
                : null;
        }

        public void Dispose()
        {
            _captureExclusion?.Dispose();
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
