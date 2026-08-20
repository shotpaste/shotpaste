using System.Windows;
using WpfBrush = System.Windows.Media.Brush;

namespace ShotPaste.Windows.Services;

internal static class AccessibilityPreferences
{
    private static readonly string[] OverrideKeys =
    [
        "WindowBrush", "HistoryHudBrush", "SurfaceBrush", "SurfaceSecondaryBrush",
        "ControlBackgroundBrush", "ControlBackgroundHoverBrush", "ControlBackgroundPressedBrush",
        "PopupBackgroundBrush", "WindowBackdropBrush", "TitleBarBrush", "ToastBackgroundBrush",
        "TextBrush", "SecondaryTextBrush", "HudTextBrush", "HudSecondaryTextBrush",
        "BorderBrush", "ControlBorderBrush", "ControlBorderHoverBrush", "PopupBorderBrush",
        "HudBrush", "HudBorderBrush", "AccentBrush", "AccentSoftBrush",
        "FocusRingBrush", "AccentForegroundBrush"
    ];

    public static bool ReduceMotion => !SystemParameters.ClientAreaAnimation;
    public static bool HighContrast => SystemParameters.HighContrast;

    public static void ApplyHighContrastResources(ResourceDictionary resources)
    {
        foreach (var key in OverrideKeys) resources.Remove(key);
        if (!HighContrast) return;

        Set(resources, System.Windows.SystemColors.WindowBrush,
            "WindowBrush", "HistoryHudBrush", "SurfaceBrush", "SurfaceSecondaryBrush",
            "ControlBackgroundBrush", "ControlBackgroundHoverBrush", "ControlBackgroundPressedBrush",
            "PopupBackgroundBrush", "WindowBackdropBrush", "TitleBarBrush", "ToastBackgroundBrush", "HudBrush");
        Set(resources, System.Windows.SystemColors.WindowTextBrush,
            "TextBrush", "SecondaryTextBrush", "HudTextBrush", "HudSecondaryTextBrush");
        Set(resources, System.Windows.SystemColors.ActiveBorderBrush,
            "BorderBrush", "ControlBorderBrush", "ControlBorderHoverBrush", "PopupBorderBrush", "HudBorderBrush");
        Set(resources, System.Windows.SystemColors.HighlightBrush, "AccentBrush", "AccentSoftBrush", "FocusRingBrush");
        Set(resources, System.Windows.SystemColors.HighlightTextBrush, "AccentForegroundBrush");
    }

    private static void Set(ResourceDictionary resources, WpfBrush brush, params string[] keys)
    {
        foreach (var key in keys) resources[key] = brush;
    }
}
