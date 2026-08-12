using System.Text.RegularExpressions;

namespace ShotPaste.Windows.Tests;

public sealed class UiDesignSystemTests
{
    [Fact]
    public void App_MergesCompleteDesignSystemDictionaries()
    {
        var app = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "App.xaml"));
        foreach (var resource in new[]
                 {
                     "Resources/DesignTokens.xaml",
                     "Resources/Themes/Colors.Light.xaml",
                     "Resources/Icons.xaml",
                     "Resources/Controls/TextBox.xaml",
                     "Resources/Controls/RadioButton.xaml",
                     "Resources/Controls/Slider.xaml",
                     "Resources/Controls/ScrollBar.xaml",
                     "Resources/Controls/Menu.xaml",
                     "Resources/Controls/Tabs.xaml"
                 })
            Assert.Contains(resource, app, StringComparison.Ordinal);
    }

    [Fact]
    public void Views_DoNotReintroduceHardcodedHexColorsOrNumericCornerRadii()
    {
        var views = Directory.EnumerateFiles(FindRepositoryFile(
                "platforms", "windows", "src", "ShotPaste.Windows", "Views"), "*.xaml")
            .Select(path => (Path: path, Source: File.ReadAllText(path)))
            .ToArray();

        var colorOffenders = views.Where(file => Regex.IsMatch(file.Source, "#[0-9A-Fa-f]{6,8}"))
            .Select(file => Path.GetFileName(file.Path)).ToArray();
        var radiusOffenders = views.Where(file => Regex.IsMatch(file.Source, "CornerRadius=\"[0-9]"))
            .Select(file => Path.GetFileName(file.Path)).ToArray();

        Assert.Empty(colorOffenders);
        Assert.Empty(radiusOffenders);
    }

    [Fact]
    public void ProductUi_UsesVectorIconsAndCustomNotifications()
    {
        var sourceRoot = FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows");
        var viewSource = string.Join('\n', Directory.EnumerateFiles(Path.Combine(sourceRoot, "Views"), "*.xaml")
            .Select(File.ReadAllText));
        var forbiddenStandaloneGlyph = new Regex(
            "(?:Content|Header|Text)=\"(?:⚙|▣|◷|⌨|↕|☷|▦|◉|⬡|↗|↱|↰|↷|↶|➤|⇢|▶|●|╱|✦|⠇|▒|▰|▧|⚑|⌛|⌕|×|Ⅱ)\"",
            RegexOptions.CultureInvariant);
        Assert.DoesNotMatch(forbiddenStandaloneGlyph, viewSource);

        var tray = File.ReadAllText(Path.Combine(sourceRoot, "Services", "TrayIconService.cs"));
        var dialogs = File.ReadAllText(Path.Combine(sourceRoot, "Services", "LocalizedDialogService.cs"));
        Assert.DoesNotContain("ContextMenuStrip", tray, StringComparison.Ordinal);
        Assert.DoesNotContain("ShowBalloonTip", tray, StringComparison.Ordinal);
        Assert.Contains("ToastService.Show", tray, StringComparison.Ordinal);
        Assert.DoesNotContain("MessageBox.Show", dialogs, StringComparison.Ordinal);
        Assert.Contains("ShotPasteDialogWindow", dialogs, StringComparison.Ordinal);
    }

    [Fact]
    public void HistoryButtons_UseSegmentedVectorComponentStyles()
    {
        var sourceRoot = FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows");
        var history = File.ReadAllText(Path.Combine(sourceRoot, "Views", "MainWindow.xaml"));
        var icons = File.ReadAllText(Path.Combine(sourceRoot, "Resources", "Icons.xaml"));

        foreach (var style in new[]
                 {
                     "HistoryToolbarButton",
                     "HistorySegmentButton",
                     "HistoryIconButton",
                     "HistoryHeaderActionButton",
                     "HistoryHeaderIconButton",
                     "HistoryCardAction",
                     "HistoryCardDangerAction"
                 })
            Assert.Contains($"x:Key=\"{style}\"", history, StringComparison.Ordinal);

        foreach (var icon in new[] { "Icon.Screenshot", "Icon.ScrollCapture", "Icon.Recording", "Icon.Clipboard", "Icon.Refresh" })
            Assert.Contains($"x:Key=\"{icon}\"", icons, StringComparison.Ordinal);

        Assert.Contains("x:Name=\"KindFilterGroup\"", history, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.Name=\"剪贴板\"", history, StringComparison.Ordinal);
        Assert.DoesNotContain("HistoryFloatingIconButton", history, StringComparison.Ordinal);
        Assert.DoesNotContain("HistoryModeToggle", history, StringComparison.Ordinal);
        Assert.DoesNotContain("StaticResource HistoryPill", history, StringComparison.Ordinal);
    }

    [Fact]
    public void WindowAppearance_UsesNativeCornersAndBackdropsWithFallback()
    {
        var source = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "WindowAppearanceService.cs"));
        Assert.Contains("DwmaWindowCornerPreference = 33", source, StringComparison.Ordinal);
        Assert.Contains("DwmaSystemBackdropType = 38", source, StringComparison.Ordinal);
        Assert.Contains("OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621)", source, StringComparison.Ordinal);
        Assert.Contains("window.AllowsTransparency = true", source, StringComparison.Ordinal);
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
