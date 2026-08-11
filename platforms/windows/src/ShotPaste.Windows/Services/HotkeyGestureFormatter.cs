using System.Windows.Input;

namespace ShotPaste.Windows.Services;

internal static class HotkeyGestureFormatter
{
    internal static bool TryFormat(
        Key eventKey,
        Key systemKey,
        ModifierKeys modifiers,
        out string gesture)
    {
        gesture = string.Empty;
        var key = eventKey == Key.System ? systemKey : eventKey;
        if (IsModifierKey(key) || key is Key.None or Key.ImeProcessed)
            return false;

        if (modifiers == ModifierKeys.None)
            return false;

        var parts = new List<string>(5);
        if (modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(DisplayName(key));

        var candidate = string.Join('+', parts);
        if (!GlobalHotkeyService.TryParseGesture(candidate, out _, out _))
            return false;

        gesture = candidate;
        return true;
    }

    private static bool IsModifierKey(Key key) => key is
        Key.LeftCtrl or Key.RightCtrl or
        Key.LeftAlt or Key.RightAlt or
        Key.LeftShift or Key.RightShift or
        Key.LWin or Key.RWin;

    private static string DisplayName(Key key) => key switch
    {
        >= Key.D0 and <= Key.D9 => ((int)(key - Key.D0)).ToString(),
        Key.Back => "Backspace",
        Key.Return => "Enter",
        _ => key.ToString()
    };
}
