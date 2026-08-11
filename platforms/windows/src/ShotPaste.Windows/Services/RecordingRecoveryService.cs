using System.Text.Json;
using System.Runtime.InteropServices;
using Drawing = System.Drawing;
using Windows.Media.Editing;
using Windows.Storage;

namespace ShotPaste.Windows.Services;

public sealed record RecoveredRecording(string Path, TimeSpan Duration);
public sealed record RecordingRecoveryScan(RecoveredRecording? Recording, string? Warning);

public static class RecordingRecoveryService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public static void Begin(string outputPath, string? gifDestination, Drawing.Rectangle region)
    {
        try
        {
            AppPaths.EnsureCreated();
            var marker = new RecoveryMarker(outputPath, gifDestination, DateTimeOffset.Now, region.X, region.Y, region.Width, region.Height);
            var temporary = AppPaths.RecordingRecoveryFile + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(marker, JsonOptions));
            File.Move(temporary, AppPaths.RecordingRecoveryFile, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static void Complete()
    {
        try { if (File.Exists(AppPaths.RecordingRecoveryFile)) File.Delete(AppPaths.RecordingRecoveryFile); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static async Task<RecordingRecoveryScan> ScanAsync()
    {
        if (!File.Exists(AppPaths.RecordingRecoveryFile)) return new RecordingRecoveryScan(null, null);
        RecoveryMarker? marker;
        try
        {
            marker = JsonSerializer.Deserialize<RecoveryMarker>(await File.ReadAllTextAsync(AppPaths.RecordingRecoveryFile));
        }
        catch (Exception exception) when (exception is IOException or JsonException)
        {
            ArchiveFailedMarker();
            return new RecordingRecoveryScan(null, "检测到损坏的录屏恢复信息，已保留到诊断目录。");
        }

        if (marker is null || string.IsNullOrWhiteSpace(marker.OutputPath) || !File.Exists(marker.OutputPath))
        {
            ArchiveFailedMarker();
            return new RecordingRecoveryScan(null, "上次录屏未生成可恢复文件，恢复信息已归档。");
        }

        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(marker.OutputPath));
            var clip = await MediaClip.CreateFromFileAsync(file);
            var duration = clip.OriginalDuration;
            if (duration <= TimeSpan.Zero) throw new InvalidDataException("录屏时长无效。");
            Complete();
            return new RecordingRecoveryScan(new RecoveredRecording(marker.OutputPath, duration), null);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or ArgumentException or COMException)
        {
            ArchiveFailedMarker();
            return new RecordingRecoveryScan(null, $"上次录屏文件无法自动恢复：{exception.Message}");
        }
    }

    private static void ArchiveFailedMarker()
    {
        try
        {
            if (!File.Exists(AppPaths.RecordingRecoveryFile)) return;
            var archived = Path.Combine(AppPaths.Root, $"recording-recovery-failed-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.Move(AppPaths.RecordingRecoveryFile, archived, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private sealed record RecoveryMarker(
        string OutputPath,
        string? GifDestination,
        DateTimeOffset StartedAt,
        int X,
        int Y,
        int Width,
        int Height);
}
