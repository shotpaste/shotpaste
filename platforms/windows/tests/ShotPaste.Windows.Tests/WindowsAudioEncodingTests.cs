using NAudio.Wave;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class WindowsAudioEncodingTests
{
    [Fact]
    public async Task SpeechRateSourceIsConvertedToNativeAacSupportedRate()
    {
        // Native Windows codec regression: the AAC MFT rejects 16 kHz PCM even
        // though that sample rate is valid input audio for the speech service.
        var directory = Path.Combine(Path.GetTempPath(), "ShotPaste-Aac-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var source = Path.Combine(directory, "speech.wav");
            using (var writer = new WaveFileWriter(source, new WaveFormat(16000, 16, 1)))
                for (var sample = 0; sample < 32000; sample++)
                    writer.WriteSample((float)(0.1 * Math.Sin(2 * Math.PI * 440 * sample / 16000)));
            var prepared = await VolcengineRecordingTranscriptionService.PrepareAudioPartAsync(source,
                Path.Combine(directory, "pending.m4a"), 0, 0, CancellationToken.None);
            var encoded = Path.Combine(directory, "result.m4a");
            await File.WriteAllBytesAsync(encoded, prepared.Data);
            using var decoded = new MediaFoundationReader(encoded);
            Assert.Contains(decoded.WaveFormat.SampleRate, new[] { 44100, 48000 });
            Assert.InRange(decoded.TotalTime.TotalSeconds, 1.9, 2.2);
            Assert.True(decoded.Read(new byte[4096], 0, 4096) > 0);
        }
        finally { Directory.Delete(directory, true); }
    }
}
