using System.Runtime.InteropServices;
using System.Text.Json;
using NAudio.Wave;

namespace ShotPaste.Windows.Services;

/// <summary>Preserves explicit screen-capture consent until the durable cloud queue acknowledges it.</summary>
internal static class ScreenRecordingTranscriptionReceipts
{
    private sealed record Receipt(string RecordingPath, string ProtectedConfiguration);
    private static string Root => Path.Combine(AppPaths.Root, "ScreenRecordingTranscription");
    private static string FilePath(string recordingPath) => Path.Combine(Root,
        VolcengineTosSigner.Hash(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(recordingPath).ToUpperInvariant())) + ".json");
    internal static void Begin(string recordingPath, RecordingTranscriptionConfiguration? configuration)
    {
        if (configuration is null) return;
        Directory.CreateDirectory(Root);
        var path = FilePath(recordingPath);
        var receipt = new Receipt(Path.GetFullPath(recordingPath), RecordingTranscriptionCredentialProtector.ProtectSnapshot(configuration));
        using (var stream = new FileStream(path + ".tmp", FileMode.Create, FileAccess.Write, FileShare.None))
        { JsonSerializer.Serialize(stream, receipt); stream.Flush(flushToDisk: true); }
        File.Move(path + ".tmp", path, true);
    }
    internal static void Acknowledge(string recordingPath)
    {
        try { File.Delete(FilePath(recordingPath)); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    internal static void Cancel(string recordingPath)
    {
        // Discard consent must reach disk before a capture can be stopped or restarted.
        var path = FilePath(recordingPath);
        if (File.Exists(path)) File.Delete(path);
    }
    internal static async Task ResumeAsync()
    {
        if (!Directory.Exists(Root)) return;
        foreach (var path in Directory.EnumerateFiles(Root, "*.json"))
        {
            try
            {
                if (new FileInfo(path).Length > 131_072) continue;
                var receipt = JsonSerializer.Deserialize<Receipt>(await File.ReadAllTextAsync(path));
                if (receipt is null || path != FilePath(receipt.RecordingPath) || !File.Exists(receipt.RecordingPath)) continue;
                // A valid audio stream is required; corrupt/incomplete local files remain available for recovery.
                await Task.Run(() => { using var reader = new MediaFoundationReader(receipt.RecordingPath); if (reader.TotalTime <= TimeSpan.Zero) throw new InvalidDataException(); });
                var config = RecordingTranscriptionCredentialProtector.UnprotectSnapshot(receipt.ProtectedConfiguration);
                RecordingTranscriptionJobs.Shared.Start(receipt.RecordingPath, config);
                Acknowledge(receipt.RecordingPath);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or
                System.Security.Cryptography.CryptographicException or FormatException or InvalidOperationException or NotSupportedException or COMException or RecordingTranscriptionException)
            { /* Retain the original receipt; never substitute current account credentials. */ }
        }
    }
}
