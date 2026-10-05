using System.ComponentModel;
using System.IO;
using System.Security;
using System.Windows;
using Microsoft.Win32;
using WpfApplication = System.Windows.Application;

namespace ShotPaste.Windows.Services;

public static class ThemeService
{
    private const string LightThemeFile = "Colors.Light.xaml";
    private const string DarkThemeFile = "Colors.Dark.xaml";
    private static string _preference = "System";
    private static bool _listening;
    public static bool IsDark { get; private set; }

    public static void Apply(string preference)
    {
        _preference = NormalizePreference(preference);
        EnsureSystemListeners();
        RefreshTheme();
    }

    public static void Shutdown()
    {
        if (!_listening) return;
        SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _listening = false;
    }

    private static void EnsureSystemListeners()
    {
        if (_listening) return;
        _listening = true;
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
    }

    private static void RefreshTheme()
    {
        var application = WpfApplication.Current;
        if (application is null) return;
        if (!application.Dispatcher.CheckAccess())
        {
            _ = application.Dispatcher.BeginInvoke(RefreshTheme);
            return;
        }

        var dark = _preference.Equals("Dark", StringComparison.OrdinalIgnoreCase) ||
            _preference.Equals("System", StringComparison.OrdinalIgnoreCase) && IsSystemDark();
        IsDark = dark;
        ReplaceThemeDictionary(application.Resources, dark ? DarkThemeFile : LightThemeFile);
        AccessibilityPreferences.ApplyHighContrastResources(application.Resources);
        WindowAppearanceService.RefreshOpenWindows();
    }

    private static void ReplaceThemeDictionary(ResourceDictionary resources, string themeFile)
    {
        var dictionaries = resources.MergedDictionaries;
        var themeIndex = -1;
        for (var index = 0; index < dictionaries.Count; index++)
        {
            var source = dictionaries[index].Source?.OriginalString.Replace('\\', '/');
            if (source is null || !source.Contains("/Themes/Colors.", StringComparison.OrdinalIgnoreCase)) continue;
            themeIndex = index;
            if (source.EndsWith(themeFile, StringComparison.OrdinalIgnoreCase)) return;
            break;
        }

        var replacement = new ResourceDictionary
        {
            Source = AppBuildIdentity.ResourceUri($"Resources/Themes/{themeFile}")
        };
        if (themeIndex >= 0)
            dictionaries[themeIndex] = replacement;
        else
            dictionaries.Insert(Math.Min(1, dictionaries.Count), replacement);
    }

    private static bool IsSystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (UnauthorizedAccessException) { return false; }
        catch (SecurityException) { return false; }
        catch (IOException) { return false; }
    }

    private static string NormalizePreference(string preference)
    {
        if (preference.Equals("Dark", StringComparison.OrdinalIgnoreCase)) return "Dark";
        if (preference.Equals("Light", StringComparison.OrdinalIgnoreCase)) return "Light";
        return "System";
    }

    private static void OnSystemParametersChanged(object? sender, PropertyChangedEventArgs e) => ScheduleRefresh();

    private static void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => ScheduleRefresh();

    private static void ScheduleRefresh()
    {
        var application = WpfApplication.Current;
        if (application is null) return;
        _ = application.Dispatcher.BeginInvoke(RefreshTheme);
    }
}
