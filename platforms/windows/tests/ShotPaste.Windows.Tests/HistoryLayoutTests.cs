using ShotPaste.Windows.Models;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Tests;

public sealed class HistoryLayoutTests
{
    [Theory]
    [InlineData(CaptureKind.Screenshot)]
    [InlineData(CaptureKind.ScrollingScreenshot)]
    [InlineData(CaptureKind.Recording)]
    [InlineData(CaptureKind.Gif)]
    [InlineData(CaptureKind.ClipboardImage)]
    [InlineData(CaptureKind.ClipboardText)]
    [InlineData(CaptureKind.ClipboardFile)]
    [InlineData(CaptureKind.ClipboardGif)]
    [InlineData(CaptureKind.ClipboardVideo)]
    public void ClipboardHistoryFilter_IsTheAggregateHistoryView(CaptureKind kind)
    {
        Assert.True(MainWindow.MatchesHistoryKind(kind, "Clipboard"));
    }

    [Fact]
    public void CaptureTypeFilters_RemainNarrowSubsetsOfClipboardHistory()
    {
        Assert.True(MainWindow.MatchesHistoryKind(CaptureKind.Screenshot, "Screenshot"));
        Assert.False(MainWindow.MatchesHistoryKind(CaptureKind.ClipboardImage, "Screenshot"));
        Assert.True(MainWindow.MatchesHistoryKind(CaptureKind.ScrollingScreenshot, "ScrollingScreenshot"));
        Assert.False(MainWindow.MatchesHistoryKind(CaptureKind.Screenshot, "ScrollingScreenshot"));
        Assert.True(MainWindow.MatchesHistoryKind(CaptureKind.Recording, "Recording"));
        Assert.True(MainWindow.MatchesHistoryKind(CaptureKind.Gif, "Recording"));
        Assert.False(MainWindow.MatchesHistoryKind(CaptureKind.ClipboardVideo, "Recording"));
    }

}
