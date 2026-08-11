using LiteScreen.Windows.Models;
using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class ScreenRecordingServiceTests
{
    [Theory]
    [InlineData(RecordingQuality.High, 12_441_600)]
    [InlineData(RecordingQuality.Medium, 8_087_040)]
    [InlineData(RecordingQuality.Low, 4_976_640)]
    public void GetVideoBitrate_ScalesWithResolutionFpsAndQuality(RecordingQuality quality, int expected)
    {
        Assert.Equal(expected, ScreenRecordingService.GetVideoBitrate(1920, 1080, 30, quality));
    }

    [Fact]
    public void GetVideoBitrate_QualityOrderingIsMonotonic()
    {
        Assert.True(ScreenRecordingService.GetVideoBitrate(1920, 1080, 30, RecordingQuality.High) >
                    ScreenRecordingService.GetVideoBitrate(1920, 1080, 30, RecordingQuality.Medium));
        Assert.True(ScreenRecordingService.GetVideoBitrate(1920, 1080, 30, RecordingQuality.Medium) >
                    ScreenRecordingService.GetVideoBitrate(1920, 1080, 30, RecordingQuality.Low));
    }

    [Fact]
    public void GetVideoBitrate_UsesLegibilityFloorAndEncoderPressureCap()
    {
        Assert.Equal(2_500_000, ScreenRecordingService.GetVideoBitrate(320, 180, 15, RecordingQuality.High));
        Assert.Equal(60_000_000, ScreenRecordingService.GetVideoBitrate(3840, 2160, 60, RecordingQuality.High));
    }

    [Fact]
    public void ClampToScreen_ClipsCrossMonitorRegionAndKeepsEvenDimensions()
    {
        var result = ScreenRecordingService.ClampToScreen(
            new System.Drawing.Rectangle(1800, 100, 400, 301),
            new System.Drawing.Rectangle(0, 0, 1920, 1080));

        Assert.Equal(new System.Drawing.Rectangle(1800, 100, 120, 300), result);
    }

    [Fact]
    public void ClampToScreen_RejectsRegionOutsideSelectedDisplay()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ScreenRecordingService.ClampToScreen(
            new System.Drawing.Rectangle(2200, 100, 400, 300),
            new System.Drawing.Rectangle(0, 0, 1920, 1080)));
    }

    [Fact]
    public void CreateRecordingSource_UsesTheOneShotRegionOnly()
    {
        var screen = System.Windows.Forms.Screen.PrimaryScreen
            ?? System.Windows.Forms.Screen.AllScreens.First();
        var width = Math.Min(640, screen.Bounds.Width);
        var height = Math.Min(360, screen.Bounds.Height);
        var target = RecordingTarget.Region(new System.Drawing.Rectangle(
            screen.Bounds.Left,
            screen.Bounds.Top,
            width,
            height));
        var plan = ScreenRecordingService.CreateRecordingSource(target);

        Assert.Equal(RecordingTargetKind.Region, target.Kind);
        Assert.Equal(0, plan.Bounds.Width % 2);
        Assert.Equal(0, plan.Bounds.Height % 2);
        Assert.Equal("DisplayRecordingSource", plan.Source.GetType().Name);
        (plan.Source as IDisposable)?.Dispose();
    }
}
