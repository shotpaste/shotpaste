namespace LiteScreen.Windows.Views;

/// <summary>
/// Shared placement rules for floating HUD windows (recording setup and in-recording
/// toolbar). Mirrors the macOS toolbar anchoring: centered on the selection, placed
/// below it when there is room, otherwise inside the selection near its bottom edge.
/// </summary>
internal static class HudPlacement
{
    public const double ScreenEdgeInset = 10;
    public const double OutsideSelectionGap = 20;
    public const double InsideSelectionBottomInset = 24;

    public static System.Windows.Point GetToolbarOrigin(
        System.Windows.Rect selection,
        System.Windows.Size toolbarSize,
        System.Windows.Rect workArea)
    {
        var minX = workArea.Left + ScreenEdgeInset;
        var maxX = Math.Max(minX, workArea.Right - toolbarSize.Width - ScreenEdgeInset);
        var x = Math.Clamp(selection.Left + (selection.Width - toolbarSize.Width) / 2, minX, maxX);

        var minY = workArea.Top + ScreenEdgeInset;
        var maxY = Math.Max(minY, workArea.Bottom - toolbarSize.Height - ScreenEdgeInset);
        var belowSelection = selection.Bottom + OutsideSelectionGap;
        var preferredY = belowSelection <= maxY
            ? belowSelection
            : selection.Bottom - toolbarSize.Height - InsideSelectionBottomInset;
        var y = Math.Clamp(preferredY, minY, maxY);
        return new System.Windows.Point(x, y);
    }
}
