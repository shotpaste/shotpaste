using Microsoft.Data.Sqlite;

namespace ShotPaste.Windows.Services;

public sealed record DatabaseRecoveryArchive(string? ArchiveDirectory, IReadOnlyList<string> ArchivedFiles)
{
    public bool IsEmpty => ArchivedFiles.Count == 0;
}

/// <summary>
/// Owns the recoverable launch-time database operations. Reset never deletes
/// capture or managed clipboard content; it only moves SQLite database files
/// into a timestamped recovery directory before a fresh database is created.
/// </summary>
public static class DatabaseRecoveryService
{
    internal static readonly string[] SidecarSuffixes = [string.Empty, "-wal", "-shm"];

    public static bool IsRecoverableLaunchFailure(Exception exception) =>
        exception is SqliteException or IOException or UnauthorizedAccessException;

    public static DatabaseRecoveryArchive ArchiveDatabaseFiles(
        string databasePath,
        DateTimeOffset? timestamp = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        var fullDatabasePath = Path.GetFullPath(databasePath);
        var directory = Path.GetDirectoryName(fullDatabasePath)
            ?? throw new InvalidOperationException("数据库目录不可用。");
        Directory.CreateDirectory(directory);

        // Failed initialization can leave idle pooled handles behind. Release
        // them before moving the database and its WAL/SHM sidecars.
        SqliteConnection.ClearAllPools();

        var existing = SidecarSuffixes
            .Select(suffix => fullDatabasePath + suffix)
            .Where(File.Exists)
            .ToArray();
        if (existing.Length == 0) return new DatabaseRecoveryArchive(null, []);

        var stamp = (timestamp ?? DateTimeOffset.Now).ToString("yyyyMMdd-HHmmss");
        var archiveDirectory = UniqueArchiveDirectory(directory, stamp);
        Directory.CreateDirectory(archiveDirectory);

        var archived = new List<string>(existing.Length);
        try
        {
            foreach (var source in existing)
            {
                var destination = Path.Combine(archiveDirectory, Path.GetFileName(source));
                File.Move(source, destination);
                archived.Add(destination);
            }
        }
        catch
        {
            // Keep the operation recoverable even if one sidecar cannot move:
            // return files already moved to their original location when safe.
            foreach (var destination in archived.AsEnumerable().Reverse())
            {
                var original = Path.Combine(directory, Path.GetFileName(destination));
                try
                {
                    if (!File.Exists(original) && File.Exists(destination))
                        File.Move(destination, original);
                }
                catch (Exception rollbackException) when (rollbackException is IOException or UnauthorizedAccessException)
                {
                    // The archive still preserves the database file. Surface the
                    // original failure to keep the user in the recovery flow.
                }
            }
            try
            {
                if (Directory.Exists(archiveDirectory) && !Directory.EnumerateFileSystemEntries(archiveDirectory).Any())
                    Directory.Delete(archiveDirectory);
            }
            catch (Exception cleanupException) when (cleanupException is IOException or UnauthorizedAccessException) { }
            throw;
        }

        return new DatabaseRecoveryArchive(archiveDirectory, archived);
    }

    private static string UniqueArchiveDirectory(string root, string timestamp)
    {
        var basePath = Path.Combine(root, $"DatabaseRecovery-{timestamp}");
        var candidate = basePath;
        for (var suffix = 2; Directory.Exists(candidate); suffix++)
            candidate = basePath + "-" + suffix;
        return candidate;
    }
}
