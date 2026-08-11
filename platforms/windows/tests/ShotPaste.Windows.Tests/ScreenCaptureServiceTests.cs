using System.Drawing;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class ScreenCaptureServiceTests
{
    [Fact]
    public void CaptureRectangle_ReturnsRequestedPixelSize()
    {
        var service = new ScreenCaptureService();
        var bounds = service.VirtualBounds;
        var rectangle = new Rectangle(bounds.Left, bounds.Top, Math.Min(64, bounds.Width), Math.Min(48, bounds.Height));
        using var result = service.CaptureRectangle(rectangle);
        Assert.Equal(rectangle.Size, result.Size);
    }
}
