using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class TrayIconServiceTests
{
    [Theory]
    [InlineData(null, null)]
    [InlineData("", "")]
    [InlineData("   ", "\t")]
    public void NormalizeBalloonContent_ReplacesEmptyValues(string? title, string? message)
    {
        var content = TrayIconService.NormalizeBalloonContent(title, message);

        Assert.False(string.IsNullOrWhiteSpace(content.Title));
        Assert.False(string.IsNullOrWhiteSpace(content.Message));
    }

    [Fact]
    public void NormalizeBalloonContent_TrimsProvidedValues()
    {
        var content = TrayIconService.NormalizeBalloonContent(" 录屏失败 ", "  编码器不可用。 ");

        Assert.Equal("录屏失败", content.Title);
        Assert.Equal("编码器不可用。", content.Message);
    }

    [Fact]
    public void TrayMenu_OnlyExposesOneShotAsTheIdleCaptureEntry()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "TrayIconService.cs"));
        var start = source.IndexOf("private WpfContextMenu BuildMenu(AppSettings settings)", StringComparison.Ordinal);
        var end = source.IndexOf("private static string Label", start, StringComparison.Ordinal);

        Assert.True(start >= 0 && end > start, "BuildMenu method was not found.");
        var method = source[start..end];
        Assert.Contains("OneShotRequested", method, StringComparison.Ordinal);
        Assert.Contains("HistoryRequested", method, StringComparison.Ordinal);
        Assert.DoesNotContain("AreaAnnotateRequested", method, StringComparison.Ordinal);
        Assert.DoesNotContain("FullscreenCaptureRequested", method, StringComparison.Ordinal);
        Assert.DoesNotContain("ScrollingCaptureRequested", method, StringComparison.Ordinal);
        Assert.DoesNotContain("OcrRequested", method, StringComparison.Ordinal);
        Assert.DoesNotContain("录制屏幕", method, StringComparison.Ordinal);
        Assert.Contains("停止录制", method, StringComparison.Ordinal);
        Assert.DoesNotContain("ContextMenuStrip", source, StringComparison.Ordinal);
        Assert.DoesNotContain("ShowBalloonTip", source, StringComparison.Ordinal);
    }

    private static string FindRepositoryFile(params string[] relativeParts)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, ".git")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        return Path.Combine([directory!.FullName, .. relativeParts]);
    }
}
