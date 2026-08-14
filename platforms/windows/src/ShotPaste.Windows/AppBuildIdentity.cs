namespace ShotPaste.Windows;

internal sealed record AppBuildIdentity(
    bool IsDebug,
    string DisplayName,
    string ExecutableName,
    string DataDirectoryName,
    string DefaultSaveDirectoryName,
    string SingleInstanceMutexName,
    string HotkeyWindowName,
    string StartupRegistryValueName,
    string UrlScheme,
    string DefaultHotkeyModifiers)
{
    internal static AppBuildIdentity Debug { get; } = new(
        IsDebug: true,
        DisplayName: "ShotPaste Debug",
        ExecutableName: "ShotPasteDebug.exe",
        DataDirectoryName: "ShotPaste.Debug",
        DefaultSaveDirectoryName: "ShotPaste Debug",
        SingleInstanceMutexName: "ShotPaste.Windows.SingleInstance.Debug",
        HotkeyWindowName: "ShotPasteDebugHotkeys",
        StartupRegistryValueName: "ShotPaste Debug",
        UrlScheme: "shotpaste-debug",
        DefaultHotkeyModifiers: "Ctrl+Alt+Shift");

    internal static AppBuildIdentity Release { get; } = new(
        IsDebug: false,
        DisplayName: "ShotPaste",
        ExecutableName: "ShotPaste.exe",
        DataDirectoryName: "ShotPaste",
        DefaultSaveDirectoryName: "ShotPaste",
        SingleInstanceMutexName: "ShotPaste.Windows.SingleInstance",
        HotkeyWindowName: "ShotPasteHotkeys",
        StartupRegistryValueName: "ShotPaste",
        UrlScheme: "shotpaste",
        DefaultHotkeyModifiers: "Ctrl+Shift");

#if DEBUG
    internal static AppBuildIdentity Current => Debug;
#else
    internal static AppBuildIdentity Current => Release;
#endif

    internal static AppBuildIdentity ForBuild(bool debug) => debug ? Debug : Release;

    internal static Uri ResourceUri(string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath))
            throw new ArgumentException("Resource path cannot be empty.", nameof(relativePath));
        var assemblyName = typeof(AppBuildIdentity).Assembly.GetName().Name
            ?? throw new InvalidOperationException("Application assembly name is unavailable.");
        var normalizedPath = relativePath.TrimStart('/', '\\').Replace('\\', '/');
        return new Uri($"/{assemblyName};component/{normalizedPath}", UriKind.Relative);
    }

    internal string FormatWindowTitle(string? title)
    {
        if (!IsDebug) return title ?? string.Empty;

        var normalized = title?.Trim() ?? string.Empty;
        if (normalized.Length == 0 || normalized.Equals(Release.DisplayName, StringComparison.Ordinal))
            return DisplayName;
        if (normalized.Equals(DisplayName, StringComparison.Ordinal) ||
            normalized.StartsWith(DisplayName + " · ", StringComparison.Ordinal))
            return normalized;

        var releasePrefix = Release.DisplayName + " · ";
        return normalized.StartsWith(releasePrefix, StringComparison.Ordinal)
            ? DisplayName + normalized[Release.DisplayName.Length..]
            : $"{DisplayName} · {normalized}";
    }
}
