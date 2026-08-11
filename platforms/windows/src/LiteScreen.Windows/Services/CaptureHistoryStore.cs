using System.Collections.ObjectModel;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using LiteScreen.Windows.Models;
using Drawing = System.Drawing;

namespace LiteScreen.Windows.Services;

/// <summary>
/// SQLite-backed history store. Captures and clipboard records are written as
/// individual rows, so adding or removing one item never rewrites the full history.
/// </summary>
public sealed class CaptureHistoryStore
{
    internal const int TextPreviewCharacterLimit = 8192;
    internal const int FullTextPersistenceCharacterLimit = 16_000_000;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _databasePath;
    private readonly string _thumbnailDirectory;
    private readonly string _clipboardDirectory;

    public CaptureHistoryStore() : this(AppPaths.HistoryDatabaseFile, AppPaths.Thumbnails) { }

    internal CaptureHistoryStore(string databasePath, string thumbnailDirectory)
    {
        _databasePath = databasePath;
        _thumbnailDirectory = thumbnailDirectory;
        _clipboardDirectory = Path.Combine(Path.GetDirectoryName(databasePath) ?? AppPaths.Root, "ClipboardFiles");
    }

    public ObservableCollection<CaptureHistoryItem> Items { get; } = [];
    public event EventHandler<CaptureHistoryItem>? ItemAdded;

