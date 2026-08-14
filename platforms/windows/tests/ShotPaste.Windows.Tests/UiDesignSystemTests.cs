using System.Text.RegularExpressions;
using System.Xml.Linq;

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

    [Theory]
    [InlineData("Colors.Light.xaml")]
    [InlineData("Colors.Dark.xaml")]
    public void ThemeTextColors_MeetWcagAaContrast(string themeFile)
    {
        var document = XDocument.Load(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Resources", "Themes", themeFile));
        var colors = document.Root!.Elements()
            .Where(element => element.Name.LocalName == "Color")
            .ToDictionary(
                element => element.Attributes().Single(attribute => attribute.Name.LocalName == "Key").Value,
                element => ParseRgb(element.Value));
        foreach (var (foreground, background) in new[]
                 {
                     ("TextColor", "WindowColor"),
                     ("TextColor", "SurfaceColor"),
                     ("SecondaryTextColor", "SurfaceColor"),
                     ("SecondaryTextColor", "SurfaceSecondaryColor")
                 })
        {
            var ratio = Contrast(colors[foreground], colors[background]);
            Assert.True(ratio >= 4.5,
                $"{themeFile}: {foreground} on {background} has {ratio:0.00}:1 contrast; expected at least 4.50:1.");
        }
    }

    [Fact]
    public void OcrResultCard_UsesReadableHudTextSurface()
    {
        var resourcePath = FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Resources", "DesignTokens.xaml");
        var document = XDocument.Load(resourcePath);
        var requiredBrushes = new HashSet<string>(StringComparer.Ordinal)
        {
            "HudBrush", "HudInputBrush", "HudTextBrush"
        };
        var brushes = document.Root!.Elements()
            .Where(element => element.Name.LocalName == "SolidColorBrush")
            .Where(element => requiredBrushes.Contains(
                element.Attributes().Single(attribute => attribute.Name.LocalName == "Key").Value))
            .ToDictionary(
                element => element.Attributes().Single(attribute => attribute.Name.LocalName == "Key").Value,
                element => ParseArgb(element.Attribute("Color")!.Value));

        var inputSurface = Composite(brushes["HudInputBrush"], brushes["HudBrush"]);
        var ratio = Contrast(brushes["HudTextBrush"].Rgb, inputSurface);
        Assert.True(ratio >= 4.5,
            $"HudTextBrush on HudInputBrush has {ratio:0.00}:1 contrast; expected at least 4.50:1.");

        var view = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "OcrResultWindow.xaml"));
        Assert.Contains("AutomationProperties.AutomationId=\"OcrResultText\"", view, StringComparison.Ordinal);
        Assert.Contains("Background=\"{DynamicResource HudInputBrush}\"", view, StringComparison.Ordinal);
        Assert.Contains("Foreground=\"{DynamicResource HudTextBrush}\"", view, StringComparison.Ordinal);
        Assert.DoesNotContain("<TextBox Grid.Row=\"1\"", view, StringComparison.Ordinal);
    }

    [Fact]
    public void AccessibilityPreferences_UseSystemContrastAndReduceMotionSignals()
    {
        var sourceRoot = FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows");
        var preferences = File.ReadAllText(Path.Combine(sourceRoot, "Services", "AccessibilityPreferences.cs"));
        Assert.Contains("SystemParameters.HighContrast", preferences, StringComparison.Ordinal);
        Assert.Contains("SystemParameters.ClientAreaAnimation", preferences, StringComparison.Ordinal);
        Assert.Contains("SystemColors.WindowTextBrush", preferences, StringComparison.Ordinal);
        Assert.Contains("SystemColors.HighlightTextBrush", preferences, StringComparison.Ordinal);

        foreach (var view in new[]
                 {
                     "RecordingToolbarWindow.xaml.cs", "MouseClickOverlayWindow.xaml.cs", "QuickAccessWindow.xaml.cs",
                     "PinnedImageWindow.xaml.cs", "SettingsWindow.xaml.cs", "ToastWindow.xaml.cs"
                 })
            Assert.Contains("ReduceMotion", File.ReadAllText(Path.Combine(sourceRoot, "Views", view)),
                StringComparison.Ordinal);
    }

    private static (double R, double G, double B) ParseRgb(string value)
    {
        var hex = value.Trim().TrimStart('#');
        if (hex.Length == 8) hex = hex[2..];
        Assert.Equal(6, hex.Length);
        return (Convert.ToInt32(hex[..2], 16) / 255d,
            Convert.ToInt32(hex.Substring(2, 2), 16) / 255d,
            Convert.ToInt32(hex.Substring(4, 2), 16) / 255d);
    }

    private static (double Alpha, (double R, double G, double B) Rgb) ParseArgb(string value)
    {
        var hex = value.Trim().TrimStart('#');
        Assert.True(hex.Length is 6 or 8);
        var alpha = hex.Length == 8 ? Convert.ToInt32(hex[..2], 16) / 255d : 1d;
        var rgb = ParseRgb(hex.Length == 8 ? hex[2..] : hex);
        return (alpha, rgb);
    }

    private static (double R, double G, double B) Composite(
        (double Alpha, (double R, double G, double B) Rgb) foreground,
        (double Alpha, (double R, double G, double B) Rgb) background)
    {
        var alpha = foreground.Alpha;
        return (
            foreground.Rgb.R * alpha + background.Rgb.R * (1 - alpha),
            foreground.Rgb.G * alpha + background.Rgb.G * (1 - alpha),
            foreground.Rgb.B * alpha + background.Rgb.B * (1 - alpha));
    }

    private static double Contrast((double R, double G, double B) first, (double R, double G, double B) second)
    {
        static double Luminance((double R, double G, double B) color)
        {
            static double Linear(double component) => component <= 0.04045
                ? component / 12.92
                : Math.Pow((component + 0.055) / 1.055, 2.4);
            return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
        }
        var one = Luminance(first);
        var two = Luminance(second);
        return (Math.Max(one, two) + 0.05) / (Math.Min(one, two) + 0.05);
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
