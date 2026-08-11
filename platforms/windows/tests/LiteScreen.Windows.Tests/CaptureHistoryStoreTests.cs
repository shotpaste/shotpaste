using LiteScreen.Windows.Services;
using Microsoft.Data.Sqlite;

namespace LiteScreen.Windows.Tests;

public sealed class CaptureHistoryStoreTests
{
    [Fact]
    public async Task PinnedStatePersistsAndCanBeClearedForANewSession()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"litescreen-history-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var database = Path.Combine(directory, "history.sqlite3");
        var thumbnails = Path.Combine(directory, "thumbnails");

        try
        {
            var store = new CaptureHistoryStore(database, thumbnails);
            await store.LoadAsync();
            await store.AddTextAsync("pinned item");
            await store.UpdatePinnedAsync(Assert.Single(store.Items), true);

            var reloaded = new CaptureHistoryStore(database, thumbnails);
            await reloaded.LoadAsync();
            Assert.True(Assert.Single(reloaded.Items).IsPinned);

            await reloaded.ClearSessionPinnedStateAsync();
            var afterClear = new CaptureHistoryStore(database, thumbnails);
            await afterClear.LoadAsync();
            Assert.False(Assert.Single(afterClear.Items).IsPinned);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public async Task UpdatePinnedAsync_UpdatesOnlyRequestedRecord()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"litescreen-history-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var database = Path.Combine(directory, "history.sqlite3");
        var thumbnails = Path.Combine(directory, "thumbnails");

        try
        {
            var store = new CaptureHistoryStore(database, thumbnails);
            await store.LoadAsync();
            await store.AddTextAsync("first");
            await store.AddTextAsync("second");
            var target = store.Items[0];
            var untouched = store.Items[1];

            await store.UpdatePinnedAsync(target, true);

            var reloaded = new CaptureHistoryStore(database, thumbnails);
            await reloaded.LoadAsync();
            Assert.True(reloaded.Items.Single(candidate => candidate.Id == target.Id).IsPinned);
            Assert.False(reloaded.Items.Single(candidate => candidate.Id == untouched.Id).IsPinned);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public async Task AddTextAsync_StoresOnlyBoundedPreviewAndLoadsFullTextOnDemand()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"litescreen-history-text-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var database = Path.Combine(directory, "history.sqlite3");
        var thumbnails = Path.Combine(directory, "thumbnails");
        var text = "HEAD-" + new string('文', CaptureHistoryStore.TextPreviewCharacterLimit + 5000) + "-TAIL";

        try
        {
            var store = new CaptureHistoryStore(database, thumbnails);
            await store.LoadAsync();
            await store.AddTextAsync(text, ClipboardMonitorService.ComputeTextHash(text));
            var item = Assert.Single(store.Items);

            Assert.True(item.TextIsTruncated);
            Assert.Equal(text.Length, item.TextLength);
            Assert.True(item.Text!.Length <= CaptureHistoryStore.TextPreviewCharacterLimit + 1);
            Assert.True(File.Exists(item.TextStoragePath));
            var loaded = await item.LoadFullTextAsync();
            Assert.Null(loaded.Error);
            Assert.Equal(text, loaded.Text);

            var reloaded = new CaptureHistoryStore(database, thumbnails);
            await reloaded.LoadAsync();
            var persisted = Assert.Single(reloaded.Items);
            Assert.True(persisted.TextIsTruncated);
            Assert.Equal(text, (await persisted.LoadFullTextAsync()).Text);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, true);
        }
    }
}
