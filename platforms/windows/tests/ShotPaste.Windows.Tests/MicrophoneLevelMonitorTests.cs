using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class MicrophoneLevelMonitorTests
{
    [Theory]
    [InlineData(false, true, false, 0.5, 1, 0, MicrophoneFeedbackState.Disabled)]
    [InlineData(true, false, false, 0.5, 1, 0, MicrophoneFeedbackState.Disconnected)]
    [InlineData(true, true, true, 0.5, 1, 0, MicrophoneFeedbackState.Muted)]
    [InlineData(true, true, false, 0.5, 0, 0, MicrophoneFeedbackState.Muted)]
    [InlineData(true, true, false, 0, 1, 2, MicrophoneFeedbackState.NoInput)]
    [InlineData(true, true, false, 0.5, 0.8, 0, MicrophoneFeedbackState.Active)]
    public void Classify_DistinguishesFeedbackStates(
        bool enabled, bool connected, bool muted, double raw, double gain, double silenceSeconds,
        MicrophoneFeedbackState expected)
    {
        var snapshot = MicrophoneLevelMonitor.Classify(
            enabled, connected, muted, raw, gain, TimeSpan.FromSeconds(silenceSeconds));

        Assert.Equal(expected, snapshot.State);
        if (expected == MicrophoneFeedbackState.Active) Assert.Equal(0.4, snapshot.Level, 3);
    }

    [Fact]
    public void Read_DefaultEndpointNeverThrowsWhenDeviceIsMissingOrAvailable()
    {
        using var monitor = new MicrophoneLevelMonitor(new ShotPaste.Windows.Models.AppSettings
        {
            RecordMicrophone = true,
            RecordingMicrophoneDeviceId = string.Empty,
            RecordingMicrophoneVolume = 0.8
        });

        var snapshot = monitor.Read();

        Assert.True(Enum.IsDefined(snapshot.State));
        Assert.InRange(snapshot.Level, 0, 1);
    }
}
