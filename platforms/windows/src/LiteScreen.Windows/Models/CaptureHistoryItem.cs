using System.Text.Json.Serialization;
using System.Windows.Media.Imaging;
using LiteScreen.Windows.Utilities;
using LiteScreen.Windows.Services;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace LiteScreen.Windows.Models;

public sealed class CaptureHistoryItem : INotifyPropertyChanged
{
    private static readonly SemaphoreSlim PreviewDecodeGate = new(4, 4);
    private int _previewLoadState;
    private bool _previewUnavailable;
    public Guid Id { get; init; } = Guid.NewGuid();
    public CaptureKind Kind { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.Now;
    public string? FilePath { get; init; }
    public IReadOnlyList<string> FilePaths { get; init; } = [];
    public string? ThumbnailPath { get; init; }
    public string? Text { get; init; }
    public string? TextStoragePath { get; init; }
    public int TextLength { get; init; }
    public bool TextIsTruncated { get; init; }
    public string? PreviewError { get; init; }
    public long SizeBytes { get; init; }
    public int PixelWidth { get; init; }
    public int PixelHeight { get; init; }
    public TimeSpan? Duration { get; init; }
    public bool IsPinned { get; set; }
    public string? ContentHash { get; init; }

    [JsonIgnore]
    public IReadOnlyList<string> ExistingFilePaths => FilePaths.Count > 0
        ? FilePaths.Where(path => File.Exists(path) || Directory.Exists(path)).ToArray()
        : !string.IsNullOrWhiteSpace(FilePath) && (File.Exists(FilePath) || Directory.Exists(FilePath))
            ? [FilePath]
            : [];

    [JsonIgnore]
    public string Title => Kind switch
    {
        CaptureKind.Screenshot => LocalizationService.TranslatePhrase("截图"),
        CaptureKind.ScrollingScreenshot => LocalizationService.TranslatePhrase("滚动截屏"),
        CaptureKind.Recording => LocalizationService.TranslatePhrase("录屏"),
        CaptureKind.Gif => "GIF",
        CaptureKind.ClipboardImage => LocalizationService.TranslatePhrase("剪贴板图片"),
        CaptureKind.ClipboardText => LocalizationService.TranslatePhrase("剪贴板文本"),
        CaptureKind.ClipboardFile => LocalizationService.TranslatePhrase("剪贴板文件"),
        CaptureKind.ClipboardGif => LocalizationService.TranslatePhrase("剪贴板 GIF"),
        CaptureKind.ClipboardVideo => LocalizationService.TranslatePhrase("剪贴板视频"),
        _ => LocalizationService.TranslatePhrase("记录")
    };

    [JsonIgnore]
    public string Subtitle => CreatedAt.LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss");

    [JsonIgnore]
    public string PreviewText => !string.IsNullOrWhiteSpace(Text)
        ? Text.Length > 160 ? Text[..160] + "…" : Text
        : !string.IsNullOrWhiteSpace(PreviewError) ? PreviewError : Title;

    [JsonIgnore]
    public bool HasStoredFullText => !string.IsNullOrWhiteSpace(TextStoragePath);

    [JsonIgnore]
    public BitmapImage? PreviewSource
    {
        get
        {
            var path = PreviewPath;
            if (!string.IsNullOrWhiteSpace(path) && HistoryThumbnailCache.Shared.TryGet(path, out var cached))
                return cached;
            if (_previewUnavailable) return null;
            // A completed item may have been evicted from the shared bounded cache.
            // Let it decode again when it next becomes visible instead of leaving a
            // permanently blank card after cache pressure.
            if (Volatile.Read(ref _previewLoadState) == 2)
                Interlocked.CompareExchange(ref _previewLoadState, 0, 2);
            if (Interlocked.CompareExchange(ref _previewLoadState, 1, 0) == 0) _ = LoadPreviewAsync();
            return null;
        }
    }

    private string? PreviewPath => ThumbnailPath ??
        (Kind is not (CaptureKind.Recording or CaptureKind.ClipboardVideo) ? FilePath : null);

    public event PropertyChangedEventHandler? PropertyChanged;

    private async Task LoadPreviewAsync()
    {
        var path = PreviewPath;
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            _previewUnavailable = true;
            Interlocked.Exchange(ref _previewLoadState, 2);
            return;
        }
        await PreviewDecodeGate.WaitAsync();
        try
        {
            if (HistoryThumbnailCache.Shared.TryGet(path, out _))
            {
                NotifyPreviewChanged();
                return;
            }
            var preview = await Task.Run(() => BitmapSourceFactory.FromPath(path, 360));
            var dispatcher = System.Windows.Application.Current?.Dispatcher;
            if (preview is null) _previewUnavailable = true;
            else HistoryThumbnailCache.Shared.Add(path, preview);
            if (dispatcher is null || dispatcher.CheckAccess()) NotifyPreviewChanged();
            else await dispatcher.InvokeAsync(NotifyPreviewChanged);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            _previewUnavailable = true;
            Interlocked.Exchange(ref _previewLoadState, 2);
        }
        finally { PreviewDecodeGate.Release(); }
    }

    private void NotifyPreviewChanged()
    {
        Interlocked.Exchange(ref _previewLoadState, 2);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(PreviewSource)));
    }

    public async Task<HistoryTextLoadResult> LoadFullTextAsync(int maximumCharacters = 16_000_000)
    {
        maximumCharacters = Math.Clamp(maximumCharacters, 1024, 32_000_000);
        if (string.IsNullOrWhiteSpace(TextStoragePath))
        {
            return TextIsTruncated
                ? new HistoryTextLoadResult(null, LocalizationService.TranslatePhrase("完整文本超过保留上限，剪贴板历史中仅保存了预览。"), true)
                : new HistoryTextLoadResult(Text ?? string.Empty, null, false);
        }
        if (!File.Exists(TextStoragePath))
            return new HistoryTextLoadResult(null, LocalizationService.TranslatePhrase("完整文本文件已丢失或不可访问。"), true);
        try
        {
            using var reader = new StreamReader(TextStoragePath, detectEncodingFromByteOrderMarks: true);
            var builder = new System.Text.StringBuilder(Math.Min(maximumCharacters, Math.Max(1024, TextLength)));
            var buffer = new char[8192];
            while (builder.Length <= maximumCharacters)
            {
                var read = await reader.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, maximumCharacters + 1 - builder.Length)));
                if (read == 0) return new HistoryTextLoadResult(builder.ToString(), null, false);
                builder.Append(buffer, 0, read);
            }
            return new HistoryTextLoadResult(builder.ToString(0, maximumCharacters),
                LocalizationService.TranslatePhrase("完整文本超过查看上限，已停止加载。"), true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return new HistoryTextLoadResult(null,
                LocalizationService.TranslatePhrase("无法读取完整文本：") + exception.Message, true);
        }
    }
}

public sealed record HistoryTextLoadResult(string? Text, string? Error, bool IsLimited);
