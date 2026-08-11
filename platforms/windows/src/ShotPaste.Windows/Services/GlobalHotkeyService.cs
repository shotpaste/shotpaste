using System.ComponentModel;
using System.Windows.Input;
using System.Windows.Interop;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public enum HotkeyAction
{
    OneShot = 1,
    History,
    RecordingPause,
    RecordingAnnotation,
    RecordingRestart,
    RecordingDelete,
    HistoryMode
}

public sealed class GlobalHotkeyService : IDisposable
{
    private readonly HwndSource _source;
    private readonly List<int> _registered = [];
    public event EventHandler<HotkeyAction>? Triggered;
    public IReadOnlyList<HotkeyAction> FailedActions { get; private set; } = [];

    public GlobalHotkeyService()
    {
        var parameters = new HwndSourceParameters("ShotPasteHotkeys")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = new IntPtr(-3)
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WindowProc);
    }

    public void RegisterConfigured(AppSettings settings)
    {
        UnregisterAll();
        var failed = new List<HotkeyAction>();
        if (!settings.ShortcutsEnabled)
        {
            FailedActions = failed;
            return;
        }
        Register(HotkeyAction.OneShot, settings.OneShotHotkey, failed);
        Register(HotkeyAction.History, settings.HistoryHotkey, failed);
        Register(HotkeyAction.HistoryMode, settings.HistoryModeHotkey, failed);
        Register(HotkeyAction.RecordingPause, settings.RecordingPauseHotkey, failed);
        Register(HotkeyAction.RecordingAnnotation, settings.RecordingAnnotationHotkey, failed);
        Register(HotkeyAction.RecordingRestart, settings.RecordingRestartHotkey, failed);
        Register(HotkeyAction.RecordingDelete, settings.RecordingDeleteHotkey, failed);
        FailedActions = failed;
    }

    private void Register(HotkeyAction action, string gesture, List<HotkeyAction> failed)
    {
        if (string.IsNullOrWhiteSpace(gesture)) return;
        if (!TryParseGesture(gesture, out var modifiers, out var key))
        {
            failed.Add(action);
            return;
        }
        Register(action, modifiers | NativeMethods.ModNoRepeat, key, failed);
    }

    internal static bool TryParseGesture(string? gesture, out uint modifiers, out Key key)
    {
        modifiers = 0;
        key = Key.None;
        if (string.IsNullOrWhiteSpace(gesture)) return false;
        foreach (var rawPart in gesture.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var part = rawPart.ToUpperInvariant();
            switch (part)
            {
                case "CTRL": case "CONTROL": modifiers |= NativeMethods.ModControl; continue;
                case "ALT": modifiers |= NativeMethods.ModAlt; continue;
                case "SHIFT": modifiers |= NativeMethods.ModShift; continue;
                case "WIN": case "WINDOWS": modifiers |= NativeMethods.ModWin; continue;
            }
            if (key != Key.None) return false;
            if (part.Length == 1 && char.IsDigit(part[0])) part = "D" + part;
            part = part switch
            {
                "BACKSPACE" => nameof(Key.Back),
                "ENTER" => nameof(Key.Return),
                "ESC" => nameof(Key.Escape),
                "DEL" => nameof(Key.Delete),
                _ => part
            };
            if (!Enum.TryParse(part, true, out key) || key == Key.None) return false;
        }
        return key != Key.None && modifiers != 0;
    }

    public void Suspend() => UnregisterAll();

    private void Register(HotkeyAction action, uint modifiers, Key key, List<HotkeyAction> failed)
    {
        var id = (int)action;
        var virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (NativeMethods.RegisterHotKey(_source.Handle, id, modifiers, virtualKey)) _registered.Add(id);
        else failed.Add(action);
    }

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == NativeMethods.WmHotkey)
        {
            handled = true;
            Triggered?.Invoke(this, (HotkeyAction)wParam.ToInt32());
        }
        return IntPtr.Zero;
    }

    private void UnregisterAll()
    {
        foreach (var id in _registered) NativeMethods.UnregisterHotKey(_source.Handle, id);
        _registered.Clear();
    }

    public void Dispose()
    {
        UnregisterAll();
        _source.RemoveHook(WindowProc);
        _source.Dispose();
    }
}
