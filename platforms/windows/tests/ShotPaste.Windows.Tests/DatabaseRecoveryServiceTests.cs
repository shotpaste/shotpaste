using Microsoft.Data.Sqlite;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class DatabaseRecoveryServiceTests
{
    [Fact]
    public async Task CorruptDatabase_CanBeArchivedAndReplacedWithoutTouchingCaptureFiles()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.sqlite3");
        var capture = Path.Combine(root, "keep-capture.png");
        await File.WriteAllBytesAsync(database, "not a sqlite database"u8.ToArray());
        await File.WriteAllTextAsync(capture, "keep");
        try
        {
            var broken = new CaptureHistoryStore(database, Path.Combine(root, "Thumbnails"));
            await Assert.ThrowsAsync<SqliteException>(() => broken.LoadAsync());
            await File.WriteAllTextAsync(database + "-wal", "wal");
            await File.WriteAllTextAsync(database + "-shm", "shm");

            var archive = DatabaseRecoveryService.ArchiveDatabaseFiles(
                database, new DateTimeOffset(2026, 8, 14, 12, 34, 56, TimeSpan.Zero));

            Assert.False(archive.IsEmpty);
            Assert.NotNull(archive.ArchiveDirectory);
            Assert.Equal(3, archive.ArchivedFiles.Count);
            Assert.All(archive.ArchivedFiles, path => Assert.True(File.Exists(path), path));
            Assert.False(File.Exists(database));
            Assert.True(File.Exists(capture));

            var fresh = new CaptureHistoryStore(database, Path.Combine(root, "Thumbnails"));
            await fresh.LoadAsync();
            Assert.Empty(fresh.Items);
            Assert.True(File.Exists(database));
            Assert.True(File.Exists(capture));
        }
        finally
        {
            await DeleteRootAsync(root);
        }
    }

    [Fact]
    public void ArchiveDatabaseFiles_UsesUniqueRecoveryDirectoriesAndLeavesUnrelatedFilesAlone()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.sqlite3");
        var unrelated = Path.Combine(root, "capture.mp4");
        File.WriteAllText(database, "first");
        File.WriteAllText(unrelated, "recording");
        var timestamp = new DateTimeOffset(2026, 8, 14, 12, 34, 56, TimeSpan.Zero);
        try
        {
            var first = DatabaseRecoveryService.ArchiveDatabaseFiles(database, timestamp);
            File.WriteAllText(database, "second");
            var second = DatabaseRecoveryService.ArchiveDatabaseFiles(database, timestamp);

            Assert.NotEqual(first.ArchiveDirectory, second.ArchiveDirectory);
            Assert.EndsWith("DatabaseRecovery-20260814-123456", first.ArchiveDirectory, StringComparison.Ordinal);
            Assert.EndsWith("DatabaseRecovery-20260814-123456-2", second.ArchiveDirectory, StringComparison.Ordinal);
            Assert.True(File.Exists(unrelated));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(typeof(SqliteException), true)]
    [InlineData(typeof(IOException), true)]
    [InlineData(typeof(UnauthorizedAccessException), true)]
    [InlineData(typeof(InvalidOperationException), false)]
    public void RecoverableFailureClassification_IsNarrow(Type exceptionType, bool expected)
    {
        Exception exception = exceptionType == typeof(SqliteException)
            ? new SqliteException("broken", 11)
            : (Exception)Activator.CreateInstance(exceptionType, "failure")!;

        Assert.Equal(expected, DatabaseRecoveryService.IsRecoverableLaunchFailure(exception));
    }

    private static string CreateRoot()
    {
        var path = Path.Combine(Path.GetTempPath(), "ShotPasteDatabaseRecoveryTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static async Task DeleteRootAsync(string root)
    {
        for (var attempt = 0; attempt < 8; attempt++)
        {
            SqliteConnection.ClearAllPools();
            GC.Collect();
            GC.WaitForPendingFinalizers();
            try
            {
                Directory.Delete(root, true);
                return;
            }
            catch (IOException) when (attempt < 7)
            {
                await Task.Delay(50);
            }
        }
    }
}
