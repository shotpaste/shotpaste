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
        "HudBrush", "HudBorderBrush", "HudInputBrush", "HudOverlayBrush", "HudBadgeBrush",
        "HudPreviewBrush", "HudDividerBrush", "HudSwatchBorderBrush",
        "HudHoverBrush", "HudPressedBrush", "HudSelectedBrush", "HudSelectedTextBrush",
        "Pinned.BackgroundBrush", "Pinned.BorderBrush",
        "Pinned.ToolbarBackgroundBrush", "Pinned.ToolbarBorderBrush",
        "AccentBrush", "AccentFillBrush", "AccentPressedBrush", "AccentSoftBrush", "AccentSoftForegroundBrush",
        "FocusRingBrush", "AccentForegroundBrush",
        "HoverBackgroundBrush", "PressedBackgroundBrush", "CardHoverBrush", "CardHoverBorderBrush"
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
            "PopupBackgroundBrush", "WindowBackdropBrush", "TitleBarBrush", "ToastBackgroundBrush", "HudBrush", "HudInputBrush", "HudOverlayBrush", "HudBadgeBrush",
            "HudPreviewBrush", "HudHoverBrush", "HudPressedBrush",
            "Pinned.BackgroundBrush", "Pinned.ToolbarBackgroundBrush", "CardHoverBrush");
        Set(resources, System.Windows.SystemColors.WindowTextBrush,
            "TextBrush", "SecondaryTextBrush", "HudTextBrush", "HudSecondaryTextBrush");
        Set(resources, System.Windows.SystemColors.ActiveBorderBrush,
            "BorderBrush", "ControlBorderBrush", "ControlBorderHoverBrush", "PopupBorderBrush", "HudBorderBrush", "HudDividerBrush", "HudSwatchBorderBrush",
            "Pinned.BorderBrush", "Pinned.ToolbarBorderBrush", "CardHoverBorderBrush");
        Set(resources, System.Windows.SystemColors.HighlightBrush,
            "AccentBrush", "AccentFillBrush", "AccentPressedBrush", "AccentSoftBrush", "FocusRingBrush",
            "HudSelectedBrush");
        Set(resources, System.Windows.SystemColors.HighlightTextBrush,
            "AccentForegroundBrush", "HudSelectedTextBrush", "AccentSoftForegroundBrush");
        Set(resources, System.Windows.Media.Brushes.Transparent, "HoverBackgroundBrush", "PressedBackgroundBrush");
    }

    private static void Set(ResourceDictionary resources, WpfBrush brush, params string[] keys)
    {
        foreach (var key in keys) resources[key] = brush;
    }
}
