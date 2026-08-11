using System.Runtime.InteropServices;
using LiteScreen.Windows.Interop;
using LiteScreen.Windows.Models;
using LiteScreen.Windows.Views;

namespace LiteScreen.Windows.Services;

public sealed class MouseClickOverlayService : IDisposable
{
    private readonly NativeMethods.LowLevelMouseProc _callback;
    private readonly MouseClickOverlayWindow _window;
    private IntPtr _hook;
    private bool _paused;
    private bool _disposed;

    public MouseClickOverlayService(System.Drawing.Rectangle recordingRegion, AppSettings settings)
    {
        _window = new MouseClickOverlayWindow(recordingRegion, settings);
        _window.Show();
        _callback = OnMouse;
        _hook = NativeMethods.SetWindowsHookEx(
            NativeMethods.WhMouseLl,
            _callback,
            NativeMethods.GetModuleHandle(null),
            0);
        if (_hook == IntPtr.Zero)
        {
            _window.Close();
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "无法启用鼠标点击效果。");
        }
    }

    public void SetPaused(bool paused)
    {
        _paused = paused;
        if (paused) _window.Dispatcher.BeginInvoke(_window.Clear);
    }

    public void UpdateRecordingRegion(System.Drawing.Rectangle recordingRegion) =>
        _window.Dispatcher.BeginInvoke(() => _window.UpdateRecordingRegion(recordingRegion));

    private IntPtr OnMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (!_paused && code >= 0 &&
            wParam.ToInt32() is NativeMethods.WmLButtonDown or NativeMethods.WmRButtonDown)
        {
            var data = Marshal.PtrToStructure<NativeMethods.MouseHookData>(lParam);
            var point = new System.Drawing.Point(data.Point.X, data.Point.Y);
            var rightButton = wParam.ToInt32() == NativeMethods.WmRButtonDown;
            _window.Dispatcher.BeginInvoke(() => _window.ShowClick(point, rightButton));
        }
        return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_hook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
        _window.Close();
    }
}
