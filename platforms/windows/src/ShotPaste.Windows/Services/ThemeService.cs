using System.Windows.Media;
using Microsoft.Win32;

namespace ShotPaste.Windows.Services;

public static class ThemeService
{
    public static void Apply(string preference)
    {
        var dark = preference.Equals("Dark", StringComparison.OrdinalIgnoreCase) ||
            preference.Equals("System", StringComparison.OrdinalIgnoreCase) && IsSystemDark();
        var resources = System.Windows.Application.Current.Resources;
        resources["WindowBrush"] = Brush(dark ? "#FF161618" : "#FFF7F7FA");
        resources["SurfaceBrush"] = Brush(dark ? "#FF232326" : "#FFFFFFFF");
        resources["SurfaceSecondaryBrush"] = Brush(dark ? "#FF303034" : "#FFF1F1F5");
        resources["TextBrush"] = Brush(dark ? "#FFF4F4F5" : "#FF19191D");
        resources["SecondaryTextBrush"] = Brush(dark ? "#FFA1A1AA" : "#FF71717A");
        resources["BorderBrush"] = Brush(dark ? "#35FFFFFF" : "#1F000000");
    }

    private static bool IsSystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static SolidColorBrush Brush(string color)
    {
        var brush = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(color));
        brush.Freeze();
        return brush;
    }
}
