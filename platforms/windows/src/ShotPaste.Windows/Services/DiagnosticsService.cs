using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public sealed record MaintenanceResult(int RemovedDirectories, int RemovedFiles);

public static class DiagnosticsService
{
    public static MaintenanceResult RunStartupMaintenance(int diagnosticsRetentionDays = 14, DateTimeOffset? now = null)
    {
        AppPaths.EnsureCreated();
        var reference = now ?? DateTimeOffset.Now;
        diagnosticsRetentionDays = Math.Clamp(diagnosticsRetentionDays, 1, 90);
        var removedDirectories = CleanDirectories(Path.Combine(AppPaths.Captures, "GifFrames"), reference.AddDays(-1));
        removedDirectories += CleanDirectories(AppPaths.Temp, reference.AddDays(-1));
        var removedFiles = CleanFiles(AppPaths.Temp, reference.AddDays(-1));
        var diagnosticsCutoff = reference.AddDays(-diagnosticsRetentionDays);
        removedFiles += CleanFiles(AppPaths.Root, diagnosticsCutoff, "recording-recovery-failed-*.json");
        removedFiles += CleanFiles(AppPaths.Root, diagnosticsCutoff, "quickaccess.log.old");
        removedFiles += CleanFiles(AppPaths.Root, diagnosticsCutoff, "crash.log");
        RotateLargeLog(Path.Combine(AppPaths.Root, "quickaccess.log"), 5 * 1024 * 1024);
        return new MaintenanceResult(removedDirectories, removedFiles);
    }

    public static void CreateSupportBundle(string destination, AppSettings settings)
    {
        AppPaths.EnsureCreated();
        if (File.Exists(destination)) File.Delete(destination);
        using var archive = ZipFile.Open(destination, ZipArchiveMode.Create);
        AddText(archive, "environment.txt", BuildEnvironmentSummary());
        AddText(archive, "settings-sanitized.json", BuildSanitizedSettings(settings));
        AddText(archive, "storage-summary.txt", BuildStorageSummary());
        AddFileIfPresent(archive, Path.Combine(AppPaths.Root, "crash.log"), "logs/crash.log");
        AddFileIfPresent(archive, Path.Combine(AppPaths.Root, "quickaccess.log"), "logs/quickaccess.log");
        foreach (var marker in Directory.EnumerateFiles(AppPaths.Root, "recording-recovery*.json").Take(10))
            AddFileIfPresent(archive, marker, "recovery/" + Path.GetFileName(marker));
    }

    private static int CleanDirectories(string root, DateTimeOffset cutoff)
    {
        if (!Directory.Exists(root)) return 0;
        var count = 0;
        foreach (var path in Directory.EnumerateDirectories(root))
        {
            try
            {
                if (Directory.GetLastWriteTimeUtc(path) > cutoff.UtcDateTime) continue;
                Directory.Delete(path, true);
                count++;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return count;
    }

    private static int CleanFiles(string root, DateTimeOffset cutoff, string pattern = "*")
    {
        if (!Directory.Exists(root)) return 0;
        var count = 0;
        foreach (var path in Directory.EnumerateFiles(root, pattern, SearchOption.TopDirectoryOnly))
        {
            try
            {
                if (File.GetLastWriteTimeUtc(path) > cutoff.UtcDateTime) continue;
                File.Delete(path);
                count++;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return count;
    }

    private static void RotateLargeLog(string path, long maximumBytes)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length <= maximumBytes) return;
            File.Move(path, path + ".old", true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static string BuildEnvironmentSummary() => string.Join(Environment.NewLine,
    [
        $"Generated: {DateTimeOffset.Now:O}",
        $"ShotPaste: {typeof(DiagnosticsService).Assembly.GetName().Version}",
        $"OS: {Environment.OSVersion}",
        $"64-bit process: {Environment.Is64BitProcess}",
        $"Runtime: {Environment.Version}",
        $"Displays: {System.Windows.Forms.Screen.AllScreens.Length}"
    ]);

    private static string BuildSanitizedSettings(AppSettings settings)
    {
        var json = JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true });
        using var document = JsonDocument.Parse(json);
        var values = document.RootElement.EnumerateObject()
            .Where(property => property.Name is not ("SaveDirectory" or "RecordingMicrophoneDeviceId" or "RecordingMicrophoneDeviceName"))
            .ToDictionary(property => property.Name, property => property.Value.Clone());
        values["SaveDirectory"] = JsonSerializer.SerializeToElement("<redacted>");
        return JsonSerializer.Serialize(values, new JsonSerializerOptions { WriteIndented = true });
    }

    private static string BuildStorageSummary()
    {
        static long Size(string path) => File.Exists(path) ? new FileInfo(path).Length : 0;
        static int Count(string path) => Directory.Exists(path) ? Directory.EnumerateFileSystemEntries(path).Take(100_001).Count() : 0;
        return string.Join(Environment.NewLine,
        [
            $"Clipboard History database bytes: {Size(AppPaths.HistoryDatabaseFile)}",
            $"Capture entries: {Count(AppPaths.Captures)}",
            $"Managed clipboard entries: {Count(AppPaths.ClipboardFiles)}",
            $"Thumbnail entries: {Count(AppPaths.Thumbnails)}"
        ]);
    }

    private static void AddText(ZipArchive archive, string name, string content)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(content);
    }

    private static void AddFileIfPresent(ZipArchive archive, string path, string name)
    {
        if (!File.Exists(path)) return;
        archive.CreateEntryFromFile(path, name, CompressionLevel.Optimal);
    }
}
