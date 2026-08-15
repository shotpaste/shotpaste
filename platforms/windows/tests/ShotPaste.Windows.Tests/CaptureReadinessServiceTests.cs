using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class CaptureReadinessServiceTests
{
    [Fact]
    public void Result_IsReadyOnlyAfterWindowsAndStalePixelsAreGone()
    {
        var ready = new CaptureReadinessResult(
            Scenario: "OneShotFrozenBackdrop",
            Timestamp: DateTimeOffset.UtcNow,
            HiddenWindowCount: 1,
            RemainingVisibleWindows: 0,
            RemainingStaleProbes: 0,
            PixelTransitionsObserved: 1,
            DispatcherDrainMilliseconds: 0,
            HiddenWaitMilliseconds: 0,
            PixelTransitionMilliseconds: 0,
            DwmFlushMilliseconds: 0,
            TotalMilliseconds: 0,
            DwmResult: 0,
            TimedOut: false,
            UsedCompositionFallback: false,
            RemoteSession: false,
            MonitorCount: 1,
            VirtualWidth: 1920,
            VirtualHeight: 1080);

        Assert.True(ready.IsReady);
        Assert.False((ready with { RemainingVisibleWindows = 1 }).IsReady);
        Assert.False((ready with { RemainingStaleProbes = 1 }).IsReady);
        Assert.True((ready with
        {
            RemainingStaleProbes = 1,
            NativeExclusionApplied = true
        }).IsReady);
    }

    [Fact]
    public void CountVisible_IgnoresZeroHandlesAndUsesEveryRealHandle()
    {
        var visible = new HashSet<IntPtr> { new(2), new(4) };

        var count = CaptureReadinessService.CountVisible(
            [IntPtr.Zero, new IntPtr(1), new IntPtr(2), new IntPtr(3), new IntPtr(4)],
            visible.Contains);

        Assert.Equal(2, count);
    }
}
