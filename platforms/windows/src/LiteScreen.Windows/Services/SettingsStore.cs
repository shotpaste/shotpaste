using System.Text.Json;
using System.Text;
using LiteScreen.Windows.Models;

namespace LiteScreen.Windows.Services;

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private static readonly UTF8Encoding Utf8WithoutBom = new(false);
    private readonly string _settingsFile;

    public AppSettings Current { get; private set; } = new();
    public string? LastConfigurationWarning { get; private set; }

    public SettingsStore() : this(AppPaths.SettingsFile) { }

    internal SettingsStore(string settingsFile)
    {
        _settingsFile = Path.GetFullPath(settingsFile);
    }

    internal SettingsStore(AppSettings settings) : this(AppPaths.SettingsFile)
    {
        Normalize(settings);
        Current = settings;
    }

    public void Load()
    {
        AppPaths.EnsureCreated();
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsFile)!);
        Current = LoadJsonWithRecovery();
        Normalize(Current);
        Directory.CreateDirectory(Current.SaveDirectory);
    }

    public void Save()
    {
        AppPaths.EnsureCreated();
        Normalize(Current);
        Directory.CreateDirectory(Current.SaveDirectory);
        WriteJsonAtomic();
    }

    public void Replace(AppSettings settings)
    {
        Normalize(settings);
        Current = settings;
        Save();
    }

    private AppSettings LoadJsonWithRecovery()
    {
        if (!File.Exists(_settingsFile)) return new AppSettings();
        try { return DeserializeSettings(File.ReadAllText(_settingsFile, Encoding.UTF8)); }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
        {
            var backup = _settingsFile + ".bak";
            if (File.Exists(backup))
            {
                try
                {
                    var recovered = DeserializeSettings(File.ReadAllText(backup, Encoding.UTF8));
                    File.Copy(backup, _settingsFile, true);
                    LastConfigurationWarning = "settings.json 已损坏，已从备份恢复。";
                    return recovered;
                }
                catch (Exception backupException) when (backupException is JsonException or IOException or UnauthorizedAccessException) { }
            }
            LastConfigurationWarning = "settings.json 已损坏，已使用安全默认值并保留原文件。";
            var corrupt = _settingsFile + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff");
            try { File.Move(_settingsFile, corrupt, false); } catch (IOException) { }
            return new AppSettings();
        }
    }

    private static AppSettings DeserializeSettings(string json)
    {
        return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
    }

    private void WriteJsonAtomic()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsFile)!);
        var temp = _settingsFile + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                var bytes = Utf8WithoutBom.GetBytes(JsonSerializer.Serialize(Current, JsonOptions));
                stream.Write(bytes);
                stream.Flush(true);
            }
            if (File.Exists(_settingsFile))
            {
                try
                {
                    _ = DeserializeSettings(File.ReadAllText(_settingsFile, Encoding.UTF8));
                    File.Copy(_settingsFile, _settingsFile + ".bak", true);
                }
                catch (Exception exception) when (exception is JsonException or IOException) { }
            }
            File.Move(temp, _settingsFile, true);
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch (IOException) { }
        }
    }

    internal static void Normalize(AppSettings settings)
    {
        settings.SchemaVersion = AppSettings.CurrentSchemaVersion;
        settings.Language = LocalizationService.Normalize(settings.Language);
        settings.DiagnosticsRetentionDays = Math.Clamp(settings.DiagnosticsRetentionDays, 1, 30);
        settings.ScreenshotScale = settings.ScreenshotScale is 1 or 2 ? settings.ScreenshotScale : 0;
        settings.ScreenshotColorSpace = settings.ScreenshotColorSpace is "Auto" or "Srgb" or "DisplayP3" ? settings.ScreenshotColorSpace : "Auto";
        settings.OcrRecognitionLanguage = string.Equals(settings.OcrRecognitionLanguage, "Auto", StringComparison.OrdinalIgnoreCase) ||
                                          LocalizationService.SupportedLanguages.Any(option => option.Code.Equals(settings.OcrRecognitionLanguage, StringComparison.OrdinalIgnoreCase))
            ? settings.OcrRecognitionLanguage
            : "Auto";
        settings.JpegQuality = Math.Clamp(settings.JpegQuality, 1, 100);
        settings.HistoryPanelPosition = settings.HistoryPanelPosition is "TopCenter" or "TopLeft" or "TopRight" or "BottomLeft" or "BottomRight"
            ? settings.HistoryPanelPosition
            : "TopCenter";
        settings.HistoryPanelScale = Math.Clamp(settings.HistoryPanelScale, 0.75d, 1.5d);
        settings.HistoryCompactWidth = Math.Clamp(settings.HistoryCompactWidth, 560d, 1600d);
        settings.HistoryCompactHeight = Math.Clamp(settings.HistoryCompactHeight, 200d, 720d);
        settings.HistoryExpandedWidth = Math.Clamp(settings.HistoryExpandedWidth, 860d, 2400d);
        settings.HistoryExpandedHeight = Math.Clamp(settings.HistoryExpandedHeight, 520d, 1600d);
        settings.HistoryExpandedLeft = NormalizeWindowCoordinate(settings.HistoryExpandedLeft);
        settings.HistoryExpandedTop = NormalizeWindowCoordinate(settings.HistoryExpandedTop);
        settings.HistoryPanelMaxItems = Math.Clamp(settings.HistoryPanelMaxItems, 3, 50);
        settings.HistoryBackgroundStyle = settings.HistoryBackgroundStyle is "Hud" or "Solid"
            ? settings.HistoryBackgroundStyle
            : "Hud";
        settings.QuickAccessScale = Math.Clamp(settings.QuickAccessScale, 0.75, 1.5);
        settings.QuickAccessAutoDismissSeconds = Math.Clamp(settings.QuickAccessAutoDismissSeconds, 3, 30);
        settings.QuickAccessPosition = settings.QuickAccessPosition switch
        {
            "TopLeft" or "BottomLeft" => "BottomLeft",
            "TopRight" or "BottomRight" => "BottomRight",
            _ => "BottomRight"
        };
        settings.QuickAccessAnimationStyle = settings.QuickAccessAnimationStyle is "Slide" or "Scale"
            ? settings.QuickAccessAnimationStyle
            : "Slide";
        settings.QuickAccessTrackpadSwipeMode = settings.QuickAccessTrackpadSwipeMode is "Natural" or "Inverted"
            ? settings.QuickAccessTrackpadSwipeMode
            : "Inverted";
        settings.DefaultHistoryFilter = settings.DefaultHistoryFilter is "Screenshot" or "ScrollingScreenshot" or "Recording" or "Clipboard"
            ? settings.DefaultHistoryFilter
            : "Screenshot";
        settings.QuickAccessSwipeSensitivity = Math.Clamp(settings.QuickAccessSwipeSensitivity, 0.5, 3);
        settings.RecordingSystemAudioVolume = Math.Clamp(settings.RecordingSystemAudioVolume, 0d, 1d);
        settings.RecordingMicrophoneVolume = Math.Clamp(settings.RecordingMicrophoneVolume, 0d, 1d);
        settings.RecordingFps = Math.Clamp(settings.RecordingFps, 1, 240);
        settings.RecordingGifFps = Math.Clamp(settings.RecordingGifFps, 5, 30);
        settings.RecordingVideoFormat = settings.RecordingVideoFormat.Equals("Mov", StringComparison.OrdinalIgnoreCase) ? "Mov" : "Mp4";
        settings.RecordingVideoCodec = settings.RecordingVideoCodec.Equals("Hevc", StringComparison.OrdinalIgnoreCase) ? "Hevc" : "H264";
        settings.RecordingAnnotationWidth = Math.Clamp(settings.RecordingAnnotationWidth, 1, 20);
        settings.RecordingAnnotationClearSeconds = Math.Clamp(settings.RecordingAnnotationClearSeconds, 1, 3600);
        settings.RecordingAnnotationMaxCount = Math.Clamp(settings.RecordingAnnotationMaxCount, 1, 200);
        settings.RecordingAnnotationClearMode = settings.RecordingAnnotationClearMode is "Manual" or "AfterSeconds" or "MaximumCount"
            ? settings.RecordingAnnotationClearMode
            : "Manual";
        settings.RecordingClickRadius = Math.Clamp(settings.RecordingClickRadius, 6, 96);
        settings.RecordingClickOpacity = Math.Clamp(settings.RecordingClickOpacity, 0.1, 1);
        settings.RecordingClickDurationMs = Math.Clamp(settings.RecordingClickDurationMs, 100, 3000);
        settings.RecordingClickRippleCount = Math.Clamp(settings.RecordingClickRippleCount, 1, 5);
        settings.RecordingClickLeftColor = NormalizeColor(settings.RecordingClickLeftColor, "#FF7C3AED");
        settings.RecordingClickRightColor = NormalizeColor(settings.RecordingClickRightColor, "#FFFF9F0A");
        settings.RecordingKeystrokeFontSize = Math.Clamp(settings.RecordingKeystrokeFontSize, 10, 72);
        settings.RecordingKeystrokeDurationMs = Math.Clamp(settings.RecordingKeystrokeDurationMs, 250, 10000);
        settings.RecordingKeystrokePosition = settings.RecordingKeystrokePosition is "TopLeft" or "TopCenter" or "TopRight" or "BottomLeft" or "BottomCenter" or "BottomRight"
            ? settings.RecordingKeystrokePosition : "BottomCenter";
        settings.RecordingKeystrokeVisibility = settings.RecordingKeystrokeVisibility switch
        {
            "All" or "ShortcutsOnly" or "SpecialOnly" or "SpecialAndShortcuts" => settings.RecordingKeystrokeVisibility,
            "AllKeys" => "All",
            _ => "SpecialAndShortcuts"
        };
        settings.RecordingAnnotationFadeMilliseconds = Math.Clamp(settings.RecordingAnnotationFadeMilliseconds, 0, 5000);
        settings.RecordingAnnotationToolPolicies ??= [];
        foreach (var tool in Enum.GetNames<RecordingAnnotationTool>())
        {
            if (!settings.RecordingAnnotationToolPolicies.TryGetValue(tool, out var policy))
            {
                settings.RecordingAnnotationToolPolicies[tool] = new RecordingAnnotationPolicySettings
                {
                    ClearMode = settings.RecordingAnnotationClearMode,
                    ClearSeconds = settings.RecordingAnnotationClearSeconds,
                    MaximumCount = settings.RecordingAnnotationMaxCount
                };
                continue;
            }
            policy.ClearMode = policy.ClearMode is "Manual" or "AfterSeconds" or "MaximumCount" ? policy.ClearMode : "Manual";
            policy.ClearSeconds = Math.Clamp(policy.ClearSeconds, 1, 3600);
            policy.MaximumCount = Math.Clamp(policy.MaximumCount, 1, 200);
        }
        settings.ScrollingAutoScrollIntervalMs = Math.Clamp(settings.ScrollingAutoScrollIntervalMs, 40, 500);
        settings.ScrollingMaxHeight = Math.Clamp(settings.ScrollingMaxHeight, 1024, 100000);
        settings.ScrollingPreviewMaxHeight = Math.Clamp(settings.ScrollingPreviewMaxHeight, 120, 1200);
        settings.QuickAccessActions ??= ["Copy", "SaveOrOpen", "Close", "Delete", "Pin", "None"];
        var supportedQuickAccessActions = new HashSet<string>(
            ["Copy", "SaveOrOpen", "Pin", "Delete", "Close", "None"],
            StringComparer.OrdinalIgnoreCase);
        var seenActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        settings.QuickAccessActions = settings.QuickAccessActions
            .Where(action => !string.IsNullOrWhiteSpace(action) && supportedQuickAccessActions.Contains(action))
            .Where(action => action.Equals("None", StringComparison.OrdinalIgnoreCase) || seenActions.Add(action))
            .Take(6)
            .Concat(Enumerable.Repeat("None", 6))
            .Take(6)
            .ToList();
        settings.QuickAccessSwipeLeftAction = NormalizeSwipeAction(settings.QuickAccessSwipeLeftAction, "Close", supportedQuickAccessActions);
        settings.QuickAccessSwipeRightAction = NormalizeSwipeAction(settings.QuickAccessSwipeRightAction, "Close", supportedQuickAccessActions);
    }

    private static string NormalizeSwipeAction(string? value, string fallback, HashSet<string> supported) =>
        !string.IsNullOrWhiteSpace(value) && supported.Contains(value) ? value : fallback;

    private static double? NormalizeWindowCoordinate(double? value) =>
        value is { } coordinate && double.IsFinite(coordinate)
            ? Math.Clamp(coordinate, -100_000d, 100_000d)
            : null;

    private static string NormalizeColor(string? color, string fallback)
    {
        if (string.IsNullOrWhiteSpace(color) ||
            !System.Text.RegularExpressions.Regex.IsMatch(color, "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"))
            return fallback;
        return color.Length == 7 ? "#FF" + color[1..].ToUpperInvariant() : color.ToUpperInvariant();
    }
}
