using System.Drawing;
using System.Drawing.Imaging;
using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class GifEncodingServiceTests
{
    [Fact]
    public void CreateFrameSchedule_CoversFullDurationAndCapsLongRecordings()
    {
        var regular = GifEncodingService.CreateFrameSchedule(TimeSpan.FromSeconds(2), 15);
        Assert.Equal(30, regular.Times.Count);
        Assert.InRange(regular.FrameDelayMilliseconds, 66, 67);

        var longRecording = GifEncodingService.CreateFrameSchedule(TimeSpan.FromMinutes(10), 30, maximumFrames: 120);
        Assert.Equal(120, longRecording.Times.Count);
        Assert.True(longRecording.Times[^1] > TimeSpan.FromMinutes(9));
        Assert.Equal(5000, longRecording.FrameDelayMilliseconds);
    }

    [Fact]
    public async Task EncodeAsync_CreatesLoopingMultiFrameGif()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var output = Path.Combine(directory, "result.gif");
        try
        {
            for (var index = 0; index < 3; index++)
            {
                using var frame = new Bitmap(80, 60);
                using var graphics = Graphics.FromImage(frame);
                graphics.Clear(index switch { 0 => Color.Red, 1 => Color.Green, _ => Color.Blue });
                frame.Save(Path.Combine(directory, $"frame-{index:000}.png"), ImageFormat.Png);
            }

            await new GifEncodingService().EncodeAsync(directory, output);

            Assert.True(File.Exists(output));
            var bytes = await File.ReadAllBytesAsync(output);
            Assert.Contains("NETSCAPE2.0", System.Text.Encoding.ASCII.GetString(bytes));
            using var gif = Image.FromFile(output);
            Assert.Equal(3, gif.GetFrameCount(FrameDimension.Time));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
