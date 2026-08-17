using ShotPaste.Windows.Services;
using System.Windows;

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

    [Theory]
    [InlineData(true, Visibility.Visible)]
    [InlineData(false, Visibility.Collapsed)]
    public void QuickAccessMenuVisibility_TracksVisibleFloatingCards(bool hasVisibleCards, Visibility expected)
    {
        Assert.Equal(expected, TrayIconService.QuickAccessMenuVisibility(hasVisibleCards));
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
        Assert.Contains("UpdateQuickAccessMenuVisibility();", method, StringComparison.Ordinal);
        Assert.Contains("menu.PlacementTarget = null;", method, StringComparison.Ordinal);
        Assert.Contains("menu.PlacementTarget = _menuPlacementTarget?.Invoke();", source, StringComparison.Ordinal);
        Assert.Contains("if (_menu?.IsOpen == true)", source, StringComparison.Ordinal);
        Assert.Contains("_menuRefreshPending = true;", source, StringComparison.Ordinal);
        Assert.Contains("menu.Dispatcher.BeginInvoke(RebuildMenu)", method, StringComparison.Ordinal);
        var updateStart = source.IndexOf("public void UpdateShortcuts(AppSettings settings)", StringComparison.Ordinal);
        var updateEnd = source.IndexOf("public void UpdateRecordingState", updateStart, StringComparison.Ordinal);
        Assert.True(updateStart >= 0 && updateEnd > updateStart, "UpdateShortcuts method was not found.");
        Assert.DoesNotContain("_menu.IsOpen = false", source[updateStart..updateEnd], StringComparison.Ordinal);
        Assert.Contains("InvokeAfterMenuClosesAsync(menu", method, StringComparison.Ordinal);
        Assert.Contains("TryCreateMenuProbe(menu)", method, StringComparison.Ordinal);
        Assert.Contains("NativeMethods.ShowWindow(probe.Handle, NativeMethods.SwHide)", method, StringComparison.Ordinal);
        Assert.Contains("CaptureReadinessService.WaitAsync", method, StringComparison.Ordinal);
        Assert.Contains("TrayMenuDismissBeforeOneShot", method, StringComparison.Ordinal);
        Assert.Contains("if (!readiness.IsReady)", method, StringComparison.Ordinal);
        Assert.True(method.IndexOf("menu.IsOpen = false", StringComparison.Ordinal) <
                    method.IndexOf("action();", StringComparison.Ordinal),
            "One Shot must not start until after the tray menu close and compositor readiness barrier.");
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
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, ".git")) &&
               !File.Exists(Path.Combine(directory.FullName, ".git")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        return Path.Combine([directory!.FullName, .. relativeParts]);
    }
}
