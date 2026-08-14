using ShotPaste.Windows.Models;
using ShotPaste.Windows.Interop;
using System.ComponentModel;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace ShotPaste.Windows.Services;

/// <summary>
/// Small, dependency-free localization catalog for the Windows client.
/// Feature windows use these keys for titles and status messages while the
/// settings surface exposes the same ten locales as the macOS client.
/// Missing keys intentionally fall back to Simplified Chinese.
/// </summary>
public static class LocalizationService
{
    public static string CurrentLanguage { get; private set; } = "zh-CN";
    internal static int WindowsEnglishFallbackCount => WindowsEnglishFallback.Value.Count;
    public sealed record LanguageOption(string Code, string NativeName);

    public static IReadOnlyList<LanguageOption> SupportedLanguages { get; } =
    [
        new("zh-CN", "简体中文"),
        new("zh-TW", "繁體中文"),
        new("en-US", "English"),
        new("ja-JP", "日本語"),
        new("ko-KR", "한국어"),
        new("de-DE", "Deutsch"),
        new("fr-FR", "Français"),
        new("es-ES", "Español"),
        new("ru-RU", "Русский"),
        new("vi-VN", "Tiếng Việt")
    ];

    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Catalog =
        new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["zh-CN"] = new Dictionary<string, string>
            {
                ["app.title"] = "ShotPaste",
                ["history.title"] = "ShotPaste · 剪贴板历史",
                ["capture.done"] = "截图已保存",
                ["ocr.done"] = "文字已复制"
            },
            ["en-US"] = new Dictionary<string, string>
            {
                ["app.title"] = "ShotPaste",
                ["history.title"] = "ShotPaste · Clipboard History",
                ["capture.done"] = "Screenshot saved",
                ["ocr.done"] = "Text copied"
            },
            ["ja-JP"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · クリップボード履歴",
                ["capture.done"] = "スクリーンショットを保存しました",
                ["ocr.done"] = "テキストをコピーしました"
            },
            ["ko-KR"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · 클립보드 기록",
                ["capture.done"] = "스크린샷을 저장했습니다",
                ["ocr.done"] = "텍스트를 복사했습니다"
            },
            ["de-DE"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · Zwischenablageverlauf"
            },
            ["fr-FR"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · Historique du presse-papiers"
            },
            ["es-ES"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · Historial del portapapeles"
            },
            ["zh-TW"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · 剪貼簿記錄"
            },
            ["vi-VN"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · Lịch sử bảng nhớ tạm"
            },
            ["ru-RU"] = new Dictionary<string, string>
            {
                ["history.title"] = "ShotPaste · История буфера обмена"
            }
        };

    private static readonly IReadOnlyDictionary<string, string> AppleLocaleByWindowsCode =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["zh-CN"] = "zh-Hans", ["zh-TW"] = "zh-Hant", ["en-US"] = "en",
            ["ja-JP"] = "ja", ["ko-KR"] = "ko", ["de-DE"] = "de",
            ["fr-FR"] = "fr", ["es-ES"] = "es", ["ru-RU"] = "ru", ["vi-VN"] = "vi"
        };
    private static readonly Lazy<IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>>> PhraseCatalog =
        new(BuildPhraseCatalog);
    private static readonly Lazy<IReadOnlyDictionary<string, string>> WindowsEnglishFallback =
        new(BuildWindowsEnglishFallback);
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> WindowsUxPhraseOverrides =
        new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.Ordinal)
        {
            ["保持打开"] = LocalizedUxPhrase(
                "Keep Open", "保持開啟", "開いたままにする", "열어 두기", "Geöffnet lassen",
                "Garder ouvert", "Mantener abierto", "Оставить открытым", "Giữ mở"),
            ["重试保存"] = LocalizedUxPhrase(
                "Retry Save", "重試儲存", "保存を再試行", "저장 다시 시도", "Speichern wiederholen",
                "Réessayer d’enregistrer", "Reintentar guardado", "Повторить сохранение", "Thử lưu lại"),
            ["长图保存失败 · 成果仍保留"] = LocalizedUxPhrase(
                "Scrolling capture save failed · Result preserved", "長截圖儲存失敗 · 結果仍保留",
                "スクロールキャプチャの保存に失敗 · 結果は保持されています", "스크롤 캡처 저장 실패 · 결과 유지됨",
                "Scrollaufnahme konnte nicht gespeichert werden · Ergebnis bleibt erhalten",
                "Échec de l’enregistrement de la capture défilante · Résultat conservé",
                "Error al guardar la captura con desplazamiento · Resultado conservado",
                "Не удалось сохранить снимок с прокруткой · Результат сохранён",
                "Không thể lưu ảnh chụp cuộn · Kết quả vẫn được giữ"),
            ["可恢复"] = LocalizedUxPhrase(
                "Recoverable", "可復原", "復元可能", "복구 가능", "Wiederherstellbar",
                "Récupérable", "Recuperable", "Можно восстановить", "Có thể khôi phục"),
            ["保存失败，成果仍保留；可重试、另存或复制"] = LocalizedUxPhrase(
                "Save failed; the result is preserved. Retry, save elsewhere, or copy it.",
                "儲存失敗，結果仍保留；可重試、另存或複製。",
                "保存に失敗しました。結果は保持されています。再試行、別の場所への保存、またはコピーができます。",
                "저장에 실패했습니다. 결과는 유지됩니다. 다시 시도하거나 다른 위치에 저장하거나 복사할 수 있습니다.",
                "Speichern fehlgeschlagen. Das Ergebnis bleibt erhalten. Erneut versuchen, an einem anderen Ort speichern oder kopieren.",
                "Échec de l’enregistrement. Le résultat est conservé. Réessayez, enregistrez ailleurs ou copiez-le.",
                "No se pudo guardar. El resultado se conserva. Reintenta, guarda en otra ubicación o cópialo.",
                "Не удалось сохранить. Результат сохранён. Повторите попытку, выберите другую папку или скопируйте его.",
                "Lưu không thành công. Kết quả vẫn được giữ. Hãy thử lại, lưu ở nơi khác hoặc sao chép.")
        };
    private static readonly Lazy<IReadOnlyDictionary<string, IReadOnlyDictionary<char, IReadOnlyList<KeyValuePair<string, string>>>>> CompositeCatalog =
        new(BuildCompositeCatalog);
    private static readonly ConditionalWeakTable<DependencyObject, ElementLocalizationState> ElementStates = new();
    private static bool _wpfLocalizationEnabled;

    private sealed class ElementLocalizationState
    {
        public HashSet<DependencyProperty> ObservedProperties { get; } = [];
        public Dictionary<DependencyProperty, LocalizedPropertyState> Properties { get; } = [];
        public HashSet<DependencyProperty> ApplyingProperties { get; } = [];
        public bool ItemContainersObserved { get; set; }
    }

    private sealed class LocalizedPropertyState
    {
        public string Source { get; set; } = string.Empty;
        public string LastTranslated { get; set; } = string.Empty;
    }

    public static string Normalize(string? language)
    {
        if (string.Equals(language, "System", StringComparison.OrdinalIgnoreCase)) return "System";
        return SupportedLanguages.Any(option => option.Code.Equals(language, StringComparison.OrdinalIgnoreCase))
            ? SupportedLanguages.First(option => option.Code.Equals(language, StringComparison.OrdinalIgnoreCase)).Code
            : "System";
    }

    private static string Resolve(string? language)
    {
        var normalized = Normalize(language);
        if (!normalized.Equals("System", StringComparison.OrdinalIgnoreCase)) return normalized;
        var system = CultureInfo.CurrentUICulture;
        var exact = SupportedLanguages.FirstOrDefault(option => option.Code.Equals(system.Name, StringComparison.OrdinalIgnoreCase));
        if (exact is not null) return exact.Code;
        var prefix = system.TwoLetterISOLanguageName;
        if (prefix.Equals("zh", StringComparison.OrdinalIgnoreCase))
            return system.Name.Contains("TW", StringComparison.OrdinalIgnoreCase) || system.Name.Contains("Hant", StringComparison.OrdinalIgnoreCase)
                ? "zh-TW"
                : "zh-CN";
        return SupportedLanguages.FirstOrDefault(option => option.Code.StartsWith(prefix + "-", StringComparison.OrdinalIgnoreCase))?.Code
            ?? "en-US";
    }

    public static string Text(string? language, string key, string? fallback = null)
    {
        var normalized = Resolve(language);
        if (Catalog.TryGetValue(normalized, out var localized) && localized.TryGetValue(key, out var value))
            return value;
        if (Catalog["zh-CN"].TryGetValue(key, out var chinese))
            return normalized == "zh-CN" ? chinese : TranslatePhrase(chinese, normalized);
        return fallback ?? key;
    }

    public static void Apply(AppSettings settings)
    {
        settings.Language = Normalize(settings.Language);
        CurrentLanguage = Resolve(settings.Language);
    }

    public static string TranslatePhrase(string? value, string? language = null)
    {
        if (string.IsNullOrWhiteSpace(value)) return value ?? string.Empty;
        var normalized = Resolve(language ?? CurrentLanguage);
        if (normalized == "zh-CN") return value;
        if (WindowsUxPhraseOverrides.TryGetValue(value, out var uxPhrase) &&
            uxPhrase.TryGetValue(normalized, out var uxTranslation))
            return uxTranslation;
        if (normalized == "en-US" && value is ("选择语言" or "麦克风" or "媒体编码组件") &&
            WindowsEnglishFallback.Value.TryGetValue(value, out var windowsEnglish))
            return windowsEnglish;
        if (!PhraseCatalog.Value.TryGetValue(normalized, out var phrases)) return value;
        var composite = phrases.TryGetValue(value, out var translated)
            ? translated
            : CompositeCatalog.Value.TryGetValue(normalized, out var candidates)
                ? TranslateComposite(value, candidates)
                : value;
        if (!ContainsCjk(composite)) return composite;
        if (normalized == "zh-TW")
        {
            var traditional = ConvertToTraditionalChinese(composite);
            // Windows NLS performs character conversion (錄制). Apply the
            // Taiwanese recording term used by the macOS catalog (錄製).
            return traditional
                .Replace("錄制", "錄製", StringComparison.Ordinal)
                .Replace("錄屏", "螢幕錄製", StringComparison.Ordinal)
                .Replace("鼠標指針", "滑鼠游標", StringComparison.Ordinal)
                .Replace("鼠標", "滑鼠", StringComparison.Ordinal)
                .Replace("后", "後", StringComparison.Ordinal);
        }
        if (!WindowsEnglishFallback.Value.TryGetValue(value, out var english)) return composite;
        if (normalized == "en-US") return english;
        return phrases.TryGetValue(english, out var localizedEnglish) ? localizedEnglish : english;
    }

    private static IReadOnlyDictionary<string, string> LocalizedUxPhrase(
        string english,
        string traditionalChinese,
        string japanese,
        string korean,
        string german,
        string french,
        string spanish,
        string russian,
        string vietnamese) => new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["en-US"] = english,
        ["zh-TW"] = traditionalChinese,
        ["ja-JP"] = japanese,
        ["ko-KR"] = korean,
        ["de-DE"] = german,
        ["fr-FR"] = french,
        ["es-ES"] = spanish,
        ["ru-RU"] = russian,
        ["vi-VN"] = vietnamese
    };

    private static string ConvertToTraditionalChinese(string value)
    {
        const uint traditionalChinese = 0x04000000;
        var required = NativeMethods.LCMapStringEx(
            "zh-TW", traditionalChinese, value, -1, null, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (required <= 1) return value;
        var buffer = new StringBuilder(required);
        var written = NativeMethods.LCMapStringEx(
            "zh-TW", traditionalChinese, value, -1, buffer, buffer.Capacity,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        return written > 1 ? buffer.ToString() : value;
    }

    public static void EnableAutomaticWpfLocalization()
    {
        if (_wpfLocalizationEnabled) return;
        _wpfLocalizationEnabled = true;
        EventManager.RegisterClassHandler(typeof(FrameworkElement), FrameworkElement.LoadedEvent,
            new RoutedEventHandler((sender, _) =>
            {
                if (sender is Window window) LocalizeWindow(window);
                else if (sender is DependencyObject element) LocalizeElementProperties(element);
            }), handledEventsToo: true);
    }

    public static void LocalizeWindow(Window window)
    {
        ObserveAndLocalize(window, Window.TitleProperty);
        var visited = new HashSet<DependencyObject>();
        LocalizeElement(window, visited);
    }

    private static void LocalizeElement(DependencyObject element, HashSet<DependencyObject> visited)
    {
        if (!visited.Add(element)) return;
        LocalizeElementProperties(element);

        foreach (var child in LogicalTreeHelper.GetChildren(element).OfType<DependencyObject>())
            LocalizeElement(child, visited);
        if (element is not System.Windows.Media.Visual && element is not System.Windows.Media.Media3D.Visual3D) return;
        for (var index = 0; index < System.Windows.Media.VisualTreeHelper.GetChildrenCount(element); index++)
            LocalizeElement(System.Windows.Media.VisualTreeHelper.GetChild(element, index), visited);
    }

    private static void LocalizeElementProperties(DependencyObject element)
    {
        if (element is Window) ObserveAndLocalize(element, Window.TitleProperty);
        if (element is TextBlock) ObserveAndLocalize(element, TextBlock.TextProperty);
        if (element is ContentControl) ObserveAndLocalize(element, ContentControl.ContentProperty);
        if (element is HeaderedContentControl) ObserveAndLocalize(element, HeaderedContentControl.HeaderProperty);
        if (element is HeaderedItemsControl) ObserveAndLocalize(element, HeaderedItemsControl.HeaderProperty);
        if (element is ItemsControl itemsControl) ObserveItemContainers(itemsControl);
        if (element is FrameworkElement)
        {
            ObserveAndLocalize(element, FrameworkElement.ToolTipProperty);
            ObserveAndLocalize(element, System.Windows.Automation.AutomationProperties.NameProperty);
            ObserveAndLocalize(element, System.Windows.Automation.AutomationProperties.HelpTextProperty);
        }
    }

    private static void ObserveItemContainers(ItemsControl itemsControl)
    {
        var state = ElementStates.GetOrCreateValue(itemsControl);
        if (!state.ItemContainersObserved)
        {
            state.ItemContainersObserved = true;
            itemsControl.ItemContainerGenerator.StatusChanged += (_, _) => ScheduleItemContainerLocalization(itemsControl);
        }
        ScheduleItemContainerLocalization(itemsControl);
    }

    private static void ScheduleItemContainerLocalization(ItemsControl itemsControl)
    {
        _ = itemsControl.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () =>
        {
            if (!itemsControl.IsLoaded) return;
            var visited = new HashSet<DependencyObject>();
            for (var index = 0; index < itemsControl.Items.Count; index++)
            {
                if (itemsControl.ItemContainerGenerator.ContainerFromIndex(index) is DependencyObject container)
                    LocalizeElement(container, visited);
            }
        });
    }

    private static void ObserveAndLocalize(DependencyObject element, DependencyProperty property)
    {
        var state = ElementStates.GetOrCreateValue(element);
        if (state.ObservedProperties.Add(property))
        {
            var descriptor = DependencyPropertyDescriptor.FromProperty(property, element.GetType());
            descriptor?.AddValueChanged(element, (_, _) => LocalizeProperty(element, property));
        }
        LocalizeProperty(element, property);
    }

    private static void LocalizeProperty(DependencyObject element, DependencyProperty property)
    {
        var state = ElementStates.GetOrCreateValue(element);
        if (state.ApplyingProperties.Contains(property) || element.GetValue(property) is not string current) return;
        if (!state.Properties.TryGetValue(property, out var propertyState))
        {
            propertyState = new LocalizedPropertyState { Source = current };
            state.Properties[property] = propertyState;
        }
        else if (!string.Equals(current, propertyState.LastTranslated, StringComparison.Ordinal))
        {
            // A binding or code-behind supplied a new source value after the element loaded.
            propertyState.Source = current;
        }

        var translated = TranslatePhrase(propertyState.Source);
        if (element is Window && property == Window.TitleProperty)
            translated = AppBuildIdentity.Current.FormatWindowTitle(translated);
        propertyState.LastTranslated = translated;
        if (string.Equals(current, translated, StringComparison.Ordinal)) return;
        state.ApplyingProperties.Add(property);
        try { element.SetCurrentValue(property, translated); }
        finally { state.ApplyingProperties.Remove(property); }
    }

    private static IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> BuildPhraseCatalog()
    {
        var result = SupportedLanguages.ToDictionary(
            language => language.Code,
            _ => new Dictionary<string, string>(StringComparer.Ordinal),
            StringComparer.OrdinalIgnoreCase);
        var assembly = Assembly.GetExecutingAssembly();
        foreach (var resourceName in assembly.GetManifestResourceNames().Where(name => name.EndsWith(".xcstrings", StringComparison.OrdinalIgnoreCase)))
        {
            using var stream = assembly.GetManifestResourceStream(resourceName);
            if (stream is null) continue;
            using var document = JsonDocument.Parse(stream);
            if (!document.RootElement.TryGetProperty("strings", out var strings)) continue;
            foreach (var entry in strings.EnumerateObject())
            {
                if (!entry.Value.TryGetProperty("localizations", out var localizations) ||
                    !TryReadLocalization(localizations, "zh-Hans", out _)) continue;
                var localizedValues = AppleLocaleByWindowsCode.Values
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .Select(locale => TryReadLocalization(localizations, locale, out var localized) ? localized : null)
                    .Where(localized => !string.IsNullOrWhiteSpace(localized))
                    .Cast<string>()
                    .Distinct(StringComparer.Ordinal)
                    .ToArray();
                foreach (var (windowsCode, appleCode) in AppleLocaleByWindowsCode)
                {
                    if (TryReadLocalization(localizations, appleCode, out var translated))
                    {
                        foreach (var sourceValue in localizedValues) result[windowsCode][sourceValue] = translated;
                    }
                }
            }
        }
        return result.ToDictionary(pair => pair.Key, pair => (IReadOnlyDictionary<string, string>)pair.Value, StringComparer.OrdinalIgnoreCase);
    }

    private static IReadOnlyDictionary<string, string> BuildWindowsEnglishFallback()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames()
            .FirstOrDefault(name => name.EndsWith("WindowsLocalization.en.json", StringComparison.OrdinalIgnoreCase));
        if (resourceName is null) return new Dictionary<string, string>(StringComparer.Ordinal);
        using var stream = assembly.GetManifestResourceStream(resourceName);
        if (stream is null) return new Dictionary<string, string>(StringComparer.Ordinal);
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ??
               new Dictionary<string, string>(StringComparer.Ordinal);
    }

    private static bool ContainsCjk(string value) => value.Any(character => character is >= '\u3400' and <= '\u9fff');

    private static bool TryReadLocalization(JsonElement localizations, string locale, out string value)
    {
        value = string.Empty;
        return localizations.TryGetProperty(locale, out var localization) &&
               localization.TryGetProperty("stringUnit", out var stringUnit) &&
               stringUnit.TryGetProperty("value", out var text) &&
               !string.IsNullOrWhiteSpace(value = text.GetString() ?? string.Empty);
    }

    private static IReadOnlyDictionary<string, IReadOnlyDictionary<char, IReadOnlyList<KeyValuePair<string, string>>>> BuildCompositeCatalog() =>
        PhraseCatalog.Value.ToDictionary(
            locale => locale.Key,
            locale =>
            {
                var values = locale.Value.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
                if (locale.Key is not ("zh-CN" or "zh-TW"))
                {
                    foreach (var (source, english) in WindowsEnglishFallback.Value)
                    {
                        values[source] = locale.Key == "en-US"
                            ? english
                            : locale.Value.TryGetValue(english, out var localizedEnglish) ? localizedEnglish : english;
                    }
                }
                return (IReadOnlyDictionary<char, IReadOnlyList<KeyValuePair<string, string>>>)values
                    .Where(pair => pair.Key.Length >= 2 && pair.Key.Any(character => character is >= '\u3400' and <= '\u9fff'))
                    .GroupBy(pair => pair.Key[0])
                    .ToDictionary(
                        group => group.Key,
                        group => (IReadOnlyList<KeyValuePair<string, string>>)group.OrderByDescending(pair => pair.Key.Length).ToArray());
            },
            StringComparer.OrdinalIgnoreCase);

    private static string TranslateComposite(
        string value,
        IReadOnlyDictionary<char, IReadOnlyList<KeyValuePair<string, string>>> candidatesByFirstCharacter)
    {
        static bool IsAsciiWord(char character) => character <= 127 && char.IsLetterOrDigit(character);
        var result = new System.Text.StringBuilder(value.Length * 2);
        var translatedAny = false;
        for (var index = 0; index < value.Length;)
        {
            if (!candidatesByFirstCharacter.TryGetValue(value[index], out var candidates))
            {
                result.Append(value[index++]);
                continue;
            }
            var match = candidates.FirstOrDefault(candidate =>
                index + candidate.Key.Length <= value.Length &&
                value.AsSpan(index, candidate.Key.Length).SequenceEqual(candidate.Key.AsSpan()));
            if (string.IsNullOrEmpty(match.Key))
            {
                result.Append(value[index++]);
                continue;
            }
            if (result.Length > 0 && IsAsciiWord(result[^1]) && match.Value.Length > 0 && IsAsciiWord(match.Value[0]))
                result.Append(' ');
            result.Append(match.Value);
            index += match.Key.Length;
            translatedAny = true;
        }
        return translatedAny ? result.ToString() : value;
    }
}
