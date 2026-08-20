using System.Drawing;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Tests;

public sealed class ScrollingProgressWindowTests
{
    [Theory]
    [InlineData((int)ScrollingProgressPhase.Ready, "开始截取")]
    [InlineData((int)ScrollingProgressPhase.Starting, "准备中")]
    [InlineData((int)ScrollingProgressPhase.Capturing, "完成")]
    [InlineData((int)ScrollingProgressPhase.Finalizing, "完成中")]
    [InlineData((int)ScrollingProgressPhase.Saving, "保存中")]
    [InlineData((int)ScrollingProgressPhase.SaveFailed, "等待重试")]
    public void PrimaryActionLabel_TracksCapturePhase(
        int phase,
        string expected)
    {
        Assert.Equal(
            expected,
            ScrollingProgressWindow.PrimaryActionLabel((ScrollingProgressPhase)phase));
    }

    [Fact]
    public void ResolvePhysicalPlacement_CentersCompactHudBelowOrAboveSelection()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(100, 200, 500, 600),
            new Rectangle(0, 0, 1920, 1080),
            new Size(270, 520));

        Assert.Equal(new Rectangle(215, 12, 270, 520), placement);
    }

    [Fact]
    public void ResolvePhysicalPlacement_FallsBackLeftOnNegativeMonitor()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(-500, 120, 450, 700),
            new Rectangle(-1920, 0, 1920, 1080),
            new Size(405, 780));

        Assert.Equal(-478, placement.X);
        Assert.Equal(12, placement.Y);
    }

    [Fact]
    public void ResolvePhysicalPlacement_ClampsTallHudToWorkingArea()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(100, 900, 800, 160),
            new Rectangle(0, 0, 1920, 1040),
            new Size(270, 520));

        Assert.Equal(368, placement.Y);
        Assert.Equal(888, placement.Bottom);
    }

    [Fact]
    public void ResolvePhysicalPlacement_AlignsActiveHudToSelectionTrailingEdge()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(100, 200, 500, 600),
            new Rectangle(0, 0, 1920, 1080),
            new Size(96, 44),
            alignTrailing: true);

        Assert.Equal(new Rectangle(504, 812, 96, 44), placement);
    }

    [Fact]
    public void AutoScrollCapsule_IsCenteredInsideSelectionBottomEdge()
    {
        var placement = ScrollingAutoScrollWindow.ResolvePhysicalPlacement(
            new Rectangle(100, 200, 500, 600),
            new Rectangle(0, 0, 1920, 1080),
            new Size(120, 36));

        Assert.Equal(new Rectangle(290, 750, 120, 36), placement);
    }

    [Fact]
    public void PreviewRail_PreservesBoundedWorkloadAndSidePlacement()
    {
        var capture = new Rectangle(100, 200, 500, 600);
        var work = new Rectangle(0, 0, 1920, 1080);
        var size = ScrollingPreviewWindow.ResolvePreviewSize(440, 840, capture, work);
        var placement = ScrollingPreviewWindow.ResolvePhysicalPlacement(capture, work, size);

        Assert.Equal(new Size(220, 420), size);
        Assert.Equal(new Rectangle(612, 200, 220, 420), placement);
    }

    [Fact]
    public void PreviewRail_AnimationInterpolationReachesExactTarget()
    {
        var from = new Rectangle(10, 20, 80, 100);
        var to = new Rectangle(30, 60, 120, 200);

        Assert.Equal(from, ScrollingPreviewWindow.Interpolate(from, to, 0));
        Assert.Equal(new Rectangle(20, 40, 100, 150),
            ScrollingPreviewWindow.Interpolate(from, to, 0.5));
        Assert.Equal(to, ScrollingPreviewWindow.Interpolate(from, to, 1));
    }
}
