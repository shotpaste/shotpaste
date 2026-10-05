using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Brushes = System.Windows.Media.Brushes;
using FlowDirection = System.Windows.FlowDirection;

namespace ShotPaste.Windows.Services;

public static class TranslationResultRenderer
{
    public static BitmapSource Render(BitmapSource source, IReadOnlyList<TranslationSourceRegion> regions,
        IReadOnlyList<TranslationTextBlock> translations)
    {
        var values = translations.ToDictionary(block => block.Id, block => block.Text, StringComparer.Ordinal);
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            drawing.DrawImage(source, new Rect(0, 0, source.PixelWidth, source.PixelHeight));
            foreach (var region in regions)
            {
                var bounds = new Rect(region.Bounds.X, region.Bounds.Y, region.Bounds.Width, region.Bounds.Height);
                if (!values.TryGetValue(region.Id, out var text) || bounds.Width < 2 || bounds.Height < 2) continue;
                // Never let model output move or resize a source region. Full text remains available in the text tab.
                drawing.PushClip(new RectangleGeometry(bounds));
                drawing.DrawRectangle(Brushes.White, null, bounds);
                var size = Math.Clamp(bounds.Height * 0.75, 8, 40);
                FormattedText formatted;
                do
                {
                    formatted = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                        new Typeface("Segoe UI"), size, Brushes.Black, 1) { MaxTextWidth = Math.Max(1, bounds.Width - 2) };
                    if (formatted.Height <= bounds.Height || size <= 8) break;
                    size -= 1;
                } while (true);
                drawing.DrawText(formatted, bounds.TopLeft);
                drawing.Pop();
            }
        }
        var bitmap = new RenderTargetBitmap(source.PixelWidth, source.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }
}
