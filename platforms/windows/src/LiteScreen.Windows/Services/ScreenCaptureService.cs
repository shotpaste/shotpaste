using System.Runtime.InteropServices;
using LiteScreen.Windows.Interop;
using LiteScreen.Windows.Models;
using Drawing = System.Drawing;

namespace LiteScreen.Windows.Services;

public sealed class ScreenCaptureService
{
    public Drawing.Rectangle VirtualBounds => new(
        NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen),
        NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen),
        NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen),
        NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen));

    public Drawing.Bitmap CaptureRectangle(Drawing.Rectangle rectangle, ScreenCaptureOptions? options = null)
    {
        rectangle = Drawing.Rectangle.Intersect(VirtualBounds, rectangle);
        if (rectangle.Width <= 0 || rectangle.Height <= 0) throw new ArgumentOutOfRangeException(nameof(rectangle));

        using var desktopScope = DesktopCaptureScope.Begin(options);

        var desktop = NativeMethods.GetDesktopWindow();
        var source = NativeMethods.GetWindowDC(desktop);
        if (source == IntPtr.Zero) throw new InvalidOperationException("无法获取桌面设备上下文。");

        var destination = NativeMethods.CreateCompatibleDC(source);
        var handle = NativeMethods.CreateCompatibleBitmap(source, rectangle.Width, rectangle.Height);
        var previous = NativeMethods.SelectObject(destination, handle);
        try
        {
            var ok = NativeMethods.BitBlt(destination, 0, 0, rectangle.Width, rectangle.Height, source,
                rectangle.X, rectangle.Y, NativeMethods.Srccopy | NativeMethods.CaptureBlt);
            if (!ok) throw new InvalidOperationException("Windows GDI 屏幕捕获失败。");
            if (options?.IncludeCursor == true)
            {
                var cursorInfo = new NativeMethods.CursorInfo { Size = Marshal.SizeOf<NativeMethods.CursorInfo>() };
                if (NativeMethods.GetCursorInfo(ref cursorInfo) &&
                    (cursorInfo.Flags & NativeMethods.CursorShowing) != 0 &&
                    cursorInfo.Cursor != IntPtr.Zero)
                {
                    var drawX = cursorInfo.Position.X - rectangle.X;
                    var drawY = cursorInfo.Position.Y - rectangle.Y;
                    if (NativeMethods.GetIconInfo(cursorInfo.Cursor, out var iconInfo))
                    {
                        drawX -= (int)iconInfo.XHotspot;
                        drawY -= (int)iconInfo.YHotspot;
                        if (iconInfo.MaskBitmap != IntPtr.Zero) NativeMethods.DeleteObject(iconInfo.MaskBitmap);
                        if (iconInfo.ColorBitmap != IntPtr.Zero) NativeMethods.DeleteObject(iconInfo.ColorBitmap);
                    }
                    NativeMethods.DrawIconEx(destination, drawX, drawY, cursorInfo.Cursor, 0, 0, 0, IntPtr.Zero, NativeMethods.DiNormal);
                }
            }
            using var attached = Drawing.Image.FromHbitmap(handle);
            return new Drawing.Bitmap(attached);
        }
        finally
        {
            NativeMethods.SelectObject(destination, previous);
            NativeMethods.DeleteObject(handle);
            NativeMethods.DeleteDC(destination);
            NativeMethods.ReleaseDC(desktop, source);
        }
    }

    private sealed class DesktopCaptureScope : IDisposable
    {
        private readonly List<IntPtr> _hiddenWindows;

        private DesktopCaptureScope(List<IntPtr> hiddenWindows) => _hiddenWindows = hiddenWindows;

        public static DesktopCaptureScope Begin(ScreenCaptureOptions? options)
        {
            var hidden = new List<IntPtr>();
            if (options?.HideDesktopIcons != true && options?.HideDesktopWidgets != true)
                return new DesktopCaptureScope(hidden);

            if (options?.HideDesktopIcons == true)
            {
                // Explorer can host the desktop icon view under Progman or WorkerW.
                HideIfVisible(NativeMethods.FindWindowEx(
                    NativeMethods.FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null), hidden);
                var worker = IntPtr.Zero;
                while ((worker = NativeMethods.FindWindowEx(IntPtr.Zero, worker, "WorkerW", null)) != IntPtr.Zero)
                    HideIfVisible(NativeMethods.FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null), hidden);
            }

            if (options?.HideDesktopWidgets == true)
            {
                NativeMethods.EnumWindows((window, _) =>
                {
                    if (!NativeMethods.IsWindowVisible(window)) return true;
                    var className = new System.Text.StringBuilder(256);
                    var title = new System.Text.StringBuilder(256);
                    NativeMethods.GetClassName(window, className, className.Capacity);
                    NativeMethods.GetWindowText(window, title, title.Capacity);
                    if (IsDesktopWidget(className.ToString(), title.ToString())) HideIfVisible(window, hidden);
                    return true;
                }, IntPtr.Zero);
            }
            return new DesktopCaptureScope(hidden);
        }

        private static void HideIfVisible(IntPtr window, List<IntPtr> hidden)
        {
            if (window != IntPtr.Zero && NativeMethods.IsWindowVisible(window) &&
                NativeMethods.ShowWindow(window, NativeMethods.SwHide)) hidden.Add(window);
        }

        private static bool IsDesktopWidget(string className, string title) =>
            className.Contains("Rainmeter", StringComparison.OrdinalIgnoreCase) ||
            className.Contains("Gadget", StringComparison.OrdinalIgnoreCase) ||
            title.Equals("Widgets", StringComparison.OrdinalIgnoreCase) ||
            title.Equals("Windows Widgets", StringComparison.OrdinalIgnoreCase) ||
            title.Contains("桌面小组件", StringComparison.OrdinalIgnoreCase);

        public void Dispose()
        {
            foreach (var window in _hiddenWindows) NativeMethods.ShowWindow(window, NativeMethods.SwShow);
        }
    }
}
