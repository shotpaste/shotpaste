using Microsoft.Win32;

namespace ShotPaste.Windows.Services;

public static class StartupService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Apply(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true) ??
            Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled)
        {
            var executable = Environment.ProcessPath;
            if (!string.IsNullOrWhiteSpace(executable)) key.SetValue("ShotPaste", $"\"{executable}\"");
        }
        else key.DeleteValue("ShotPaste", throwOnMissingValue: false);
    }
}
