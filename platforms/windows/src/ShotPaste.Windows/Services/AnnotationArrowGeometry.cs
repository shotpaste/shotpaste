using System.Windows;
using System.Windows.Media;
using WpfPoint = System.Windows.Point;

namespace ShotPaste.Windows.Services;

internal static class AnnotationArrowGeometry
{
    internal enum TipStyle
    {
        None,
        Arrow,
        Circle,
        Square
    }

    internal static Geometry CreateTapered(WpfPoint start, WpfPoint end, double strokeWidth)
        => CreateCurved(start, end, Midpoint(start, end), strokeWidth, TipStyle.None, TipStyle.Arrow);

    internal static Geometry CreateClassic(
        WpfPoint start,
        WpfPoint end,
        WpfPoint control,
        double strokeWidth,
        TipStyle startTip = TipStyle.None,
        TipStyle endTip = TipStyle.Arrow)
    {
        if ((end - start).Length < 0.5)
            return new EllipseGeometry(start, Math.Max(1, strokeWidth / 2), Math.Max(1, strokeWidth / 2));

        var figure = new PathFigure { StartPoint = start, IsClosed = false, IsFilled = false };
        if (IsCurved(start, end, control))
            figure.Segments.Add(new QuadraticBezierSegment(control, end, true));
        else
            figure.Segments.Add(new LineSegment(end, true));

        var group = new GeometryGroup { FillRule = FillRule.Nonzero };
        group.Children.Add(new PathGeometry([figure]));
        var startDirection = QuadraticTangent(start, control, end, 0);
        var endDirection = QuadraticTangent(start, control, end, 1);
        AddTip(group, start, startDirection, startTip, strokeWidth, includeArrow: true);
        AddTip(group, end, -endDirection, endTip, strokeWidth, includeArrow: true);
        group.Freeze();
        return group;
    }

    internal static Geometry CreateCurved(
        WpfPoint start,
        WpfPoint end,
        WpfPoint control,
        double strokeWidth,
        TipStyle startTip = TipStyle.None,
        TipStyle endTip = TipStyle.Arrow)
    {
        var chord = end - start;
        if (chord.Length < 0.5)
            return new EllipseGeometry(start, Math.Max(1, strokeWidth / 2), Math.Max(1, strokeWidth / 2));

        var bodyHalfWidth = Math.Max(1.2, strokeWidth * 0.55);
        var headLength = Math.Min(chord.Length * 0.42, Math.Max(14, strokeWidth * 4.5));
        var headHalfWidth = Math.Min(chord.Length * 0.28, Math.Max(6, strokeWidth * 2.1));
        const int segments = 28;
        var points = Enumerable.Range(0, segments + 1)
            .Select(index => Quadratic(start, control, end, index / (double)segments))
            .ToArray();
        var tangents = Enumerable.Range(0, segments + 1)
            .Select(index => QuadraticTangent(start, control, end, index / (double)segments))
            .ToArray();

        var left = new List<WpfPoint>(segments + 1);
        var right = new List<WpfPoint>(segments + 1);
        for (var index = 0; index <= segments; index++)
        {
            var tangent = tangents[index];
            var normal = new Vector(-tangent.Y, tangent.X);
            left.Add(points[index] + normal * bodyHalfWidth);
            right.Add(points[index] - normal * bodyHalfWidth);
        }

        var endDirection = tangents[^1];
        var endNormal = new Vector(-endDirection.Y, endDirection.X);
        var endBase = end - endDirection * headLength;
        var startDirection = tangents[0];
        var startNormal = new Vector(-startDirection.Y, startDirection.X);
        var startBase = start + startDirection * headLength;

        var geometry = new StreamGeometry { FillRule = FillRule.Nonzero };
        using (var context = geometry.Open())
        {
            context.BeginFigure(left[0], isFilled: true, isClosed: true);
            foreach (var point in left.Skip(1)) context.LineTo(point, isStroked: true, isSmoothJoin: true);
            if (endTip == TipStyle.Arrow)
            {
                context.LineTo(endBase + endNormal * headHalfWidth, true, true);
                context.LineTo(end, true, true);
                context.LineTo(endBase - endNormal * headHalfWidth, true, true);
            }
            foreach (var point in right.AsEnumerable().Reverse()) context.LineTo(point, isStroked: true, isSmoothJoin: true);
            if (startTip == TipStyle.Arrow)
            {
                context.LineTo(startBase - startNormal * headHalfWidth, true, true);
                context.LineTo(start, true, true);
                context.LineTo(startBase + startNormal * headHalfWidth, true, true);
            }
        }

        var group = new GeometryGroup { FillRule = FillRule.Nonzero };
        group.Children.Add(geometry);
        AddTip(group, start, startDirection, startTip, strokeWidth);
        AddTip(group, end, -endDirection, endTip, strokeWidth);
        group.Freeze();
        return group;
    }

    internal static bool IsCurved(WpfPoint start, WpfPoint end, WpfPoint control, double tolerance = 0.75)
    {
        var midpoint = Midpoint(start, end);
        return (control - midpoint).Length > tolerance;
    }

    internal static WpfPoint DefaultControl(WpfPoint start, WpfPoint end) => Midpoint(start, end);

    private static WpfPoint Quadratic(WpfPoint start, WpfPoint control, WpfPoint end, double t)
    {
        var inverse = 1d - t;
        return new WpfPoint(
            inverse * inverse * start.X + 2 * inverse * t * control.X + t * t * end.X,
            inverse * inverse * start.Y + 2 * inverse * t * control.Y + t * t * end.Y);
    }

    private static Vector QuadraticTangent(WpfPoint start, WpfPoint control, WpfPoint end, double t)
    {
        var tangent = 2 * (1 - t) * (control - start) + 2 * t * (end - control);
        if (tangent.Length < 0.001) tangent = end - start;
        tangent.Normalize();
        return tangent;
    }

    private static void AddTip(
        GeometryGroup group,
        WpfPoint point,
        Vector outward,
        TipStyle tip,
        double strokeWidth,
        bool includeArrow = false)
    {
        if (tip == TipStyle.None || tip == TipStyle.Arrow && !includeArrow) return;
        var radius = Math.Min(Math.Max(strokeWidth * 1.9, 5), 14);
        if (tip == TipStyle.Arrow)
        {
            var headLength = Math.Min(Math.Max(strokeWidth * 3.5, 12), 24);
            const double headAngle = Math.PI / 6;
            var normal = new Vector(-outward.Y, outward.X);
            var baseDistance = headLength * Math.Cos(headAngle);
            var halfWidth = headLength * Math.Sin(headAngle);
            var basePoint = point + outward * baseDistance;
            var firstArm = new PathFigure { StartPoint = point, IsClosed = false, IsFilled = false };
            firstArm.Segments.Add(new LineSegment(basePoint + normal * halfWidth, true));
            var secondArm = new PathFigure { StartPoint = point, IsClosed = false, IsFilled = false };
            secondArm.Segments.Add(new LineSegment(basePoint - normal * halfWidth, true));
            group.Children.Add(new PathGeometry([firstArm, secondArm]));
            return;
        }
        if (tip == TipStyle.Circle)
        {
            group.Children.Add(new EllipseGeometry(point, radius, radius));
            return;
        }

        var center = point + outward * (radius * 0.25);
        group.Children.Add(new RectangleGeometry(new Rect(center.X - radius, center.Y - radius, radius * 2, radius * 2)));
    }

    private static WpfPoint Midpoint(WpfPoint start, WpfPoint end) =>
        new((start.X + end.X) / 2d, (start.Y + end.Y) / 2d);
}
