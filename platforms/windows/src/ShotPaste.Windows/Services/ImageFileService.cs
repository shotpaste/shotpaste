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
        using var buffer = new MemoryStream();
        bitmap.Save(buffer, ImageFormat.Png);
        buffer.Position = 0;
        using var source = SKBitmap.Decode(buffer) ?? throw new InvalidOperationException("无法解码截图。");
        using var colorSpace = settings.Current.ScreenshotColorSpace == "DisplayP3"
            ? SKColorSpace.CreateCicp(SKColorspacePrimariesCicp.SmpteEg4321, SKColorspaceTransferFnCicp.Iec6196621)
            : SKColorSpace.CreateSrgb();
        var info = new SKImageInfo(source.Width, source.Height, SKColorType.Bgra8888, SKAlphaType.Premul, colorSpace);
        using var surface = SKSurface.Create(info) ?? throw new InvalidOperationException("无法创建色彩空间画布。");
        surface.Canvas.Clear(SKColors.Transparent);
        surface.Canvas.DrawBitmap(source, 0, 0, new SKSamplingOptions(SKFilterMode.Nearest));
        surface.Canvas.Flush();
        using var image = surface.Snapshot();
        using var encoded = image.Encode(format, quality);
        using var output = File.Create(path);
        encoded.SaveTo(output);
    }
}
