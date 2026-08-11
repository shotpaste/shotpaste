using LiteScreen.Windows.Models;
using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class RecordingFormatCapabilityServiceTests
{
    [Fact]
    public void Resolve_MovAndUnavailableHevc_FallsBackToMatchingMp4H264Plan()
    {
        var support = new RecordingMediaSupport(true, false, 0, "fixture");

        var decision = RecordingFormatCapabilityService.Resolve("Mov", "Hevc", support);

        Assert.Equal("Mov", decision.RequestedContainer);
        Assert.Equal("Hevc", decision.RequestedCodec);
        Assert.Equal("Mp4", decision.ActualContainer);
        Assert.Equal("H264", decision.ActualCodec);
        Assert.Equal(".mp4", decision.Extension);
        Assert.True(decision.UsedFallback);
        Assert.Contains(RecordingFormatCapabilityService.MovUnavailable, decision.FallbackReason);
        Assert.Contains(RecordingFormatCapabilityService.HevcUnavailable, decision.FallbackReason);
    }

    [Fact]
    public void Resolve_AvailableHevc_ProducesHevcInsideMp4WithoutFallback()
    {
        var support = new RecordingMediaSupport(true, true, 1, "fixture");

        var decision = RecordingFormatCapabilityService.Resolve("Mp4", "Hevc", support);

        Assert.Equal("Mp4", decision.ActualContainer);
        Assert.Equal("Hevc", decision.ActualCodec);
        Assert.False(decision.UsedFallback);
    }

    [Fact]
    public void Resolve_GifIntermediate_UsesH264EvenWhenHevcIsAvailable()
    {
        var support = new RecordingMediaSupport(true, true, 1, "fixture");

        var decision = RecordingFormatCapabilityService.Resolve("Mp4", "Hevc", support, gifIntermediate: true);

        Assert.Equal("H264", decision.ActualCodec);
        Assert.Contains(RecordingFormatCapabilityService.GifIntermediate, decision.FallbackReason);
    }

    [Theory]
    [InlineData("H264", "H264VideoEncoder")]
    [InlineData("Hevc", "H265VideoEncoder")]
    public void CreateVideoEncoder_MatchesResolvedCodec(string codec, string expectedType)
    {
        var method = typeof(ScreenRecordingService).GetMethod("CreateVideoEncoder",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
        var encoder = method.Invoke(null, [codec, RecordingQuality.High])!;

        Assert.Equal(expectedType, encoder.GetType().Name);
    }

    [Theory]
    [InlineData(RecordingQuality.High, 90)]
    [InlineData(RecordingQuality.Medium, 75)]
    [InlineData(RecordingQuality.Low, 55)]
    public void EncoderQuality_MapsEveryUserPreset(RecordingQuality quality, int expected)
    {
        Assert.Equal(expected, ScreenRecordingService.GetEncoderQuality(quality));
    }
}
