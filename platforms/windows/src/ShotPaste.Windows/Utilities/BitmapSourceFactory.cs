using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;
using DrawingPixelFormat = System.Drawing.Imaging.PixelFormat;

namespace ShotPaste.Windows.Utilities;

public static class BitmapSourceFactory
{
    public static BitmapSource FromBitmap(Drawing.Bitmap bitmap)
    {
        ArgumentNullException.ThrowIfNull(bitmap);
        Drawing.Bitmap? converted = null;
        var source = bitmap;
        if (bitmap.PixelFormat is not (DrawingPixelFormat.Format32bppArgb or
            DrawingPixelFormat.Format32bppPArgb or DrawingPixelFormat.Format32bppRgb))
        {
            converted = new Drawing.Bitmap(bitmap.Width, bitmap.Height, DrawingPixelFormat.Format32bppPArgb);
            converted.SetResolution(
                (float)ValidDpi(bitmap.HorizontalResolution),
                (float)ValidDpi(bitmap.VerticalResolution));
            using var graphics = Drawing.Graphics.FromImage(converted);
            graphics.DrawImageUnscaled(bitmap, 0, 0);
            source = converted;
        }

        var rectangle = new Drawing.Rectangle(0, 0, source.Width, source.Height);
        var data = source.LockBits(rectangle, ImageLockMode.ReadOnly, source.PixelFormat);
        BitmapSource result;
        try
        {
            var format = source.PixelFormat switch
            {
                DrawingPixelFormat.Format32bppPArgb => System.Windows.Media.PixelFormats.Pbgra32,
                DrawingPixelFormat.Format32bppRgb => System.Windows.Media.PixelFormats.Bgr32,
                _ => System.Windows.Media.PixelFormats.Bgra32
            };
            var stride = Math.Abs(data.Stride);
            var pixels = GC.AllocateUninitializedArray<byte>(checked(stride * source.Height));
            for (var row = 0; row < source.Height; row++)
            {
                var sourceRow = IntPtr.Add(data.Scan0, data.Stride * row);
                var targetRow = data.Stride >= 0 ? row : source.Height - row - 1;
                Marshal.Copy(sourceRow, pixels, targetRow * stride, stride);
            }
            result = BitmapSource.Create(
                source.Width,
                source.Height,
                ValidDpi(source.HorizontalResolution),
                ValidDpi(source.VerticalResolution),
                format,
                null,
                pixels,
                stride);
        }
        finally
        {
            source.UnlockBits(data);
            converted?.Dispose();
        }
        result.Freeze();
        return result;
    }

    private static double ValidDpi(float value) => float.IsFinite(value) && value > 0 ? value : 96d;

    public static BitmapImage? FromPath(string? path, int? decodePixelWidth = null)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return null;
        var result = new BitmapImage();
        result.BeginInit();
        result.CacheOption = BitmapCacheOption.OnLoad;
        if (decodePixelWidth is > 0) result.DecodePixelWidth = decodePixelWidth.Value;
        result.UriSource = new Uri(path!, UriKind.Absolute);
        result.EndInit();
        result.Freeze();
        return result;
    }

    public static Drawing.Bitmap ToBitmap(BitmapSource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        BitmapSource converted = source.Format == System.Windows.Media.PixelFormats.Bgra32
            ? source
            : new FormatConvertedBitmap(source, System.Windows.Media.PixelFormats.Bgra32, null, 0);
        var sourceStride = checked(converted.PixelWidth * 4);
        var pixels = GC.AllocateUninitializedArray<byte>(checked(sourceStride * converted.PixelHeight));
        converted.CopyPixels(pixels, sourceStride, 0);

        var bitmap = new Drawing.Bitmap(converted.PixelWidth, converted.PixelHeight, DrawingPixelFormat.Format32bppArgb);
        bitmap.SetResolution((float)ValidDpi((float)converted.DpiX), (float)ValidDpi((float)converted.DpiY));
        var rectangle = new Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rectangle, ImageLockMode.WriteOnly, DrawingPixelFormat.Format32bppArgb);
        try
        {
            var targetStride = Math.Abs(data.Stride);
            if (targetStride == sourceStride && data.Stride > 0)
                Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
            else
            {
                for (var row = 0; row < bitmap.Height; row++)
                {
                    var targetRow = data.Stride > 0 ? row : bitmap.Height - row - 1;
                    Marshal.Copy(pixels, row * sourceStride, IntPtr.Add(data.Scan0, targetRow * targetStride), sourceStride);
                }
            }
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
        return bitmap;
    }
}
