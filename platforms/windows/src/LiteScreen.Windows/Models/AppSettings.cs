using System.Text.Json.Serialization;

namespace LiteScreen.Windows.Models;

public sealed class AppSettings
{
    public const int CurrentSchemaVersion = 11;
    public int SchemaVersion { get; set; } = CurrentSchemaVersion;
    public string Language { get; set; } = "System";
    public bool PlaySounds { get; set; } = true;
    public string SaveDirectory { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "LiteScreen");
    public bool CopyAfterCapture { get; set; } = true;
    public bool ShowQuickAccess { get; set; } = true;
    public bool CopyScreenshots { get; set; } = true;
    public bool ShowCursorInScreenshots { get; set; }
    public bool HideDesktopIconsInScreenshots { get; set; }
    public bool HideDesktopWidgetsInScreenshots { get; set; }
    public bool ExcludeOwnApplicationFromScreenshots { get; set; } = true;
    public int ScreenshotScale { get; set; }
    public string ScreenshotColorSpace { get; set; } = "Auto";
    public bool ShowCaptureNotifications { get; set; } = true;
    public bool ShowOcrSuccessNotifications { get; set; }
    public bool ShowOcrLinkNotifications { get; set; } = true;
    public string OcrRecognitionLanguage { get; set; } = "Auto";
    public bool CopyRecordings { get; set; } = true;
    public bool ShowQuickAccessForScreenshots { get; set; } = true;
    public bool ShowQuickAccessForRecordings { get; set; } = true;
    public bool SaveScreenshots { get; set; } = true;
    public bool SaveRecordings { get; set; } = true;
    public bool IncludeCursorInRecording { get; set; } = true;
    public bool HighlightMouseClicks { get; set; }
    public bool ShowKeystrokes { get; set; }
    public bool IncludeLiteScreenInRecording { get; set; }
    public double RecordingClickRadius { get; set; } = 24d;
    public string RecordingClickLeftColor { get; set; } = "#FF7C3AED";
    public string RecordingClickRightColor { get; set; } = "#FFFF9F0A";
    public double RecordingClickOpacity { get; set; } = 0.72d;
    public int RecordingClickDurationMs { get; set; } = 420;
    public int RecordingClickRippleCount { get; set; } = 2;
    public string RecordingKeystrokePosition { get; set; } = "BottomCenter";
    public double RecordingKeystrokeFontSize { get; set; } = 18d;
    public int RecordingKeystrokeDurationMs { get; set; } = 1250;
    public string RecordingKeystrokeVisibility { get; set; } = "SpecialAndShortcuts";
    public string RecordingAnnotationColor { get; set; } = "#FF7C3AED";
    public double RecordingAnnotationWidth { get; set; } = 4;
    public string RecordingAnnotationClearMode { get; set; } = "Manual";
    public int RecordingAnnotationClearSeconds { get; set; } = 5;
    public int RecordingAnnotationMaxCount { get; set; } = 12;
    public Dictionary<string, RecordingAnnotationPolicySettings> RecordingAnnotationToolPolicies { get; set; } = [];
    public bool RecordingAnnotationFadeEnabled { get; set; } = true;
    public int RecordingAnnotationFadeMilliseconds { get; set; } = 350;
    public bool DimNonSelectedRecordingArea { get; set; } = true;
    public bool RecordSystemAudio { get; set; } = true;
    public bool RecordMicrophone { get; set; }
    public string RecordingMicrophoneDeviceId { get; set; } = string.Empty;
    public string RecordingMicrophoneDeviceName { get; set; } = string.Empty;
    public double RecordingSystemAudioVolume { get; set; } = 0.8d;
    public double RecordingMicrophoneVolume { get; set; } = 0.8d;
    public RecordingQuality RecordingQualityPreset { get; set; } = RecordingQuality.High;
    public RecordingOutputMode RecordingOutputMode { get; set; } = RecordingOutputMode.Video;
    public string RecordingVideoFormat { get; set; } = "Mp4";
    public string RecordingVideoCodec { get; set; } = "H264";
    public bool ClipboardHistoryEnabled { get; set; } = true;
    public bool LaunchAtStartup { get; set; }
    public bool UrlSchemeEnabled { get; set; } = true;
    public bool ShowTrayIcon { get; set; } = true;
    public bool ShowRecordingDurationInTray { get; set; } = true;
    public bool ShowRecordingToolbar { get; set; } = true;
    public int RecordingFps { get; set; } = 30;
    public int RecordingGifFps { get; set; } = 15;
    public int HistoryRetentionDays { get; set; }
    public int HistoryMaxCount { get; set; }
    public string DefaultHistoryFilter { get; set; } = "Screenshot";
    public string Theme { get; set; } = "System";
    public string ScreenshotFormat { get; set; } = "Png";
    public int JpegQuality { get; set; } = 90;
    public int QuickAccessAutoDismissSeconds { get; set; } = 10;
    public bool QuickAccessAutoDismissEnabled { get; set; } = true;
    public bool QuickAccessHideCardWhenWindowOpen { get; set; } = true;
    public string QuickAccessPosition { get; set; } = "BottomRight";
    public bool PauseQuickAccessOnHover { get; set; } = true;
    public double QuickAccessScale { get; set; } = 1d;
    public bool QuickAccessEnableDrag { get; set; } = true;
    public string QuickAccessAnimationStyle { get; set; } = "Slide";
    public bool QuickAccessTwoFingerSwipeEnabled { get; set; } = true;
    public double QuickAccessSwipeSensitivity { get; set; } = 1d;
    public string QuickAccessTrackpadSwipeMode { get; set; } = "Inverted";
    public string QuickAccessSwipeLeftAction { get; set; } = "Close";
    public string QuickAccessSwipeRightAction { get; set; } = "Close";
    public List<string> QuickAccessActions { get; set; } = ["Copy", "SaveOrOpen", "Close", "Delete", "Pin", "None"];
    [JsonIgnore]
    public string QuickAccessActionsText
    {
        get => string.Join(", ", QuickAccessActions ?? []);
        set => QuickAccessActions = (value ?? string.Empty)
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(6)
            .Concat(Enumerable.Repeat("None", 6))
            .Take(6)
            .ToList();
    }
    [JsonIgnore] public string QuickAccessAction1 { get => GetQuickAccessSlot(0); set => SetQuickAccessSlot(0, value); }
    [JsonIgnore] public string QuickAccessAction2 { get => GetQuickAccessSlot(1); set => SetQuickAccessSlot(1, value); }
    [JsonIgnore] public string QuickAccessAction3 { get => GetQuickAccessSlot(2); set => SetQuickAccessSlot(2, value); }
    [JsonIgnore] public string QuickAccessAction4 { get => GetQuickAccessSlot(3); set => SetQuickAccessSlot(3, value); }
    [JsonIgnore] public string QuickAccessAction5 { get => GetQuickAccessSlot(4); set => SetQuickAccessSlot(4, value); }
    [JsonIgnore] public string QuickAccessAction6 { get => GetQuickAccessSlot(5); set => SetQuickAccessSlot(5, value); }
    public string ScreenshotNameTemplate { get; set; } = "LiteScreen_{datetime}_{ms}";
    public string RecordingNameTemplate { get; set; } = "LiteScreen_Recording_{datetime}";
    public bool ShortcutsEnabled { get; set; } = true;
    public string OneShotHotkey { get; set; } = "Ctrl+Shift+1";
    public string HistoryHotkey { get; set; } = "Ctrl+Shift+H";
    public string HistoryModeHotkey { get; set; } = "Ctrl+Shift+J";
    public string RecordingPauseHotkey { get; set; } = "Ctrl+Shift+P";
    public string RecordingAnnotationHotkey { get; set; } = "Ctrl+Shift+D";
    public string RecordingRestartHotkey { get; set; } = "Ctrl+Shift+R";
    public string RecordingDeleteHotkey { get; set; } = "Ctrl+Shift+Backspace";
    public string HistoryPanelPosition { get; set; } = "TopCenter";
    public double HistoryPanelScale { get; set; } = 1d;
    public double HistoryCompactWidth { get; set; } = 860d;
    public double HistoryCompactHeight { get; set; } = 230d;
    public double HistoryExpandedWidth { get; set; } = 980d;
    public double HistoryExpandedHeight { get; set; } = 680d;
    public double? HistoryExpandedLeft { get; set; }
    public double? HistoryExpandedTop { get; set; }
    public int HistoryPanelMaxItems { get; set; } = 10;
    public string HistoryBackgroundStyle { get; set; } = "Hud";

