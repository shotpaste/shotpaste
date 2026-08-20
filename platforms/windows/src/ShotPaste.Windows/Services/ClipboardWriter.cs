using System.Collections.Specialized;
using System.IO;
using System.Windows.Media.Imaging;
using SkiaSharp;
using WpfClipboard = System.Windows.Clipboard;
using WpfDataObject = System.Windows.DataObject;

namespace ShotPaste.Windows.Services;

internal static class ClipboardWriter
{
    internal const long MaximumBitmapPixelCount = 32_000_000;

    internal static void SetText(string text) =>
        WpfClipboard.SetDataObject(CreateTextDataObject(text), copy: true);

    internal static void SetImage(BitmapSource image)
    {
        var data = CreateMarkedDataObject(AppBuildIdentity.Current);
        data.SetImage(image);
        WpfClipboard.SetDataObject(data, copy: true);
    }

    internal static async Task SetImageFileAsync(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var payload = await Task.Run(() => LoadImageFilePayload(fullPath));

        void Commit()
        {
            var data = CreateMarkedDataObject(AppBuildIdentity.Current);
            var paths = new StringCollection { payload.Path };
            data.SetFileDropList(paths);
            data.SetData(payload.EncodedFormat, new MemoryStream(payload.EncodedBytes, writable: false));
            if (payload.Bitmap is not null) data.SetImage(payload.Bitmap);
            WpfClipboard.SetDataObject(data, copy: true);
        }

        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess())
            await dispatcher.InvokeAsync(Commit);
        else
            Commit();
    }

    internal static bool ShouldCreateBitmapRepresentation(int pixelWidth, int pixelHeight)
    {
        if (pixelWidth < 0 || pixelHeight < 0) return false;
        try
        {
            return checked((long)pixelWidth * pixelHeight) <= MaximumBitmapPixelCount;
        }
        catch (OverflowException)
        {
            return false;
        }
    }

    internal static void SetFileDropList(StringCollection paths)
    {
        var data = CreateMarkedDataObject(AppBuildIdentity.Current);
        data.SetFileDropList(paths);
        WpfClipboard.SetDataObject(data, copy: true);
    }

    internal static WpfDataObject CreateTextDataObject(string text, AppBuildIdentity? identity = null)
    {
        var data = CreateMarkedDataObject(identity ?? AppBuildIdentity.Current);
        data.SetText(text);
        return data;
    }

    private static WpfDataObject CreateMarkedDataObject(AppBuildIdentity identity)
    {
        var data = new WpfDataObject();
        data.SetData(identity.InternalClipboardWriteMarkerFormat, BitConverter.GetBytes(1u));
        return data;
    }

    private static ImageFileClipboardPayload LoadImageFilePayload(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("The screenshot file does not exist.", path);
        using var codec = SKCodec.Create(path) ?? throw new InvalidDataException("Unable to read screenshot dimensions.");
        var shouldDecode = ShouldCreateBitmapRepresentation(codec.Info.Width, codec.Info.Height);
        var bitmap = shouldDecode ? DecodeBitmapSource(path) : null;
        var bytes = File.ReadAllBytes(path);
        return new ImageFileClipboardPayload(path, EncodedClipboardFormat(path), bytes, bitmap);
    }

    private static BitmapSource? DecodeBitmapSource(string path)
    {
        if (!Path.GetExtension(path).Equals(".webp", StringComparison.OrdinalIgnoreCase))
            return ShotPaste.Windows.Utilities.BitmapSourceFactory.FromPath(path);

        using var bitmap = SKBitmap.Decode(path);
        if (bitmap is null) return null;
        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        using var stream = encoded.AsStream();
        var result = new BitmapImage();
        result.BeginInit();
        result.CacheOption = BitmapCacheOption.OnLoad;
        result.StreamSource = stream;
        result.EndInit();
        result.Freeze();
        return result;
    }

    private static string EncodedClipboardFormat(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".png" => "PNG",
        ".jpg" or ".jpeg" => "JFIF",
        ".webp" => "image/webp",
        _ => "application/octet-stream"
    };

    private sealed record ImageFileClipboardPayload(
        string Path,
        string EncodedFormat,
        byte[] EncodedBytes,
        BitmapSource? Bitmap);
}
