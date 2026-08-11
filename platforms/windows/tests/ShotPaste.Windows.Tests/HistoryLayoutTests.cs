namespace ShotPaste.Windows.Tests;

public sealed class HistoryLayoutTests
{
    [Fact]
    public void MainWindow_UsesSeparateCompactCarouselAndExpandedVirtualizedGrid()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "MainWindow.xaml"));

        Assert.Contains("x:Name=\"CompactHistoryItems\"", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"CompactHistoryCarousel\"", source, StringComparison.Ordinal);
        Assert.Contains("<VirtualizingStackPanel Orientation=\"Horizontal\"/>", source, StringComparison.Ordinal);
        Assert.Contains("x:Name=\"HistoryItems\"", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"ExpandedHistoryGrid\"", source, StringComparison.Ordinal);
        Assert.Contains("<controls:VirtualizingWrapPanel", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Binding Tag, RelativeSource={RelativeSource AncestorType={x:Type ListBox}}", source, StringComparison.Ordinal);

        var codeBehind = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "MainWindow.xaml.cs"));
        Assert.Contains("CaptureScrollOffset", codeBehind, StringComparison.Ordinal);
        Assert.Contains("RestoreViewState", codeBehind, StringComparison.Ordinal);
        Assert.Contains("HistoryCompactWidth", codeBehind, StringComparison.Ordinal);
        Assert.Contains("HistoryExpandedHeight", codeBehind, StringComparison.Ordinal);
        Assert.Contains("OnToggleHistoryMode", codeBehind, StringComparison.Ordinal);
        Assert.Contains("PositionExpandedWindow", codeBehind, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.AutomationId=\"HistoryModeToggle\"", source, StringComparison.Ordinal);
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
