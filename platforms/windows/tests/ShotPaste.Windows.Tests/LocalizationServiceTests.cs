using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class LocalizationServiceTests
{
    [Fact]
    public void SupportedLanguages_MatchesMacOSLocaleSet()
    {
        Assert.Equal(10, LocalizationService.SupportedLanguages.Count);
        Assert.Contains(LocalizationService.SupportedLanguages, option => option.Code == "en-US");
        Assert.Contains(LocalizationService.SupportedLanguages, option => option.Code == "ru-RU");
        Assert.Contains(LocalizationService.SupportedLanguages, option => option.Code == "zh-TW");
        Assert.Contains(LocalizationService.SupportedLanguages, option => option.Code == "vi-VN");
    }

    [Fact]
    public void Normalize_UnknownLanguage_FallsBackToSystem()
    {
        Assert.Equal("System", LocalizationService.Normalize("xx-YY"));
        Assert.Equal("en-US", LocalizationService.Normalize("EN-us"));
    }

    [Fact]
    public void Apply_UpdatesCurrentLanguageAndLocalizedText()
    {
        var settings = new AppSettings { Language = "en-US" };
        try
        {
            LocalizationService.Apply(settings);

            Assert.Equal("en-US", LocalizationService.CurrentLanguage);
            Assert.Equal("Screenshot saved", LocalizationService.Text(settings.Language, "capture.done"));
        }
        finally
        {
            LocalizationService.Apply(new AppSettings { Language = "zh-CN" });
        }
    }

    [Fact]
    public void TranslatePhrase_ReusesMacOsStringCatalog()
    {
        Assert.Equal("Preferences", LocalizationService.TranslatePhrase("设置", "en-US"));
        Assert.NotEqual("设置", LocalizationService.TranslatePhrase("设置", "ja-JP"));
        Assert.Equal("錄製中包含 ShotPaste",
            LocalizationService.TranslatePhrase("录制中包含 ShotPaste", "zh-TW"));
        Assert.Equal("儲存與截圖後操作",
            LocalizationService.TranslatePhrase("保存与截图后操作", "zh-TW"));
        Assert.Equal("包含滑鼠游標",
            LocalizationService.TranslatePhrase("包含鼠标指针", "zh-TW"));
    }

    [Fact]
    public void EnglishLocalization_CoversEveryChineseXamlLiteral()
    {
        Assert.True(LocalizationService.WindowsEnglishFallbackCount > 200,
            $"Fallback entries: {LocalizationService.WindowsEnglishFallbackCount}; resources: {string.Join(", ", typeof(LocalizationService).Assembly.GetManifestResourceNames())}");
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, ".git")) &&
               !File.Exists(Path.Combine(directory.FullName, ".git"))) directory = directory.Parent;
        var root = directory?.FullName ?? Directory.GetCurrentDirectory();
        var views = Path.Combine(root, "platforms", "windows", "src", "ShotPaste.Windows", "Views");
        Assert.True(Directory.Exists(views), $"Views directory not found from {root}");
        var values = Directory.EnumerateFiles(views, "*.xaml")
            .SelectMany(path => System.Text.RegularExpressions.Regex.Matches(
                    File.ReadAllText(path), @"(?:Text|Content|Header|ToolTip|Title)=""([^""]+)""")
                .Select(match => match.Groups[1].Value))
            .Where(ContainsCjk)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var missing = values
            .Select(value => (Source: value, Result: LocalizationService.TranslatePhrase(value, "en-US")))
            .Where(pair => ContainsCjk(pair.Result))
            .ToArray();
        Assert.True(missing.Length == 0, $"{missing.Length} Windows XAML phrases still contain Chinese:\n" +
            string.Join("\n", missing.Take(200).Select(pair => $"{pair.Source} => {pair.Result}")));
    }

    [Fact]
    public void EnglishLocalization_CoversEveryChineseCodeString()
    {
        var root = FindRepositoryRoot();
        var sourceRoot = Path.Combine(root, "platforms", "windows", "src", "ShotPaste.Windows");
        var values = Directory.EnumerateFiles(sourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.EndsWith("LocalizationService.cs", StringComparison.OrdinalIgnoreCase))
            .SelectMany(path => System.Text.RegularExpressions.Regex.Matches(
                    File.ReadAllText(path), "\\$?\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"")
                .Select(match => match.Groups[1].Value))
            .Where(ContainsCjk)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var missing = values
            .Select(value => (Source: value, Result: LocalizationService.TranslatePhrase(value, "en-US")))
            .Where(pair => ContainsCjk(pair.Result))
            .ToArray();

        Assert.True(missing.Length == 0, $"{missing.Length} Windows code strings still contain Chinese in English:\n" +
            string.Join("\n", missing.Take(300).Select(pair => $"{pair.Source} => {pair.Result}")));
    }

    [Fact]
    public void NativeDialogs_AreRoutedThroughLocalizedBoundary()
    {
        var sourceRoot = Path.Combine(FindRepositoryRoot(), "platforms", "windows", "src", "ShotPaste.Windows");
        var offenders = Directory.EnumerateFiles(sourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.EndsWith("LocalizedDialogService.cs", StringComparison.OrdinalIgnoreCase))
            .SelectMany(path => File.ReadLines(path).Select((line, index) => (Path: path, Line: index + 1, Text: line)))
            .Where(entry => entry.Text.Contains("MessageBox.Show", StringComparison.Ordinal) ||
                            (ContainsCjk(entry.Text) &&
                             System.Text.RegularExpressions.Regex.IsMatch(entry.Text,
                                 "\\b(?:Title|Filter|Description)\\s*=\\s*\"")))
            .ToArray();

        Assert.True(offenders.Length == 0, "Native dialog localization bypasses:\n" +
            string.Join("\n", offenders.Select(entry => $"{Path.GetFileName(entry.Path)}:{entry.Line}: {entry.Text.Trim()}")));
    }

    [Fact]
    public void AutomaticWpfLocalization_TracksDynamicPropertyChangesAndLanguageSwitches()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                LocalizationService.EnableAutomaticWpfLocalization();
                LocalizationService.Apply(new AppSettings { Language = "en-US" });
                var text = new System.Windows.Controls.TextBlock { Text = "剪贴板文本" };
                var button = new System.Windows.Controls.Button { Content = "复制" };
                var window = new System.Windows.Window { Content = text, Title = "ShotPaste · 欢迎" };
                text.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.FrameworkElement.LoadedEvent));
                button.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.FrameworkElement.LoadedEvent));
                LocalizationService.LocalizeWindow(window);

                Assert.Equal("Clipboard Text", text.Text);
                Assert.Equal("Copy", button.Content);
                Assert.Equal("ShotPaste Debug · Welcome", window.Title);
                text.Text = "已复制到剪贴板";
                Assert.Equal("Copied to clipboard", text.Text);
                window.Title = "ShotPaste · 设置";
                Assert.Equal("ShotPaste Debug · Preferences", window.Title);

                LocalizationService.Apply(new AppSettings { Language = "zh-CN" });
                LocalizationService.LocalizeWindow(window);
                Assert.Equal("已复制到剪贴板", text.Text);
                Assert.Equal("ShotPaste Debug · 设置", window.Title);
            }
            catch (Exception exception) { failure = exception; }
            finally { LocalizationService.Apply(new AppSettings { Language = "zh-CN" }); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(10)), "Localization STA test timed out.");
        if (failure is not null) throw failure;
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, ".git")) &&
               !File.Exists(Path.Combine(directory.FullName, ".git"))) directory = directory.Parent;
        return directory?.FullName ?? Directory.GetCurrentDirectory();
    }

    private static bool ContainsCjk(string value) => value.Any(character => character is >= '\u3400' and <= '\u9fff');
}
