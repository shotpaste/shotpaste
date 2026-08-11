using System.Runtime.InteropServices;
using System.Windows.Input;
using LiteScreen.Windows.Interop;
using LiteScreen.Windows.Models;
using LiteScreen.Windows.Views;

namespace LiteScreen.Windows.Services;

public sealed class KeystrokeOverlayService : IDisposable
{
    private readonly NativeMethods.LowLevelKeyboardProc _callback;
    private readonly KeystrokeOverlayWindow _window;
    private readonly HashSet<uint> _pressedVirtualKeys = [];
    private IntPtr _hook;
    private bool _paused;

    public KeystrokeOverlayService(System.Drawing.Rectangle recordingRegion)
        : this(recordingRegion, new AppSettings())
    {
    }

    public KeystrokeOverlayService(System.Drawing.Rectangle recordingRegion, AppSettings settings)
    {
        _window = new KeystrokeOverlayWindow(recordingRegion, settings);
        _window.Show();
        _callback = OnKeyboard;
        _hook = NativeMethods.SetWindowsHookEx(NativeMethods.WhKeyboardLl, _callback, NativeMethods.GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero)
        {
            _window.Close();
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "无法启用按键显示。");
        }
    }

    public void UpdateRecordingRegion(System.Drawing.Rectangle recordingRegion) =>
        _window.Dispatcher.BeginInvoke(() => _window.UpdateRecordingRegion(recordingRegion));

    public void SetPaused(bool paused)
    {
        _paused = paused;
        if (paused) _window.Dispatcher.BeginInvoke(_window.ClearGesture);
    }

    private IntPtr OnKeyboard(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var data = Marshal.PtrToStructure<NativeMethods.KeyboardHookData>(lParam);
            var message = wParam.ToInt32();
            if (message == NativeMethods.WmKeyUp || message == NativeMethods.WmSysKeyUp)
            {
                _pressedVirtualKeys.Remove(data.VirtualKey);
            }
            else if (message == NativeMethods.WmKeyDown || message == NativeMethods.WmSysKeyDown)
            {
                var isRepeat = !_pressedVirtualKeys.Add(data.VirtualKey);
                var key = KeyInterop.KeyFromVirtualKey((int)data.VirtualKey);
                if (!_paused && !isRepeat && !IsModifier(key) && ShouldDisplay(key, _window.VisibilityRule))
                {
                    var label = BuildLabel(key);
                    _window.Dispatcher.BeginInvoke(() => _window.ShowGesture(label));
                }
            }
        }
        return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
    }

    internal static string BuildLabel(Key key, Func<int, bool>? isDown = null)
    {
        isDown ??= virtualKey => (NativeMethods.GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        var parts = new List<string>();
        if (isDown(0x11)) parts.Add("Ctrl");
        if (isDown(0x12)) parts.Add("Alt");
        if (isDown(0x10)) parts.Add("Shift");
        if (isDown(0x5B) || isDown(0x5C)) parts.Add("Win");
        parts.Add(FriendlyKey(key));
        return string.Join(" + ", parts);
    }

    internal static bool ShouldDisplay(Key key, Func<int, bool>? isDown = null)
        => ShouldDisplay(key, "SpecialAndShortcuts", isDown);

    internal static bool ShouldDisplay(Key key, string visibilityRule, Func<int, bool>? isDown = null)
    {
        isDown ??= virtualKey => (NativeMethods.GetAsyncKeyState(virtualKey) & 0x8000) != 0;
        var shortcut = isDown(0x11) || isDown(0x12) || isDown(0x10) || isDown(0x5B) || isDown(0x5C);
        var special = key is Key.Return or Key.Escape or Key.Tab or Key.Back or Key.Delete or Key.Space or
            Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End or Key.Prior or Key.Next or
            Key.Insert or Key.Snapshot or Key.Pause || key is >= Key.F1 and <= Key.F24;
        return visibilityRule switch
        {
            "All" => true,
            "ShortcutsOnly" => shortcut,
            "SpecialOnly" => special,
            "None" => false,
            _ => shortcut || special
        };
    }

    private static bool IsModifier(Key key) => key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin;

    private static string FriendlyKey(Key key)
    {
        if (key is >= Key.D0 and <= Key.D9) return ((int)key - (int)Key.D0).ToString();
        if (key is >= Key.NumPad0 and <= Key.NumPad9) return "Num " + ((int)key - (int)Key.NumPad0);
        return key switch
        {
            Key.Return => "Enter",
            Key.Escape => "Esc",
            Key.Back => "Backspace",
            Key.Space => "Space",
            Key.Prior => "Page Up",
            Key.Next => "Page Down",
            Key.Snapshot => "Print Screen",
            _ => key.ToString()
        };
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
        _window.Close();
    }
}
