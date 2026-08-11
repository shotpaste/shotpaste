using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Media.Editing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace LiteScreen.Windows.Services;

public sealed class GifEncodingService
{
    internal sealed record GifFrameSchedule(IReadOnlyList<TimeSpan> Times, int FrameDelayMilliseconds);

    public Task EncodeAsync(string framesDirectory, string destination, int frameDelayMilliseconds = 67, int maximumWidth = 960) =>
        Task.Run(() => Encode(framesDirectory, destination, frameDelayMilliseconds, maximumWidth));

    public async Task EncodeVideoAsync(
        string videoPath,
        string destination,
        int framesPerSecond = 15,
        IProgress<double>? progress = null,
        int maximumWidth = 960)
    {
        var framesDirectory = Path.Combine(AppPaths.Captures, "GifFrames", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(framesDirectory);
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(videoPath));
            var clip = await MediaClip.CreateFromFileAsync(file);
            var composition = new MediaComposition();
            composition.Clips.Add(clip);
            var schedule = CreateFrameSchedule(composition.Duration, framesPerSecond);
            if (schedule.Times.Count == 0) throw new InvalidOperationException("录屏没有可转换为 GIF 的视频帧。");

            for (var index = 0; index < schedule.Times.Count; index++)
            {
                using var thumbnail = await composition.GetThumbnailAsync(
                    schedule.Times[index], maximumWidth, 0, VideoFramePrecision.NearestFrame);
                var size = checked((uint)thumbnail.Size);
                var bytes = new byte[size];
                using (var reader = new DataReader(thumbnail.GetInputStreamAt(0)))
                {
                    await reader.LoadAsync(size);
                    reader.ReadBytes(bytes);
                }
                await File.WriteAllBytesAsync(Path.Combine(framesDirectory, $"frame-{index:000000}.jpg"), bytes);
                progress?.Report((index + 1d) / schedule.Times.Count * 0.9d);
            }

            await EncodeAsync(framesDirectory, destination, schedule.FrameDelayMilliseconds, maximumWidth);
            progress?.Report(1d);
        }
        finally
        {
            try { if (Directory.Exists(framesDirectory)) Directory.Delete(framesDirectory, true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal static GifFrameSchedule CreateFrameSchedule(TimeSpan duration, int framesPerSecond, int maximumFrames = 1800)
    {
        if (duration <= TimeSpan.Zero || maximumFrames <= 0) return new GifFrameSchedule([], 67);
        framesPerSecond = Math.Clamp(framesPerSecond, 5, 30);
        var requestedDelay = 1000d / framesPerSecond;
        var requestedCount = Math.Max(1, (int)Math.Ceiling(duration.TotalMilliseconds / requestedDelay));
        var frameCount = Math.Min(requestedCount, maximumFrames);
        var delay = requestedCount <= maximumFrames
            ? requestedDelay
            : duration.TotalMilliseconds / frameCount;
        var times = Enumerable.Range(0, frameCount)
            .Select(index => TimeSpan.FromMilliseconds(Math.Min(
                duration.TotalMilliseconds - 1,
                index * delay)))
            .ToArray();
        return new GifFrameSchedule(times, Math.Max(20, (int)Math.Round(delay)));
    }

    private static void Encode(string framesDirectory, string destination, int frameDelayMilliseconds, int maximumWidth)
    {
        var paths = Directory.EnumerateFiles(framesDirectory)
            .Where(x => Path.GetExtension(x).Equals(".png", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(x).Equals(".jpg", StringComparison.OrdinalIgnoreCase))
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (paths.Length == 0) throw new InvalidOperationException("录屏没有生成可用于 GIF 的帧。");

        var encoder = new GifBitmapEncoder();
        foreach (var path in paths)
        {
            var image = Load(path);
            BitmapSource output = image;
            if (image.PixelWidth > maximumWidth)
            {
                var scale = (double)maximumWidth / image.PixelWidth;
                var resized = new TransformedBitmap(image, new ScaleTransform(scale, scale));
                resized.Freeze();
                output = resized;
            }
            var metadata = new BitmapMetadata("gif");
            metadata.SetQuery("/grctlext/Delay", (ushort)Math.Clamp((int)Math.Round(frameDelayMilliseconds / 10d), 2, ushort.MaxValue));
            metadata.SetQuery("/grctlext/Disposal", (byte)2);
            encoder.Frames.Add(BitmapFrame.Create(output, null, metadata, null));
        }

        using var encoded = new MemoryStream();
        encoder.Save(encoded);
        var looping = AddInfiniteLoopExtension(encoded.ToArray());
        File.WriteAllBytes(destination, looping);
    }

    private static BitmapImage Load(string path)
    {
        var image = new BitmapImage();
        image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.UriSource = new Uri(path); image.EndInit(); image.Freeze();
        return image;
    }

    private static byte[] AddInfiniteLoopExtension(byte[] gif)
    {
        if (gif.Length < 13 || gif[0] != (byte)'G' || gif[1] != (byte)'I' || gif[2] != (byte)'F') return gif;
        var packed = gif[10];
        var colorTableLength = (packed & 0x80) != 0 ? 3 * (1 << ((packed & 0x07) + 1)) : 0;
        var insertAt = Math.Min(gif.Length, 13 + colorTableLength);
        byte[] extension = [0x21, 0xFF, 0x0B, (byte)'N', (byte)'E', (byte)'T', (byte)'S', (byte)'C', (byte)'A', (byte)'P', (byte)'E', (byte)'2', (byte)'.', (byte)'0', 0x03, 0x01, 0x00, 0x00, 0x00];
        var result = new byte[gif.Length + extension.Length];
        System.Buffer.BlockCopy(gif, 0, result, 0, insertAt);
        System.Buffer.BlockCopy(extension, 0, result, insertAt, extension.Length);
        System.Buffer.BlockCopy(gif, insertAt, result, insertAt + extension.Length, gif.Length - insertAt);
        return result;
    }
}
