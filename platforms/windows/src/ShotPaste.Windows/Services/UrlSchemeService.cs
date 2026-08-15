using Microsoft.Win32;

namespace ShotPaste.Windows.Services;

public enum AppCommand
{
    None,
    Invalid,
    OneShot,
    CancelCapture,
    History,
    Settings,
    ControlRecording
}

public sealed record ParsedAppCommand(
    AppCommand Command,
    string? SettingsTab = null,
    bool IsUrl = false,
    string? Error = null,
    string? CaptureMode = null,
    string? HistoryFilter = null,
    string? RecordingAction = null);

public static class UrlSchemeService
{
    internal static string Scheme => AppBuildIdentity.Current.UrlScheme;
    internal static string ProtocolKey => $@"Software\Classes\{Scheme}";

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
            protocol.SetValue(null, $"URL:{AppBuildIdentity.Current.DisplayName} Protocol");
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
            if (Uri.TryCreate(argument, UriKind.Absolute, out var uri) &&
                uri.Scheme.Equals(Scheme, StringComparison.OrdinalIgnoreCase))
                return ParseUrl(uri);

            if (argument.TrimStart().StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase))
                return Invalid(isUrl: true, "ShotPaste 链接格式无效");

            var parsed = ParseCommandLine(argument.Trim());
            if (parsed.Command != AppCommand.None) return parsed;
        }
        return new ParsedAppCommand(AppCommand.None);
    }

    private static ParsedAppCommand ParseUrl(Uri uri)
    {
        var parts = new[] { uri.Host }
            .Concat(uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries))
            .Where(part => !string.IsNullOrWhiteSpace(part))
            .Select(part => Uri.UnescapeDataString(part).Trim().ToLowerInvariant())
            .ToArray();
        var route = string.Join('/', parts);

        if (route is "settings" or "preferences" || route.StartsWith("settings/", StringComparison.Ordinal) ||
            route.StartsWith("preferences/", StringComparison.Ordinal) ||
            route.StartsWith("settings-", StringComparison.Ordinal) ||
            route.StartsWith("preferences-", StringComparison.Ordinal))
        {
            var prefix = route.StartsWith("preferences", StringComparison.Ordinal) ? "preferences" : "settings";
            var pathTab = parts.Skip(1).FirstOrDefault() ??
                (route.Length > prefix.Length + 1 ? route[(prefix.Length + 1)..] : null);
            var settingsTab = ReadQueryValue(uri.Query, "tab") ?? pathTab;
            if (string.IsNullOrWhiteSpace(settingsTab))
                return new ParsedAppCommand(AppCommand.Settings, IsUrl: true);
            var normalizedTab = NormalizeSettingsTab(settingsTab);
            return normalizedTab is null
                ? Invalid(true, "未知的设置页面")
                : new ParsedAppCommand(AppCommand.Settings, normalizedTab, IsUrl: true);
        }

        if (route is "capture/one-shot" or "capture-one-shot" or "capture" or "one-shot" or "oneshot" or
            "screenshot/one-shot" or "screenshot-one-shot")
        {
            var requested = ReadQueryValue(uri.Query, "mode");
            var mode = string.IsNullOrWhiteSpace(requested) ? "screenshot" : NormalizeCaptureMode(requested);
            return mode is null ? Invalid(true, "未知的捕获模式") : Capture(mode, true);
        }

        if (route is "capture/screenshot" or "screenshot") return Capture("screenshot", true);
        if (route is "capture/scrolling" or "scrolling-capture") return Capture("scrolling", true);
        if (route is "capture/ocr" or "ocr") return Capture("ocr", true);
        if (route is "record" or "record/screen" or "recording/start") return Capture("recording", true);
        if (route is "capture/cancel" or "one-shot/cancel") return new ParsedAppCommand(AppCommand.CancelCapture, IsUrl: true);

        if (route is "open/history" or "open-history" or "history" or "capture-history")
        {
            var requested = ReadQueryValue(uri.Query, "filter");
            var filter = string.IsNullOrWhiteSpace(requested) ? null : NormalizeHistoryFilter(requested);
            return requested is not null && filter is null
                ? Invalid(true, "未知的历史筛选条件")
                : new ParsedAppCommand(AppCommand.History, IsUrl: true, HistoryFilter: filter);
        }
        if (route is "open/clipboard" or "clipboard-history")
            return new ParsedAppCommand(AppCommand.History, IsUrl: true, HistoryFilter: "clipboard");

        if (route is "recording/pause" or "recording/resume" or "recording/stop" or "record/stop")
            return new ParsedAppCommand(
                AppCommand.ControlRecording,
                IsUrl: true,
                RecordingAction: route.EndsWith("pause", StringComparison.Ordinal) ? "pause" :
                    route.EndsWith("resume", StringComparison.Ordinal) ? "resume" : "stop");

        return Invalid(true, "无法识别此 ShotPaste 链接");
    }

    private static ParsedAppCommand ParseCommandLine(string argument)
    {
        var command = argument.ToLowerInvariant();
        if (command is "--one-shot" or "--screenshot") return Capture("screenshot", false);
        if (command is "--scrolling" or "--scrolling-capture") return Capture("scrolling", false);
        if (command == "--ocr") return Capture("ocr", false);
        if (command is "--record" or "--recording") return Capture("recording", false);
        if (command is "--cancel" or "--cancel-capture") return new ParsedAppCommand(AppCommand.CancelCapture);
        if (command == "--history") return new ParsedAppCommand(AppCommand.History);
        if (command == "--settings") return new ParsedAppCommand(AppCommand.Settings);

        if (command.StartsWith("--one-shot=", StringComparison.Ordinal) ||
            command.StartsWith("--capture=", StringComparison.Ordinal))
        {
            var mode = NormalizeCaptureMode(argument[(argument.IndexOf('=') + 1)..]);
            return mode is null ? Invalid(false, "未知的捕获模式") : Capture(mode, false);
        }
        if (command.StartsWith("--history=", StringComparison.Ordinal))
        {
            var filter = NormalizeHistoryFilter(argument["--history=".Length..]);
            return filter is null
                ? Invalid(false, "未知的历史筛选条件")
                : new ParsedAppCommand(AppCommand.History, HistoryFilter: filter);
        }
        if (command.StartsWith("--recording=", StringComparison.Ordinal))
        {
            var action = NormalizeRecordingAction(argument["--recording=".Length..]);
            return action is null
                ? Invalid(false, "未知的录屏控制操作")
                : new ParsedAppCommand(AppCommand.ControlRecording, RecordingAction: action);
        }
        if (command.StartsWith("--settings=", StringComparison.Ordinal))
        {
            var tab = NormalizeSettingsTab(argument["--settings=".Length..]);
            return tab is null
                ? Invalid(false, "未知的设置页面")
                : new ParsedAppCommand(AppCommand.Settings, SettingsTab: tab);
        }
        return new ParsedAppCommand(AppCommand.None);
    }

    private static ParsedAppCommand Capture(string mode, bool isUrl) =>
        new(AppCommand.OneShot, IsUrl: isUrl, CaptureMode: mode);

    private static ParsedAppCommand Invalid(bool isUrl, string error) =>
        new(AppCommand.Invalid, IsUrl: isUrl, Error: error);

    internal static string? NormalizeCaptureMode(string? value) => NormalizeValue(value) switch
    {
        "screenshot" or "screenshots" => "screenshot",
        "scrolling" or "scrolling-capture" or "scrolling-screenshot" => "scrolling",
        "recording" or "record" or "screen-recording" => "recording",
        "ocr" or "text" => "ocr",
        _ => null
    };

    internal static string? NormalizeHistoryFilter(string? value) => NormalizeValue(value) switch
    {
        "all" => "all",
        "screenshot" or "screenshots" => "screenshot",
        "scrolling" or "scrolling-screenshot" or "scrolling-screenshots" => "scrolling",
        "recording" or "recordings" or "video" or "videos" => "recording",
        "clipboard" => "clipboard",
        _ => null
    };

    internal static string? NormalizeRecordingAction(string? value) => NormalizeValue(value) switch
    {
        "pause" => "pause",
        "resume" => "resume",
        "stop" => "stop",
        _ => null
    };

    internal static string? NormalizeSettingsTab(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        return NormalizeValue(value) switch
        {
            "general" => "general",
            "capture" or "screenshots" or "screenshot" or "capture-recording" => "capture-recording",
            "quickaccess" or "quick-access" => "quick-access",
            "history" => "history",
            "shortcuts" or "keyboard-shortcuts" or "shortcuts-appearance" => "shortcuts-appearance",
            "appearance" or "theme" => "appearance",
            "permissions" or "privacy" or "advanced" or "configuration" or "config" or "toml" => "advanced",
            _ => null
        };
    }

    private static string? NormalizeValue(string? value) => value?
        .Trim().ToLowerInvariant().Replace('_', '-').Replace(' ', '-');

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
