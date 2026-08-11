using ShotPaste.Windows.Controls;

namespace ShotPaste.Windows.Tests;

public sealed class VirtualizingWrapPanelTests
{
    [Fact]
    public void CalculateLayout_UsesAdaptiveColumnsAndOnlyVisibleRows()
    {
        var layout = VirtualizingWrapPanel.CalculateLayout(
            itemCount: 100,
            availableWidth: 900,
            itemWidth: 286,
            itemHeight: 226,
            verticalOffset: 0,
            viewportHeight: 600);

        Assert.Equal(3, layout.Columns);
        Assert.Equal(34, layout.Rows);
        Assert.Equal(0, layout.FirstIndex);
        Assert.Equal(11, layout.LastIndex);
        Assert.Equal(34 * 226, layout.ExtentHeight);
    }

    [Fact]
    public void CalculateLayout_StartsAtRowContainingVerticalOffset()
    {
        var layout = VirtualizingWrapPanel.CalculateLayout(
            itemCount: 100,
            availableWidth: 900,
            itemWidth: 286,
            itemHeight: 226,
            verticalOffset: 500,
            viewportHeight: 400);

        Assert.Equal(6, layout.FirstIndex);
        Assert.Equal(14, layout.LastIndex);
    }

    [Fact]
    public void CalculateLayout_HandlesEmptyHistory()
    {
        var layout = VirtualizingWrapPanel.CalculateLayout(0, 900, 286, 226, 0, 600);

        Assert.Equal(0, layout.Rows);
        Assert.Equal(0, layout.FirstIndex);
        Assert.Equal(-1, layout.LastIndex);
        Assert.Equal(0, layout.ExtentHeight);
    }
}
