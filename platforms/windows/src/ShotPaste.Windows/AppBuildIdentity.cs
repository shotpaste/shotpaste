namespace ShotPaste.Windows;

internal sealed record AppBuildIdentity(
    bool IsDebug,
    string DisplayName,
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
}
