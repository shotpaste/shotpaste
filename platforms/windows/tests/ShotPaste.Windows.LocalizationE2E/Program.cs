using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Drawing = System.Drawing;

namespace ShotPaste.Windows.LocalizationE2E;

internal static class Program
{
    private static readonly TimeSpan UiTimeout = TimeSpan.FromSeconds(22);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1) throw new ArgumentException("Usage: LocalizationE2E <ShotPaste.exe> [output-root]");
            var executable = Path.GetFullPath(args[0]);
            var outputRoot = Path.GetFullPath(args.ElementAtOrDefault(1) ??
                                              Path.Combine("build", "e2e", "localization"));
            var result = RunAsync(executable, outputRoot).GetAwaiter().GetResult();
            Directory.CreateDirectory(outputRoot);
            File.WriteAllText(Path.Combine(outputRoot, "summary.json"),
                JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine(JsonSerializer.Serialize(result));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }

    private static async Task<object> RunAsync(string executable, string outputRoot)
    {
        if (!File.Exists(executable)) throw new FileNotFoundException("Product executable was not found.", executable);
        Directory.CreateDirectory(outputRoot);
        var results = new List<object>();
        foreach (var language in LocalizationService.SupportedLanguages)
            results.Add(await RunLocaleAsync(executable, outputRoot, language));
        return new { Locales = results.Count, Results = results };
    }

    private static async Task<object> RunLocaleAsync(
        string executable,
        string outputRoot,
        LocalizationService.LanguageOption language)
    {
        var root = Path.Combine(outputRoot, language.Code);
        Directory.CreateDirectory(root);
        foreach (var fileName in new[] { "history.sqlite3", "history.sqlite3-shm", "history.sqlite3-wal", "crash.log" })
        {
            var path = Path.Combine(root, fileName);
            if (File.Exists(path)) File.Delete(path);
        }
        WriteSettings(root, language.Code);

        var shellEvidence = await VerifyHistoryAndSettingsAsync(executable, root, language.Code);
        var inlineEvidence = await VerifyInlineAsync(executable, root, language.Code);
        var recordingEvidence = await VerifyOneShotRecordingAsync(executable, root, language.Code);

        var persisted = JsonSerializer.Deserialize<AppSettings>(
                            await File.ReadAllTextAsync(Path.Combine(root, "settings.json"))) ??
                        throw new InvalidOperationException($"{language.Code}: settings did not persist.");
        if (!persisted.Language.Equals(language.Code, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"{language.Code}: persisted language changed to {persisted.Language}.");
        var crashLog = Path.Combine(root, "crash.log");
        if (File.Exists(crashLog))
            throw new InvalidOperationException($"{language.Code}: product wrote a crash log: {await File.ReadAllTextAsync(crashLog)}");
        return new
        {
            language.Code,
            language.NativeName,
            Shell = shellEvidence,
            Inline = inlineEvidence,
            OneShotRecording = recordingEvidence,
            PersistedLanguage = persisted.Language
        };
    }

    private static async Task<object> VerifyHistoryAndSettingsAsync(string executable, string root, string language)
    {
        using var product = Launch(executable, root, "--settings");
        try
        {
            var history = await WaitForAutomationIdAsync(product.Id, "HistoryWindow");
            var settings = await WaitForAutomationIdAsync(product.Id, "SettingsWindow");
            var expectedHistoryTitle = LocalizationService.Text(language, "history.title");
            var expectedSettingsTitle = LocalizationService.TranslatePhrase("ShotPaste · 设置", language);
            AssertEqual(expectedHistoryTitle, history.Current.Name, language, "history title");
            AssertEqual(expectedSettingsTitle, settings.Current.Name, language, "settings title");

            var names = VisibleNames(settings);
            var expectedSection = LocalizationService.TranslatePhrase("保存与截图后操作", language);
            var expectedSave = LocalizationService.TranslatePhrase("保存截图", language);
            AssertContains(names, expectedSection, language, "settings section");
            AssertContains(names, expectedSave, language, "settings checkbox");
            AssertNoSimplifiedChineseLeak(names, language);

            var screenshot = Path.Combine(root, "settings-and-history.png");
            SaveElementScreenshot(settings, screenshot);
            return new
            {
                HistoryTitle = history.Current.Name,
                SettingsTitle = settings.Current.Name,
                ExpectedSection = expectedSection,
                VisibleNames = names.Length,
                Screenshot = screenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> VerifyInlineAsync(string executable, string root, string language)
    {
        using var product = Launch(executable, root, "--one-shot");
        try
        {
            await WaitForAutomationIdAsync(product.Id, "InlineAnnotateWindow");
            await DragAsync(new Drawing.Point(90, 430), new Drawing.Point(610, 760));
            var selection = await WaitForAutomationIdAsync(product.Id, "SelectionImage");
            var selectionBounds = selection.Current.BoundingRectangle;
            if (selectionBounds.Width < 100 || selectionBounds.Height < 100)
                throw new InvalidOperationException($"{language}: inline selection did not enter annotation mode.");
            var done = await WaitForAutomationIdAsync(product.Id, "OneShotDone");
            var expectedHelp = LocalizationService.TranslatePhrase("完成", language);
            if (!done.Current.HelpText.Equals(expectedHelp, StringComparison.Ordinal))
                throw new InvalidOperationException(
                    $"{language}: inline Done help text mismatch: expected '{expectedHelp}', actual '{done.Current.HelpText}'.");
            Invoke(await WaitForAutomationIdAsync(product.Id, "OneShotCancel"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "OneShotDone") is null,
                $"{language}: inline window did not close after Cancel.");
            return new { SelectionWidth = selectionBounds.Width, SelectionHeight = selectionBounds.Height, DoneHelpText = expectedHelp };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> VerifyOneShotRecordingAsync(string executable, string root, string language)
    {
        using var product = Launch(executable, root, "--one-shot");
        try
        {
            var overlay = await WaitForAutomationIdAsync(product.Id, "InlineAnnotateWindow");
            Invoke(await WaitForAutomationIdAsync(product.Id, "OneShotRecording"));
            await DragAsync(new Drawing.Point(90, 430), new Drawing.Point(610, 760));
            var start = await WaitForAutomationIdAsync(product.Id, "OneShotStartRecording");
            var expectedStart = LocalizationService.TranslatePhrase("开始录屏", language);
            AssertEqual(expectedStart, start.Current.Name, language, "One Shot recording start");
            var visibleNames = VisibleNames(overlay);
            AssertContains(visibleNames, "MP4", language, "One Shot recording format");
            AssertContains(visibleNames, "GIF", language, "One Shot recording format");
            AssertNoSimplifiedChineseLeak(visibleNames, language);
            return new { Start = start.Current.Name, Controls = visibleNames.Length };
        }
        finally { StopExactProcess(product); }
    }

    private static Process Launch(string executable, string root, string command) =>
        Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", root, command }
        }) ?? throw new InvalidOperationException("Could not launch the product executable.");

    private static void StopExactProcess(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
        catch (InvalidOperationException) { }
    }

    private static void WriteSettings(string root, string language)
    {
        var settings = new AppSettings
        {
            SaveDirectory = Path.Combine(root, "Captures"),
            HistoryPanelPosition = "TopCenter",
            Language = language,
            ClipboardHistoryEnabled = false,
            ShortcutsEnabled = false,
            ShowQuickAccess = false,
            UrlSchemeEnabled = false,
            RecordSystemAudio = false,
            RecordMicrophone = false
        };
        Directory.CreateDirectory(settings.SaveDirectory);
        File.WriteAllText(Path.Combine(root, "settings.json"),
            JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static async Task<AutomationElement> WaitForAutomationIdAsync(int processId, string id)
    {
        AutomationElement? result = null;
        await WaitUntilAsync(() =>
        {
            result = FindByAutomationId(processId, id);
            return result is not null && !result.Current.IsOffscreen;
        }, $"Automation element {id} did not appear for process {processId}.");
        return result!;
    }

    private static AutomationElement? FindByAutomationId(int processId, string id)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.AutomationIdProperty, id));
        return AutomationElement.RootElement.FindFirst(TreeScope.Descendants, condition);
    }

    private static AutomationElement AncestorWindow(AutomationElement element)
    {
        var walker = TreeWalker.ControlViewWalker;
        for (var current = element; current is not null; current = walker.GetParent(current))
            if (current.Current.ControlType == ControlType.Window) return current;
        throw new InvalidOperationException("Element had no window ancestor.");
    }

    private static string[] VisibleNames(AutomationElement root) =>
        root.FindAll(TreeScope.Descendants, Condition.TrueCondition)
            .Cast<AutomationElement>()
            .Where(element => !element.Current.IsOffscreen && !string.IsNullOrWhiteSpace(element.Current.Name))
            .Select(element => element.Current.Name.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToArray();

    private static string[] VisibleHelpTexts(AutomationElement root) =>
        root.FindAll(TreeScope.Descendants, Condition.TrueCondition)
            .Cast<AutomationElement>()
            .Where(element => !element.Current.IsOffscreen && !string.IsNullOrWhiteSpace(element.Current.HelpText))
            .Select(element => element.Current.HelpText.Trim())
            .Distinct(StringComparer.Ordinal)
            .ToArray();

    private static void Invoke(AutomationElement element) =>
        ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();

    private static async Task DragAsync(Drawing.Point start, Drawing.Point end)
    {
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Native.SetCursorPos(start.X, start.Y);
        await Task.Delay(80);
        Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
        for (var step = 1; step <= 14; step++)
        {
            Native.SetCursorPos(start.X + (end.X - start.X) * step / 14,
                start.Y + (end.Y - start.Y) * step / 14);
            await Task.Delay(18);
        }
        Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
        await Task.Delay(280);
    }

    private static void SaveElementScreenshot(AutomationElement element, string path)
    {
        var bounds = element.Current.BoundingRectangle;
        var rectangle = Drawing.Rectangle.FromLTRB((int)Math.Round(bounds.Left), (int)Math.Round(bounds.Top),
            (int)Math.Round(bounds.Right), (int)Math.Round(bounds.Bottom));
        using var bitmap = new Drawing.Bitmap(rectangle.Width, rectangle.Height);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(rectangle.Left, rectangle.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, ImageFormat.Png);
    }

    private static void AssertEqual(string expected, string actual, string language, string label)
    {
        if (!expected.Equals(actual, StringComparison.Ordinal))
            throw new InvalidOperationException(
                $"{language}: {label} mismatch: expected '{expected}', actual '{actual}'.");
    }

    private static void AssertContains(
        IReadOnlyList<string> names,
        string expected,
        string language,
        string label,
        bool allowSubstring = false)
    {
        var found = allowSubstring
            ? names.Any(name => name.Contains(expected, StringComparison.OrdinalIgnoreCase))
            : names.Contains(expected, StringComparer.Ordinal);
        if (!found)
            throw new InvalidOperationException(
                $"{language}: localized {label} '{expected}' was not visible. Names: {string.Join(" | ", names.Take(20))}");
    }

    private static void AssertNoSimplifiedChineseLeak(IEnumerable<string> names, string language)
    {
        if (language == "zh-CN") return;
        var combined = string.Join("\n", names);
        var forbidden = language == "zh-TW"
            ? new[] { "设置", "录制", "截图", "选择目录", "历史记录", "剪贴板历史" }
            : language is "ja-JP" or "ko-KR"
                ? new[] { "保存与截图后操作", "复制到剪贴板", "还没有符合条件的记录", "历史记录", "剪贴板历史" }
                : new[] { "保存与截图后操作", "保存截图", "复制到剪贴板", "还没有符合条件的记录", "历史记录", "剪贴板历史" };
        var leaked = forbidden.FirstOrDefault(combined.Contains);
        if (leaked is not null)
        {
            var sourceName = names.FirstOrDefault(name => name.Contains(leaked, StringComparison.Ordinal)) ?? leaked;
            throw new InvalidOperationException(
                $"{language}: unlocalized Simplified Chinese text leaked: '{leaked}' in '{sourceName}'.");
        }
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, string failure)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < UiTimeout)
        {
            try { if (predicate()) return; }
            catch (ElementNotAvailableException) { }
            await Task.Delay(85);
        }
        throw new TimeoutException(failure);
    }

    private static class Native
    {
        internal const uint MouseLeftDown = 0x0002;
        internal const uint MouseLeftUp = 0x0004;

        [DllImport("user32.dll")]
        internal static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        internal static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extraInfo);
    }
}
