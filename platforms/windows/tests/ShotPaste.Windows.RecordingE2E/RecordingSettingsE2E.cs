using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Text.Json;
using System.Windows.Automation;
using ShotPaste.Windows.Models;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.RecordingE2E;

internal static class RecordingSettingsE2E
{
    internal static async Task<object> RunAsync(string executable, string outputRoot)
    {
        var root = Path.Combine(outputRoot, "recording-settings");
        Directory.CreateDirectory(root);
        var settingsPath = Path.Combine(root, "settings.json");
        File.WriteAllText(settingsPath, JsonSerializer.Serialize(new AppSettings
        {
            ClipboardHistoryEnabled = false,
            ShortcutsEnabled = false,
            Language = "zh-CN",
            RecordingClickRippleCount = 3,
            RecordingKeystrokePosition = "TopCenter",
            RecordingKeystrokeVisibility = "All"
        }, new JsonSerializerOptions { WriteIndented = true }));
        using var product = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", root, "--settings" }
        }) ?? throw new InvalidOperationException("Could not launch ShotPaste settings E2E.");
        var screenshot = Path.Combine(root, "recording-effects-preview.png");
        try
        {
            await WaitForAsync(product.Id, "SettingsWindow");
            Select(await WaitForAsync(product.Id, "SettingsCaptureRecordingTab"));
            Select(await WaitForAsync(product.Id, "SettingsCaptureRecordingSubtab"));
            SetValue(await WaitForAsync(product.Id, "RecordingClickRadius"), "52");
            SetValue(await WaitForAsync(product.Id, "RecordingClickOpacity"), "0.85");
            SetValue(await WaitForAsync(product.Id, "RecordingClickDuration"), "750");
            SetValue(await WaitForAsync(product.Id, "RecordingClickLeftColor"), "#FF39FF14");
            SetValue(await WaitForAsync(product.Id, "RecordingClickRightColor"), "#FFFF453A");
            SetValue(await WaitForAsync(product.Id, "RecordingKeystrokeFontSize"), "27");
            SetValue(await WaitForAsync(product.Id, "RecordingKeystrokeDuration"), "850");
            SetValue(await WaitForAsync(product.Id, "RecordingAnnotationFadeDuration"), "480");
            var include = await WaitForAsync(product.Id, "IncludeShotPasteInRecording");
            if (include.GetCurrentPattern(TogglePattern.Pattern) is TogglePattern toggle &&
                toggle.Current.ToggleState != ToggleState.On)
                toggle.Toggle();

            Invoke(await WaitForAsync(product.Id, "PreviewRecordingEffects"));
            await WaitForAsync(product.Id, "MouseClickEffectPreview");
            await WaitForAsync(product.Id, "KeystrokeEffectPreview");
            SaveDesktopScreenshot(screenshot);
            await Task.Delay(1150);
            Invoke(await WaitForAsync(product.Id, "SettingsSave"));
            await WaitUntilAsync(() => Find(product.Id, "SettingsWindow") is null,
                "Settings window did not close after Save.");

            var saved = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(settingsPath)) ??
                        throw new InvalidOperationException("Saved settings JSON was empty.");
            if (saved.RecordingClickRadius != 52 || Math.Abs(saved.RecordingClickOpacity - 0.85) > 0.001 ||
                saved.RecordingClickDurationMs != 750 || saved.RecordingClickRippleCount != 3 ||
                saved.RecordingKeystrokeFontSize != 27 || saved.RecordingKeystrokeDurationMs != 850 ||
                saved.RecordingKeystrokePosition != "TopCenter" || saved.RecordingKeystrokeVisibility != "All" ||
                saved.RecordingAnnotationFadeMilliseconds != 480 || !saved.IncludeShotPasteInRecording)
                throw new InvalidOperationException("Recording effect settings were not persisted exactly after UI preview.");
            return new
            {
                PreviewScreenshot = screenshot,
                saved.RecordingClickRadius,
                saved.RecordingClickOpacity,
                saved.RecordingClickDurationMs,
                saved.RecordingClickRippleCount,
                saved.RecordingClickLeftColor,
                saved.RecordingClickRightColor,
                saved.RecordingKeystrokePosition,
                saved.RecordingKeystrokeFontSize,
                saved.RecordingKeystrokeDurationMs,
                saved.RecordingKeystrokeVisibility,
                saved.RecordingAnnotationFadeMilliseconds,
                saved.IncludeShotPasteInRecording
            };
        }
        finally
        {
            if (!product.HasExited)
            {
                product.Kill(entireProcessTree: true);
                product.WaitForExit(5000);
            }
        }
    }

    private static void SetValue(AutomationElement element, string value)
    {
        if (element.GetCurrentPattern(ValuePattern.Pattern) is not ValuePattern pattern)
            throw new InvalidOperationException($"{element.Current.AutomationId} does not support ValuePattern.");
        pattern.SetValue(value);
    }

    private static void Invoke(AutomationElement element)
    {
        if (element.GetCurrentPattern(InvokePattern.Pattern) is not InvokePattern pattern)
            throw new InvalidOperationException($"{element.Current.AutomationId} does not support InvokePattern.");
        pattern.Invoke();
    }

    private static void Select(AutomationElement element)
    {
        if (element.GetCurrentPattern(SelectionItemPattern.Pattern) is not SelectionItemPattern pattern)
            throw new InvalidOperationException($"{element.Current.AutomationId} does not support SelectionItemPattern.");
        pattern.Select();
    }

    private static async Task<AutomationElement> WaitForAsync(int processId, string automationId)
    {
        AutomationElement? result = null;
        await WaitUntilAsync(() => (result = Find(processId, automationId)) is not null,
            $"Automation element {automationId} did not appear.");
        return result!;
    }

    private static AutomationElement? Find(int processId, string automationId)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.AutomationIdProperty, automationId));
        return AutomationElement.RootElement.FindFirst(TreeScope.Descendants, condition);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, string failure)
    {
        var timeout = Stopwatch.StartNew();
        while (timeout.Elapsed < TimeSpan.FromSeconds(20))
        {
            try { if (predicate()) return; }
            catch (ElementNotAvailableException) { }
            await Task.Delay(80);
        }
        throw new TimeoutException(failure);
    }

    private static void SaveDesktopScreenshot(string path)
    {
        var bounds = Forms.SystemInformation.VirtualScreen;
        using var bitmap = new Drawing.Bitmap(bounds.Width, bounds.Height);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, ImageFormat.Png);
    }
}
