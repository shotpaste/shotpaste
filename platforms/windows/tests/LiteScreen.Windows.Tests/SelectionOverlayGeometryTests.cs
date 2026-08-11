using System.Drawing;
using System.Windows;
using LiteScreen.Windows.Services;
using WpfSize = System.Windows.Size;

namespace LiteScreen.Windows.Tests;

public sealed class SelectionOverlayGeometryTests
{
    [Fact]
    public void ToPhysicalUsesBackdropScaleInsteadOfAssumingNinetySixDpi()
    {
        var result = SelectionOverlayGeometry.ToPhysical(
            new Rect(100, 50, 400, 200),
            new WpfSize(1280, 720),
            new Rectangle(-1920, 0, 2560, 1440));

        Assert.Equal(new Rectangle(-1720, 100, 800, 400), result);
    }

    [Fact]
    public void ToPhysicalRoundsOutwardAndClampsAtDesktopEdges()
    {
        var result = SelectionOverlayGeometry.ToPhysical(
            new Rect(-2, 10.2, 100.1, 100.1),
            new WpfSize(1000, 800),
            new Rectangle(0, 0, 1250, 1000));

        Assert.Equal(new Rectangle(0, 12, 123, 126), result);
    }

    [Fact]
    public void ToLogicalMapsPhysicalCropBackToPixelAlignedOverlayBounds()
    {
        var result = SelectionOverlayGeometry.ToLogical(
            new Rectangle(201, 101, 799, 399),
            new WpfSize(1280, 720),
            new Rectangle(0, 0, 2560, 1440));

        Assert.Equal(new Rect(100.5, 50.5, 399.5, 199.5), result);
    }

    [Theory]
    [InlineData(-2560, -180, 6400, 2340, 3200, 1170, -1800, 120, 1500, 900)]
    [InlineData(-1920, 0, 5760, 2160, 3840, 1440, -1500, 180, 2700, 1180)]
    public void PhysicalLogicalRoundTripPreservesNegativeAndMixedDpiDesktopPixels(
        int desktopX, int desktopY, int desktopWidth, int desktopHeight,
        double logicalWidth, double logicalHeight,
        int selectionX, int selectionY, int selectionWidth, int selectionHeight)
    {
        var desktop = new Rectangle(desktopX, desktopY, desktopWidth, desktopHeight);
        var physical = new Rectangle(selectionX, selectionY, selectionWidth, selectionHeight);
        var logical = SelectionOverlayGeometry.ToLogical(physical, new WpfSize(logicalWidth, logicalHeight), desktop);
        var roundTrip = SelectionOverlayGeometry.ToPhysical(logical, new WpfSize(logicalWidth, logicalHeight), desktop);

        Assert.Equal(physical, roundTrip);
    }

    [Fact]
    public void DimRegionsCoverOnlyOutsideOfSelection()
    {
        var regions = SelectionOverlayGeometry.CreateDimRegions(
            new Rect(100, 80, 300, 200), new WpfSize(800, 600));

        Assert.Equal(new Rect(0, 0, 800, 80), regions.Top);
        Assert.Equal(new Rect(0, 80, 100, 200), regions.Left);
        Assert.Equal(new Rect(400, 80, 400, 200), regions.Right);
        Assert.Equal(new Rect(0, 280, 800, 320), regions.Bottom);
        var dimmedArea = regions.Top.Width * regions.Top.Height +
            regions.Left.Width * regions.Left.Height +
            regions.Right.Width * regions.Right.Height +
            regions.Bottom.Width * regions.Bottom.Height;
        Assert.Equal(800 * 600 - 300 * 200, dimmedArea);
    }

    [Fact]
    public void NoSelectionDimsTheEntireDesktop()
    {
        var regions = SelectionOverlayGeometry.CreateDimRegions(null, new WpfSize(800, 600));

        Assert.Equal(new Rect(0, 0, 800, 600), regions.Top);
        Assert.True(regions.Left.IsEmpty);
        Assert.True(regions.Right.IsEmpty);
        Assert.True(regions.Bottom.IsEmpty);
    }
}
