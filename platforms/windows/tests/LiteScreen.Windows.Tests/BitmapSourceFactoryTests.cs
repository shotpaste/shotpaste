using System.Drawing.Imaging;
using LiteScreen.Windows.Utilities;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;

namespace LiteScreen.Windows.Tests;

public sealed class BitmapSourceFactoryTests
{
    [Fact]
    public void FullImageAndThumbnailLoadingHaveSeparatePixelContracts()
    {
        var path = Path.Combine(Path.GetTempPath(), $"litescreen-image-{Guid.NewGuid():N}.png");
        try
        {
            using (var bitmap = new Drawing.Bitmap(960, 640)) bitmap.Save(path, ImageFormat.Png);

            var full = BitmapSourceFactory.FromPath(path);
            var thumbnail = BitmapSourceFactory.FromPath(path, 360);

            Assert.NotNull(full);
            Assert.NotNull(thumbnail);
            Assert.Equal((960, 640), (full!.PixelWidth, full.PixelHeight));
            Assert.Equal((360, 240), (thumbnail!.PixelWidth, thumbnail.PixelHeight));
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public void BitmapSourceRoundTripPreservesTransparentAndSoftAlpha()
    {
        var pixels = new byte[]
        {
            10, 20, 30, 0,
            40, 50, 60, 128,
            70, 80, 90, 255
        };
        var source = BitmapSource.Create(3, 1, 96, 96, PixelFormats.Bgra32, null, pixels, 12);

        using var bitmap = BitmapSourceFactory.ToBitmap(source);
        var restored = BitmapSourceFactory.FromBitmap(bitmap);

        Assert.Equal(0, bitmap.GetPixel(0, 0).A);
        Assert.Equal(128, bitmap.GetPixel(1, 0).A);
        Assert.Equal(255, bitmap.GetPixel(2, 0).A);
        var restoredPixels = new byte[12];
        new FormatConvertedBitmap(restored, PixelFormats.Bgra32, null, 0).CopyPixels(restoredPixels, 12, 0);
        Assert.Equal(new byte[] { 0, 128, 255 }, new[] { restoredPixels[3], restoredPixels[7], restoredPixels[11] });
    }

    [Fact]
    public void CroppedArgbBitmapWithPaddedStrideRoundTripsWithoutRowCorruption()
    {
        using var source = new Drawing.Bitmap(101, 83, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        for (var y = 0; y < source.Height; y++)
        for (var x = 0; x < source.Width; x++)
            source.SetPixel(x, y, Drawing.Color.FromArgb((x + y) % 256, x % 256, y % 256, (x * 3 + y * 5) % 256));
        using var crop = source.Clone(new Drawing.Rectangle(7, 11, 87, 61), System.Drawing.Imaging.PixelFormat.Format32bppArgb);

        var wpf = BitmapSourceFactory.FromBitmap(crop);
        using var restored = BitmapSourceFactory.ToBitmap(wpf);

        Assert.Equal(crop.Size, restored.Size);
        foreach (var point in new[] { new Drawing.Point(0, 0), new Drawing.Point(43, 30), new Drawing.Point(86, 60) })
            Assert.Equal(crop.GetPixel(point.X, point.Y).ToArgb(), restored.GetPixel(point.X, point.Y).ToArgb());
    }
}
