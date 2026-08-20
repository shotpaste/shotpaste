using System.Windows;
using WpfPoint = System.Windows.Point;
using WpfSize = System.Windows.Size;

namespace ShotPaste.Windows.Services;

internal static class InlineAreaGeometry
{
    internal const double MinimumSelectionSize = 5;

    internal static Rect Normalize(WpfPoint first, WpfPoint second) => new(
        Math.Min(first.X, second.X),
        Math.Min(first.Y, second.Y),
        Math.Abs(first.X - second.X),
        Math.Abs(first.Y - second.Y));

    internal static Rect Clamp(Rect value, WpfSize bounds)
    {
        var width = Math.Min(Math.Max(0, value.Width), Math.Max(0, bounds.Width));
        var height = Math.Min(Math.Max(0, value.Height), Math.Max(0, bounds.Height));
        var x = Math.Clamp(value.X, 0, Math.Max(0, bounds.Width - width));
        var y = Math.Clamp(value.Y, 0, Math.Max(0, bounds.Height - height));
        return new Rect(x, y, width, height);
    }

    internal static Rect Resize(Rect start, string handle, Vector delta, WpfSize bounds)
    {
        var minimumWidth = Math.Min(MinimumSelectionSize, bounds.Width);
        var minimumHeight = Math.Min(MinimumSelectionSize, bounds.Height);
        var left = start.Left;
        var top = start.Top;
        var right = start.Right;
        var bottom = start.Bottom;

        if (handle.Contains("Left", StringComparison.Ordinal))
            left = Math.Clamp(start.Left + delta.X, 0, right - minimumWidth);
        if (handle.Contains("Right", StringComparison.Ordinal))
            right = Math.Clamp(start.Right + delta.X, left + minimumWidth, bounds.Width);
        if (handle.Contains("Top", StringComparison.Ordinal))
            top = Math.Clamp(start.Top + delta.Y, 0, bottom - minimumHeight);
        if (handle.Contains("Bottom", StringComparison.Ordinal))
            bottom = Math.Clamp(start.Bottom + delta.Y, top + minimumHeight, bounds.Height);

        return new Rect(left, top, right - left, bottom - top);
    }
}
