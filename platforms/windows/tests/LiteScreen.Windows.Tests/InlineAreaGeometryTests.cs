using System.Windows;
using LiteScreen.Windows.Services;
using WpfPoint = System.Windows.Point;
using WpfSize = System.Windows.Size;

namespace LiteScreen.Windows.Tests;

public sealed class InlineAreaGeometryTests
{
    [Fact]
    public void NormalizeSupportsReverseDrag()
    {
        var result = InlineAreaGeometry.Normalize(new WpfPoint(300, 220), new WpfPoint(80, 40));

        Assert.Equal(new Rect(80, 40, 220, 180), result);
    }

    [Fact]
    public void ClampKeepsSelectionInsideVirtualDesktop()
    {
        var result = InlineAreaGeometry.Clamp(new Rect(940, 740, 200, 120), new WpfSize(1000, 800));

        Assert.Equal(new Rect(800, 680, 200, 120), result);
    }

    [Fact]
    public void ResizeCornerChangesBothAxes()
    {
        var result = InlineAreaGeometry.Resize(
            new Rect(100, 100, 400, 300), "BottomRight", new Vector(80, 50), new WpfSize(1000, 800));

        Assert.Equal(new Rect(100, 100, 480, 350), result);
    }

    [Fact]
    public void ResizeHonorsMinimumSelectionSize()
    {
        var result = InlineAreaGeometry.Resize(
            new Rect(100, 100, 100, 100), "TopLeft", new Vector(500, 500), new WpfSize(1000, 800));

        Assert.Equal(InlineAreaGeometry.MinimumSelectionSize, result.Width);
        Assert.Equal(InlineAreaGeometry.MinimumSelectionSize, result.Height);
    }

    [Fact]
    public void ResizeCannotCrossDesktopEdge()
    {
        var result = InlineAreaGeometry.Resize(
            new Rect(700, 500, 200, 200), "BottomRight", new Vector(500, 500), new WpfSize(1000, 800));

        Assert.Equal(new Rect(700, 500, 300, 300), result);
    }
}
