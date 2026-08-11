using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public static class CaptureOutputNaming
{
    public static string NewPath(string directory, CaptureKind kind, string extension, string? template = null)
    {
        Directory.CreateDirectory(directory);
        var prefix = kind switch
        {
            CaptureKind.ScrollingScreenshot => "ShotPaste-Scrolling",
            CaptureKind.Recording => "ShotPaste-Recording",
            CaptureKind.Gif => "ShotPaste-GIF",
            CaptureKind.ClipboardImage => "ShotPaste-Clipboard",
            _ => "ShotPaste"
        };
        var now = DateTime.Now;
        var baseName = string.IsNullOrWhiteSpace(template) ? $"{prefix}-{now:yyyy-MM-dd-HHmmss}" : Expand(template, now, kind);
        var parts = baseName.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Where(x => x is not "." and not "..").Select(Sanitize).Where(x => x.Length > 0).ToArray();
        if (parts.Length == 0) parts = [prefix];
        var relative = Path.Combine(parts);
        var folder = Path.Combine(directory, Path.GetDirectoryName(relative) ?? string.Empty);
        Directory.CreateDirectory(folder);
        var stem = Path.GetFileNameWithoutExtension(relative);
        var path = Path.Combine(folder, stem + extension);
        for (var suffix = 2; File.Exists(path); suffix++) path = Path.Combine(folder, $"{stem}_{suffix}{extension}");
        return path;
    }

    private static string Expand(string template, DateTime now, CaptureKind kind) => template
        .Replace("{datetime}", now.ToString("yyyy-MM-dd_HH-mm-ss"), StringComparison.OrdinalIgnoreCase)
        .Replace("{date}", now.ToString("yyyy-MM-dd"), StringComparison.OrdinalIgnoreCase)
        .Replace("{year}", now.ToString("yyyy"), StringComparison.OrdinalIgnoreCase)
        .Replace("{month}", now.ToString("MM"), StringComparison.OrdinalIgnoreCase)
        .Replace("{day}", now.ToString("dd"), StringComparison.OrdinalIgnoreCase)
        .Replace("{time}", now.ToString("HH-mm-ss"), StringComparison.OrdinalIgnoreCase)
        .Replace("{ms}", now.ToString("fff"), StringComparison.OrdinalIgnoreCase)
        .Replace("{timestamp}", DateTimeOffset.Now.ToUnixTimeSeconds().ToString(), StringComparison.OrdinalIgnoreCase)
        .Replace("{type}", kind.ToString(), StringComparison.OrdinalIgnoreCase);

    private static string Sanitize(string value)
    {
        foreach (var character in Path.GetInvalidFileNameChars()) value = value.Replace(character, '_');
        return value.Trim().Trim('.');
    }
}
