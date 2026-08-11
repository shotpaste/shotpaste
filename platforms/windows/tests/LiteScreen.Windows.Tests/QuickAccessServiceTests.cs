using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class QuickAccessServiceTests
{
    [Theory]
    [InlineData("TopLeft", "BottomLeft")]
    [InlineData("topright", "BottomRight")]
    [InlineData("Left", "BottomLeft")]
    [InlineData("Right", "BottomRight")]
    [InlineData(null, "BottomRight")]
    public void NormalizePosition_UsesMacAlignedScreenEdges(string? value, string expected)
    {
        Assert.Equal(expected, QuickAccessService.NormalizePosition(value));
    }

    [Theory]
    [InlineData("BottomLeft", true, false)]
    [InlineData("BottomRight", false, false)]
    public void LayoutKeepsFiveCardsInsideTheRequestedEdge(string position, bool left, bool top)
    {
        var workArea = new System.Drawing.Rectangle(-1280, 80, 1280, 900);
        var sizes = Enumerable.Repeat((Width: 204d, Height: 128d), QuickAccessService.MaximumCards).ToArray();

        var result = QuickAccessService.CalculateLayout(workArea, sizes, position);

        Assert.Equal(5, result.Count);
        Assert.All(result, bounds =>
        {
            Assert.InRange(bounds.Left, workArea.Left, workArea.Right - bounds.Width);
            Assert.InRange(bounds.Top, workArea.Top, workArea.Bottom - bounds.Height);
            Assert.Equal(left ? workArea.Left + 18d : workArea.Right - bounds.Width - 18d, bounds.Left);
        });
        Assert.True(top ? result[1].Top > result[0].Top : result[1].Top < result[0].Top);
    }
}
