using System.Windows.Media.Imaging;
using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class HistoryThumbnailCacheTests
{
    [Fact]
    public void Cache_IsSharedByPathAndEvictsLeastRecentlyUsedWithinCapacity()
    {
        var root = Path.Combine(Path.GetTempPath(), "LiteScreenThumbnailCache", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var paths = Enumerable.Range(0, 3).Select(index => Path.Combine(root, $"{index}.png")).ToArray();
        foreach (var path in paths) File.WriteAllBytes(path, Convert.FromBase64String(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="));
        try
        {
            var cache = new HistoryThumbnailCache(2, 1024 * 1024);
            cache.Add(paths[0], Load(paths[0]));
            cache.Add(paths[1], Load(paths[1]));
            Assert.True(cache.TryGet(paths[0], out _));
            cache.Add(paths[2], Load(paths[2]));

            Assert.True(cache.TryGet(paths[0], out _));
            Assert.False(cache.TryGet(paths[1], out _));
            Assert.True(cache.TryGet(paths[2], out _));
            Assert.Equal(2, cache.Count);
            Assert.True(cache.Metrics.Hits >= 3);
            Assert.True(cache.Metrics.Misses >= 1);
            Assert.Equal(1, cache.Metrics.Evictions);
        }
        finally { Directory.Delete(root, true); }
    }

    private static BitmapImage Load(string path)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.UriSource = new Uri(path);
        image.EndInit();
        image.Freeze();
        return image;
    }
}
