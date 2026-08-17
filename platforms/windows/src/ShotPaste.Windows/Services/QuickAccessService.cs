using ShotPaste.Windows.Models;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Views;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;
using System.Windows;
using System.Windows.Interop;
namespace ShotPaste.Windows.Services;

public sealed class QuickAccessService(AppController controller, SettingsStore settings) : IDisposable
{
    internal const int MaximumCards = 5;
    private readonly List<QuickAccessWindow> _windows = [];
    private readonly HashSet<Guid> _openItemIds = [];
    private Drawing.Rectangle _activeWorkingArea = Forms.Screen.PrimaryScreen?.WorkingArea ?? Drawing.Rectangle.Empty;
    private bool _suspended;

    internal bool IsSuspended => _suspended;
    internal bool HasVisibleItems => _windows.Any(window => window.IsVisible);

    public void Show(CaptureHistoryItem item)
    {
        if (System.Windows.Application.Current is null)
        {
            App.WriteQuickAccessLog($"Show skipped no application instance kind={item.Kind} file={(string.IsNullOrWhiteSpace(item.FilePath) ? "(null)" : item.FilePath)}");
            return;
        }
        if (!System.Windows.Application.Current.Dispatcher.CheckAccess())
        {
            System.Windows.Application.Current.Dispatcher.BeginInvoke(() => Show(item));
            return;
        }
        try
        {
            _activeWorkingArea = WorkingAreaAtCursor();
            App.WriteQuickAccessLog($"Show start kind={item.Kind} file={(string.IsNullOrWhiteSpace(item.FilePath) ? "(null)" : item.FilePath)} existingWindows={_windows.Count}");
            App.WriteQuickAccessLog($"Show activeWorkingArea={_activeWorkingArea.Left},{_activeWorkingArea.Top} { _activeWorkingArea.Width}x{_activeWorkingArea.Height}");
            try
            {
                using var g = System.Drawing.Graphics.FromHwnd(IntPtr.Zero);
                App.WriteQuickAccessLog($"Graphics dpi={g.DpiX}/{g.DpiY} systemWorkArea={SystemParameters.WorkArea.Left},{SystemParameters.WorkArea.Top} {SystemParameters.WorkArea.Width}x{SystemParameters.WorkArea.Height} virtual={SystemParameters.VirtualScreenLeft},{SystemParameters.VirtualScreenTop} {SystemParameters.VirtualScreenWidth}x{SystemParameters.VirtualScreenHeight}");
            }
            catch (Exception exception)
            {
                App.WriteQuickAccessLog($"Graphics dpi read failed: {exception.Message}");
            }
            var existing = _windows.FirstOrDefault(x => x.Item.FilePath == item.FilePath && x.Item.Text == item.Text);
            if (existing is not null)
            {
                App.WriteQuickAccessLog($"Show reuse existing window file={existing.Item.FilePath}");
                existing.WindowState = WindowState.Normal;
                existing.ShowInTaskbar = App.UiTestMode;
                existing.Topmost = true;
                if (IsSuspended || ShouldHide(existing.Item.Id))
                {
                    existing.Suspend();
                    App.WriteQuickAccessLog($"Show reuse deferred while suspended file={existing.Item.FilePath}");
                    return;
                }
                existing.Show();
                ConfigureQuickAccessWindowHandle(existing);
                EnsureWindowVisible(existing);
                EnsureWindowStronglyVisible(existing);
                Reposition();
                // RetryShowQuickAccess is a visibility repair loop for the same
                // card. It must not restart that card's lifetime on every retry.
                existing.ReconcilePointerCountdown();
                ScheduleSettle(existing);
                App.WriteQuickAccessLog($"Show reuse done visible={existing.IsVisible} left={existing.Left:0.###} top={existing.Top:0.###}");
                return;
            }

            while (_windows.Count >= MaximumCards) _windows[0].Close();
            var window = new QuickAccessWindow(item, controller, settings);
            window.Closed += (_, _) => { _windows.Remove(window); Reposition(); };
            window.SizeChanged += (_, _) => Reposition();
            window.SourceInitialized += (_, _) =>
            {
                EnsureWindowStronglyVisible(window);
                Reposition();
            };
            window.Loaded += (_, _) =>
            {
                Reposition();
                EnsureWindowVisible(window);
                EnsureWindowStronglyVisible(window);
            };
            window.Topmost = true;
            window.WindowState = WindowState.Normal;
            window.ShowInTaskbar = App.UiTestMode;
            _windows.Add(window);
            App.WriteQuickAccessLog($"Show new window created count={_windows.Count} file={item.FilePath}");
            if (IsSuspended || ShouldHide(item.Id))
            {
                App.WriteQuickAccessLog($"Show new window deferred while suspended file={item.FilePath}");
                return;
            }
            window.Show();
            ConfigureQuickAccessWindowHandle(window);
            EnsureWindowVisible(window);
            Reposition();
            ScheduleSettle(window);
            App.WriteQuickAccessLog($"Show done visible={window.IsVisible} left={window.Left:0.###} top={window.Top:0.###}");
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"Show failed: {exception.Message}\n{exception}");
            try { App.WriteCrashLog(exception); } catch { }
        }
    }

    public void HideAll()
    {
        foreach (var window in _windows.ToArray()) window.Close();
        _windows.Clear();
    }

    public void FocusNewest()
    {
        var window = _windows.LastOrDefault(candidate => candidate.IsVisible);
        if (window is null)
        {
            controller.ShowHistory();
            return;
        }
        window.EnterKeyboardMode();
    }

    public void SuspendAll()
    {
        _suspended = true;
        foreach (var window in _windows.ToArray()) window.Suspend();
    }

    public void ResumeAll()
    {
        if (!_suspended) return;
        _suspended = false;
        foreach (var window in _windows.ToArray())
        {
            if (ShouldHide(window.Item.Id)) continue;
            window.Resume();
        }
        Reposition();
    }

    public void SetItemWindowOpen(Guid itemId, bool isOpen)
    {
        if (isOpen) _openItemIds.Add(itemId);
        else _openItemIds.Remove(itemId);
        var window = _windows.FirstOrDefault(candidate => candidate.Item.Id == itemId);
        if (window is null) return;
        if (ShouldHide(itemId))
        {
            window.Suspend();
            return;
        }
        if (_suspended) return;
        window.Resume();
        Reposition();
    }

    public void RefreshSettings()
    {
        if (_suspended) return;
        foreach (var window in _windows.ToArray())
        {
            if (ShouldHide(window.Item.Id)) window.Suspend();
            else window.Resume();
        }
        Reposition();
    }

    private bool ShouldHide(Guid itemId) =>
        settings.Current.QuickAccessHideCardWhenWindowOpen && _openItemIds.Contains(itemId);

    private void Reposition()
    {
        var position = NormalizePosition(settings.Current.QuickAccessPosition);
        var workingArea = _activeWorkingArea.IsEmpty ? WorkingAreaAtCursor() : _activeWorkingArea;
        if (workingArea.IsEmpty || workingArea.Width <= 0 || workingArea.Height <= 0)
        {
            App.WriteQuickAccessLog($"Reposition skipped invalid workingArea left={workingArea.Left} top={workingArea.Top} width={workingArea.Width} height={workingArea.Height}");
            return;
        }
        App.WriteQuickAccessLog($"Reposition position={position} workingArea={workingArea.Left},{workingArea.Top} {workingArea.Width}x{workingArea.Height}");
        var windows = _windows.AsEnumerable().Reverse().ToArray();
        var sizes = windows.Select(window => (
            Width: window.ActualWidth > 0 ? window.ActualWidth : window.Width > 0 ? window.Width : 204d,
            Height: window.ActualHeight > 0 ? window.ActualHeight : window.Height > 0 ? window.Height : 128d)).ToArray();
        var layout = CalculateLayout(workingArea, sizes, position);
        for (var index = 0; index < windows.Length; index++)
        {
            var window = windows[index];
            var width = sizes[index].Width;
            var height = sizes[index].Height;
            window.Left = layout[index].Left;
            window.Top = layout[index].Top;
            App.WriteQuickAccessLog($"Reposition window file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)} left={window.Left:0.###} top={window.Top:0.###} width={width:0.###} height={height:0.###}");
            BringToTopmost(window);
        }
        App.WriteQuickAccessLog($"Reposition finished windows={_windows.Count}");
    }

    internal static string NormalizePosition(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "topleft" => "BottomLeft",
        "topright" => "BottomRight",
        "bottomleft" or "left" => "BottomLeft",
        _ => "BottomRight"
    };

    internal static IReadOnlyList<Rect> CalculateLayout(
        Drawing.Rectangle workingArea,
        IReadOnlyList<(double Width, double Height)> sizes,
        string? requestedPosition)
    {
        var position = NormalizePosition(requestedPosition);
        var right = position.EndsWith("Right", StringComparison.OrdinalIgnoreCase);
        var stackFromTop = position.StartsWith("Top", StringComparison.OrdinalIgnoreCase);
        var edge = stackFromTop ? workingArea.Top + 18d : workingArea.Bottom - 18d;
        var result = new List<Rect>(sizes.Count);
        foreach (var (width, height) in sizes)
        {
            var requestedLeft = right ? workingArea.Right - width - 18d : workingArea.Left + 18d;
            var requestedTop = stackFromTop ? edge : edge - height;
            var left = Math.Clamp(requestedLeft,
                workingArea.Left + 2d,
                Math.Max(workingArea.Left + 2d, workingArea.Right - width - 2d));
            var top = Math.Clamp(requestedTop,
                workingArea.Top + 2d,
                Math.Max(workingArea.Top + 2d, workingArea.Bottom - height - 2d));
            result.Add(new Rect(left, top, width, height));
            edge = stackFromTop ? top + height + 8d : top - 8d;
        }
        return result;
    }

    private static void EnsureWindowVisible(QuickAccessWindow window)
    {
        try
        {
            ConfigureQuickAccessWindowHandle(window);
            window.WindowState = WindowState.Normal;
            if (!window.IsVisible) window.Show();
            window.Topmost = true;
            window.Visibility = Visibility.Visible;
            window.Focusable = false;
            ForceToTopmost(window);
            BringToTopmost(window);
            try { window.UpdateLayout(); }
            catch (Exception exception)
            {
                App.WriteQuickAccessLog($"EnsureWindowVisible update layout failed: {exception.Message}");
            }
            ReinforceNativeWindow(window);
            ValidateNativeWindow(window);

            App.WriteQuickAccessLog($"EnsureWindowVisible done visible={window.IsVisible} topmost={window.Topmost} left={window.Left:0.###} top={window.Top:0.###}");
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"EnsureWindowVisible failed: {exception.Message}\n{exception}");
            try { App.WriteCrashLog(exception); } catch { }
        }
    }

    private static void ScheduleSettle(QuickAccessWindow window)
    {
        if (!window.Dispatcher.CheckAccess())
        {
            window.Dispatcher.BeginInvoke(ScheduleSettle, System.Windows.Threading.DispatcherPriority.ContextIdle, window);
            return;
        }
        _ = SettleWindowVisibilityAsync(window);
    }

    private static async Task SettleWindowVisibilityAsync(QuickAccessWindow window)
    {
        try
        {
            const int maxAttempts = 6;
            for (var attempt = 1; attempt <= maxAttempts; attempt++)
            {
                if (window.Dispatcher.HasShutdownStarted) return;
                var file = string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath;
                await window.Dispatcher.InvokeAsync(() =>
                {
                    try { window.Topmost = true; } catch { }
                    try { window.Focusable = false; } catch { }
                    try { window.Show(); } catch { }
                    try { window.Visibility = Visibility.Visible; } catch { }
                    try { window.Opacity = 1d; } catch { }
                    try { EnsureWindowVisible(window); } catch { }
                    try { EnsureWindowStronglyVisible(window); } catch { }
                    try { ReinforceNativeWindow(window); } catch { }
                    try { window.Activate(); } catch { }
                }, System.Windows.Threading.DispatcherPriority.Send);

                if (IsNativeWindowOnScreen(window))
                {
                    App.WriteQuickAccessLog($"SettleWindowVisibility ok attempt={attempt} file={file}");
                    return;
                }

                App.WriteQuickAccessLog($"SettleWindowVisibility retry attempt={attempt} file={file}");
                await Task.Delay(80);
            }

            App.WriteQuickAccessLog($"SettleWindowVisibility failed file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)}");
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"SettleWindowVisibility failed: {exception.Message}");
            try { App.WriteCrashLog(exception); } catch { }
        }
    }

    private static void ConfigureQuickAccessWindowHandle(QuickAccessWindow window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) return;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
            var forcedStyle = style | NativeMethods.WsExNoActivate | toolWindowStyle;
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, new IntPtr(forcedStyle));
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                0,
                0,
                0,
                0,
                NativeMethods.SwpNoMove |
                NativeMethods.SwpNoSize |
                NativeMethods.SwpNoActivate |
                NativeMethods.SwpFrameChanged);
            if (!App.UiTestMode) NativeMethods.SetWindowDisplayAffinity(handle, 0);
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"ConfigureQuickAccessWindowHandle failed: {exception.Message}");
        }
    }

    private static void ValidateNativeWindow(QuickAccessWindow window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) return;
            var visible = NativeMethods.IsWindowVisible(handle);
            if (!visible)
            {
                App.WriteQuickAccessLog($"ValidateNativeWindow not visible file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)}");
                window.Show();
            }
            if (!NativeMethods.GetWindowRect(handle, out var bounds)) return;
            var nativeRect = new Drawing.Rectangle(
                bounds.Left,
                bounds.Top,
                Math.Max(1, bounds.Right - bounds.Left),
                Math.Max(1, bounds.Bottom - bounds.Top));
            var intersectsScreen = Forms.Screen.AllScreens.Any(screen => screen.Bounds.IntersectsWith(nativeRect));
            App.WriteQuickAccessLog($"ValidateNativeWindow rect={nativeRect.Left},{nativeRect.Top} {nativeRect.Width}x{nativeRect.Height} visible={visible} intersects={intersectsScreen}");
            if (intersectsScreen) return;

            var fallback = Forms.Screen.PrimaryScreen?.WorkingArea ?? new Drawing.Rectangle(0, 0, 1920, 1080);
            var safeLeft = Math.Max(0, Math.Min((int)window.Left, Math.Max(0, fallback.Right - (int)window.Width)));
            var safeTop = Math.Max(0, Math.Min((int)window.Top, Math.Max(0, fallback.Bottom - (int)window.Height)));
            window.Left = safeLeft;
            window.Top = safeTop;
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                safeLeft,
                safeTop,
                0,
                0,
                NativeMethods.SwpNoSize | NativeMethods.SwpShowWindow | NativeMethods.SwpNoActivate);
            App.WriteQuickAccessLog($"ValidateNativeWindow rebound to={safeLeft},{safeTop} file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)}");
            try { EnsureWindowStronglyVisible(window); } catch { }
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"ValidateNativeWindow failed: {exception.Message}");
        }
    }

    private static void EnsureWindowStronglyVisible(QuickAccessWindow window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero)
            {
                App.WriteQuickAccessLog($"EnsureWindowStronglyVisible missing handle file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)}");
                return;
            }

            App.WriteQuickAccessLog($"EnsureWindowStronglyVisible start file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)} handle=0x{handle.ToString("X")} nativeVisible={NativeMethods.IsWindowVisible(handle)}");
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            var fallbackStyle = style | NativeMethods.WsExNoActivate;
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, new IntPtr(fallbackStyle));
            NativeMethods.ShowWindow(handle, NativeMethods.SwRestore);
            NativeMethods.ShowWindow(handle, NativeMethods.SwShow);
            NativeMethods.ShowWindowAsync(handle, NativeMethods.SwShowNA);
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                0,
                0,
                0,
                0,
                NativeMethods.SwpNoMove |
                NativeMethods.SwpNoSize |
                NativeMethods.SwpShowWindow |
                NativeMethods.SwpNoActivate);
            window.Visibility = Visibility.Visible;
            window.Opacity = 1d;
            window.Topmost = true;
            PulseTopmostWindow(handle);
            if (!App.UiTestMode) NativeMethods.SetWindowDisplayAffinity(handle, NativeMethods.WdaExcludeFromCapture);
            if (!NativeMethods.IsWindowVisible(handle)) NativeMethods.ShowWindow(handle, NativeMethods.SwShowNA);
            App.WriteQuickAccessLog($"EnsureWindowStronglyVisible ok file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)}");
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"EnsureWindowStronglyVisible failed: {exception.Message}");
        }
    }

    private static void ReinforceNativeWindow(QuickAccessWindow window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) return;
            NativeMethods.ShowWindowAsync(handle, NativeMethods.SwShowNA);
            NativeMethods.ShowWindow(handle, NativeMethods.SwShowNoActivate);
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                0,
                0,
                0,
                0,
                NativeMethods.SwpNoMove |
                NativeMethods.SwpNoSize |
                NativeMethods.SwpShowWindow |
                NativeMethods.SwpNoActivate |
                NativeMethods.SwpFrameChanged);
            App.WriteQuickAccessLog($"ReinforceNativeWindow ok visible={window.IsVisible} topmost={window.Topmost} file={(string.IsNullOrWhiteSpace(window.Item.FilePath) ? "(null)" : window.Item.FilePath)}");
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"ReinforceNativeWindow failed: {exception.Message}");
        }
    }

    private static void PulseTopmostWindow(IntPtr handle)
    {
        try
        {
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndNoTopmost,
                0,
                0,
                0,
                0,
                NativeMethods.SwpNoSize |
                NativeMethods.SwpNoMove |
                NativeMethods.SwpNoActivate |
                NativeMethods.SwpShowWindow |
                NativeMethods.SwpNoOwnerZOrder);
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                0,
                0,
                0,
                0,
                NativeMethods.SwpNoSize |
                NativeMethods.SwpNoMove |
                NativeMethods.SwpNoActivate |
                NativeMethods.SwpShowWindow |
                NativeMethods.SwpNoOwnerZOrder);
        }
        catch
        {
        }
    }

    private static void BringToTopmost(Window window)
    {
        try
        {
            window.Topmost = false;
            window.Topmost = true;
        }
        catch
        {
            window.Topmost = true;
        }
    }

    private static void ForceToTopmost(Window window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) return;
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                0,
                0,
                0,
                0,
                NativeMethods.SwpNoMove | NativeMethods.SwpNoSize | NativeMethods.SwpShowWindow | NativeMethods.SwpNoActivate);
            NativeMethods.SetForegroundWindow(handle);
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"ForceToTopmost failed: {exception.Message}");
        }
    }

    private static Drawing.Rectangle WorkingAreaAtCursor()
    {
        var cursor = Forms.Cursor.Position;
        return WorkingAreaAtCursor(cursor);
    }

    private static Drawing.Rectangle WorkingAreaAtCursor(System.Drawing.Point cursor)
    {
        System.Drawing.Rectangle physical;
        try
        {
            physical = Forms.Screen.FromPoint(cursor).WorkingArea;
        }
        catch
        {
            return Forms.Screen.PrimaryScreen?.WorkingArea ?? Drawing.Rectangle.Empty;
        }
        var dpi = MonitorDpi(new NativeMethods.PointStruct(cursor.X, cursor.Y));
        var scaleX = 96d / Math.Max(1d, dpi.X);
        var scaleY = 96d / Math.Max(1d, dpi.Y);
        var logical = new Drawing.Rectangle(
            (int)Math.Round(physical.Left * scaleX),
            (int)Math.Round(physical.Top * scaleY),
            Math.Max(1, (int)Math.Round(physical.Width * scaleX)),
            Math.Max(1, (int)Math.Round(physical.Height * scaleY)));
        App.WriteQuickAccessLog($"WorkingAreaAtCursor cursor={cursor.X},{cursor.Y} physical={physical.Left},{physical.Top} {physical.Width}x{physical.Height} logical={logical.Left},{logical.Top} {logical.Width}x{logical.Height} dpi={dpi.X}/{dpi.Y} scale={scaleX:0.###}/{scaleY:0.###}");
        return logical;
    }

    private static (double X, double Y) MonitorDpi(NativeMethods.PointStruct point)
    {
        try
        {
            var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MonitorDefaultToNearest);
            if (monitor == IntPtr.Zero) return (96d, 96d);
            var result = NativeMethods.GetDpiForMonitor(monitor, NativeMethods.DpiTypeEffective, out var dpiX, out var dpiY);
            if (result != 0) return (96d, 96d);
            if (dpiX is 0 || dpiY is 0) return (96d, 96d);
            return (dpiX, dpiY);
        }
        catch
        {
            return (96d, 96d);
        }
    }

    private static bool IsNativeWindowOnScreen(QuickAccessWindow window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) return false;
            if (!NativeMethods.IsWindowVisible(handle)) return false;
            if (!NativeMethods.GetWindowRect(handle, out var bounds)) return false;

            var nativeRect = new Drawing.Rectangle(
                bounds.Left,
                bounds.Top,
                Math.Max(1, bounds.Right - bounds.Left),
                Math.Max(1, bounds.Bottom - bounds.Top));
            var intersectsScreen = Forms.Screen.AllScreens.Any(screen => screen.Bounds.IntersectsWith(nativeRect));
            return intersectsScreen && nativeRect.Width > 1 && nativeRect.Height > 1;
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        HideAll();
    }
}
