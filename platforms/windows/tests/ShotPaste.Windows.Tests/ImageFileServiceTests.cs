using System.Drawing;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using SkiaSharp;

namespace ShotPaste.Windows.Tests;

public sealed class ImageFileServiceTests
{
    [Theory]
    [InlineData(".png")]
    [InlineData(".jpg")]
    [InlineData(".webp")]
    public void SaveToPath_WritesConfiguredFormats(string extension)
    {
        var path = Path.Combine(Path.GetTempPath(), $"shotpaste-image-{Guid.NewGuid():N}{extension}");
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
        var path = Path.Combine(Path.GetTempPath(), $"shotpaste-image-{Guid.NewGuid():N}.png");
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

    [Fact]
    public void SaveToPath_LockedDestinationPreservesExistingFileAndCleansTemporaryOutput()
    {
        var root = Path.Combine(Path.GetTempPath(), "ShotPasteAtomicSaveTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "capture.png");
        File.WriteAllText(path, "original");
        var service = new ImageFileService(new SettingsStore(new AppSettings { ScreenshotColorSpace = "Srgb" }));
        using var source = new Bitmap(24, 16);
        using (var graphics = Graphics.FromImage(source)) graphics.Clear(Color.CornflowerBlue);
        try
        {
            Exception? failure;
            using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                failure = Record.Exception(() => service.SaveToPath(source, path));

            Assert.True(failure is IOException or UnauthorizedAccessException,
                $"Expected a locked-file failure, received {failure?.GetType().Name ?? "no exception"}.");
            Assert.Equal("original", File.ReadAllText(path));
            Assert.Empty(Directory.EnumerateFiles(root, ".*.tmp"));
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }
}
