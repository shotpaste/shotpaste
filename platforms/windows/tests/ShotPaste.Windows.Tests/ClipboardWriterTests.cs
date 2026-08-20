using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class ClipboardWriterTests
{
    [Theory]
    [InlineData(8_000, 4_000, true)]
    [InlineData(8_000, 4_001, false)]
    [InlineData(3_840, 32_768, false)]
    [InlineData(-1, 100, false)]
    public void BitmapRepresentation_UsesThirtyTwoMillionPixelBudget(
        int width,
        int height,
        bool expected)
    {
        Assert.Equal(expected, ClipboardWriter.ShouldCreateBitmapRepresentation(width, height));
    }
}
