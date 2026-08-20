using System.Diagnostics;
using System.Text.Json;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Services;

public sealed record CaptureHideProbe(IntPtr Handle, Drawing.Rectangle Bounds, ulong VisibleFingerprint);

public sealed record CaptureHideState(IReadOnlyList<CaptureHideProbe> Windows)
{
    public static CaptureHideState Empty { get; } = new([]);
    public IReadOnlyList<IntPtr> Handles => Windows.Select(window => window.Handle).ToArray();
}

public sealed record CaptureReadinessResult(
    string Scenario,
    DateTimeOffset Timestamp,
    int HiddenWindowCount,
    int RemainingVisibleWindows,
    int RemainingStaleProbes,
    int PixelTransitionsObserved,
    double DispatcherDrainMilliseconds,
    double HiddenWaitMilliseconds,
    double PixelTransitionMilliseconds,
    double DwmFlushMilliseconds,
    double TotalMilliseconds,
    int DwmResult,
    bool TimedOut,
    bool UsedCompositionFallback,
    bool RemoteSession,
    int MonitorCount,
    int VirtualWidth,
    int VirtualHeight)
{
    public bool NativeExclusionApplied { get; init; }
    public bool IsReady => RemainingVisibleWindows == 0 &&
                           (NativeExclusionApplied || RemainingStaleProbes == 0);
}

/// <summary>
/// Establishes an observable capture boundary after ShotPaste windows are
/// hidden. HWND visibility alone is insufficient: GDI can still expose the
/// previous composed frame. A sparse pre-hide fingerprint must disappear
/// from every former window region before capture proceeds.
/// </summary>
public static class CaptureReadinessService
{
    private static readonly object EvidenceSync = new();

    public static CaptureHideProbe CreateProbe(IntPtr handle, Drawing.Rectangle bounds) =>
        new(handle, bounds, CaptureFingerprint(bounds));

    public static async Task<CaptureReadinessResult> WaitAsync(
        string scenario,
        CaptureHideState hiddenState,
        bool nativeExclusionApplied = false,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var budget = timeout ?? TimeSpan.FromMilliseconds(500);
        var total = Stopwatch.StartNew();
        var dispatcher = Stopwatch.StartNew();
        if (System.Windows.Application.Current?.Dispatcher is { } currentDispatcher)
        {
            await currentDispatcher.InvokeAsync(
                () => { },
                DispatcherPriority.ContextIdle,
                cancellationToken);
        }
        dispatcher.Stop();

        var hiddenWait = Stopwatch.StartNew();
        var remainingVisible = CountVisible(hiddenState.Handles, NativeMethods.IsWindowVisible);
        while (remainingVisible > 0 && total.Elapsed < budget)
        {
            await Task.Delay(4, cancellationToken);
            remainingVisible = CountVisible(hiddenState.Handles, NativeMethods.IsWindowVisible);
        }
        hiddenWait.Stop();

        var dwmMilliseconds = 0d;
        var flush = Stopwatch.StartNew();
        var dwmResult = NativeMethods.DwmFlush();
        flush.Stop();
        dwmMilliseconds += flush.Elapsed.TotalMilliseconds;

        var pixelWait = Stopwatch.StartNew();
        var transitions = nativeExclusionApplied
            ? new List<ProbeTransitionState>()
            : hiddenState.Windows.Select(probe => new ProbeTransitionState(probe)).ToList();
        if (!nativeExclusionApplied) ObserveTransitions(transitions);
        while (!nativeExclusionApplied && transitions.Any(state => !state.Ready) && total.Elapsed < budget)
        {
            await Task.Delay(4, cancellationToken);
            flush.Restart();
            var nextResult = NativeMethods.DwmFlush();
            flush.Stop();
            dwmMilliseconds += flush.Elapsed.TotalMilliseconds;
            if (dwmResult >= 0 && nextResult < 0) dwmResult = nextResult;
            ObserveTransitions(transitions);
        }
        pixelWait.Stop();

        var fallback = !nativeExclusionApplied &&
                       (dwmResult < 0 || transitions.Any(state => !state.Ready));
        if (fallback)
        {
            // Remote/legacy composition can fail to expose a DWM boundary.
            // Pay a conservative delay only on this exceptional path, then
            // perform one final observable fingerprint check.
            await Task.Delay(TimeSpan.FromMilliseconds(64), cancellationToken);
            NativeMethods.DwmFlush();
            for (var attempt = 0; attempt < 3 && transitions.Any(state => !state.Ready); attempt++)
            {
                ObserveTransitions(transitions);
                if (transitions.All(state => state.Ready)) break;
                await Task.Delay(16, cancellationToken);
                NativeMethods.DwmFlush();
            }
        }
        total.Stop();

        var remainingStale = nativeExclusionApplied ? 0 : transitions.Count(state => !state.Ready);

        var virtualScreen = Forms.SystemInformation.VirtualScreen;
        return new CaptureReadinessResult(
            scenario,
            DateTimeOffset.Now,
            hiddenState.Windows.Count,
            remainingVisible,
            remainingStale,
            hiddenState.Windows.Count - remainingStale,
            Math.Round(dispatcher.Elapsed.TotalMilliseconds, 3),
            Math.Round(hiddenWait.Elapsed.TotalMilliseconds, 3),
            Math.Round(pixelWait.Elapsed.TotalMilliseconds, 3),
            Math.Round(dwmMilliseconds, 3),
            Math.Round(total.Elapsed.TotalMilliseconds, 3),
            dwmResult,
            remainingVisible > 0 || remainingStale > 0,
            fallback,
            Forms.SystemInformation.TerminalServerSession,
            Forms.Screen.AllScreens.Length,
            virtualScreen.Width,
            virtualScreen.Height)
        {
            NativeExclusionApplied = nativeExclusionApplied
        };
    }

