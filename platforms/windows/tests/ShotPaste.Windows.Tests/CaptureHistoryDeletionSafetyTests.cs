using Microsoft.Data.Sqlite;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class CaptureHistoryDeletionSafetyTests
{
    [Fact]
    public async Task RemoveAsync_RecycleFailureKeepsDatabaseAndUiRecord()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.db");
        var file = Path.Combine(root, "capture.png");
        await File.WriteAllTextAsync(file, "capture");
        var recycle = new FakeRecoverableFiles(path => new RecoverableFileResult(path, false, false, "locked"));
        try
        {
            var store = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await store.LoadAsync();
            var item = new CaptureHistoryItem { Kind = CaptureKind.Screenshot, FilePath = file };
            await store.AddAsync(item);

            var result = await store.RemoveAsync(item, deleteFile: true);

            Assert.False(result.RecordRemoved);
            Assert.Single(result.Failures);
            Assert.Contains(item, store.Items);
            var reloaded = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await reloaded.LoadAsync();
            Assert.Contains(reloaded.Items, candidate => candidate.Id == item.Id);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task RemoveAsync_RecyclesUserFileBeforeRemovingRecord()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.db");
        var file = Path.Combine(root, "capture.png");
        await File.WriteAllTextAsync(file, "capture");
        CaptureHistoryStore? store = null;
        var recordWasPresentDuringRecycle = false;
        var recycle = new FakeRecoverableFiles(path =>
        {
            recordWasPresentDuringRecycle = store!.Items.Count == 1;
            return new RecoverableFileResult(path, true, false);
        });
        try
        {
            store = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await store.LoadAsync();
            var item = new CaptureHistoryItem { Kind = CaptureKind.Screenshot, FilePath = file };
            await store.AddAsync(item);

            var result = await store.RemoveAsync(item, deleteFile: true);

            Assert.True(recordWasPresentDuringRecycle);
            Assert.True(result.RecordRemoved);
            Assert.Empty(store.Items);
            Assert.Equal(Path.GetFullPath(file), Assert.Single(recycle.Paths));
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task RemoveAsync_NeverDeletesOriginalClipboardFileDrop()
    {
        var root = CreateRoot();
        var externalRoot = CreateRoot();
        var database = Path.Combine(root, "history.db");
        var original = Path.Combine(externalRoot, "original.txt");
        await File.WriteAllTextAsync(original, "keep me");
        var recycle = new FakeRecoverableFiles(path => new RecoverableFileResult(path, true, false));
        try
        {
            var store = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await store.LoadAsync();
            var item = new CaptureHistoryItem
            {
                Kind = CaptureKind.ClipboardFile,
                FilePath = original,
                FilePaths = [original]
            };
            await store.AddAsync(item);

            var result = await store.RemoveAsync(item, deleteFile: true);

            Assert.True(result.RecordRemoved);
            Assert.Empty(recycle.Paths);
            Assert.True(File.Exists(original));
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, true);
            Directory.Delete(externalRoot, true);
        }
    }

    [Fact]
    public async Task RemoveAsync_DatabasePreflightFailureDoesNotTouchUserFile()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.db");
        var file = Path.Combine(root, "capture.png");
        await File.WriteAllTextAsync(file, "capture");
        var recycle = new FakeRecoverableFiles(path => new RecoverableFileResult(path, true, false));
        try
        {
            var store = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await store.LoadAsync();
            var item = new CaptureHistoryItem { Kind = CaptureKind.Screenshot, FilePath = file };
            await store.AddAsync(item);

            SqliteConnection.ClearAllPools();
            File.Delete(database);
            Directory.CreateDirectory(database);

            var result = await store.RemoveAsync(item, deleteFile: true);

            Assert.False(result.RecordRemoved);
            Assert.Single(result.Failures);
            Assert.Empty(recycle.Paths);
            Assert.True(File.Exists(file));
            Assert.Contains(item, store.Items);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task RemoveAsync_MissingFileStillRemovesDatabaseRecord()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.db");
        var missing = Path.Combine(root, "already-missing.png");
        var recycle = new FakeRecoverableFiles(path => new RecoverableFileResult(path, true, true));
        try
        {
            var store = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await store.LoadAsync();
            var item = new CaptureHistoryItem { Kind = CaptureKind.Screenshot, FilePath = missing };
            await store.AddAsync(item);

            var result = await store.RemoveAsync(item, deleteFile: true);

            Assert.True(result.RecordRemoved);
            Assert.Empty(result.Failures);
            Assert.Empty(store.Items);
            Assert.Equal(Path.GetFullPath(missing), Assert.Single(recycle.Paths));
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task RemoveAsync_MixedRecycleFailureKeepsRecordAndCanBeRetried()
    {
        var root = CreateRoot();
        var database = Path.Combine(root, "history.db");
        var managedRoot = Path.Combine(root, "ClipboardFiles", "set");
        Directory.CreateDirectory(managedRoot);
        var first = Path.Combine(managedRoot, "first.txt");
        var second = Path.Combine(managedRoot, "second.txt");
        await File.WriteAllTextAsync(first, "first");
        await File.WriteAllTextAsync(second, "second");
        var failSecond = true;
        var recycle = new FakeRecoverableFiles(path =>
        {
            if (path.Equals(Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase) && failSecond)
                return new RecoverableFileResult(path, false, false, "locked");
            if (File.Exists(path)) File.Delete(path);
            return new RecoverableFileResult(path, true, !File.Exists(path));
        });
        try
        {
            var store = new CaptureHistoryStore(database, Path.Combine(root, "thumbs"), recycle);
            await store.LoadAsync();
            var item = new CaptureHistoryItem
            {
                Kind = CaptureKind.ClipboardFile,
                FilePath = first,
                FilePaths = [first, second]
            };
            await store.AddAsync(item);

            var firstAttempt = await store.RemoveAsync(item, deleteFile: true);

            Assert.False(firstAttempt.RecordRemoved);
            Assert.Single(firstAttempt.Failures);
            Assert.Contains(item, store.Items);
            Assert.False(File.Exists(first));
            Assert.True(File.Exists(second));

            failSecond = false;
            var retry = await store.RemoveAsync(item, deleteFile: true);

            Assert.True(retry.RecordRemoved);
            Assert.Empty(retry.Failures);
            Assert.Empty(store.Items);
            Assert.False(File.Exists(second));
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(root, true);
        }
    }

    private static string CreateRoot()
    {
        var path = Path.Combine(Path.GetTempPath(), "ShotPasteDeletionTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private sealed class FakeRecoverableFiles(
        Func<string, RecoverableFileResult> handler) : IRecoverableFileOperations
    {
        public List<string> Paths { get; } = [];

        public RecoverableFileResult MoveToRecycleBin(string path)
        {
            var fullPath = Path.GetFullPath(path);
            Paths.Add(fullPath);
            return handler(fullPath);
        }
    }
}