    public bool ScrollingAutoScrollEnabled { get; set; } = true;
    public bool ScrollingShowHints { get; set; } = true;
    public int ScrollingAutoScrollIntervalMs { get; set; } = 40;
    public int ScrollingMaxHeight { get; set; } = 32768;
    public bool ScrollingDetectFixedBars { get; set; } = true;
    public bool ScrollingSafetyGuardEnabled { get; set; } = true;
    public int ScrollingPreviewMaxHeight { get; set; } = 420;

    public bool DiagnosticsEnabled { get; set; } = true;
    public int DiagnosticsRetentionDays { get; set; } = 3;

    private string GetQuickAccessSlot(int index)
    {
        EnsureQuickAccessSlots();
        return QuickAccessActions[index];
    }

    private void SetQuickAccessSlot(int index, string? value)
    {
        EnsureQuickAccessSlots();
        var normalized = string.IsNullOrWhiteSpace(value) ? "None" : value;
        if (!normalized.Equals("None", StringComparison.OrdinalIgnoreCase))
        {
            for (var slot = 0; slot < QuickAccessActions.Count; slot++)
            {
                if (slot != index && QuickAccessActions[slot].Equals(normalized, StringComparison.OrdinalIgnoreCase))
                    QuickAccessActions[slot] = "None";
            }
        }
        QuickAccessActions[index] = normalized;
    }

    private void EnsureQuickAccessSlots()
    {
        QuickAccessActions ??= [];
        while (QuickAccessActions.Count < 6) QuickAccessActions.Add("None");
        if (QuickAccessActions.Count > 6) QuickAccessActions = QuickAccessActions.Take(6).ToList();
    }
}

public sealed class RecordingAnnotationPolicySettings
{
    public string ClearMode { get; set; } = "Manual";
    public int ClearSeconds { get; set; } = 5;
    public int MaximumCount { get; set; } = 12;
}

public sealed record ScreenCaptureOptions(
    bool IncludeCursor = false,
    bool HideDesktopIcons = false,
    bool HideDesktopWidgets = false,
    bool ExcludeOwnApplication = true);
