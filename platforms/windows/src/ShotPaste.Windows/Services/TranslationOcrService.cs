using Drawing = System.Drawing;

namespace ShotPaste.Windows.Services;

public sealed record TranslationSourceRegion(string Id, string Text, Drawing.Rectangle Bounds);

public static class TranslationOcrService
{
    public static async Task<IReadOnlyList<TranslationSourceRegion>> RecognizeAsync(
        Drawing.Bitmap image, string language, CancellationToken token)
    {
        if ((long)image.Width * image.Height > 25_000_000)
            throw new InvalidOperationException("one-shot.translation-input-too-large");
        var service = new OcrService(() => language == "auto" ? "Auto" : language);
        var result = new List<TranslationSourceRegion>();
        // Bound native OCR inputs without shrinking small text on large or high-DPI displays.
        const int tileSize = 1800;
        for (var y = 0; y < image.Height; y += tileSize)
        for (var x = 0; x < image.Width; x += tileSize)
        {
            token.ThrowIfCancellationRequested();
            using var tile = image.Clone(new Drawing.Rectangle(x, y, Math.Min(tileSize, image.Width - x),
                Math.Min(tileSize, image.Height - y)), Drawing.Imaging.PixelFormat.Format32bppArgb);
            var lines = await service.RecognizeTranslationLinesAsync(tile, token);
            token.ThrowIfCancellationRequested();
            foreach (var line in lines)
            {
                var bounds = line.Bounds;
                bounds.Offset(x, y);
                result.Add(new($"b{result.Count}", line.Text, bounds));
            }
        }
        return result.OrderBy(line => line.Bounds.Top).ThenBy(line => line.Bounds.Left).ToArray();
    }
}
