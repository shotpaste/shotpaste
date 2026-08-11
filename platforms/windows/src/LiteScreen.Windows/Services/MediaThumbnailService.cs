using System.Runtime.InteropServices;
using Windows.Media.Editing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace LiteScreen.Windows.Services;

public sealed record MediaThumbnailResult(
    string? ThumbnailPath,
    int PixelWidth,
    int PixelHeight,
    TimeSpan? Duration,
    string? Error);

public static class MediaThumbnailService
{
    public static async Task<MediaThumbnailResult> CreateAsync(string mediaPath, string thumbnailDirectory)
    {
        try
        {
            Directory.CreateDirectory(thumbnailDirectory);
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(mediaPath));
            var properties = await file.Properties.GetVideoPropertiesAsync();
            var clip = await MediaClip.CreateFromFileAsync(file);
            var composition = new MediaComposition();
            composition.Clips.Add(clip);
            var duration = composition.Duration;
            var position = duration <= TimeSpan.Zero
                ? TimeSpan.Zero
                : TimeSpan.FromTicks(Math.Min(duration.Ticks - 1, Math.Max(0, duration.Ticks / 5)));
            using var thumbnail = await composition.GetThumbnailAsync(position, 320, 220, VideoFramePrecision.NearestFrame);
            var path = Path.Combine(thumbnailDirectory, Guid.NewGuid().ToString("N") + ".jpg");
            await WriteStreamAsync(thumbnail, path);
            return new MediaThumbnailResult(path, (int)properties.Width, (int)properties.Height, duration, null);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or
                                                COMException or NotSupportedException or InvalidOperationException)
        {
            return new MediaThumbnailResult(null, 0, 0, null,
                LocalizationService.TranslatePhrase("视频预览不可用：") + exception.Message);
        }
    }

    private static async Task WriteStreamAsync(IRandomAccessStream stream, string path)
    {
        var size = checked((uint)stream.Size);
        var bytes = new byte[size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync(size);
        reader.ReadBytes(bytes);
        await File.WriteAllBytesAsync(path, bytes);
    }
}
