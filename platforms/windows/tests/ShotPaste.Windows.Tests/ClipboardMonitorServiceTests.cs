using System.Text;
using System.Windows;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Models;
using Microsoft.Data.Sqlite;

namespace ShotPaste.Windows.Tests;

public sealed class ClipboardMonitorServiceTests
{
    [Fact]
    public void ShouldIgnoreClipboardData_RespectsWindowsPrivacyFormats()
    {
        var excluded = new DataObject();
        excluded.SetData(ClipboardMonitorService.ExcludeFromMonitorFormat, new byte[] { 1 });
        Assert.True(ClipboardMonitorService.ShouldIgnoreClipboardData(excluded));

        var historyDisabled = new DataObject();
        historyDisabled.SetData(ClipboardMonitorService.CanIncludeInHistoryFormat, BitConverter.GetBytes(0u));
        Assert.True(ClipboardMonitorService.ShouldIgnoreClipboardData(historyDisabled));

        var historyEnabled = new DataObject();
        historyEnabled.SetData(ClipboardMonitorService.CanIncludeInHistoryFormat, BitConverter.GetBytes(1u));
        Assert.False(ClipboardMonitorService.ShouldIgnoreClipboardData(historyEnabled));
    }

    [Fact]
    public void ComputeHash_IsStableAndContentSensitive()
    {
        var first = ClipboardMonitorService.ComputeHash("image", Encoding.UTF8.GetBytes("same"));
        var second = ClipboardMonitorService.ComputeHash("image", Encoding.UTF8.GetBytes("same"));
        var different = ClipboardMonitorService.ComputeHash("image", Encoding.UTF8.GetBytes("different"));

        Assert.Equal(first, second);
        Assert.NotEqual(first, different);
        Assert.Equal(64, first.Length);
    }

    [Fact]
    public async Task PersistFilesAsync_CopiesEveryFileAndDirectoryIntoManagedStorage()
    {
        var root = Path.Combine(Path.GetTempPath(), "ShotPasteClipboardTests", Guid.NewGuid().ToString("N"));
        var source = Path.Combine(root, "source");
        var managed = Path.Combine(root, "managed");
        Directory.CreateDirectory(source);
        var file = Path.Combine(source, "first.txt");
        await File.WriteAllTextAsync(file, "first");
        var folder = Path.Combine(source, "folder");
        Directory.CreateDirectory(folder);
        await File.WriteAllTextAsync(Path.Combine(folder, "nested.txt"), "nested");

        try
        {
            var persisted = await ClipboardMonitorService.PersistFilesAsync([file, folder], managed);

            Assert.Equal(2, persisted.Count);
            Assert.All(persisted, path => Assert.StartsWith(Path.GetFullPath(managed), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase));
            Assert.Equal("first", await File.ReadAllTextAsync(persisted[0]));
            Assert.Equal("nested", await File.ReadAllTextAsync(Path.Combine(persisted[1], "nested.txt")));

            File.Delete(file);
            Directory.Delete(folder, true);
            Assert.All(persisted, path => Assert.True(File.Exists(path) || Directory.Exists(path)));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public async Task ComputeFilesHashAsync_DeduplicatesSameContentsAcrossLocations()
    {
        var root = Path.Combine(Path.GetTempPath(), "ShotPasteClipboardHashTests", Guid.NewGuid().ToString("N"));
        var first = Path.Combine(root, "a", "note.txt");
        var second = Path.Combine(root, "b", "note.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(first)!);
        Directory.CreateDirectory(Path.GetDirectoryName(second)!);
        await File.WriteAllTextAsync(first, "persistent clipboard");
        await File.WriteAllTextAsync(second, "persistent clipboard");
        try
        {
            Assert.Equal(
                await ClipboardMonitorService.ComputeFilesHashAsync([first]),
                await ClipboardMonitorService.ComputeFilesHashAsync([second]));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Theory]
    [InlineData("photo.png", CaptureKind.ClipboardImage)]
    [InlineData("animation.GIF", CaptureKind.ClipboardGif)]
    [InlineData("clip.mp4", CaptureKind.ClipboardVideo)]
    [InlineData("archive.zip", CaptureKind.ClipboardFile)]
    public void Classifier_MapsClipboardFilesToIndependentHistoryKinds(string name, CaptureKind expected)
    {
        Assert.Equal(expected, ClipboardFileClassifier.Classify(name));
    }

    [Fact]
    public async Task CaptureFileDropAsync_CreatesOneTypedRecordPerPathAndDeduplicatesReplay()
    {
        var root = Path.Combine(Path.GetTempPath(), "ShotPasteClipboardMultiTests", Guid.NewGuid().ToString("N"));
        var source = Path.Combine(root, "source");
        var managed = Path.Combine(root, "ClipboardFiles");
        var database = Path.Combine(root, "history.sqlite3");
        Directory.CreateDirectory(source);
        var image = Path.Combine(source, "photo.png");
        using (var bitmap = new System.Drawing.Bitmap(24, 18)) bitmap.Save(image, System.Drawing.Imaging.ImageFormat.Png);
        var gif = Path.Combine(source, "motion.gif");
        using (var bitmap = new System.Drawing.Bitmap(18, 14)) bitmap.Save(gif, System.Drawing.Imaging.ImageFormat.Gif);
        var video = Path.Combine(source, "broken.mp4");
        await File.WriteAllTextAsync(video, "not a video");
        var file = Path.Combine(source, "notes.txt");
        await File.WriteAllTextAsync(file, "ordinary file");
        try
        {
            var store = new CaptureHistoryStore(database, Path.Combine(root, "Thumbnails"));
            await store.LoadAsync();
            var first = await ClipboardMonitorService.CaptureFileDropAsync([image, gif, video, file], store, managed);
            var replay = await ClipboardMonitorService.CaptureFileDropAsync([image, gif, video, file], store, managed);

            Assert.Equal(4, first.Count);
            Assert.Empty(replay);
            Assert.Equal(4, store.Items.Count);
            Assert.Contains(first, item => item.Kind == CaptureKind.ClipboardImage && item.ThumbnailPath is not null);
            Assert.Contains(first, item => item.Kind == CaptureKind.ClipboardGif && item.ThumbnailPath is not null);
            Assert.Contains(first, item => item.Kind == CaptureKind.ClipboardVideo && item.PreviewError is not null);
            Assert.Contains(first, item => item.Kind == CaptureKind.ClipboardFile);
            Assert.All(first, item => Assert.Single(item.FilePaths));
            Assert.Equal(4, first.Select(item => item.ContentHash).Distinct().Count());
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    [Fact]
    public void ComputeTextHash_IsStableWithoutOneLargeUtf8Buffer()
    {
        var text = string.Concat(Enumerable.Repeat("大文本-clipboard-", 20_000));
        Assert.Equal(ClipboardMonitorService.ComputeTextHash(text), ClipboardMonitorService.ComputeTextHash(text));
        Assert.NotEqual(ClipboardMonitorService.ComputeTextHash(text), ClipboardMonitorService.ComputeTextHash(text + "x"));
    }
}
