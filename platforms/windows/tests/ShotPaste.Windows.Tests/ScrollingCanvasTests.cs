using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class ScrollingCanvasTests
{
    [Fact]
    public void AdvanceCursor_OnlyAddsRowsPastHistoricalExtents()
    {
        const int width = 40;
        const int height = 100;
        var canvas = new ScrollingCanvas(width, height, 500);
        canvas.Seed(new byte[width * height * 4], height);

        Assert.Equal(20, canvas.AdvanceCursor(20, 400));
        Assert.Equal(0, canvas.AdvanceCursor(-10, 400));
        Assert.Equal(0, canvas.AdvanceCursor(-10, 400));
        Assert.Equal(12, canvas.AdvanceCursor(-12, 400));
    }

    [Fact]
    public void Preview_StaysFullWidthWhenLongCanvasExceedsViewport()
    {
        const int width = 100;
        const int height = 100;
        var canvas = new ScrollingCanvas(width, height, 600);
        var pixels = new byte[width * height * 4];
        for (var index = 3; index < pixels.Length; index += 4) pixels[index] = 255;
        canvas.Seed(pixels, height);

        for (var index = 0; index < 8; index++)
        {
            var rows = canvas.AdvanceCursor(20, 600 - canvas.UsedHeight);
            Assert.Equal(rows, canvas.AppendDown(pixels, height, 0, 0, rows, 0));
        }

        using var preview = canvas.CreatePreviewBitmap(50, 60);
        Assert.NotNull(preview);
        Assert.Equal(50, preview.Width);
        Assert.Equal(60, preview.Height);
    }
}
