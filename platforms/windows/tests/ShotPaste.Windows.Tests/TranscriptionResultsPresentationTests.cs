using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Tests;

public sealed class TranscriptionResultsPresentationTests
{
    [Fact]
    public void AudioHistoryUsesRecordingCategoryWithoutAttemptingImageDecode()
    {
        var item = new CaptureHistoryItem { Kind = CaptureKind.Audio, FilePath = "saved.m4a", Duration = TimeSpan.FromSeconds(5) };
        Assert.True(MainWindow.MatchesHistoryKind(item.Kind, "Recording"));
        Assert.Null(item.PreviewSource);
    }

    [Fact]
    public void ResultsCanFindRemovedSourceByNameDateAndType()
    {
        var job = new RecordingTranscriptionJob { RecordingPath = "removed-meeting.m4a", CreatedAt = new DateTimeOffset(2026, 9, 7, 12, 0, 0, TimeSpan.Zero) };
        Assert.True(TranscriptionResultsWindow.Matches(job, "audio", "MEETING"));
        Assert.True(TranscriptionResultsWindow.Matches(job, "all", "2026-09-07"));
        Assert.False(TranscriptionResultsWindow.Matches(job, "video", ""));
        Assert.False(TranscriptionResultsWindow.Matches(job, "audio", "unrelated"));
    }

    [Theory]
    [InlineData("en-US", "Transcription Results")]
    [InlineData("zh-CN", "转写结果")]
    public void SharedCatalogKeysResolveWithoutEnglishFallback(string locale, string expected)
    {
        Assert.Equal(expected, LocalizationService.Text(locale, "recording.results.title"));
    }
}
