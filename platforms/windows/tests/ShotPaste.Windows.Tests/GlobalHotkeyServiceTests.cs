using System.Windows.Input;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class GlobalHotkeyServiceTests
{
    [Theory]
    [InlineData("Ctrl+Shift+4", Key.D4, NativeMethods.ModControl | NativeMethods.ModShift)]
    [InlineData("Win+Alt+A", Key.A, NativeMethods.ModWin | NativeMethods.ModAlt)]
    [InlineData("Control + H", Key.H, NativeMethods.ModControl)]
    [InlineData("Ctrl+Backspace", Key.Back, NativeMethods.ModControl)]
    [InlineData("Alt+Enter", Key.Return, NativeMethods.ModAlt)]
    [InlineData("Shift+Esc", Key.Escape, NativeMethods.ModShift)]
    [InlineData("Win+Del", Key.Delete, NativeMethods.ModWin)]
    public void ParsesConfigurableGesture(string gesture, Key expectedKey, uint expectedModifiers)
    {
        Assert.True(GlobalHotkeyService.TryParseGesture(gesture, out var modifiers, out var key));
        Assert.Equal(expectedKey, key);
        Assert.Equal(expectedModifiers, modifiers);
    }

    [Theory]
    [InlineData("")]
    [InlineData("A")]
    [InlineData("Ctrl+A+B")]
    [InlineData("Ctrl+NotAKey")]
    public void RejectsInvalidGesture(string gesture)
    {
        Assert.False(GlobalHotkeyService.TryParseGesture(gesture, out _, out _));
    }

    [Theory]
    [InlineData(Key.D4, Key.None, ModifierKeys.Control | ModifierKeys.Shift, "Ctrl+Shift+4")]
    [InlineData(Key.A, Key.None, ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows, "Ctrl+Alt+Win+A")]
    [InlineData(Key.System, Key.F, ModifierKeys.Alt, "Alt+F")]
    [InlineData(Key.Back, Key.None, ModifierKeys.Control | ModifierKeys.Shift, "Ctrl+Shift+Backspace")]
    public void FormatsRecordedKeyChord(Key eventKey, Key systemKey, ModifierKeys modifiers, string expected)
    {
        Assert.True(HotkeyGestureFormatter.TryFormat(eventKey, systemKey, modifiers, out var gesture));
        Assert.Equal(expected, gesture);
        Assert.True(GlobalHotkeyService.TryParseGesture(gesture, out _, out _));
    }

    [Theory]
    [InlineData(Key.LeftCtrl, ModifierKeys.Control)]
    [InlineData(Key.A, ModifierKeys.None)]
    public void IgnoresIncompleteRecordedKeyChord(Key key, ModifierKeys modifiers)
    {
        Assert.False(HotkeyGestureFormatter.TryFormat(key, Key.None, modifiers, out _));
    }

    [Fact]
    public void ParsesEveryDefaultConfiguredGesture()
    {
        var settings = new AppSettings();
        var gestures = new[]
        {
            settings.OneShotHotkey,
            settings.HistoryHotkey,
            settings.RecordingPauseHotkey,
            settings.RecordingAnnotationHotkey,
            settings.RecordingRestartHotkey,
            settings.RecordingDeleteHotkey
        };

        Assert.All(gestures, gesture =>
            Assert.True(GlobalHotkeyService.TryParseGesture(gesture, out _, out _), gesture));
    }

    [Fact]
    public void RegisteredActionsContainOnlyOneShotHistoryAndActiveRecordingControls()
    {
        Assert.Equal(
            [
                HotkeyAction.OneShot,
                HotkeyAction.History,
                HotkeyAction.RecordingPause,
                HotkeyAction.RecordingAnnotation,
                HotkeyAction.RecordingRestart,
                HotkeyAction.RecordingDelete
            ],
            Enum.GetValues<HotkeyAction>());
    }

    [Fact]
    public void KeystrokeOverlayBuildsReadableChord()
    {
        var pressed = new HashSet<int> { 0x11, 0x10 };
        Assert.Equal("Ctrl + Shift + A", KeystrokeOverlayService.BuildLabel(Key.A, pressed.Contains));
    }

    [Fact]
    public void KeystrokeOverlayFiltersUnmodifiedTypingButKeepsShortcutsAndSpecialKeys()
    {
        Assert.False(KeystrokeOverlayService.ShouldDisplay(Key.A, _ => false));
        Assert.True(KeystrokeOverlayService.ShouldDisplay(Key.A, key => key == 0x11));
        Assert.True(KeystrokeOverlayService.ShouldDisplay(Key.Escape, _ => false));
    }

    [Fact]
    public void KeystrokeOverlayVisibilityRuleSupportsAllConfiguredModes()
    {
        Assert.True(KeystrokeOverlayService.ShouldDisplay(Key.A, "All", _ => false));
        Assert.False(KeystrokeOverlayService.ShouldDisplay(Key.A, "ShortcutsOnly", _ => false));
        Assert.True(KeystrokeOverlayService.ShouldDisplay(Key.A, "ShortcutsOnly", key => key == 0x11));
        Assert.True(KeystrokeOverlayService.ShouldDisplay(Key.Escape, "SpecialOnly", _ => false));
        Assert.False(KeystrokeOverlayService.ShouldDisplay(Key.A, "SpecialOnly", _ => false));
    }
}
