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
    public void PrimaryActionLabel_TracksCapturePhase(
        int phase,
        string expected)
    {
        Assert.Equal(
            expected,
            ScrollingProgressWindow.PrimaryActionLabel((ScrollingProgressPhase)phase));
    }

    [Fact]
    public void ResolvePhysicalPlacement_PrefersSpaceToTheRight()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(100, 200, 500, 600),
            new Rectangle(0, 0, 1920, 1080),
            new Size(270, 520));

        Assert.Equal(new Rectangle(612, 200, 270, 520), placement);
    }

    [Fact]
    public void ResolvePhysicalPlacement_FallsBackLeftOnNegativeMonitor()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(-500, 120, 450, 700),
            new Rectangle(-1920, 0, 1920, 1080),
            new Size(405, 780));

        Assert.Equal(-917, placement.X);
        Assert.Equal(120, placement.Y);
    }

    [Fact]
    public void ResolvePhysicalPlacement_ClampsTallHudToWorkingArea()
    {
        var placement = ScrollingProgressWindow.ResolvePhysicalPlacement(
            new Rectangle(100, 900, 800, 160),
            new Rectangle(0, 0, 1920, 1040),
            new Size(270, 520));

        Assert.Equal(520, placement.Y);
        Assert.Equal(1040, placement.Bottom);
    }
}