    private static void ObserveTransitions(IEnumerable<ProbeTransitionState> transitions)
    {
        foreach (var transition in transitions.Where(state => !state.Ready))
            transition.Observe(CaptureFingerprint(transition.Probe.Bounds));
    }

    internal static int CountVisible(IReadOnlyCollection<IntPtr> windows, Func<IntPtr, bool> isVisible) =>
        windows.Count(handle => handle != IntPtr.Zero && isVisible(handle));

    internal static ulong CaptureFingerprint(Drawing.Rectangle bounds)
    {
        var sampleBounds = Drawing.Rectangle.Intersect(bounds, Forms.SystemInformation.VirtualScreen);
        if (sampleBounds.Width <= 1 || sampleBounds.Height <= 1) return 0;
        var desktop = NativeMethods.GetDesktopWindow();
        var source = NativeMethods.GetWindowDC(desktop);
        if (source == IntPtr.Zero) return 0;
        var destination = NativeMethods.CreateCompatibleDC(source);
        var sampleBitmap = NativeMethods.CreateCompatibleBitmap(source, 8, 8);
        if (destination == IntPtr.Zero || sampleBitmap == IntPtr.Zero)
        {
            if (sampleBitmap != IntPtr.Zero) NativeMethods.DeleteObject(sampleBitmap);
            if (destination != IntPtr.Zero) NativeMethods.DeleteDC(destination);
            NativeMethods.ReleaseDC(desktop, source);
            return 0;
        }
        var previous = NativeMethods.SelectObject(destination, sampleBitmap);
        try
        {
            NativeMethods.SetStretchBltMode(destination, 3); // COLORONCOLOR
            if (!NativeMethods.StretchBlt(destination, 0, 0, 8, 8, source,
                    sampleBounds.Left, sampleBounds.Top, sampleBounds.Width, sampleBounds.Height,
                    NativeMethods.Srccopy | NativeMethods.CaptureBlt)) return 0;
            const ulong offset = 14695981039346656037UL;
            const ulong prime = 1099511628211UL;
            var hash = offset;
            for (var row = 0; row < 8; row++)
            for (var column = 0; column < 8; column++)
            {
                hash ^= NativeMethods.GetPixel(destination, column, row);
                hash *= prime;
            }
            return hash;
        }
        finally
        {
            NativeMethods.SelectObject(destination, previous);
            NativeMethods.DeleteObject(sampleBitmap);
            NativeMethods.DeleteDC(destination);
            NativeMethods.ReleaseDC(desktop, source);
        }
    }

    public static void AppendEvidence(CaptureReadinessResult result)
    {
        Directory.CreateDirectory(AppPaths.Root);
        var path = Path.Combine(AppPaths.Root, "capture-readiness.jsonl");
        var json = JsonSerializer.Serialize(result);
        lock (EvidenceSync) File.AppendAllText(path, json + Environment.NewLine);
    }

    private sealed class ProbeTransitionState(CaptureHideProbe probe)
    {
        public CaptureHideProbe Probe { get; } = probe;
        public bool Transitioned { get; private set; }
        public int StableMatches { get; private set; }
        public ulong LastFingerprint { get; private set; } = probe.VisibleFingerprint;
        public bool Ready => Transitioned && StableMatches >= 2;

        public void Observe(ulong fingerprint)
        {
            if (fingerprint == Probe.VisibleFingerprint && !Transitioned)
            {
                LastFingerprint = fingerprint;
                StableMatches = 0;
                return;
            }

            if (!Transitioned)
            {
                Transitioned = true;
                StableMatches = 0;
            }
            else if (fingerprint == LastFingerprint)
            {
                StableMatches++;
            }
            else
            {
                StableMatches = 0;
            }
            LastFingerprint = fingerprint;
        }
    }
}
