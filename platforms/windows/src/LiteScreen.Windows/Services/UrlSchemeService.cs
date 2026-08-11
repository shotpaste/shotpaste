using Microsoft.Win32;

namespace LiteScreen.Windows.Services;

public enum AppCommand
{
    None,
    Invalid,
    OneShot,
    History,
    Settings
}

public sealed record ParsedAppCommand(
    AppCommand Command,
    string? SettingsTab = null,
    bool IsUrl = false,
    string? Error = null);

public static class UrlSchemeService
{
    private const string ProtocolKey = @"Software\Classes\litescreen";

    public static void Apply(bool enabled)
    {
        try
        {
            if (!enabled)
            {
                Registry.CurrentUser.DeleteSubKeyTree(ProtocolKey, false);
                return;
            }
            using var protocol = Registry.CurrentUser.CreateSubKey(ProtocolKey);
            protocol.SetValue(null, "URL:Lite Screen Protocol");
            protocol.SetValue("URL Protocol", string.Empty);
            using var command = protocol.CreateSubKey(@"shell\open\command");
            command.SetValue(null, $"\"{Environment.ProcessPath}\" \"%1\"");
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            App.WriteCrashLog(exception);
        }
    }

    internal static ParsedAppCommand Parse(IReadOnlyList<string> arguments)
    {
        foreach (var argument in arguments)
        {
            if (Uri.TryCreate(argument, UriKind.Absolute, out var uri) && uri.Scheme.Equals("litescreen", StringComparison.OrdinalIgnoreCase))
            {
                var route = Uri.UnescapeDataString((uri.Host + uri.AbsolutePath).Trim('/'))
                    .Replace('/', '-').ToLowerInvariant();
                var settingsTab = ReadQueryValue(uri.Query, "tab");
                if (route == "settings" || route.StartsWith("settings-", StringComparison.Ordinal) ||
                    route == "preferences" || route.StartsWith("preferences-", StringComparison.Ordinal))
                {
                    var prefix = route.StartsWith("preferences", StringComparison.Ordinal) ? "preferences" : "settings";
                    settingsTab ??= route.Length > prefix.Length + 1 ? route[(prefix.Length + 1)..] : null;
                    var normalizedTab = NormalizeSettingsTab(settingsTab);
                    if (!string.IsNullOrWhiteSpace(settingsTab) && normalizedTab is null)
                        return new ParsedAppCommand(AppCommand.Invalid, IsUrl: true, Error: "未知的设置页面");
                    return new ParsedAppCommand(AppCommand.Settings, SettingsTab: normalizedTab, IsUrl: true);
                }
                return route switch
                {
                    "capture-one-shot" or "one-shot" or "oneshot" or "screenshot-one-shot" => new ParsedAppCommand(AppCommand.OneShot, IsUrl: true),
                    "open-history" or "capture-history" or "history" => new ParsedAppCommand(AppCommand.History, IsUrl: true),
                    _ => new ParsedAppCommand(AppCommand.Invalid, IsUrl: true, Error: "无法识别此 LiteScreen 链接")
                };
            }

            if (argument.TrimStart().StartsWith("litescreen:", StringComparison.OrdinalIgnoreCase))
                return new ParsedAppCommand(AppCommand.Invalid, IsUrl: true, Error: "LiteScreen 链接格式无效");

            var command = argument.Trim().ToLowerInvariant();
            var parsed = command switch
            {
                "--one-shot" => AppCommand.OneShot,
                "--history" => AppCommand.History,
                "--settings" => AppCommand.Settings,
                _ => AppCommand.None
            };
            if (parsed != AppCommand.None) return new ParsedAppCommand(parsed);
            if (command.StartsWith("--settings=", StringComparison.Ordinal))
            {
                var tab = NormalizeSettingsTab(command["--settings=".Length..]);
                return tab is null
                    ? new ParsedAppCommand(AppCommand.Invalid, Error: "未知的设置页面")
                    : new ParsedAppCommand(AppCommand.Settings, SettingsTab: tab);
            }
        }
        return new ParsedAppCommand(AppCommand.None);
    }

    internal static string? NormalizeSettingsTab(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        return value.Trim().ToLowerInvariant().Replace('_', '-').Replace(' ', '-') switch
        {
            "general" => "general",
            "capture" or "screenshots" or "screenshot" => "capture-recording",
            "quickaccess" or "quick-access" => "quick-access",
            "history" => "history",
            "shortcuts" or "keyboard-shortcuts" => "shortcuts-appearance",
            "permissions" or "privacy" or "advanced" or "configuration" or "config" or "toml" => "advanced",
            _ => null
        };
    }

    private static string? ReadQueryValue(string query, string name)
    {
        foreach (var part in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var components = part.Split('=', 2);
            if (!Uri.UnescapeDataString(components[0]).Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
            return components.Length == 2 ? Uri.UnescapeDataString(components[1].Replace('+', ' ')) : string.Empty;
        }
        return null;
    }
}
