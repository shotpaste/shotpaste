namespace ShotPaste.Windows.Tests;

public sealed class HistoryLayoutTests
{
    [Fact]
    public void MainWindow_UsesOnlyFullClipboardFirstVirtualizedGrid()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "MainWindow.xaml"));

        Assert.Contains("x:Name=\"HistoryItems\"", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"ExpandedHistoryGrid\"", source, StringComparison.Ordinal);
        Assert.Contains("<controls:VirtualizingWrapPanel", source, StringComparison.Ordinal);
        Assert.Contains("ItemWidth=\"228\" ItemHeight=\"208\"", source, StringComparison.Ordinal);
        Assert.Contains("Width=\"214\" Height=\"190\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Name=\"ClipboardFilter\"", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"ClipboardHistoryFilter\"", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.Name=\"剪贴板历史\"", source, StringComparison.Ordinal);
        Assert.Contains("<TextBlock Text=\"剪贴板历史\"/>", source, StringComparison.Ordinal);
        Assert.Contains("Text=\"搜索捕获内容\"", source, StringComparison.Ordinal);
        Assert.Contains("Content=\"不限时间\" Tag=\"All\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("<Button Tag=\"All\"", source, StringComparison.Ordinal);
        Assert.Contains("Content=\"{StaticResource Icon.Pin}\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("AutomationProperties.AutomationId=\"HistorySettings\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Key=\"HistorySegmentButton\"", source, StringComparison.Ordinal);
        Assert.Contains("Property=\"FontWeight\" Value=\"{DynamicResource FontWeight.Medium}\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Key=\"HistoryHeaderActionButton\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Name=\"HeaderUtilities\" Grid.Column=\"2\" Height=\"34\"", source, StringComparison.Ordinal);
        Assert.Contains("Width=\"238\" Height=\"34\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("CompactHistory", source, StringComparison.Ordinal);
        Assert.DoesNotContain("HistoryModeToggle", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Binding Tag, RelativeSource={RelativeSource AncestorType={x:Type ListBox}}", source, StringComparison.Ordinal);

        var codeBehind = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "MainWindow.xaml.cs"));
        Assert.Contains("public void ShowClipboardHistory()", codeBehind, StringComparison.Ordinal);
        Assert.Contains("_selectedKind = \"Clipboard\";", codeBehind, StringComparison.Ordinal);
        Assert.Contains("HistoryExpandedHeight", codeBehind, StringComparison.Ordinal);
        Assert.Contains("PositionHistoryWindow", codeBehind, StringComparison.Ordinal);
        Assert.Contains("\"Clipboard\" => ClipboardFileClassifier.IsClipboardKind(item.Kind)", codeBehind, StringComparison.Ordinal);
        Assert.DoesNotContain("HistoryCompact", codeBehind, StringComparison.Ordinal);
        Assert.DoesNotContain("ToggleHistoryMode", codeBehind, StringComparison.Ordinal);
        Assert.DoesNotContain("FontWeightProperty", codeBehind, StringComparison.Ordinal);
    }

    [Fact]
    public void Settings_UseMacParityPagesAndDoNotExposeWindowsOnlyConfiguration()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "SettingsWindow.xaml"));
        var controller = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "AppController.cs"));

        foreach (var automationId in new[]
                 {
                     "SettingsGeneralTab", "SettingsCaptureRecordingTab", "SettingsQuickAccessTab",
                     "SettingsHistoryTab", "SettingsShortcutsTab", "SettingsAdvancedTab",
                     "SettingsCaptureGeneralSubtab", "SettingsCaptureScreenshotSubtab", "SettingsCaptureRecordingSubtab"
                 })
            Assert.Contains($"AutomationProperties.AutomationId=\"{automationId}\"", source, StringComparison.Ordinal);

        Assert.DoesNotContain("SettingsAppearanceTab", source, StringComparison.Ordinal);
        Assert.DoesNotContain("SettingsCaptureScrollingSubtab", source, StringComparison.Ordinal);
        Assert.DoesNotContain("打开 Windows 键盘设置", source, StringComparison.Ordinal);
        Assert.DoesNotContain("MOV（Windows 不可用）", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Text=\"预设\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("实验性滚动算法", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Binding ScrollingAutoScrollEnabled", source, StringComparison.Ordinal);
        Assert.DoesNotContain("_settings.Current.ScrollingAutoScroll", controller, StringComparison.Ordinal);
        Assert.DoesNotContain("_settings.Current.ScrollingMaxHeight", controller, StringComparison.Ordinal);

        Assert.True(source.IndexOf("Text=\"应用程序窗口\"", StringComparison.Ordinal) <
                    source.IndexOf("Text=\"桌面\"", StringComparison.Ordinal));
        Assert.True(source.IndexOf("Text=\"桌面\"", StringComparison.Ordinal) <
                    source.IndexOf("Text=\"格式\"", StringComparison.Ordinal));
        Assert.True(source.IndexOf("Text=\"格式\"", StringComparison.Ordinal) <
                    source.IndexOf("Text=\"OCR（文本识别）\"", StringComparison.Ordinal));
        Assert.True(source.IndexOf("Text=\"快速操作\"", StringComparison.Ordinal) <
                    source.IndexOf("Text=\"位置与外观\"", StringComparison.Ordinal));
        Assert.True(source.IndexOf("Text=\"位置与外观\"", StringComparison.Ordinal) <
                    source.IndexOf("Text=\"行为\"", StringComparison.Ordinal));
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
