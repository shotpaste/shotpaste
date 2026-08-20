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
        Assert.Equal("release", identity.VariantName);
        Assert.Equal("ShotPaste", identity.DisplayName);
        Assert.Equal("ShotPaste.exe", identity.ExecutableName);
        Assert.Equal("com.ahtcfg24.shotpaste.windows", identity.NativeManifestIdentity);
        Assert.Equal("ShotPaste", identity.DataDirectoryName);
        Assert.Equal("ShotPaste", identity.DefaultSaveDirectoryName);
        Assert.Equal("ShotPaste.Windows.SingleInstance", identity.SingleInstanceMutexName);
        Assert.Equal("ShotPasteHotkeys", identity.HotkeyWindowName);
        Assert.Equal("ShotPaste", identity.StartupRegistryValueName);
        Assert.Equal("shotpaste", identity.UrlScheme);
        Assert.Equal("Ctrl+Shift", identity.DefaultHotkeyModifiers);
        Assert.Equal(48123, identity.DefaultMcpServerPort);
        Assert.True(identity.PerformsAutomaticUpdateChecks);
    }

    [Fact]
    public void DebugIdentity_IsDisjointFromReleaseForEverySharedOperatingSystemResource()
    {
        var debug = AppBuildIdentity.ForBuild(debug: true);
        var release = AppBuildIdentity.ForBuild(debug: false);

        Assert.True(debug.IsDebug);
        Assert.Equal("debug", debug.VariantName);
        Assert.Equal("ShotPaste Debug", debug.DisplayName);
        Assert.Equal("ShotPasteDebug.exe", debug.ExecutableName);
        Assert.Equal("com.ahtcfg24.shotpaste.windows.debug", debug.NativeManifestIdentity);
        Assert.Equal("ShotPaste.Debug", debug.DataDirectoryName);
        Assert.Equal("shotpaste-debug", debug.UrlScheme);
        Assert.Equal(48124, debug.DefaultMcpServerPort);
        Assert.NotEqual(release.ExecutableName, debug.ExecutableName);
        Assert.NotEqual(release.DataDirectoryName, debug.DataDirectoryName);
        Assert.NotEqual(release.DefaultSaveDirectoryName, debug.DefaultSaveDirectoryName);
        Assert.NotEqual(release.SingleInstanceMutexName, debug.SingleInstanceMutexName);
        Assert.NotEqual(release.HotkeyWindowName, debug.HotkeyWindowName);
        Assert.NotEqual(release.StartupRegistryValueName, debug.StartupRegistryValueName);
        Assert.NotEqual(release.UrlScheme, debug.UrlScheme);
        Assert.NotEqual(release.DefaultHotkeyModifiers, debug.DefaultHotkeyModifiers);
        Assert.NotEqual(release.DefaultMcpServerPort, debug.DefaultMcpServerPort);
        Assert.NotEqual(release.NativeManifestIdentity, debug.NativeManifestIdentity);
        Assert.NotEqual(release.InternalClipboardWriteMarkerFormat, debug.InternalClipboardWriteMarkerFormat);
        Assert.NotEqual(AppPaths.DefaultRootFor(release), AppPaths.DefaultRootFor(debug));
        Assert.False(debug.PerformsAutomaticUpdateChecks);
    }

    [Theory]
    [InlineData(null, "ShotPaste Debug")]
    [InlineData("", "ShotPaste Debug")]
    [InlineData("ShotPaste", "ShotPaste Debug")]
    [InlineData("ShotPaste · 设置", "ShotPaste Debug · 设置")]
    [InlineData("剪贴板文本", "ShotPaste Debug · 剪贴板文本")]
    [InlineData("ShotPaste Debug · 设置", "ShotPaste Debug · 设置")]
    public void DebugIdentity_FormatsEveryWindowTitleWithoutDoublePrefixing(string? title, string expected) =>
        Assert.Equal(expected, AppBuildIdentity.ForBuild(debug: true).FormatWindowTitle(title));

    [Theory]
    [InlineData(null, "")]
    [InlineData("", "")]
    [InlineData("ShotPaste", "ShotPaste")]
    [InlineData("ShotPaste · 设置", "ShotPaste · 设置")]
    [InlineData("剪贴板文本", "剪贴板文本")]
    public void ReleaseIdentity_PreservesWindowTitles(string? title, string expected) =>
        Assert.Equal(expected, AppBuildIdentity.ForBuild(debug: false).FormatWindowTitle(title));

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
        Assert.Equal(identity.DefaultMcpServerPort, settings.McpServerPort);
    }

    [Fact]
    public void CurrentBuild_MetadataCompilerAndRuntimeIdentityAgree()
    {
        var identity = AppBuildIdentity.Current;

        Assert.Equal(identity.VariantName, AppBuildIdentity.ConfiguredVariantName);
#if DEBUG
        Assert.True(identity.IsDebug);
#else
        Assert.False(identity.IsDebug);
#endif
        Assert.Empty(AppBuildIdentity.ValidateCurrentBuild(identity.ExecutableName));
    }

    [Fact]
    public void ProjectImportsCanonicalVariantIdentityAndDistinctNativeManifests()
    {
        var project = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "ShotPaste.Windows.csproj"));
        var debugConfiguration = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Config", "AppVariant.Debug.props"));
        var releaseConfiguration = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Config", "AppVariant.Release.props"));
        var debugManifest = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "app.Debug.manifest"));
        var releaseManifest = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "app.manifest"));
        var debugPng = FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Assets", "shotpaste-debug-icon.png");
        var debugIco = FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Assets", "shotpaste-debug-icon.ico");

        Assert.Contains("Config\\AppVariant.$(Configuration).props", project, StringComparison.Ordinal);
        Assert.Contains("<AssemblyName>$(ShotPasteAssemblyName)</AssemblyName>", project, StringComparison.Ordinal);
        Assert.Contains("<ApplicationManifest>$(ShotPasteApplicationManifest)</ApplicationManifest>", project,
            StringComparison.Ordinal);
        Assert.Contains("<ShotPasteVariant>debug</ShotPasteVariant>", debugConfiguration, StringComparison.Ordinal);
        Assert.Contains("<ShotPasteAssemblyName>ShotPasteDebug</ShotPasteAssemblyName>", debugConfiguration,
            StringComparison.Ordinal);
        Assert.Contains("<ShotPasteApplicationIcon>Assets\\shotpaste-debug-icon.ico</ShotPasteApplicationIcon>",
            debugConfiguration, StringComparison.Ordinal);
        Assert.Contains("<ShotPasteVariant>release</ShotPasteVariant>", releaseConfiguration, StringComparison.Ordinal);
        Assert.Contains("<ShotPasteAssemblyName>ShotPaste</ShotPasteAssemblyName>", releaseConfiguration,
            StringComparison.Ordinal);
        Assert.Contains("name=\"com.ahtcfg24.shotpaste.windows.debug\"", debugManifest, StringComparison.Ordinal);
        Assert.Contains("name=\"com.ahtcfg24.shotpaste.windows\"", releaseManifest, StringComparison.Ordinal);
        Assert.DoesNotContain("name=\"com.ahtcfg24.shotpaste.windows\" />", debugManifest, StringComparison.Ordinal);
        Assert.Contains("..\\..\\..\\..\\assets\\shotpaste-icon.png", project, StringComparison.Ordinal);
        Assert.True(File.Exists(debugPng));
        Assert.True(File.Exists(debugIco));
        Assert.False(File.ReadAllBytes(FindRepositoryFile("assets", "shotpaste-icon.png"))
            .SequenceEqual(File.ReadAllBytes(debugPng)));
        Assert.True(new FileInfo(debugIco).Length > 0);
    }

    [Fact]
    public void VariantResourcesResolveFromTheCurrentAssemblyAfterDebugExecutableRename()
    {
        var files = new[]
        {
            FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows", "Controls", "WindowTitleBar.xaml"),
            FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows", "Resources", "Controls", "Common.xaml"),
            FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows", "Services", "ThemeService.cs"),
            FindRepositoryFile("platforms", "windows", "src", "ShotPaste.Windows", "Services", "TrayIconService.cs"),
            FindRepositoryFile("platforms", "windows", "tests", "ShotPaste.Windows.OcrE2E", "Program.cs")
        };

        Assert.All(files, file => Assert.DoesNotContain(
            "ShotPaste;component/",
            File.ReadAllText(file),
            StringComparison.Ordinal));
    }

    [Fact]
    public void ResourceUrisFollowTheCompiledAssemblyName()
    {
        var assemblyName = typeof(AppBuildIdentity).Assembly.GetName().Name;

        Assert.Equal(
            $"/{assemblyName};component/Assets/shotpaste-icon.png",
            AppBuildIdentity.ResourceUri("/Assets\\shotpaste-icon.png").OriginalString);
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
