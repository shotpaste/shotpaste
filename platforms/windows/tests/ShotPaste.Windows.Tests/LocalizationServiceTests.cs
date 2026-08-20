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

    [Theory]
    [InlineData("保持打开", "de-DE", "Geöffnet lassen")]
    [InlineData("重试保存", "ja-JP", "保存を再試行")]
    [InlineData("可恢复", "ko-KR", "복구 가능")]
    [InlineData("长图保存失败 · 成果仍保留", "fr-FR", "Échec de l’enregistrement de la capture défilante · Résultat conservé")]
    public void TranslatePhrase_LocalizesWindowsRecoveryUx(string source, string language, string expected)
    {
        Assert.Equal(expected, LocalizationService.TranslatePhrase(source, language));
    }

    [Fact]
    public void DatabaseRecoveryEntry_HasExplicitNativeCopyForEveryVisibleLocale()
    {
        string[] phrases =
        [
            "ShotPaste 需要历史数据库才能运行。", "数据库：", "错误：", "退出 ShotPaste",
            "ShotPaste 会把当前数据库文件移到恢复文件夹，然后创建新的空数据库。",
            "这会清空 ShotPaste 内的历史记录，但不会删除磁盘上的截图、录屏或剪贴板文件。",
            "当前错误："
        ];
        var sourceRoot = Path.Combine(FindRepositoryRoot(), "platforms", "windows", "src", "ShotPaste.Windows");
        var english = phrases.ToDictionary(
            phrase => phrase,
            phrase => LocalizationService.TranslatePhrase(phrase, "en-US"),
            StringComparer.Ordinal);

        foreach (var language in LocalizationService.SupportedLanguages.Where(language => language.Code != "zh-CN"))
        {
            var suffix = language.Code == "en-US" ? "en" : language.Code;
            var resourcePath = Path.Combine(sourceRoot, "Resources", $"WindowsLocalization.{suffix}.json");
            using var resource = System.Text.Json.JsonDocument.Parse(File.ReadAllText(resourcePath));
            var translations = resource.RootElement.EnumerateObject()
                .Where(property => phrases.Contains(property.Name, StringComparer.Ordinal))
                .GroupBy(property => property.Name, StringComparer.Ordinal)
                .ToDictionary(group => group.Key, group => group.Last().Value.GetString() ?? string.Empty,
                    StringComparer.Ordinal);

            Assert.All(phrases, phrase =>
            {
                Assert.True(translations.TryGetValue(phrase, out var expected),
                    $"{language.Code} is missing database recovery text: {phrase}");
                Assert.Equal(expected, LocalizationService.TranslatePhrase(phrase, language.Code));
                Assert.NotEqual(phrase, expected);
            });

            if (language.Code != "en-US")
                Assert.True(phrases.Count(phrase => !string.Equals(translations[phrase], english[phrase], StringComparison.Ordinal)) >= 6,
                    $"{language.Code} still uses English for most database recovery text.");
        }
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
                    File.ReadAllText(path), @"(?:Text|Content|Header|ToolTip|Title|AutomationProperties\.Name)=""([^""]+)""")
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
    public void NativeLocaleCoverage_DoesNotLeakSimplifiedChineseOrImplicitEnglishFallback()
    {
        var sourceRoot = Path.Combine(FindRepositoryRoot(), "platforms", "windows", "src", "ShotPaste.Windows");
        var codeEntries = Directory.EnumerateFiles(sourceRoot, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.EndsWith("LocalizationService.cs", StringComparison.OrdinalIgnoreCase))
            .SelectMany(path => System.Text.RegularExpressions.Regex.Matches(
                    File.ReadAllText(path), "\\$?\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"")
                .Select(match => match.Groups[1].Value))
            .Where(ContainsCjk);
        var viewRoot = Path.Combine(sourceRoot, "Views");
        var xamlEntries = Directory.EnumerateFiles(viewRoot, "*.xaml")
            .SelectMany(path => System.Text.RegularExpressions.Regex.Matches(
                    File.ReadAllText(path), @"(?:Text|Content|Header|ToolTip|Title|AutomationProperties\.Name)=""([^""]+)""")
                .Select(match => match.Groups[1].Value))
            .Where(ContainsCjk);
        var entries = codeEntries.Concat(xamlEntries).Distinct(StringComparer.Ordinal).ToArray();

        var localeFailureMessages = new List<string>();
        foreach (var language in LocalizationService.SupportedLanguages
            .Where(language => language.Code is "de-DE" or "fr-FR" or "es-ES" or "ru-RU" or "vi-VN" or "ja-JP" or "ko-KR")
            .ToArray())
        {
            var resourcePath = Path.Combine(sourceRoot, "Resources", $"WindowsLocalization.{language.Code}.json");
            using var resource = System.Text.Json.JsonDocument.Parse(File.ReadAllText(resourcePath));
            var explicitOverrides = resource.RootElement.EnumerateObject()
                .Select(property => property.Name)
                .ToHashSet(StringComparer.Ordinal);
            var failures = entries
                .Select(source => (Source: source, Result: LocalizationService.TranslatePhrase(source, language.Code)))
                .Where(pair => language.Code is "ja-JP" or "ko-KR"
                    ? string.Equals(pair.Source, pair.Result, StringComparison.Ordinal) && !explicitOverrides.Contains(pair.Source)
                    : ContainsCjk(pair.Result))
                .ToArray();
            if (failures.Length > 0)
                localeFailureMessages.Add($"{language.Code} has {failures.Length} native localization gaps:\n" +
                    string.Join("\n", failures.Take(200).Select(pair => $"{pair.Source} => {pair.Result}")));
        }
        Assert.True(localeFailureMessages.Count == 0, string.Join("\n\n", localeFailureMessages));

        string[] parityPhrases =
        [
            "数据库已重置", "清空全部历史（关联文件移入回收站）", "检测 OCR 结果中的链接并显示卡片",
            "导出 ShotPaste 诊断包", "所有已启用快捷键均可注册。"
        ];
        foreach (var language in LocalizationService.SupportedLanguages.Where(language => language.Code is not ("zh-CN" or "en-US")))
        foreach (var phrase in parityPhrases)
            Assert.NotEqual(LocalizationService.TranslatePhrase(phrase, "en-US"),
                LocalizationService.TranslatePhrase(phrase, language.Code));
    }

    [Fact]
    public void WindowsLocaleOverrides_PreserveEveryFormattingPlaceholder()
    {
        var resources = Path.Combine(FindRepositoryRoot(), "platforms", "windows", "src", "ShotPaste.Windows", "Resources");
        foreach (var path in Directory.EnumerateFiles(resources, "WindowsLocalization.*.json"))
        {
            using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path));
            foreach (var property in document.RootElement.EnumerateObject())
            {
                var required = System.Text.RegularExpressions.Regex.Matches(property.Name, "\\{[^{}]+\\}")
                    .Select(match => match.Value)
                    .ToArray();
                var translated = property.Value.GetString() ?? string.Empty;
                Assert.All(required, placeholder => Assert.Contains(placeholder, translated, StringComparison.Ordinal));
            }
        }
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
                Assert.Equal($"{AppBuildIdentity.Current.DisplayName} · Welcome", window.Title);
                text.Text = "已复制到剪贴板";
                Assert.Equal("Copied to clipboard", text.Text);
                window.Title = "ShotPaste · 设置";
                Assert.Equal($"{AppBuildIdentity.Current.DisplayName} · Preferences", window.Title);

                LocalizationService.Apply(new AppSettings { Language = "zh-CN" });
                LocalizationService.LocalizeWindow(window);
                Assert.Equal("已复制到剪贴板", text.Text);
                Assert.Equal($"{AppBuildIdentity.Current.DisplayName} · 设置", window.Title);
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
