using System.Drawing;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class MouseWheelMonitorTests
{
    [Fact]
    public void IsInsideScrollRegion_AcceptsPointInsideRegion()
    {
        var inside = MouseWheelMonitor.IsInsideScrollRegion(
            new NativeMethods.PointStruct(500, 400),
            new Rectangle(100, 100, 800, 600),
            slop: 0);

        Assert.True(inside);
    }

    [Fact]
    public void IsInsideScrollRegion_RejectsPointFarOutsideRegion()
    {
        var outside = MouseWheelMonitor.IsInsideScrollRegion(
            new NativeMethods.PointStruct(50, 750),
            new Rectangle(100, 100, 800, 600),
            slop: 0);

        Assert.False(outside);
    }

    [Fact]
    public void IsInsideScrollRegion_AllowsSlopAroundRegionEdges()
    {
        var nearEdge = MouseWheelMonitor.IsInsideScrollRegion(
            new NativeMethods.PointStruct(100 - MouseWheelMonitor.ScrollHitSlop, 700),
            new Rectangle(100, 100, 800, 600));

        Assert.True(nearEdge);
    }

    [Fact]
    public void IsVerticalWheelMessage_IgnoresHorizontalWheelInput()
    {
        Assert.True(MouseWheelMonitor.IsVerticalWheelMessage(NativeMethods.WmMouseWheel));
        Assert.False(MouseWheelMonitor.IsVerticalWheelMessage(NativeMethods.WmMouseHwheels));
    }
}
