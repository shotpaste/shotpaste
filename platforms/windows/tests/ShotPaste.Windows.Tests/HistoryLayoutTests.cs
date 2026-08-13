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
        Assert.Contains("ItemWidth=\"290\" ItemHeight=\"238\"", source, StringComparison.Ordinal);
        Assert.Contains("Width=\"270\" Height=\"218\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Name=\"ClipboardFilter\"", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"ClipboardHistoryFilter\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Key=\"HistorySegmentButton\"", source, StringComparison.Ordinal);
        Assert.Contains("Property=\"FontWeight\" Value=\"{DynamicResource FontWeight.Medium}\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Key=\"HistoryHeaderActionButton\"", source, StringComparison.Ordinal);
        Assert.Contains("x:Name=\"HeaderUtilities\" Grid.Column=\"2\" Height=\"34\"", source, StringComparison.Ordinal);
        Assert.Contains("Width=\"270\" Height=\"34\"", source, StringComparison.Ordinal);
        Assert.DoesNotContain("CompactHistory", source, StringComparison.Ordinal);
        Assert.DoesNotContain("HistoryModeToggle", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Binding Tag, RelativeSource={RelativeSource AncestorType={x:Type ListBox}}", source, StringComparison.Ordinal);

        var codeBehind = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "MainWindow.xaml.cs"));
        Assert.Contains("public void ShowClipboardHistory()", codeBehind, StringComparison.Ordinal);
        Assert.Contains("_selectedKind = \"Clipboard\";", codeBehind, StringComparison.Ordinal);
        Assert.Contains("HistoryExpandedHeight", codeBehind, StringComparison.Ordinal);
        Assert.Contains("PositionHistoryWindow", codeBehind, StringComparison.Ordinal);
        Assert.DoesNotContain("HistoryCompact", codeBehind, StringComparison.Ordinal);
        Assert.DoesNotContain("ToggleHistoryMode", codeBehind, StringComparison.Ordinal);
        Assert.DoesNotContain("FontWeightProperty", codeBehind, StringComparison.Ordinal);
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
