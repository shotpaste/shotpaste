using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using Microsoft.Win32;
using Windows.UI.ViewManagement;
using WpfApplication = System.Windows.Application;
using WpfColor = System.Windows.Media.Color;

namespace ShotPaste.Windows.Services;

public static class ThemeService
{
    private const string LightThemeFile = "Colors.Light.xaml";
    private const string DarkThemeFile = "Colors.Dark.xaml";
    private static string _preference = "System";
    private static bool _listening;
    private static UISettings? _uiSettings;
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
        if (_uiSettings is not null) _uiSettings.ColorValuesChanged -= OnColorValuesChanged;
        _uiSettings = null;
        _listening = false;
    }

    private static void EnsureSystemListeners()
    {
        if (_listening) return;
        _listening = true;
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        try
        {
            _uiSettings = new UISettings();
            _uiSettings.ColorValuesChanged += OnColorValuesChanged;
        }
        catch (COMException)
        {
            _uiSettings = null;
        }
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
        ApplyAccentColor(application.Resources, GetSystemAccentColor());
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
            Source = new Uri($"/ShotPaste;component/Resources/Themes/{themeFile}", UriKind.Relative)
        };
        if (themeIndex >= 0)
            dictionaries[themeIndex] = replacement;
        else
            dictionaries.Insert(Math.Min(1, dictionaries.Count), replacement);
    }

    private static void ApplyAccentColor(ResourceDictionary resources, WpfColor accentColor)
    {
        foreach (var dictionary in resources.MergedDictionaries)
        {
            if (!dictionary.Contains("AccentColor")) continue;
            dictionary["AccentColor"] = accentColor;
            return;
        }
        resources["AccentColor"] = accentColor;
    }

    private static WpfColor GetSystemAccentColor()
    {
        try
        {
            var color = (_uiSettings ?? new UISettings()).GetColorValue(UIColorType.Accent);
            return WpfColor.FromArgb(byte.MaxValue, color.R, color.G, color.B);
        }
        catch (COMException)
        {
            var fallback = SystemParameters.WindowGlassColor;
            return WpfColor.FromArgb(byte.MaxValue, fallback.R, fallback.G, fallback.B);
        }
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

    private static void OnColorValuesChanged(UISettings sender, object args) => ScheduleRefresh();

    private static void ScheduleRefresh()
    {
        var application = WpfApplication.Current;
        if (application is null) return;
        _ = application.Dispatcher.BeginInvoke(RefreshTheme);
    }
}
