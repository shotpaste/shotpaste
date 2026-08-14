using System.Text;

namespace ShotPaste.Windows.Services;

internal static class UiTestIsolationPolicy
{
    internal const string VariantMarkerFileName = ".shotpaste-ui-test-variant";

    internal static string PrepareDataRoot(
        IReadOnlyList<string> arguments,
        AppBuildIdentity identity)
    {
        if (!TryGetArgumentValue(arguments, "--data-root", out var requestedRoot))
            throw new InvalidOperationException("--ui-test requires an explicit --data-root.");
        if (!Path.IsPathFullyQualified(requestedRoot))
            throw new InvalidOperationException("--ui-test --data-root must be an absolute path.");

        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(requestedRoot));
        foreach (var productionRoot in new[]
                 {
                     AppPaths.DefaultRootFor(AppBuildIdentity.Debug),
                     AppPaths.DefaultRootFor(AppBuildIdentity.Release)
                 })
        {
            if (PathsOverlap(root, productionRoot))
                throw new InvalidOperationException(
                    $"UI test data root '{root}' overlaps production data root '{productionRoot}'.");
        }

        Directory.CreateDirectory(root);
        EnsureVariantMarker(root, identity);
        return root;
    }

    private static void EnsureVariantMarker(string root, AppBuildIdentity identity)
    {
        var markerPath = Path.Combine(root, VariantMarkerFileName);
        try
        {
            using var stream = new FileStream(markerPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            using var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            writer.Write(identity.VariantName);
            writer.Flush();
            return;
        }
        catch (IOException) when (File.Exists(markerPath))
        {
            // Another launch, or an earlier test session, already owns the root.
        }

        var configuredVariant = ReadMarker(markerPath);
        if (!string.Equals(configuredVariant, identity.VariantName, StringComparison.Ordinal))
            throw new InvalidOperationException(
                $"UI test data root '{root}' belongs to app variant '{configuredVariant}', not '{identity.VariantName}'.");
    }

    private static string ReadMarker(string markerPath)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                var value = File.ReadAllText(markerPath).Trim();
                if (value.Length > 0 || attempt == 4) return value;
            }
            catch (IOException) when (attempt < 4)
            {
                // Allow a concurrently starting instance to finish its tiny marker write.
            }
            Thread.Sleep(20);
        }
    }

    private static bool PathsOverlap(string first, string second) =>
        IsSameOrDescendant(first, second) || IsSameOrDescendant(second, first);

    private static bool IsSameOrDescendant(string candidate, string root)
    {
        var fullCandidate = Path.TrimEndingDirectorySeparator(Path.GetFullPath(candidate));
        var fullRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        return string.Equals(fullCandidate, fullRoot, StringComparison.OrdinalIgnoreCase) ||
               fullCandidate.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryGetArgumentValue(IReadOnlyList<string> arguments, string name, out string value)
    {
        value = string.Empty;
        for (var index = 0; index < arguments.Count; index++)
        {
            var argument = arguments[index];
            if (argument.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
            {
                value = argument[(name.Length + 1)..];
                return !string.IsNullOrWhiteSpace(value);
            }

            if (!argument.Equals(name, StringComparison.OrdinalIgnoreCase) || index + 1 >= arguments.Count) continue;
            value = arguments[index + 1];
            return !string.IsNullOrWhiteSpace(value) && !value.StartsWith("--", StringComparison.Ordinal);
        }

        return false;
    }
}
