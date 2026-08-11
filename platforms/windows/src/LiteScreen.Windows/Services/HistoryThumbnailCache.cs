using System.Windows.Media.Imaging;

namespace LiteScreen.Windows.Services;

public sealed record HistoryThumbnailCacheMetrics(
    int Count,
    long EstimatedBytes,
    long Hits,
    long Misses,
    long Evictions,
    long Invalidations);

/// <summary>
/// Process-wide LRU for history thumbnails. History rows never retain their own
/// bitmap, so recycled views and mode switches share a bounded decode result.
/// </summary>
public sealed class HistoryThumbnailCache
{
    private sealed record Entry(BitmapImage Image, long Cost, DateTime LastWriteUtc, LinkedListNode<string> Node);
    private readonly object _sync = new();
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly LinkedList<string> _lru = new();
    private readonly int _maximumEntries;
    private readonly long _maximumBytes;
    private long _estimatedBytes;
    private long _hits;
    private long _misses;
    private long _evictions;
    private long _invalidations;

    public static HistoryThumbnailCache Shared { get; } = new(96, 64L * 1024 * 1024);

    public HistoryThumbnailCache(int maximumEntries, long maximumBytes)
    {
        _maximumEntries = Math.Clamp(maximumEntries, 1, 4096);
        _maximumBytes = Math.Max(1, maximumBytes);
    }

    public int Count { get { lock (_sync) return _entries.Count; } }
    public long EstimatedBytes { get { lock (_sync) return _estimatedBytes; } }
    public HistoryThumbnailCacheMetrics Metrics
    {
        get
        {
            lock (_sync)
                return new HistoryThumbnailCacheMetrics(
                    _entries.Count,
                    _estimatedBytes,
                    _hits,
                    _misses,
                    _evictions,
                    _invalidations);
        }
    }

    public bool TryGet(string path, out BitmapImage? image)
    {
        image = null;
        var key = Normalize(path);
        lock (_sync)
        {
            if (!_entries.TryGetValue(key, out var entry))
            {
                _misses++;
                return false;
            }
            var lastWrite = GetLastWriteUtc(key);
            if (lastWrite != entry.LastWriteUtc)
            {
                RemoveCore(key, entry);
                _misses++;
                _invalidations++;
                return false;
            }
            _lru.Remove(entry.Node);
            _lru.AddFirst(entry.Node);
            image = entry.Image;
            _hits++;
            return true;
        }
    }

    public void Add(string path, BitmapImage image)
    {
        ArgumentNullException.ThrowIfNull(image);
        var key = Normalize(path);
        var cost = Math.Max(1L, (long)Math.Max(1, image.PixelWidth) * Math.Max(1, image.PixelHeight) * 4L);
        lock (_sync)
        {
            if (_entries.Remove(key, out var existing))
            {
                _lru.Remove(existing.Node);
                _estimatedBytes -= existing.Cost;
            }
            var node = _lru.AddFirst(key);
            _entries[key] = new Entry(image, cost, GetLastWriteUtc(key), node);
            _estimatedBytes += cost;
            while (_entries.Count > _maximumEntries || _estimatedBytes > _maximumBytes)
            {
                var oldest = _lru.Last;
                if (oldest is null) break;
                if (_entries.TryGetValue(oldest.Value, out var entry))
                {
                    RemoveCore(oldest.Value, entry);
                    _evictions++;
                }
                else _lru.RemoveLast();
            }
        }
    }

    public void Remove(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        var key = Normalize(path);
        lock (_sync)
        {
            if (_entries.TryGetValue(key, out var entry)) RemoveCore(key, entry);
        }
    }

    public void Clear()
    {
        lock (_sync)
        {
            _entries.Clear();
            _lru.Clear();
            _estimatedBytes = 0;
        }
    }

    private void RemoveCore(string key, Entry entry)
    {
        _entries.Remove(key);
        _lru.Remove(entry.Node);
        _estimatedBytes = Math.Max(0, _estimatedBytes - entry.Cost);
    }

    private static string Normalize(string path)
    {
        try { return Path.GetFullPath(path); }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException) { return path; }
    }

    private static DateTime GetLastWriteUtc(string path)
    {
        try { return File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue; }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return DateTime.MinValue; }
    }
}
