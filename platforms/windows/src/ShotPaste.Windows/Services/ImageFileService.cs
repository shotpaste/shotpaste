using System.Drawing.Imaging;
using ShotPaste.Windows.Models;
using SkiaSharp;
using Drawing = System.Drawing;
using System.Windows.Media.Imaging;

namespace ShotPaste.Windows.Services;

public sealed class ImageFileService(SettingsStore settings)
{
    public string NewPath(string directory, CaptureKind kind)
    {
        var extension = settings.Current.ScreenshotFormat switch { "Jpeg" => ".jpg", "WebP" => ".webp", _ => ".png" };
        return CaptureOutputNaming.NewPath(directory, kind, extension, settings.Current.ScreenshotNameTemplate);
    }

    public string Save(Drawing.Bitmap bitmap, string directory, CaptureKind kind)
    {
        var format = settings.Current.ScreenshotFormat;
        var path = NewPath(directory, kind);
        var encodedFormat = format switch
        {
            "Jpeg" => SKEncodedImageFormat.Jpeg,
            "WebP" => SKEncodedImageFormat.Webp,
            _ => SKEncodedImageFormat.Png
        };
        SaveEncoded(bitmap, path, encodedFormat,
            encodedFormat == SKEncodedImageFormat.Png ? 100 : Math.Clamp(settings.Current.JpegQuality, 1, 100));
        return path;
    }

    public void SaveToPath(Drawing.Bitmap bitmap, string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        var format = extension switch
        {
            ".jpg" or ".jpeg" => SKEncodedImageFormat.Jpeg,
            ".webp" => SKEncodedImageFormat.Webp,
            _ => SKEncodedImageFormat.Png
        };
        SaveEncoded(bitmap, path, format, format == SKEncodedImageFormat.Png ? 100 : Math.Clamp(settings.Current.JpegQuality, 1, 100));
    }

    public BitmapSource Load(string path)
    {
        if (Path.GetExtension(path).Equals(".webp", StringComparison.OrdinalIgnoreCase))
        {
            using var bitmap = SKBitmap.Decode(path) ?? throw new InvalidOperationException("无法打开图片。");
            using var image = SKImage.FromBitmap(bitmap);
            using var data = image.Encode(SKEncodedImageFormat.Png, 100);
            using var stream = data.AsStream();
            var result = new BitmapImage();
            result.BeginInit(); result.CacheOption = BitmapCacheOption.OnLoad; result.StreamSource = stream; result.EndInit(); result.Freeze();
            return result;
        }
        return Utilities.BitmapSourceFactory.FromPath(path) ?? throw new InvalidOperationException("无法打开图片。");
    }

    private void SaveEncoded(Drawing.Bitmap bitmap, string path, SKEncodedImageFormat format, int quality)
    {
        Drawing.Bitmap? converted = null;
        var source = bitmap;
        if (bitmap.PixelFormat is not (PixelFormat.Format32bppArgb or
            PixelFormat.Format32bppPArgb or PixelFormat.Format32bppRgb))
        {
            converted = new Drawing.Bitmap(bitmap.Width, bitmap.Height, PixelFormat.Format32bppPArgb);
            using var graphics = Drawing.Graphics.FromImage(converted);
            graphics.CompositingMode = Drawing.Drawing2D.CompositingMode.SourceCopy;
            graphics.DrawImageUnscaled(bitmap, 0, 0);
            source = converted;
        }

        using var colorSpace = settings.Current.ScreenshotColorSpace == "DisplayP3"
            ? SKColorSpace.CreateCicp(SKColorspacePrimariesCicp.SmpteEg4321, SKColorspaceTransferFnCicp.Iec6196621)
            : SKColorSpace.CreateSrgb();
        var rectangle = new Drawing.Rectangle(0, 0, source.Width, source.Height);
        var data = source.LockBits(rectangle, ImageLockMode.ReadOnly, source.PixelFormat);
        try
        {
            var alphaType = source.PixelFormat switch
            {
                PixelFormat.Format32bppPArgb => SKAlphaType.Premul,
                PixelFormat.Format32bppRgb => SKAlphaType.Opaque,
                _ => SKAlphaType.Unpremul,
            };
            var info = new SKImageInfo(
                source.Width,
                source.Height,
                SKColorType.Bgra8888,
                alphaType,
                colorSpace);
            var pixelAddress = data.Stride >= 0
                ? data.Scan0
                : IntPtr.Add(data.Scan0, data.Stride * (source.Height - 1));
            using var pixmap = new SKPixmap(info, pixelAddress, Math.Abs(data.Stride));
            using var image = SKImage.FromPixels(pixmap) ??
                              throw new InvalidOperationException("无法解码截图。");
            using var encoded = image.Encode(format, quality) ??
                                throw new InvalidOperationException("无法解码截图。");
            SaveAtomically(encoded, path);
        }
        finally
        {
            source.UnlockBits(data);
            converted?.Dispose();
        }
    }

    private static void SaveAtomically(SKData encoded, string path)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath) ?? throw new IOException("保存路径缺少有效目录。");
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var output = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                encoded.SaveTo(output);
                output.Flush(true);
            }
            File.Move(temporaryPath, fullPath, true);
        }
        finally
        {
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
