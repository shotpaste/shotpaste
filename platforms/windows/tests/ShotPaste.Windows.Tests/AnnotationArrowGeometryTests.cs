using System.Windows;
using System.Windows.Media;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class AnnotationArrowGeometryTests
{
    [Fact]
    public void TaperedArrowHasAVisiblyWiderHeadThanItsShaft()
    {
        var geometry = AnnotationArrowGeometry.CreateTapered(
            new Point(0, 20), new Point(100, 20), strokeWidth: 4);

        Assert.IsType<GeometryGroup>(geometry);
        Assert.Equal(100, geometry.Bounds.Width, precision: 6);
        Assert.True(geometry.Bounds.Height >= 16,
            $"Expected a prominent arrowhead, but geometry height was {geometry.Bounds.Height}.");
    }

    [Fact]
    public void CurvedArrowBoundsAndHitGeometryFollowControlPoint()
    {
        var geometry = AnnotationArrowGeometry.CreateCurved(
            new Point(10, 80), new Point(190, 80), new Point(100, 10), 5,
            AnnotationArrowGeometry.TipStyle.Circle,
            AnnotationArrowGeometry.TipStyle.Arrow);

        Assert.True(geometry.Bounds.Top < 46, $"Curve did not follow its control point: {geometry.Bounds}.");
        Assert.True(geometry.FillContains(new Point(100, 45), 8, ToleranceType.Absolute));
        Assert.True(AnnotationArrowGeometry.IsCurved(new Point(10, 80), new Point(190, 80), new Point(100, 10)));
    }

    [Fact]
    public void MidpointControlIsReportedAsStraight()
    {
        var start = new Point(-25, 12);
        var end = new Point(75, 32);
        Assert.False(AnnotationArrowGeometry.IsCurved(start, end, AnnotationArrowGeometry.DefaultControl(start, end)));
    }
}
