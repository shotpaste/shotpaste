using System.Drawing;
using LiteScreen.Windows.Models;
using LiteScreen.Windows.Services;
using SkiaSharp;

namespace LiteScreen.Windows.Tests;

public sealed class ImageFileServiceTests
{
    [Theory]
    [InlineData(".png")]
    [InlineData(".jpg")]
    [InlineData(".webp")]
    public void SaveToPath_WritesConfiguredFormats(string extension)
    {
        var path = Path.Combine(Path.GetTempPath(), $"litescreen-image-{Guid.NewGuid():N}{extension}");
        var service = new ImageFileService(new SettingsStore(new AppSettings { ScreenshotColorSpace = "Srgb" }));
        using var source = new Bitmap(24, 16);
        using (var graphics = Graphics.FromImage(source)) graphics.Clear(Color.CornflowerBlue);
        try
        {
            service.SaveToPath(source, path);

            using var decoded = SKBitmap.Decode(path);
            Assert.NotNull(decoded);
            Assert.Equal(24, decoded.Width);
            Assert.Equal(16, decoded.Height);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public void SaveToPath_DisplayP3_EmbedsWideGamutColorSpace()
    {
        var path = Path.Combine(Path.GetTempPath(), $"litescreen-image-{Guid.NewGuid():N}.png");
        var service = new ImageFileService(new SettingsStore(new AppSettings { ScreenshotColorSpace = "DisplayP3" }));
        using var source = new Bitmap(12, 12);
        using (var graphics = Graphics.FromImage(source)) graphics.Clear(Color.OrangeRed);
        try
        {
            service.SaveToPath(source, path);

            using var codec = SKCodec.Create(path);
            Assert.NotNull(codec);
            Assert.NotNull(codec.Info.ColorSpace);
            Assert.False(codec.Info.ColorSpace.IsSrgb);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }
}
