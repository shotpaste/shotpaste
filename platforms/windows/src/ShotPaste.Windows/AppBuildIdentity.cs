using System.Reflection;

namespace ShotPaste.Windows;

internal sealed record AppBuildIdentity(
    bool IsDebug,
    string VariantName,
    string DisplayName,
    string ExecutableName,
    string NativeManifestIdentity,
    string DataDirectoryName,
    string DefaultSaveDirectoryName,
    string SingleInstanceMutexName,
    string HotkeyWindowName,
    string StartupRegistryValueName,
    string UrlScheme,
    string DefaultHotkeyModifiers)
{
    private const string VariantMetadataName = "ShotPasteVariant";

    internal static AppBuildIdentity Debug { get; } = new(
        IsDebug: true,
        VariantName: "debug",
        DisplayName: "ShotPaste Debug",
        ExecutableName: "ShotPasteDebug.exe",
        NativeManifestIdentity: "com.ahtcfg24.shotpaste.windows.debug",
        DataDirectoryName: "ShotPaste.Debug",
        DefaultSaveDirectoryName: "ShotPaste Debug",
        SingleInstanceMutexName: "ShotPaste.Windows.SingleInstance.Debug",
        HotkeyWindowName: "ShotPasteDebugHotkeys",
        StartupRegistryValueName: "ShotPaste Debug",
        UrlScheme: "shotpaste-debug",
        DefaultHotkeyModifiers: "Ctrl+Alt+Shift");

    internal static AppBuildIdentity Release { get; } = new(
        IsDebug: false,
        VariantName: "release",
        DisplayName: "ShotPaste",
        ExecutableName: "ShotPaste.exe",
        NativeManifestIdentity: "com.ahtcfg24.shotpaste.windows",
        DataDirectoryName: "ShotPaste",
        DefaultSaveDirectoryName: "ShotPaste",
        SingleInstanceMutexName: "ShotPaste.Windows.SingleInstance",
        HotkeyWindowName: "ShotPasteHotkeys",
        StartupRegistryValueName: "ShotPaste",
        UrlScheme: "shotpaste",
        DefaultHotkeyModifiers: "Ctrl+Shift");

    internal string InternalClipboardWriteMarkerFormat => $"{NativeManifestIdentity}.internal-media-write";
    internal bool PerformsAutomaticUpdateChecks => !IsDebug;

    internal static AppBuildIdentity Current { get; } = ResolveCurrent();
    internal static string? ConfiguredVariantName => ReadAssemblyMetadata(VariantMetadataName);

    internal static AppBuildIdentity ForBuild(bool debug) => debug ? Debug : Release;

    internal static IReadOnlyList<string> ValidateCurrentBuild(string? processPath = null)
    {
        var identity = Current;
        var assembly = typeof(AppBuildIdentity).Assembly;
        var errors = new List<string>();
        ValidateMetadata(errors, VariantMetadataName, identity.VariantName);
        ValidateMetadata(errors, "ShotPasteDisplayName", identity.DisplayName);
        ValidateMetadata(errors, "ShotPasteExecutableName", identity.ExecutableName);
        ValidateMetadata(errors, "ShotPasteUrlScheme", identity.UrlScheme);
        ValidateMetadata(errors, "ShotPasteNativeManifestIdentity", identity.NativeManifestIdentity);

        var expectedAssemblyName = Path.GetFileNameWithoutExtension(identity.ExecutableName);
        if (!string.Equals(assembly.GetName().Name, expectedAssemblyName, StringComparison.Ordinal))
            errors.Add($"Assembly name '{assembly.GetName().Name}' does not match '{expectedAssemblyName}'.");

        var title = assembly.GetCustomAttribute<AssemblyTitleAttribute>()?.Title;
        if (!string.Equals(title, identity.DisplayName, StringComparison.Ordinal))
            errors.Add($"Assembly title '{title}' does not match '{identity.DisplayName}'.");

        var product = assembly.GetCustomAttribute<AssemblyProductAttribute>()?.Product;
        if (!string.Equals(product, identity.DisplayName, StringComparison.Ordinal))
            errors.Add($"Assembly product '{product}' does not match '{identity.DisplayName}'.");

        if (!string.IsNullOrWhiteSpace(processPath) &&
            !string.Equals(Path.GetFileName(processPath), identity.ExecutableName, StringComparison.OrdinalIgnoreCase))
            errors.Add($"Process executable '{Path.GetFileName(processPath)}' does not match '{identity.ExecutableName}'.");

#if DEBUG
        if (!identity.IsDebug) errors.Add("Compiler configuration is Debug but the configured app variant is Release.");
#else
        if (identity.IsDebug) errors.Add("Compiler configuration is Release but the configured app variant is Debug.");
#endif
        return errors;
    }

    private static AppBuildIdentity ResolveCurrent()
    {
        var configuredVariant = ConfiguredVariantName;
        if (string.Equals(configuredVariant, Debug.VariantName, StringComparison.OrdinalIgnoreCase)) return Debug;
        if (string.Equals(configuredVariant, Release.VariantName, StringComparison.OrdinalIgnoreCase)) return Release;

        // Keep non-app contexts usable. Canonical app and test products always
        // carry ShotPasteVariant and verify it against this model.
#if DEBUG
        return Debug;
#else
        return Release;
#endif
    }

    private static void ValidateMetadata(List<string> errors, string name, string expected)
    {
        var value = ReadAssemblyMetadata(name);
        if (!string.Equals(value, expected, StringComparison.Ordinal))
            errors.Add($"Assembly metadata '{name}' is '{value}' instead of '{expected}'.");
    }

    private static string? ReadAssemblyMetadata(string name) =>
        typeof(AppBuildIdentity).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => string.Equals(attribute.Key, name, StringComparison.Ordinal))
            ?.Value;

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
