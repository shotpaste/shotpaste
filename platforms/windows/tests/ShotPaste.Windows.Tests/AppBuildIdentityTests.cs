using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class AppBuildIdentityTests
{
    [Fact]
    public void ReleaseIdentity_PreservesEveryExistingExternalContract()
    {
        var identity = AppBuildIdentity.ForBuild(debug: false);

        Assert.False(identity.IsDebug);
        Assert.Equal("ShotPaste", identity.DisplayName);
        Assert.Equal("ShotPaste", identity.DataDirectoryName);
        Assert.Equal("ShotPaste", identity.DefaultSaveDirectoryName);
        Assert.Equal("ShotPaste.Windows.SingleInstance", identity.SingleInstanceMutexName);
        Assert.Equal("ShotPasteHotkeys", identity.HotkeyWindowName);
        Assert.Equal("ShotPaste", identity.StartupRegistryValueName);
        Assert.Equal("shotpaste", identity.UrlScheme);
        Assert.Equal("Ctrl+Shift", identity.DefaultHotkeyModifiers);
    }

    [Fact]
    public void DebugIdentity_IsDisjointFromReleaseForEverySharedOperatingSystemResource()
    {
        var debug = AppBuildIdentity.ForBuild(debug: true);
        var release = AppBuildIdentity.ForBuild(debug: false);

        Assert.True(debug.IsDebug);
        Assert.Equal("ShotPaste Debug", debug.DisplayName);
        Assert.Equal("ShotPaste.Debug", debug.DataDirectoryName);
        Assert.Equal("shotpaste-debug", debug.UrlScheme);
        Assert.NotEqual(release.DataDirectoryName, debug.DataDirectoryName);
        Assert.NotEqual(release.DefaultSaveDirectoryName, debug.DefaultSaveDirectoryName);
        Assert.NotEqual(release.SingleInstanceMutexName, debug.SingleInstanceMutexName);
        Assert.NotEqual(release.HotkeyWindowName, debug.HotkeyWindowName);
        Assert.NotEqual(release.StartupRegistryValueName, debug.StartupRegistryValueName);
        Assert.NotEqual(release.UrlScheme, debug.UrlScheme);
        Assert.NotEqual(release.DefaultHotkeyModifiers, debug.DefaultHotkeyModifiers);
        Assert.NotEqual(AppPaths.DefaultRootFor(release), AppPaths.DefaultRootFor(debug));
    }

    [Fact]
    public void CurrentBuild_DefaultSettingsAndStorageUseCurrentIdentity()
    {
        var identity = AppBuildIdentity.Current;
        var settings = new AppSettings();

        Assert.Equal(AppPaths.DefaultRootFor(identity), AppPaths.Root);
        Assert.Equal(identity.DefaultSaveDirectoryName, Path.GetFileName(settings.SaveDirectory));
        Assert.All(
            new[]
            {
                settings.OneShotHotkey,
                settings.HistoryHotkey,
                settings.RecordingPauseHotkey,
                settings.RecordingAnnotationHotkey,
                settings.RecordingRestartHotkey,
                settings.RecordingDeleteHotkey
            },
            gesture => Assert.True(
                gesture.StartsWith(identity.DefaultHotkeyModifiers + "+", StringComparison.Ordinal),
                gesture));
        Assert.Equal($@"Software\Classes\{identity.UrlScheme}", UrlSchemeService.ProtocolKey);
    }

    [Fact]
    public void ProjectUsesDebugOnlyIconAssetsWithoutChangingReleaseIconInput()
    {
        var project = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "ShotPaste.Windows.csproj"));
        var debugPng = FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Assets", "shotpaste-debug-icon.png");
        var debugIco = FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Assets", "shotpaste-debug-icon.ico");

        Assert.Contains("<ApplicationIcon>Assets\\shotpaste-debug-icon.ico</ApplicationIcon>", project,
            StringComparison.Ordinal);
        Assert.Contains("Condition=\"'$(Configuration)' == 'Debug'\"", project, StringComparison.Ordinal);
        Assert.Contains("..\\..\\..\\..\\assets\\shotpaste-icon.png", project, StringComparison.Ordinal);
        Assert.True(File.Exists(debugPng));
        Assert.True(File.Exists(debugIco));
        Assert.False(File.ReadAllBytes(FindRepositoryFile("assets", "shotpaste-icon.png"))
            .SequenceEqual(File.ReadAllBytes(debugPng)));
        Assert.True(new FileInfo(debugIco).Length > 0);
    }

    private static string FindRepositoryFile(params string[] relativeParts)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, ".git")) &&
               !File.Exists(Path.Combine(directory.FullName, ".git")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        return Path.Combine([directory!.FullName, .. relativeParts]);
    }
}
