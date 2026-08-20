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
    RecordingDelete
}

public enum HotkeyAvailability
{
    Available,
    Disabled,
    Invalid,
    Conflict
}

public sealed record HotkeyAvailabilityResult(HotkeyAction Action, HotkeyAvailability Availability, string Message);

public sealed class GlobalHotkeyService : IDisposable
{
    private readonly HwndSource _source;
    private readonly List<int> _registered = [];
    public event EventHandler<HotkeyAction>? Triggered;
    public IReadOnlyList<HotkeyAction> FailedActions { get; private set; } = [];

    public GlobalHotkeyService()
    {
        var parameters = new HwndSourceParameters(AppBuildIdentity.Current.HotkeyWindowName)
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

    internal static IReadOnlyDictionary<HotkeyAction, HotkeyAvailabilityResult> ProbeConfigured(AppSettings settings)
    {
        var gestures = new (HotkeyAction Action, string Gesture)[]
        {
            (HotkeyAction.OneShot, settings.OneShotHotkey),
            (HotkeyAction.History, settings.HistoryHotkey),
            (HotkeyAction.RecordingPause, settings.RecordingPauseHotkey),
            (HotkeyAction.RecordingAnnotation, settings.RecordingAnnotationHotkey),
            (HotkeyAction.RecordingRestart, settings.RecordingRestartHotkey),
            (HotkeyAction.RecordingDelete, settings.RecordingDeleteHotkey)
        };
        if (!settings.ShortcutsEnabled)
            return gestures.ToDictionary(entry => entry.Action, entry =>
                new HotkeyAvailabilityResult(entry.Action, HotkeyAvailability.Disabled, "全局快捷键已停用"));

        var parameters = new HwndSourceParameters(AppBuildIdentity.Current.HotkeyWindowName + ".Probe")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = new IntPtr(-3)
        };
        using var source = new HwndSource(parameters);
        var registered = new List<int>();
        var results = new Dictionary<HotkeyAction, HotkeyAvailabilityResult>();
        try
        {
            foreach (var entry in gestures)
            {
                if (string.IsNullOrWhiteSpace(entry.Gesture))
                {
                    results[entry.Action] = new(entry.Action, HotkeyAvailability.Disabled, "未设置");
                    continue;
                }
                if (!TryParseGesture(entry.Gesture, out var modifiers, out var key))
                {
                    results[entry.Action] = new(entry.Action, HotkeyAvailability.Invalid, "格式无效");
                    continue;
                }
                var id = 0x5A00 + (int)entry.Action;
                var virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
                if (NativeMethods.RegisterHotKey(source.Handle, id, modifiers | NativeMethods.ModNoRepeat, virtualKey))
                {
                    registered.Add(id);
                    results[entry.Action] = new(entry.Action, HotkeyAvailability.Available, "可用");
                }
                else
                {
                    results[entry.Action] = new(entry.Action, HotkeyAvailability.Conflict, "已被系统或其他应用占用");
                }
            }
        }
        finally
        {
            foreach (var id in registered) NativeMethods.UnregisterHotKey(source.Handle, id);
        }
        return results;
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
