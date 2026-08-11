using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class QuickAccessCountdownTests
{
    [Fact]
    public void PauseAndResumePreserveRemainingTime()
    {
        var origin = DateTimeOffset.Parse("2026-08-08T00:00:00Z");
        var countdown = new QuickAccessCountdown(TimeSpan.FromSeconds(10));

        countdown.Reset(origin);
        countdown.Pause(origin.AddSeconds(3));
        Assert.Equal(TimeSpan.FromSeconds(7), countdown.Remaining(origin.AddHours(1)));

        countdown.Resume(origin.AddHours(1));
        Assert.Equal(TimeSpan.FromSeconds(5), countdown.Remaining(origin.AddHours(1).AddSeconds(2)));
    }

    [Fact]
    public void ResetStartsAFullNewCycleWhileExpiredResumeStaysExpired()
    {
        var origin = DateTimeOffset.Parse("2026-08-08T00:00:00Z");
        var countdown = new QuickAccessCountdown(TimeSpan.FromSeconds(4));

        countdown.Reset(origin);
        countdown.Pause(origin.AddSeconds(6));
        Assert.Equal(TimeSpan.Zero, countdown.Resume(origin.AddSeconds(7)));
        Assert.Equal(TimeSpan.FromSeconds(4), countdown.Reset(origin.AddSeconds(8)));
    }
}
