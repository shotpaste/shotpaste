using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingUploadProgressTests
{
    [Fact]
    public async Task UploadProgressReportsOnlyWrittenBytesAndPreservesSignedPayload()
    {
        var audio = Enumerable.Range(0, 150_000).Select(index => (byte)(index % 251)).ToArray();
        var progress = new List<(long Sent, long Total)>();
        using var content = new VolcengineRecordingTranscriptionService.UploadContent(audio,
            (sent, total) => progress.Add((sent, total)));
        using var destination = new MemoryStream();
        await content.CopyToAsync(destination, CancellationToken.None);
        Assert.Equal(audio.LongLength, content.Headers.ContentLength);
        Assert.Equal(audio, destination.ToArray());
        Assert.Equal(new long[] { 0, 65_536, 131_072, 150_000 }, progress.Select(item => item.Sent));
        Assert.All(progress, item => Assert.Equal(audio.LongLength, item.Total));
    }

    [Fact]
    public async Task CancellationStopsUploadBeforeReportingCompletion()
    {
        using var cancellation = new CancellationTokenSource();
        var progress = new List<long>();
        using var content = new VolcengineRecordingTranscriptionService.UploadContent(new byte[150_000],
            (sent, _) => { progress.Add(sent); if (sent > 0) cancellation.Cancel(); });
        using var destination = new MemoryStream();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => content.CopyToAsync(destination, cancellation.Token));
        Assert.Equal(65_536, destination.Length);
        Assert.Equal(new long[] { 0, 65_536 }, progress);
    }

    [Theory]
    [InlineData("es-ES", "es-MX")]
    [InlineData("zh-TW", "zh-CN")]
    [InlineData("zh-Hans", "zh-CN")]
    [InlineData("zh-Hant", "zh-CN")]
    public void InterfaceLocaleResolvesToSupportedSpeechLanguage(string locale, string expected) =>
        Assert.Equal(expected, VolcengineTranscriptionProtocol.NormalizeLanguage(locale));
}
