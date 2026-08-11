using System.Windows;
using Drawing = System.Drawing;
using WpfSize = System.Windows.Size;

namespace ShotPaste.Windows.Services;

public readonly record struct SelectionDimRegions(Rect Top, Rect Left, Rect Right, Rect Bottom);

public static class SelectionOverlayGeometry
{
    public static Drawing.Rectangle ToPhysical(Rect selection, WpfSize logicalBounds, Drawing.Rectangle physicalBounds)
    {
        if (logicalBounds.Width <= 0 || logicalBounds.Height <= 0 ||
            physicalBounds.Width <= 0 || physicalBounds.Height <= 0 ||
            selection.Width <= 0 || selection.Height <= 0)
            return Drawing.Rectangle.Empty;

        var clamped = Clamp(selection, logicalBounds);
        var scaleX = physicalBounds.Width / logicalBounds.Width;
        var scaleY = physicalBounds.Height / logicalBounds.Height;
        var left = Math.Clamp((int)Math.Floor(clamped.Left * scaleX), 0, physicalBounds.Width - 1);
        var top = Math.Clamp((int)Math.Floor(clamped.Top * scaleY), 0, physicalBounds.Height - 1);
        var right = Math.Clamp((int)Math.Ceiling(clamped.Right * scaleX), left + 1, physicalBounds.Width);
        var bottom = Math.Clamp((int)Math.Ceiling(clamped.Bottom * scaleY), top + 1, physicalBounds.Height);
        return new Drawing.Rectangle(physicalBounds.Left + left, physicalBounds.Top + top, right - left, bottom - top);
    }

    public static Rect ToLogical(Drawing.Rectangle selection, WpfSize logicalBounds, Drawing.Rectangle physicalBounds)
    {
        if (logicalBounds.Width <= 0 || logicalBounds.Height <= 0 ||
            physicalBounds.Width <= 0 || physicalBounds.Height <= 0 ||
            selection.Width <= 0 || selection.Height <= 0)
            return Rect.Empty;

        var clamped = Drawing.Rectangle.Intersect(selection, physicalBounds);
        if (clamped.Width <= 0 || clamped.Height <= 0) return Rect.Empty;

        var scaleX = logicalBounds.Width / physicalBounds.Width;
        var scaleY = logicalBounds.Height / physicalBounds.Height;
        return new Rect(
            (clamped.Left - physicalBounds.Left) * scaleX,
            (clamped.Top - physicalBounds.Top) * scaleY,
            clamped.Width * scaleX,
            clamped.Height * scaleY);
    }

    public static SelectionDimRegions CreateDimRegions(Rect? selection, WpfSize logicalBounds)
    {
        var full = new Rect(0, 0, Math.Max(0, logicalBounds.Width), Math.Max(0, logicalBounds.Height));
        if (selection is not { } value || value.Width <= 0 || value.Height <= 0)
            return new SelectionDimRegions(full, Rect.Empty, Rect.Empty, Rect.Empty);

        var rect = Clamp(value, logicalBounds);
        return new SelectionDimRegions(
            new Rect(0, 0, full.Width, Math.Max(0, rect.Top)),
            new Rect(0, rect.Top, Math.Max(0, rect.Left), rect.Height),
            new Rect(rect.Right, rect.Top, Math.Max(0, full.Width - rect.Right), rect.Height),
            new Rect(0, rect.Bottom, full.Width, Math.Max(0, full.Height - rect.Bottom)));
    }

    private static Rect Clamp(Rect value, WpfSize bounds)
    {
        var left = Math.Clamp(value.Left, 0, Math.Max(0, bounds.Width));
        var top = Math.Clamp(value.Top, 0, Math.Max(0, bounds.Height));
        var right = Math.Clamp(value.Right, left, Math.Max(left, bounds.Width));
        var bottom = Math.Clamp(value.Bottom, top, Math.Max(top, bounds.Height));
        return new Rect(left, top, right - left, bottom - top);
    }
}
