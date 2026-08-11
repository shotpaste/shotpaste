using System.Drawing;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingRegionOverlayWindowTests
{
    [Fact]
    public void MoveWithinBoundsAppliesPointerDelta()
    {
        var moved = RecordingRegionOverlayWindow.MoveWithinBounds(
            new Rectangle(100, 120, 640, 480),
            75,
            30,
            new Rectangle(0, 0, 1920, 1080));

        Assert.Equal(new Rectangle(175, 150, 640, 480), moved);
    }

    [Fact]
    public void MoveWithinBoundsClampsAllScreenEdges()
    {
        var region = new Rectangle(100, 120, 640, 480);
        var bounds = new Rectangle(0, 0, 1920, 1080);

        Assert.Equal(new Rectangle(0, 0, 640, 480),
            RecordingRegionOverlayWindow.MoveWithinBounds(region, -500, -500, bounds));
        Assert.Equal(new Rectangle(1280, 600, 640, 480),
            RecordingRegionOverlayWindow.MoveWithinBounds(region, 5000, 5000, bounds));
    }

    [Fact]
    public void GetResizeHandle_DetectsCornersEdgesAndCenter()
    {
        var region = new Rectangle(100, 120, 640, 480);

        Assert.Equal(RecordingResizeHandle.TopLeft,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(100, 120), region));
        Assert.Equal(RecordingResizeHandle.TopRight,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(740, 120), region));
        Assert.Equal(RecordingResizeHandle.BottomLeft,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(100, 600), region));
        Assert.Equal(RecordingResizeHandle.BottomRight,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(740, 600), region));
        Assert.Equal(RecordingResizeHandle.Top,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(400, 120), region));
        Assert.Equal(RecordingResizeHandle.Bottom,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(400, 600), region));
        Assert.Equal(RecordingResizeHandle.Left,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(100, 400), region));
        Assert.Equal(RecordingResizeHandle.Right,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(740, 400), region));
        Assert.Null(RecordingRegionOverlayWindow.GetResizeHandle(new Point(400, 400), region));

        // A few pixels outside the border still counts so the edge is easy to grab.
        Assert.Equal(RecordingResizeHandle.Top,
            RecordingRegionOverlayWindow.GetResizeHandle(new Point(400, 112), region));
    }

    [Fact]
    public void ResizeRegion_RightAndBottomEdgesResizeAndClampToBounds()
    {
        var region = new Rectangle(100, 100, 400, 300);
        var bounds = new Rectangle(0, 0, 1920, 1080);

        var right = RecordingRegionOverlayWindow.ResizeRegion(
            region, RecordingResizeHandle.Right, 80, 0, bounds);
        Assert.Equal(new Rectangle(100, 100, 480, 300), right);

        var clamped = RecordingRegionOverlayWindow.ResizeRegion(
            region, RecordingResizeHandle.Right, 5000, 0, bounds);
        Assert.Equal(bounds.Right, clamped.Right);

        var corner = RecordingRegionOverlayWindow.ResizeRegion(
            region, RecordingResizeHandle.BottomRight, 60, -40, bounds);
        Assert.Equal(new Rectangle(100, 100, 460, 260), corner);
    }

    [Fact]
    public void ResizeRegion_LeftAndTopEdgesResizeAndKeepMinimumSize()
    {
        var region = new Rectangle(400, 300, 400, 300);
        var bounds = new Rectangle(0, 0, 1920, 1080);

        var left = RecordingRegionOverlayWindow.ResizeRegion(
            region, RecordingResizeHandle.Left, -200, 0, bounds);
        Assert.Equal(200, left.Left);
        Assert.Equal(600, left.Width);

        var min = RecordingRegionOverlayWindow.ResizeRegion(
            region, RecordingResizeHandle.Left, 500, 0, bounds);
        Assert.Equal(region.Right - 50, min.Left);
        Assert.Equal(50, min.Width);
    }
}
