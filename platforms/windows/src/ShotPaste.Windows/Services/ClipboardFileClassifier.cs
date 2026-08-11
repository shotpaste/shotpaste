using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public static class ClipboardFileClassifier
{
    private static readonly HashSet<string> ImageExtensions =
        new([".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif"], StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> VideoExtensions =
        new([".mp4", ".mov", ".m4v", ".avi", ".wmv", ".mkv", ".webm", ".mpeg", ".mpg"], StringComparer.OrdinalIgnoreCase);

    public static CaptureKind Classify(string path)
    {
        if (Directory.Exists(path)) return CaptureKind.ClipboardFile;
        var extension = Path.GetExtension(path);
        if (extension.Equals(".gif", StringComparison.OrdinalIgnoreCase)) return CaptureKind.ClipboardGif;
        if (ImageExtensions.Contains(extension)) return CaptureKind.ClipboardImage;
        if (VideoExtensions.Contains(extension)) return CaptureKind.ClipboardVideo;
        return CaptureKind.ClipboardFile;
    }

    public static bool IsClipboardKind(CaptureKind kind) => kind is
        CaptureKind.ClipboardImage or CaptureKind.ClipboardText or CaptureKind.ClipboardFile or
        CaptureKind.ClipboardGif or CaptureKind.ClipboardVideo;
}