    public async Task LoadAsync()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_databasePath) ?? AppPaths.Root);
        Directory.CreateDirectory(_thumbnailDirectory);
        Directory.CreateDirectory(_clipboardDirectory);
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            var records = await ReadAllAsync(connection);

            await InvokeOnUiAsync(() =>
            {
                Items.Clear();
                foreach (var item in records.OrderByDescending(item => item.CreatedAt)) Items.Add(item);
            });
        }
        finally { _gate.Release(); }
    }

    public async Task<CaptureHistoryItem> AddFileAsync(string path, CaptureKind kind, TimeSpan? duration = null, string? contentHash = null)
    {
        var item = await CreateFileItemAsync(path, kind, contentHash, duration: duration);
        await AddAsync(item);
        return item;
    }

    public async Task<CaptureHistoryItem> AddClipboardPathAsync(
        string path,
        string? contentHash = null,
        DateTimeOffset? createdAt = null)
    {
        CaptureHistoryItem item;
        if (File.Exists(path))
        {
            item = await CreateFileItemAsync(path, ClipboardFileClassifier.Classify(path), contentHash, createdAt,
                fileDropSource: true);
        }
        else
        {
            item = new CaptureHistoryItem
            {
                Kind = CaptureKind.ClipboardFile,
                CreatedAt = createdAt ?? DateTimeOffset.Now,
                FilePath = path,
                FilePaths = [path],
                Text = Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)),
                SizeBytes = GetPathSize(path),
                ContentHash = contentHash
            };
        }
        await AddAsync(item);
        return item;
    }

    public async Task AddTextAsync(string text, string? contentHash = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        string? storagePath = null;
        var truncated = text.Length > TextPreviewCharacterLimit;
        var preview = truncated ? text[..TextPreviewCharacterLimit] + "…" : text;
        if (truncated && text.Length <= FullTextPersistenceCharacterLimit)
        {
            Directory.CreateDirectory(_clipboardDirectory);
            storagePath = Path.Combine(_clipboardDirectory, Guid.NewGuid().ToString("N") + ".txt");
            await File.WriteAllTextAsync(storagePath, text);
        }
        await AddAsync(new CaptureHistoryItem
        {
            Kind = CaptureKind.ClipboardText,
            Text = preview,
            TextStoragePath = storagePath,
            TextLength = text.Length,
            TextIsTruncated = truncated,
            SizeBytes = System.Text.Encoding.UTF8.GetByteCount(text),
            ContentHash = contentHash,
            PreviewError = truncated && storagePath is null
                ? LocalizationService.TranslatePhrase("完整文本超过保留上限，剪贴板历史中仅保存了预览。")
                : null
        });
    }

    public async Task AddAsync(CaptureHistoryItem item)
    {
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await UpsertAsync(connection, item);
            await InvokeOnUiAsync(() => Items.Insert(0, item));
        }
        finally { _gate.Release(); }
        ItemAdded?.Invoke(this, item);
    }

    public async Task<bool> ContainsContentHashAsync(string contentHash)
    {
        if (string.IsNullOrWhiteSpace(contentHash)) return false;
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT 1 FROM history_items WHERE content_hash = $content_hash LIMIT 1;";
            command.Parameters.AddWithValue("$content_hash", contentHash);
            return await command.ExecuteScalarAsync() is not null;
        }
        finally { _gate.Release(); }
    }

    public async Task RemoveAsync(CaptureHistoryItem item, bool deleteFile)
    {
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM history_items WHERE id = $id;";
            command.Parameters.AddWithValue("$id", item.Id.ToString("D"));
            await command.ExecuteNonQueryAsync();
            await InvokeOnUiAsync(() => Items.Remove(item));
        }
        finally { _gate.Release(); }

        if (deleteFile && IsManagedClipboardItem(item))
        {
            foreach (var path in ClipboardPaths(item))
                TryDeleteManagedClipboardPath(path);
            TryDeleteManagedClipboardPath(item.TextStoragePath);
            TryDelete(item.ThumbnailPath);
        }
        else if (deleteFile)
        {
            TryDelete(item.FilePath);
            TryDelete(item.ThumbnailPath);
        }
    }

    public async Task PruneAsync(int retentionDays, int maxCount = 0)
    {
        var expired = new HashSet<CaptureHistoryItem>();
        if (retentionDays > 0)
        {
            var threshold = DateTimeOffset.Now.AddDays(-retentionDays);
            foreach (var item in Items.Where(item => !item.IsPinned && item.CreatedAt < threshold)) expired.Add(item);
        }
        if (maxCount > 0)
        {
            foreach (var item in Items.Where(item => !item.IsPinned).OrderByDescending(item => item.CreatedAt).Skip(maxCount))
                expired.Add(item);
        }
        foreach (var item in expired) await RemoveAsync(item, true);
    }

    public async Task ClearAsync()
    {
        var snapshot = Items.ToArray();
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM history_items;";
            await command.ExecuteNonQueryAsync();
            await InvokeOnUiAsync(Items.Clear);
        }
        finally { _gate.Release(); }
        foreach (var item in snapshot)
        {
            TryDelete(item.ThumbnailPath);
            if (IsManagedClipboardItem(item))
            {
                foreach (var path in ClipboardPaths(item))
                    TryDeleteManagedClipboardPath(path);
                TryDeleteManagedClipboardPath(item.TextStoragePath);
            }
        }
    }

    /// <summary>
    /// Persists mutable fields such as IsPinned without replacing the database.
    /// Existing callers can keep using this compatibility method.
    /// </summary>
    public async Task SaveAsync()
    {
        var snapshot = await InvokeOnUiAsync(() => Items.ToArray());
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await using var transaction = connection.BeginTransaction();
            foreach (var item in snapshot) await UpsertAsync(connection, item, transaction);
            await transaction.CommitAsync();
        }
        finally { _gate.Release(); }
    }

    public async Task UpdatePinnedAsync(CaptureHistoryItem item, bool isPinned)
    {
        item.IsPinned = isPinned;
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE history_items SET is_pinned = $is_pinned WHERE id = $id;";
            command.Parameters.AddWithValue("$is_pinned", isPinned ? 1 : 0);
            command.Parameters.AddWithValue("$id", item.Id.ToString("D"));
            await command.ExecuteNonQueryAsync();
        }
        finally { _gate.Release(); }
    }

    public async Task ClearSessionPinnedStateAsync()
    {
        await _gate.WaitAsync();
        try
        {
            await using var connection = await OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE history_items SET is_pinned = 0 WHERE is_pinned <> 0;";
            await command.ExecuteNonQueryAsync();
            await InvokeOnUiAsync(() =>
            {
                foreach (var item in Items.Where(item => item.IsPinned)) item.IsPinned = false;
            });
        }
        finally { _gate.Release(); }
    }

    private async Task<SqliteConnection> OpenConnectionAsync()
    {
        var connection = new SqliteConnection($"Data Source={_databasePath};Mode=ReadWriteCreate;Cache=Shared");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS history_items (
                id TEXT PRIMARY KEY,
                kind INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                file_path TEXT NULL,
                thumbnail_path TEXT NULL,
                text_value TEXT NULL,
                size_bytes INTEGER NOT NULL,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                duration_ticks INTEGER NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                file_paths_json TEXT NULL,
                content_hash TEXT NULL,
                text_storage_path TEXT NULL,
                text_length INTEGER NOT NULL DEFAULT 0,
                text_is_truncated INTEGER NOT NULL DEFAULT 0,
                preview_error TEXT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_history_created_at ON history_items(created_at DESC);
            """;
        await command.ExecuteNonQueryAsync();
        await EnsureColumnAsync(connection, "file_paths_json", "TEXT NULL");
        await EnsureColumnAsync(connection, "content_hash", "TEXT NULL");
        await EnsureColumnAsync(connection, "text_storage_path", "TEXT NULL");
        await EnsureColumnAsync(connection, "text_length", "INTEGER NOT NULL DEFAULT 0");
        await EnsureColumnAsync(connection, "text_is_truncated", "INTEGER NOT NULL DEFAULT 0");
        await EnsureColumnAsync(connection, "preview_error", "TEXT NULL");
        await using var indexCommand = connection.CreateCommand();
        indexCommand.CommandText = "CREATE INDEX IF NOT EXISTS idx_history_content_hash ON history_items(content_hash) WHERE content_hash IS NOT NULL;";
        await indexCommand.ExecuteNonQueryAsync();
        return connection;
    }

    private static async Task EnsureColumnAsync(SqliteConnection connection, string name, string declaration)
    {
        await using var query = connection.CreateCommand();
        query.CommandText = "PRAGMA table_info(history_items);";
        await using var reader = await query.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            if (string.Equals(reader.GetString(1), name, StringComparison.OrdinalIgnoreCase)) return;
        }
        await reader.DisposeAsync();
        await using var alter = connection.CreateCommand();
        alter.CommandText = $"ALTER TABLE history_items ADD COLUMN {name} {declaration};";
        await alter.ExecuteNonQueryAsync();
    }

    private static async Task<List<CaptureHistoryItem>> ReadAllAsync(SqliteConnection connection)
    {
        var result = new List<CaptureHistoryItem>();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT id, kind, created_at, file_path, thumbnail_path, text_value, size_bytes, pixel_width, pixel_height, duration_ticks, is_pinned, file_paths_json, content_hash, text_storage_path, text_length, text_is_truncated, preview_error FROM history_items ORDER BY created_at DESC;";
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync()) result.Add(ReadItem(reader));
        return result;
    }

    private static CaptureHistoryItem ReadItem(SqliteDataReader reader)
    {
        var id = Guid.TryParse(reader.GetString(0), out var parsedId) ? parsedId : Guid.NewGuid();
        var createdAt = DateTimeOffset.TryParse(reader.GetString(2), out var parsedCreatedAt) ? parsedCreatedAt : DateTimeOffset.Now;
        var durationTicks = reader.IsDBNull(9) ? (long?)null : reader.GetInt64(9);
        var filePaths = reader.IsDBNull(11)
            ? []
            : JsonSerializer.Deserialize<string[]>(reader.GetString(11)) ?? [];
        return new CaptureHistoryItem
        {
            Id = id,
            Kind = (CaptureKind)reader.GetInt32(1),
            CreatedAt = createdAt,
            FilePath = reader.IsDBNull(3) ? null : reader.GetString(3),
            ThumbnailPath = reader.IsDBNull(4) ? null : reader.GetString(4),
            Text = reader.IsDBNull(5) ? null : reader.GetString(5),
            SizeBytes = reader.GetInt64(6),
            PixelWidth = reader.GetInt32(7),
            PixelHeight = reader.GetInt32(8),
            Duration = durationTicks.HasValue ? TimeSpan.FromTicks(durationTicks.Value) : null,
            IsPinned = reader.GetInt32(10) != 0,
            FilePaths = filePaths,
            ContentHash = reader.IsDBNull(12) ? null : reader.GetString(12),
            TextStoragePath = reader.IsDBNull(13) ? null : reader.GetString(13),
            TextLength = reader.IsDBNull(14) ? 0 : reader.GetInt32(14),
            TextIsTruncated = !reader.IsDBNull(15) && reader.GetInt32(15) != 0,
            PreviewError = reader.IsDBNull(16) ? null : reader.GetString(16)
        };
    }

    private static async Task UpsertAsync(SqliteConnection connection, CaptureHistoryItem item, SqliteTransaction? transaction = null)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO history_items (id, kind, created_at, file_path, thumbnail_path, text_value, size_bytes, pixel_width, pixel_height, duration_ticks, is_pinned, file_paths_json, content_hash, text_storage_path, text_length, text_is_truncated, preview_error)
            VALUES ($id, $kind, $created_at, $file_path, $thumbnail_path, $text_value, $size_bytes, $pixel_width, $pixel_height, $duration_ticks, $is_pinned, $file_paths_json, $content_hash, $text_storage_path, $text_length, $text_is_truncated, $preview_error)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                created_at = excluded.created_at,
                file_path = excluded.file_path,
                thumbnail_path = excluded.thumbnail_path,
                text_value = excluded.text_value,
                size_bytes = excluded.size_bytes,
                pixel_width = excluded.pixel_width,
                pixel_height = excluded.pixel_height,
                duration_ticks = excluded.duration_ticks,
                is_pinned = excluded.is_pinned,
                file_paths_json = excluded.file_paths_json,
                content_hash = excluded.content_hash,
                text_storage_path = excluded.text_storage_path,
                text_length = excluded.text_length,
                text_is_truncated = excluded.text_is_truncated,
                preview_error = excluded.preview_error;
            """;
        command.Parameters.AddWithValue("$id", item.Id.ToString("D"));
        command.Parameters.AddWithValue("$kind", (int)item.Kind);
        command.Parameters.AddWithValue("$created_at", item.CreatedAt.ToString("O"));
        command.Parameters.AddWithValue("$file_path", (object?)item.FilePath ?? DBNull.Value);
        command.Parameters.AddWithValue("$thumbnail_path", (object?)item.ThumbnailPath ?? DBNull.Value);
        command.Parameters.AddWithValue("$text_value", (object?)item.Text ?? DBNull.Value);
        command.Parameters.AddWithValue("$size_bytes", item.SizeBytes);
        command.Parameters.AddWithValue("$pixel_width", item.PixelWidth);
        command.Parameters.AddWithValue("$pixel_height", item.PixelHeight);
        command.Parameters.AddWithValue("$duration_ticks", item.Duration?.Ticks is { } ticks ? ticks : DBNull.Value);
        command.Parameters.AddWithValue("$is_pinned", item.IsPinned ? 1 : 0);
        command.Parameters.AddWithValue("$file_paths_json", item.FilePaths.Count > 0 ? JsonSerializer.Serialize(item.FilePaths) : DBNull.Value);
        command.Parameters.AddWithValue("$content_hash", (object?)item.ContentHash ?? DBNull.Value);
        command.Parameters.AddWithValue("$text_storage_path", (object?)item.TextStoragePath ?? DBNull.Value);
        command.Parameters.AddWithValue("$text_length", item.TextLength);
        command.Parameters.AddWithValue("$text_is_truncated", item.TextIsTruncated ? 1 : 0);
        command.Parameters.AddWithValue("$preview_error", (object?)item.PreviewError ?? DBNull.Value);
        await command.ExecuteNonQueryAsync();
    }

    private static Task InvokeOnUiAsync(Action action)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            action();
            return Task.CompletedTask;
        }
        return dispatcher.InvokeAsync(action).Task;
    }

    private static async Task<T> InvokeOnUiAsync<T>(Func<T> function)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) return function();
        return await dispatcher.InvokeAsync(function);
    }

    private async Task<CaptureHistoryItem> CreateFileItemAsync(
        string path,
        CaptureKind kind,
        string? contentHash,
        DateTimeOffset? createdAt = null,
        TimeSpan? duration = null,
        Guid? id = null,
        bool isPinned = false,
        bool fileDropSource = false)
    {
        var info = new FileInfo(path);
        var width = 0;
        var height = 0;
        string? thumbnail = null;
        string? previewError = null;
        if (info.Exists && kind is CaptureKind.Recording or CaptureKind.ClipboardVideo)
        {
            var media = await MediaThumbnailService.CreateAsync(path, _thumbnailDirectory);
            width = media.PixelWidth;
            height = media.PixelHeight;
            thumbnail = media.ThumbnailPath;
            duration ??= media.Duration;
            previewError = media.Error;
        }
        else if (info.Exists && kind is not CaptureKind.ClipboardFile)
        {
            try
            {
                using var image = Drawing.Image.FromFile(path);
                width = image.Width;
                height = image.Height;
                thumbnail = await CreateThumbnailAsync(image);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or OutOfMemoryException)
            {
                previewError = LocalizationService.TranslatePhrase("图片预览不可用：") + exception.Message;
            }
        }
        return new CaptureHistoryItem
        {
            Id = id ?? Guid.NewGuid(),
            Kind = kind,
            CreatedAt = createdAt ?? DateTimeOffset.Now,
            FilePath = path,
            FilePaths = fileDropSource ? [path] : [],
            ThumbnailPath = thumbnail,
            Text = fileDropSource ? Path.GetFileName(path) : null,
            SizeBytes = info.Exists ? info.Length : 0,
            PixelWidth = width,
            PixelHeight = height,
            Duration = duration,
            ContentHash = contentHash,
            PreviewError = previewError,
            IsPinned = isPinned
        };
    }

    private async Task<string> CreateThumbnailAsync(Drawing.Image image)
    {
        var id = Guid.NewGuid().ToString("N") + ".jpg";
        var path = Path.Combine(_thumbnailDirectory, id);
        await Task.Run(() =>
        {
            var ratio = Math.Min(320d / image.Width, 220d / image.Height);
            var width = Math.Max(1, (int)(image.Width * ratio));
            var height = Math.Max(1, (int)(image.Height * ratio));
            using var thumb = new Drawing.Bitmap(width, height);
            using var graphics = Drawing.Graphics.FromImage(thumb);
            graphics.InterpolationMode = Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(image, 0, 0, width, height);
            thumb.Save(path, Drawing.Imaging.ImageFormat.Jpeg);
        });
        return path;
    }

    private static void TryDelete(string? path)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
            HistoryThumbnailCache.Shared.Remove(path);
            File.Delete(path);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void TryDeleteManagedClipboardPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        var managedRoot = Path.GetFullPath(_clipboardDirectory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var fullPath = Path.GetFullPath(path);
        if (!fullPath.StartsWith(managedRoot, StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            if (File.Exists(fullPath)) File.Delete(fullPath);
            else if (Directory.Exists(fullPath)) Directory.Delete(fullPath, true);
            var parent = Path.GetDirectoryName(fullPath);
            if (!string.IsNullOrWhiteSpace(parent) && Directory.Exists(parent) && !Directory.EnumerateFileSystemEntries(parent).Any())
                Directory.Delete(parent);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static IEnumerable<string> ClipboardPaths(CaptureHistoryItem item) => item.FilePaths.Count > 0
        ? item.FilePaths
        : item.FilePath is null ? Array.Empty<string>() : [item.FilePath];

    private static bool IsManagedClipboardItem(CaptureHistoryItem item) =>
        item.FilePaths.Count > 0 || item.Kind is CaptureKind.ClipboardFile or CaptureKind.ClipboardGif or
            CaptureKind.ClipboardVideo or CaptureKind.ClipboardText;

    private static long GetPathSize(string path)
    {
        try
        {
            if (File.Exists(path)) return new FileInfo(path).Length;
            if (!Directory.Exists(path)) return 0;
            return Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories)
                .Where(file => (File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0)
                .Sum(file => new FileInfo(file).Length);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return 0; }
    }
}
