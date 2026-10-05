using System.Diagnostics;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Media;
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
            if (args.Length < 1) throw new ArgumentException("Usage: LocalizationE2E <ShotPaste.exe> [output-root] [--require-dpi-scale=1.5] [--language=zh-CN]");
            Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
            var executable = Path.GetFullPath(args[0]);
            var outputRoot = Path.GetFullPath(args.ElementAtOrDefault(1) ??
                                              Path.Combine("build", "e2e", "localization"));
            var requiredDpiScale = args.Skip(2)
                .FirstOrDefault(argument => argument.StartsWith("--require-dpi-scale=", StringComparison.OrdinalIgnoreCase))?
                .Split('=', 2).ElementAtOrDefault(1);
            var requestedLanguage = args.Skip(2).FirstOrDefault(argument => argument.StartsWith("--language=", StringComparison.OrdinalIgnoreCase))?.Split('=', 2)[1];
            var result = RunAsync(executable, outputRoot,
                double.TryParse(requiredDpiScale, NumberStyles.Float, CultureInfo.InvariantCulture, out var scale)
                    ? scale
                    : 0, requestedLanguage).GetAwaiter().GetResult();
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

    private static async Task<object> RunAsync(string executable, string outputRoot, double requiredDpiScale, string? requestedLanguage)
    {
        if (!File.Exists(executable)) throw new FileNotFoundException("Product executable was not found.", executable);
        Directory.CreateDirectory(outputRoot);
        var results = new List<object>();
        var languages = LocalizationService.SupportedLanguages.Where(language => requestedLanguage is null ||
            language.Code.Equals(requestedLanguage, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (languages.Length == 0) throw new ArgumentException("Unknown localization test language.");
        foreach (var language in languages)
            results.Add(await RunLocaleAsync(executable, outputRoot, language, requiredDpiScale));
        return new { Locales = results.Count, RequiredDpiScale = requiredDpiScale, Results = results };
    }

    private static async Task<object> RunLocaleAsync(
        string executable,
        string outputRoot,
        LocalizationService.LanguageOption language,
        double requiredDpiScale)
    {
        var root = Path.Combine(outputRoot, language.Code);
        Directory.CreateDirectory(root);
        foreach (var fileName in new[] { "history.sqlite3", "history.sqlite3-shm", "history.sqlite3-wal", "crash.log" })
        {
            var path = Path.Combine(root, fileName);
            if (File.Exists(path)) File.Delete(path);
        }
        WriteSettings(root, language.Code);
        var fixtureHistory = new CaptureHistoryStore(Path.Combine(root, "history.sqlite3"), Path.Combine(root, "Thumbnails"));
        await fixtureHistory.LoadAsync();
        await fixtureHistory.AddTextAsync("ShotPaste localization layout-check selection fixture");

        var shellEvidence = await VerifyHistoryAndSettingsAsync(executable, root, language.Code, requiredDpiScale);
        var inlineEvidence = await VerifyInlineAsync(executable, root, language.Code, requiredDpiScale);
        var recordingEvidence = await VerifyOneShotRecordingAsync(executable, root, language.Code, requiredDpiScale);
        var auxiliaryEvidence = await VerifyAuxiliarySurfacesAsync(executable, root, language.Code, requiredDpiScale);

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
            AuxiliarySurfaces = auxiliaryEvidence,
            PersistedLanguage = persisted.Language
        };
    }

    private static async Task<object> VerifyHistoryAndSettingsAsync(
        string executable,
        string root,
        string language,
        double requiredDpiScale)
    {
        using var product = Launch(executable, root, "--settings");
        try
        {
            var history = await WaitForAutomationIdAsync(product.Id, "HistoryWindow");
            var settings = await WaitForAutomationIdAsync(product.Id, "SettingsWindow");
            var expectedHistoryTitle = AppBuildIdentity.Current.FormatWindowTitle(
                LocalizationService.Text(language, "history.title"));
            var expectedSettingsTitle = AppBuildIdentity.Current.FormatWindowTitle(
                LocalizationService.TranslatePhrase("ShotPaste · 设置", language));
            AssertEqual(expectedHistoryTitle, history.Current.Name, language, "history title");
            AssertEqual(expectedSettingsTitle, settings.Current.Name, language, "settings title");

            var actualDpiScale = Native.GetDpiForWindow(new IntPtr(settings.Current.NativeWindowHandle)) / 96d;
            if (requiredDpiScale > 0 && Math.Abs(actualDpiScale - requiredDpiScale) > 0.04)
                throw new InvalidOperationException(
                    $"{language}: settings rendered at {actualDpiScale:0.##}x, required {requiredDpiScale:0.##}x.");

            var pages = new[]
            {
                (Name: "general", Top: "SettingsGeneralTab", Inner: (string?)null),
                (Name: "capture-general", Top: "SettingsCaptureRecordingTab", Inner: "SettingsCaptureGeneralSubtab"),
                (Name: "capture-screenshot", Top: "SettingsCaptureRecordingTab", Inner: "SettingsCaptureScreenshotSubtab"),
                (Name: "capture-recording", Top: "SettingsCaptureRecordingTab", Inner: "SettingsCaptureRecordingSubtab"),
                (Name: "quick-access", Top: "SettingsQuickAccessTab", Inner: (string?)null),
                (Name: "history", Top: "SettingsHistoryTab", Inner: (string?)null),
                (Name: "ai", Top: "SettingsAiTab", Inner: (string?)null),
                (Name: "shortcuts", Top: "SettingsShortcutsTab", Inner: (string?)null),
                (Name: "advanced", Top: "SettingsAdvancedTab", Inner: (string?)null)
            };
            var pageEvidence = new List<object>();
            foreach (var page in pages)
            {
                Select(await WaitForAutomationIdAsync(product.Id, page.Top));
                if (page.Inner is not null) Select(await WaitForAutomationIdAsync(product.Id, page.Inner));
                await Task.Delay(240);
                var pageNames = VisibleNames(settings);
                AssertNoSimplifiedChineseLeak(pageNames, language);
                var pageScreenshot = Path.Combine(root, $"settings-{page.Name}.png");
                SaveElementScreenshot(settings, pageScreenshot);
                var layout = AssertVisibleLayout(settings, language, page.Name, actualDpiScale);
                pageEvidence.Add(new
                {
                    page.Name,
                    VisibleNames = pageNames.Length,
                    layout.VisibleInteractiveControls,
                    layout.MeasuredSingleLineTexts,
                    Screenshot = pageScreenshot
                });
            }

            Select(await WaitForAutomationIdAsync(product.Id, "SettingsCaptureRecordingTab"));
            Select(await WaitForAutomationIdAsync(product.Id, "SettingsCaptureGeneralSubtab"));
            await Task.Delay(160);
            var names = VisibleNames(settings);
            var expectedSection = LocalizationService.TranslatePhrase("保存与截图后操作", language);
            var expectedSave = LocalizationService.TranslatePhrase("保存", language);
            AssertContains(names, expectedSection, language, "settings section");
            AssertContains(names, expectedSave, language, "save action row");
            AssertContains(names, LocalizationService.TranslatePhrase("截图", language), language, "screenshot action column");
            AssertContains(names, LocalizationService.TranslatePhrase("屏幕录制", language), language, "recording action column");
            AssertNoSimplifiedChineseLeak(names, language);

            Invoke(await WaitForAutomationIdAsync(product.Id, "SettingsSave"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "SettingsWindow") is null,
                $"{language}: settings window did not close before history validation.");
            await Task.Delay(180);
            var historyNames = VisibleNames(history);
            AssertNoSimplifiedChineseLeak(historyNames, language);
            var historyScreenshot = Path.Combine(root, "history-window.png");
            SaveElementScreenshot(history, historyScreenshot);
            var historyLayout = AssertVisibleLayout(history, language, "history-window", actualDpiScale);
            var searchEvidence = await VerifyHistorySearchAsync(history, product.Id, root, language, actualDpiScale);
            return new
            {
                HistoryTitle = history.Current.Name,
                SettingsTitle = settings.Current.Name,
                DpiScale = actualDpiScale,
                ExpectedSection = expectedSection,
                VisibleNames = names.Length,
                HistoryScreenshot = historyScreenshot,
                HistoryVisibleInteractiveControls = historyLayout.VisibleInteractiveControls,
                HistoryMeasuredSingleLineTexts = historyLayout.MeasuredSingleLineTexts,
                SearchEvidence = searchEvidence,
                Pages = pageEvidence
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<IReadOnlyList<object>> VerifyHistorySearchAsync(
        AutomationElement history, int processId, string root, string language, double dpiScale)
    {
        var originalBounds = history.Current.BoundingRectangle;
        if (!history.TryGetCurrentPattern(TransformPattern.Pattern, out var raw) || raw is not TransformPattern transform || !transform.Current.CanResize)
            throw new InvalidOperationException($"{language}: history window did not expose native resizing for the minimum-width layout check.");
        var evidence = new List<object>();
        foreach (var size in new[] { "default", "minimum" })
        {
            if (size == "minimum")
            {
                transform.Resize(860 * dpiScale, originalBounds.Height);
                await Task.Delay(240);
            }
            var search = await WaitForAutomationIdAsync(processId, "HistorySearch");
            var date = await WaitForAutomationIdAsync(processId, "HistoryTimeFilter");
            var expectedName = LocalizationService.TranslatePhrase("搜索捕获内容", language);
            AssertEqual(expectedName, search.Current.Name, language, "complete accessible history search name");
            AssertElementHit(search, language, "history search");
            AssertElementHit(date, language, "history date filter");
            AssertElementHit(await WaitForAutomationIdAsync(processId, "ScreenshotHistoryFilter"), language, "history screenshot filter");
            AssertElementHit(await WaitForAutomationIdAsync(processId, "ClipboardHistoryFilter"), language, "history clipboard filter");
            ClickElement(search, language, "history search");
            ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).SetValue("layout-check");
            await WaitUntilAsync(() => ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).Current.Value == "layout-check",
                $"{language}: history search did not accept input at {size} width.");
            var clear = await WaitForAutomationIdAsync(processId, "HistoryClearSearch");
            AssertElementHit(search, language, "history search with clear action");
            AssertElementHit(date, language, "history date filter with search input");
            AssertVisibleLayout(history, language, "history-window", dpiScale);
            var screenshot = Path.Combine(root, $"history-search-{size}.png");
            SaveElementScreenshot(history, screenshot);
            var searchBounds = search.Current.BoundingRectangle;
            var dateBounds = date.Current.BoundingRectangle;
            var clearBounds = clear.Current.BoundingRectangle;
            var selectionEvidence = await VerifyHistorySelectionAsync(history, processId, root, language, dpiScale, size);
            clear = await WaitForAutomationIdAsync(processId, "HistoryClearSearch");
            ClickElement(clear, language, "history search clear");
            await WaitUntilAsync(() => ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).Current.Value.Length == 0,
                $"{language}: clearing history search did not empty its native value at {size} width.");
            AssertVisibleLayout(history, language, "history-window", dpiScale);
            evidence.Add(new { Size = size, WindowBounds = history.Current.BoundingRectangle, Search = searchBounds,
                Date = dateBounds, Clear = clearBounds, InputAcceptedAndCleared = true,
                Selection = selectionEvidence, Screenshot = screenshot });
        }
        transform.Resize(originalBounds.Width, originalBounds.Height);
        await Task.Delay(180);
        return evidence;
    }

    private static async Task<object> VerifyHistorySelectionAsync(
        AutomationElement history, int processId, string root, string language, double dpiScale, string size)
    {
        var grid = await WaitForAutomationIdAsync(processId, "ExpandedHistoryGrid");
        AutomationElement? item = null;
        await WaitUntilAsync(() =>
        {
            item = grid.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem))
                .Cast<AutomationElement>().FirstOrDefault(element => !element.Current.IsOffscreen &&
                    element.Current.Name.Contains("layout-check selection fixture", StringComparison.Ordinal));
            return item is not null;
        }, $"{language}: the selected-history layout fixture did not survive the search filter.");
        var itemName = item!.Current.Name;
        ClickElement(item, language, "history item selection");
        var clearSelection = await WaitForAutomationIdAsync(processId, "HistoryClearSelection");
        var summary = await WaitForAutomationIdAsync(processId, "HistorySelectionSummary");
        var expectedSummary = LocalizationService.TranslatePhrase("已选择 {count} 项", language)
            .Replace("{count}", 1.ToString(CultureInfo.CurrentCulture), StringComparison.Ordinal);
        AssertEqual(expectedSummary, summary.Current.Name, language, "localized selected-history count");
        AssertNoSimplifiedChineseLeak(VisibleNames(history), language);
        var search = FindByAutomationId(processId, "HistorySearch");
        if (search is not null && !search.Current.IsOffscreen)
            throw new InvalidOperationException($"{language}: selection actions did not replace the search field at {size} width.");
        var copySelection = await WaitForAutomationIdAsync(processId, "HistoryCopySelection");
        var deleteSelection = await WaitForAutomationIdAsync(processId, "HistoryDeleteSelection");
        AssertElementHit(copySelection, language, "copy selected history");
        AssertElementHit(clearSelection, language, "clear history selection");
        AssertElementHit(deleteSelection, language, "delete selected history");
        AssertElementHit(await WaitForAutomationIdAsync(processId, "HistoryTimeFilter"), language, "date filter during selection");
        AssertVisibleLayout(history, language, "history-window", dpiScale);
        var screenshot = Path.Combine(root, $"history-selection-{size}.png");
        SaveElementScreenshot(history, screenshot);
        var copyBounds = copySelection.Current.BoundingRectangle;
        var clearBounds = clearSelection.Current.BoundingRectangle;
        var deleteBounds = deleteSelection.Current.BoundingRectangle;
        ClickElement(deleteSelection, language, "selected-history deletion confirmation");
        var dialog = await WaitForAutomationIdAsync(processId, "ShotPasteDialog");
        var expectedMessage = LocalizationService.TranslatePhrase("确定删除选中的 {count} 条历史记录吗？由 ShotPaste 保存的文件会移入 Windows 回收站，可以恢复。", language)
            .Replace("{count}", 1.ToString(CultureInfo.CurrentCulture), StringComparison.Ordinal);
        AssertContains(VisibleNames(dialog), expectedMessage, language, "localized selection-delete message");
        AssertEqual(AppBuildIdentity.Current.FormatWindowTitle(LocalizationService.TranslatePhrase("删除历史记录", language)),
            dialog.Current.Name, language, "localized selection-delete title");
        var primary = await WaitForAutomationIdAsync(processId, "DialogPrimary");
        AssertEqual(LocalizationService.TranslatePhrase("移入回收站", language), primary.Current.Name, language, "localized recycle action");
        AssertNoSimplifiedChineseLeak(VisibleNames(dialog), language);
        AssertElementHit(primary, language, "selected-history recycle confirmation");
        var cancel = await WaitForAutomationIdAsync(processId, "DialogSecondary");
        AssertEqual(LocalizationService.TranslatePhrase("取消", language), cancel.Current.Name, language, "localized cancellation action");
        AssertElementHit(cancel, language, "selected-history delete cancellation");
        AssertVisibleLayout(dialog, language, "selection-delete-dialog", dpiScale);
        var dialogScreenshot = Path.Combine(root, $"history-selection-delete-{size}.png");
        SaveElementScreenshot(dialog, dialogScreenshot);
        ClickElement(cancel, language, "selected-history delete cancellation");
        await WaitUntilAsync(() => FindByAutomationId(processId, "ShotPasteDialog") is null,
            $"{language}: cancelling selection deletion did not close the confirmation.");
        if (!string.Equals(item.Current.Name, itemName, StringComparison.Ordinal) ||
            !((SelectionItemPattern)item.GetCurrentPattern(SelectionItemPattern.Pattern)).Current.IsSelected)
            throw new InvalidOperationException($"{language}: cancelling deletion lost the fixture item or its selection.");
        clearSelection = await WaitForAutomationIdAsync(processId, "HistoryClearSelection");
        ClickElement(clearSelection, language, "clear history selection");
        search = await WaitForAutomationIdAsync(processId, "HistorySearch");
        await WaitUntilAsync(() => ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).Current.Value == "layout-check",
            $"{language}: clearing selection lost the previous search text at {size} width.");
        if (!string.Equals(item.Current.Name, itemName, StringComparison.Ordinal) ||
            ((SelectionItemPattern)item.GetCurrentPattern(SelectionItemPattern.Pattern)).Current.IsSelected)
            throw new InvalidOperationException($"{language}: clearing selection changed the filtered item or left it selected.");
        AssertElementHit(search, language, "restored history search");
        AssertVisibleLayout(history, language, "history-window", dpiScale);
        return new { Item = itemName, Copy = copyBounds, Clear = clearBounds, Delete = deleteBounds,
            SearchTextPreserved = true, FilteredItemPreserved = true, DeleteCancelledAndSelectionPreserved = true,
            DeleteMessage = expectedMessage, DeleteScreenshot = dialogScreenshot, Screenshot = screenshot };
    }

    private static void AssertElementHit(AutomationElement element, string language, string label)
    {
        var bounds = element.Current.BoundingRectangle;
        if (element.Current.IsOffscreen || !element.Current.IsEnabled || bounds.Width <= 1 || bounds.Height <= 1)
            throw new InvalidOperationException($"{language}: {label} was not visibly operable: {bounds}.");
        var point = new System.Windows.Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
        var hit = AutomationElement.FromPoint(point);
        if (!IsSelfOrDescendant(hit, element))
            throw new InvalidOperationException($"{language}: {label} is obscured at its center by {hit.Current.AutomationId}.");
    }

    private static void ClickElement(AutomationElement element, string language, string label)
    {
        AssertElementHit(element, language, label);
        var bounds = element.Current.BoundingRectangle;
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Native.SetCursorPos((int)Math.Round(bounds.Left + bounds.Width / 2), (int)Math.Round(bounds.Top + bounds.Height / 2));
        Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
        Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
    }

    private static async Task<object> VerifyInlineAsync(
        string executable,
        string root,
        string language,
        double requiredDpiScale)
    {
        using var product = Launch(executable, root, "--one-shot");
        try
        {
            var overlay = await WaitForAutomationIdAsync(product.Id, "InlineAnnotateWindow");
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
            var dpiScale = AssertRequiredDpi(overlay, requiredDpiScale, language, "inline annotation");
            var screenshot = Path.Combine(root, "inline-annotation.png");
            SaveElementScreenshot(overlay, screenshot);
            var layout = AssertVisibleLayout(overlay, language, "inline-annotation", dpiScale);
            var scrolledTools = await VerifyClippedAnnotationToolsAsync(overlay, product.Id, root, language, dpiScale);
            Invoke(await WaitForAutomationIdAsync(product.Id, "OneShotCancel"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "OneShotDone") is null,
                $"{language}: inline window did not close after Cancel.");
            return new
            {
                SelectionWidth = selectionBounds.Width,
                SelectionHeight = selectionBounds.Height,
                DoneHelpText = expectedHelp,
                DpiScale = dpiScale,
                layout.VisibleInteractiveControls,
                layout.MeasuredSingleLineTexts,
                ScrolledTools = scrolledTools,
                Screenshot = screenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> VerifyOneShotRecordingAsync(
        string executable,
        string root,
        string language,
        double requiredDpiScale)
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
            AssertContains(visibleNames, LocalizationService.TranslatePhrase("MP4", language), language,
                "One Shot recording format");
            AssertContains(visibleNames, LocalizationService.TranslatePhrase("GIF", language), language,
                "One Shot recording format");
            AssertNoSimplifiedChineseLeak(visibleNames, language);
            var dpiScale = AssertRequiredDpi(overlay, requiredDpiScale, language, "One Shot recording");
            var screenshot = Path.Combine(root, "one-shot-recording.png");
            SaveElementScreenshot(overlay, screenshot);
            var layout = AssertVisibleLayout(overlay, language, "one-shot-recording", dpiScale);
            return new
            {
                Start = start.Current.Name,
                Controls = visibleNames.Length,
                DpiScale = dpiScale,
                layout.VisibleInteractiveControls,
                layout.MeasuredSingleLineTexts,
                Screenshot = screenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> VerifyAuxiliarySurfacesAsync(
        string executable,
        string root,
        string language,
        double requiredDpiScale)
    {
        var plans = new[]
        {
            (Name: "ocr-card", Surface: "ocr", AutomationId: "OcrResultCard"),
            (Name: "scrolling-save-recovery", Surface: "scrolling-recovery", AutomationId: "ScrollingProgressWindow"),
            (Name: "recording-toolbar", Surface: "recording-toolbar", AutomationId: "RecordingToolbarWindow"),
            (Name: "audio-preparation", Surface: "audio-preparation", AutomationId: "AudioRecordingPreparationWindow"),
            (Name: "transcription-results", Surface: "transcription-results", AutomationId: "TranscriptionResultsWindow"),
            (Name: "quick-access", Surface: "quick-access", AutomationId: "QuickAccessWindow"),
            (Name: "dirty-dialog", Surface: "dialog", AutomationId: "ShotPasteDialog")
        };
        var evidence = new List<object>();
        foreach (var plan in plans)
        {
            using var product = Launch(executable, root, $"--ui-test-surface={plan.Surface}");
            try
            {
                var surface = await WaitForAutomationIdAsync(product.Id, plan.AutomationId);
                var dpiScale = AssertRequiredDpi(surface, requiredDpiScale, language, plan.Name);
                object? badgeEvidence = null;
                if (plan.Surface == "quick-access")
                    badgeEvidence = await VerifyQuickAccessBadgesAsync(surface, product.Id, root, language, dpiScale);
                var names = VisibleNames(surface);
                AssertNoSimplifiedChineseLeak(names, language);
                var screenshot = Path.Combine(root, $"{plan.Name}.png");
                SaveElementScreenshot(surface, screenshot);
                var layout = AssertVisibleLayout(surface, language, plan.Name, dpiScale);
                evidence.Add(new
                {
                    plan.Name,
                    plan.AutomationId,
                    DpiScale = dpiScale,
                    VisibleNames = names.Length,
                    layout.VisibleInteractiveControls,
                    layout.MeasuredSingleLineTexts,
                    BadgeEvidence = badgeEvidence,
                    Screenshot = screenshot
                });
            }
            finally { StopExactProcess(product); }
        }
        return new { Count = evidence.Count, Surfaces = evidence };
    }

    private static async Task<object> VerifyQuickAccessBadgesAsync(
        AutomationElement card, int processId, string root, string language, double dpiScale)
    {
        var bounds = card.Current.BoundingRectangle;
        var work = System.Windows.Forms.Screen.FromHandle(new IntPtr(card.Current.NativeWindowHandle)).WorkingArea;
        var outsideX = bounds.Left > work.Left + 20 ? bounds.Left - 12 : bounds.Right + 12;
        var outsideY = Math.Clamp(bounds.Top - 12, work.Top + 2, work.Bottom - 2);
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Native.SetCursorPos((int)Math.Round(Math.Clamp(outsideX, work.Left + 2, work.Right - 2)), (int)Math.Round(outsideY));
        await Task.Delay(500);
        var title = await WaitForAutomationIdAsync(processId, "QuickAccessTitle");
        const string fullTitle = "ShotPaste localization preview";
        AssertEqual(fullTitle, title.Current.Name, language, "complete accessible Quick Access title");
        var titleBounds = title.Current.BoundingRectangle;
        if (!Contains(bounds, titleBounds))
            throw new InvalidOperationException($"{language}: idle Quick Access title escapes its card: {titleBounds} outside {bounds}.");
        var duration = FindByAutomationId(processId, "QuickAccessDuration");
        if (duration is not null && !duration.Current.IsOffscreen)
            throw new InvalidOperationException($"{language}: a text Quick Access item unexpectedly displayed a recording duration.");
        AssertVisibleLayout(card, language, "quick-access-idle", dpiScale);
        var idleScreenshot = Path.Combine(root, "quick-access-idle-title.png");
        SaveElementScreenshot(card, idleScreenshot);

        Native.SetCursorPos((int)Math.Round(bounds.Left + bounds.Width / 2), (int)Math.Round(bounds.Top + bounds.Height / 2));
        await WaitUntilAsync(() =>
        {
            var badge = FindByAutomationId(processId, "QuickAccessTitle");
            return badge is null || badge.Current.IsOffscreen;
        }, $"{language}: hovering Quick Access left an invisible title exposed to accessibility.");
        await Task.Delay(220);
        await WaitForAutomationIdAsync(processId, "QuickAccessCopy");
        AssertVisibleLayout(card, language, "quick-access-hover", dpiScale);
        var hoverScreenshot = Path.Combine(root, "quick-access-hover-actions.png");
        SaveElementScreenshot(card, hoverScreenshot);

        Native.SetCursorPos((int)Math.Round(Math.Clamp(outsideX, work.Left + 2, work.Right - 2)), (int)Math.Round(outsideY));
        await Task.Delay(260);
        title = await WaitForAutomationIdAsync(processId, "QuickAccessTitle");
        AssertEqual(fullTitle, title.Current.Name, language, "restored accessible Quick Access title");
        if (!Contains(bounds, title.Current.BoundingRectangle))
            throw new InvalidOperationException($"{language}: restored Quick Access title escapes its card.");
        duration = FindByAutomationId(processId, "QuickAccessDuration");
        if (duration is not null && !duration.Current.IsOffscreen)
            throw new InvalidOperationException($"{language}: leaving a text card hover incorrectly restored a recording duration.");
        AssertVisibleLayout(card, language, "quick-access-restored", dpiScale);
        var restoredScreenshot = Path.Combine(root, "quick-access-restored-title.png");
        SaveElementScreenshot(card, restoredScreenshot);
        // Leave the card in the action mode used by the existing auxiliary-surface contract.
        Native.SetCursorPos((int)Math.Round(bounds.Left + bounds.Width / 2), (int)Math.Round(bounds.Top + bounds.Height / 2));
        await Task.Delay(220);
        return new
        {
            FullAccessibleTitle = fullTitle,
            IdleTitleBounds = titleBounds,
            TextItemDurationVisible = false,
            IdleScreenshot = idleScreenshot,
            HoverScreenshot = hoverScreenshot,
            RestoredScreenshot = restoredScreenshot
        };
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

    private static void Select(AutomationElement element)
    {
        if (element.GetCurrentPattern(SelectionItemPattern.Pattern) is not SelectionItemPattern pattern)
            throw new InvalidOperationException($"{element.Current.AutomationId} does not support SelectionItemPattern.");
        pattern.Select();
    }

    private static double AssertRequiredDpi(
        AutomationElement window,
        double requiredDpiScale,
        string language,
        string surface)
    {
        var actual = Native.GetDpiForWindow(new IntPtr(window.Current.NativeWindowHandle)) / 96d;
        if (requiredDpiScale > 0 && Math.Abs(actual - requiredDpiScale) > 0.04)
            throw new InvalidOperationException(
                $"{language}: {surface} rendered at {actual:0.##}x, required {requiredDpiScale:0.##}x.");
        return actual;
    }

    private static (int VisibleInteractiveControls, int MeasuredSingleLineTexts) AssertVisibleLayout(
        AutomationElement window,
        string language,
        string page,
        double dpiScale)
    {
        var windowBounds = window.Current.BoundingRectangle;
        var screen = System.Windows.Forms.Screen.FromHandle(new IntPtr(window.Current.NativeWindowHandle));
        var screenWorkArea = screen.WorkingArea;
        const double workAreaTolerance = 3d;
        var permittedArea = page is "inline-annotation" or "one-shot-recording"
            ? screen.Bounds
            : screenWorkArea;
        if (windowBounds.Left < permittedArea.Left - workAreaTolerance ||
            windowBounds.Top < permittedArea.Top - workAreaTolerance ||
            windowBounds.Right > permittedArea.Right + workAreaTolerance ||
            windowBounds.Bottom > permittedArea.Bottom + workAreaTolerance)
            throw new InvalidOperationException(
                $"{language}/{page}: window {windowBounds} exceeds permitted monitor area {permittedArea} at {dpiScale:0.##}x.");
        var footerAction = window.FindFirst(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.AutomationIdProperty, "SettingsSave"));
        var contentViewportBottom = footerAction?.Current.BoundingRectangle.Top ?? windowBounds.Bottom;
        var elements = window.FindAll(TreeScope.Descendants, Condition.TrueCondition)
            .Cast<AutomationElement>()
            .Where(element => !element.Current.IsOffscreen)
            .Select(element =>
            {
                var rawBounds = element.Current.BoundingRectangle;
                var visible = VisibleBounds(element, windowBounds);
                return (Element: element, RawBounds: rawBounds, Bounds: visible.Bounds,
                    visible.HorizontalScrollAncestor);
            })
            .Where(item => item.Bounds.Width > 1 && item.Bounds.Height > 1)
            .Where(item => item.Bounds.Left + item.Bounds.Width / 2 >= windowBounds.Left &&
                           item.Bounds.Left + item.Bounds.Width / 2 <= windowBounds.Right &&
                           item.Bounds.Top + item.Bounds.Height / 2 >= windowBounds.Top &&
                           item.Bounds.Top + item.Bounds.Height / 2 <= windowBounds.Bottom)
            .Where(item => item.Bounds.Bottom <= contentViewportBottom + 1 ||
                           item.Element.Current.AutomationId == "SettingsSave")
            .ToArray();
        foreach (var item in elements)
        {
            const double tolerance = 2.5;
            if (!item.HorizontalScrollAncestor &&
                (item.RawBounds.Left < windowBounds.Left - tolerance ||
                 item.RawBounds.Right > windowBounds.Right + tolerance))
                throw new InvalidOperationException(
                    $"{language}/{page}: '{item.Element.Current.Name}' ({item.Element.Current.ControlType.ProgrammaticName}) is clipped horizontally by the window: {item.RawBounds} outside {windowBounds}.");
        }

        var interactiveTypes = new HashSet<ControlType>
        {
            ControlType.Button, ControlType.CheckBox, ControlType.ComboBox, ControlType.Edit,
            ControlType.Hyperlink, ControlType.RadioButton, ControlType.Slider, ControlType.TabItem
        };
        var interactive = elements.Where(item => interactiveTypes.Contains(item.Element.Current.ControlType)).ToArray();
        for (var left = 0; left < interactive.Length; left++)
        for (var right = left + 1; right < interactive.Length; right++)
        {
            var first = interactive[left];
            var second = interactive[right];
            if (Contains(first.Bounds, second.Bounds) || Contains(second.Bounds, first.Bounds)) continue;
            var overlapWidth = Math.Min(first.Bounds.Right, second.Bounds.Right) - Math.Max(first.Bounds.Left, second.Bounds.Left);
            var overlapHeight = Math.Min(first.Bounds.Bottom, second.Bounds.Bottom) - Math.Max(first.Bounds.Top, second.Bounds.Top);
            if (overlapWidth > 3 && overlapHeight > 3)
                throw new InvalidOperationException(
                    $"{language}/{page}: interactive controls overlap: '{first.Element.Current.Name}' {first.Bounds} and '{second.Element.Current.Name}' {second.Bounds}.");
        }

        var singleLineTexts = elements.Where(item =>
                item.Element.Current.ControlType == ControlType.Text &&
                !string.IsNullOrWhiteSpace(item.Element.Current.Name) &&
                item.Bounds.Height <= 25 * dpiScale)
            .ToArray();
        var measuredTexts = 0;
        foreach (var item in singleLineTexts)
        {
            var text = item.Element.Current.Name.Trim();
            var font = AutomationFont(item.Element);
            if (font is null) continue;
            var (fontFamily, fontSize) = font.Value;
            measuredTexts++;
            var formatted = new FormattedText(text, CultureInfo.CurrentUICulture, System.Windows.FlowDirection.LeftToRight,
                new Typeface(fontFamily), fontSize, System.Windows.Media.Brushes.Black, Math.Max(1, dpiScale));
            // A scroll viewport can deliberately reveal part of a complete label.
            // Measure its arranged width so clipping does not conceal a genuinely undersized text element.
            var availableWidthInDips = item.RawBounds.Width / Math.Max(1, dpiScale);
            var fallbackTolerance = text.Any(character => character is >= '\u3400' and <= '\u9fff' ||
                                                           character is >= '\u3040' and <= '\u30ff' ||
                                                           character is >= '\uac00' and <= '\ud7af')
                ? Math.Max(6, availableWidthInDips * 0.80)
                : Math.Max(4, availableWidthInDips * 0.20);
            if (formatted.WidthIncludingTrailingWhitespace > availableWidthInDips + fallbackTolerance)
                throw new InvalidOperationException(
                    $"{language}/{page}: single-line text appears truncated: '{text}' needs {formatted.WidthIncludingTrailingWhitespace:0.#} DIP but has {availableWidthInDips:0.#} DIP at {fontSize:0.#} DIP {fontFamily}.");
        }
        return (interactive.Length, measuredTexts);
    }

    private static (System.Windows.Rect Bounds, bool HorizontalScrollAncestor) VisibleBounds(
        AutomationElement element, System.Windows.Rect windowBounds)
    {
        var bounds = element.Current.BoundingRectangle;
        var horizontalScrollAncestor = false;
        bounds.Intersect(windowBounds);
        var walker = TreeWalker.RawViewWalker;
        for (var ancestor = walker.GetParent(element); ancestor is not null; ancestor = walker.GetParent(ancestor))
        {
            if (ancestor.Current.ControlType == ControlType.Window) break;
            var hasScrollPattern = ancestor.TryGetCurrentPattern(ScrollPattern.Pattern, out var raw);
            if (ancestor.Current.ClassName.Equals("ScrollViewer", StringComparison.Ordinal) || hasScrollPattern)
            {
                // WPF can report IsOffscreen=false and full child bounds beyond a ScrollViewer's viewport.
                bounds.Intersect(ancestor.Current.BoundingRectangle);
                if (raw is ScrollPattern scroll && scroll.Current.HorizontallyScrollable)
                    horizontalScrollAncestor = true;
            }
        }
        return (bounds, horizontalScrollAncestor);
    }

    private static async Task<IReadOnlyList<object>> VerifyClippedAnnotationToolsAsync(
        AutomationElement overlay, int processId, string root, string language, double dpiScale)
    {
        var windowBounds = overlay.Current.BoundingRectangle;
        var tools = overlay.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button))
            .Cast<AutomationElement>()
            .Where(element => element.Current.AutomationId.StartsWith("InlineTool", StringComparison.Ordinal))
            .Where(element =>
            {
                var visible = VisibleBounds(element, windowBounds);
                return visible.HorizontalScrollAncestor && !Contains(visible.Bounds, element.Current.BoundingRectangle);
            })
            .ToArray();
        var evidence = new List<object>();
        foreach (var tool in tools)
        {
            var id = tool.Current.AutomationId;
            var before = tool.Current.BoundingRectangle;
            var beforeVisible = VisibleBounds(tool, windowBounds).Bounds;
            var walker = TreeWalker.RawViewWalker;
            AutomationElement? viewport = null;
            ScrollPattern? scroll = null;
            for (var ancestor = walker.GetParent(tool); ancestor is not null; ancestor = walker.GetParent(ancestor))
            {
                if (ancestor.Current.ControlType == ControlType.Window) break;
                if (ancestor.TryGetCurrentPattern(ScrollPattern.Pattern, out var raw) && raw is ScrollPattern candidate &&
                    candidate.Current.HorizontallyScrollable)
                { viewport = ancestor; scroll = candidate; break; }
            }
            if (viewport is null || scroll is null)
                throw new InvalidOperationException($"{language}: clipped annotation tool {id} had no usable horizontal scroll viewport.");
            // Button peers do not expose ScrollItemPattern. Scroll the owning viewport, then require real hit testing.
            for (var attempt = 0; attempt < 6 && !Contains(VisibleBounds(tool, windowBounds).Bounds, tool.Current.BoundingRectangle); attempt++)
            {
                var viewportBounds = viewport.Current.BoundingRectangle;
                var toolBounds = tool.Current.BoundingRectangle;
                var state = scroll.Current;
                var extent = viewportBounds.Width * 100 / state.HorizontalViewSize;
                var maximumOffset = extent - viewportBounds.Width;
                if (maximumOffset <= 0)
                    throw new InvalidOperationException($"{language}: {id} is clipped but its scroll viewport has no scrollable extent.");
                var delta = toolBounds.Left < viewportBounds.Left
                    ? toolBounds.Left - viewportBounds.Left
                    : toolBounds.Right - viewportBounds.Right;
                var offset = maximumOffset * state.HorizontalScrollPercent / 100;
                scroll.SetScrollPercent(Math.Clamp((offset + delta) * 100 / maximumOffset, 0, 100), ScrollPattern.NoScroll);
                await Task.Delay(180);
            }
            var after = tool.Current.BoundingRectangle;
            var afterVisible = VisibleBounds(tool, windowBounds).Bounds;
            if (!Contains(afterVisible, after) || afterVisible.Width <= 1 || afterVisible.Height <= 1)
                throw new InvalidOperationException($"{language}: scrolling did not fully reveal annotation tool {id}: {after} clipped to {afterVisible}.");
            var point = new System.Windows.Point(after.Left + after.Width / 2, after.Top + after.Height / 2);
            var hit = AutomationElement.FromPoint(point);
            if (!IsSelfOrDescendant(hit, tool))
                throw new InvalidOperationException($"{language}: revealed annotation tool {id} is covered by {hit.Current.AutomationId} at {point}.");
            Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            Native.SetCursorPos((int)Math.Round(point.X), (int)Math.Round(point.Y));
            Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
            Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
            var expectedTool = tool.Current.HelpText;
            await WaitUntilAsync(() => FindByAutomationId(processId, "ContextPillText")?.Current.Name == expectedTool,
                $"{language}: revealed tool {id} did not activate after a real mouse click.");
            var screenshot = Path.Combine(root, $"inline-scroll-{id}.png");
            SaveElementScreenshot(overlay, screenshot);
            AssertNoSimplifiedChineseLeak(VisibleNames(overlay).Concat(VisibleHelpTexts(overlay)), language);
            AssertVisibleLayout(overlay, language, "inline-annotation", dpiScale);
            evidence.Add(new
            {
                AutomationId = id,
                Before = before,
                BeforeVisible = beforeVisible.IsEmpty ? (System.Windows.Rect?)null : beforeVisible,
                Viewport = viewport.Current.BoundingRectangle,
                After = after,
                AfterVisible = afterVisible,
                Hit = hit.Current.AutomationId,
                SelectedTool = expectedTool,
                Screenshot = screenshot
            });
        }
        return evidence;
    }

    private static bool IsSelfOrDescendant(AutomationElement element, AutomationElement ancestor)
    {
        var expectedId = ancestor.GetRuntimeId();
        var walker = TreeWalker.RawViewWalker;
        for (var current = element; current is not null; current = walker.GetParent(current))
        {
            if (current.GetRuntimeId().SequenceEqual(expectedId)) return true;
            if (current.Current.ControlType == ControlType.Window) break;
        }
        return false;
    }

    private static bool Contains(System.Windows.Rect outer, System.Windows.Rect inner) =>
        inner.Left >= outer.Left - 1 && inner.Top >= outer.Top - 1 &&
        inner.Right <= outer.Right + 1 && inner.Bottom <= outer.Bottom + 1;

    private static (string Family, double Size)? AutomationFont(AutomationElement element)
    {
        try
        {
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var raw) || raw is not TextPattern pattern)
                return null;
            var range = pattern.DocumentRange;
            var rectangles = range.GetBoundingRectangles();
            if (rectangles.Length > 1 && rectangles.Skip(1)
                .Any(rectangle => Math.Abs(rectangle.Top - rectangles[0].Top) > 2)) return null;
            var familyValue = range.GetAttributeValue(TextPattern.FontNameAttribute);
            var sizeValue = range.GetAttributeValue(TextPattern.FontSizeAttribute);
            var family = familyValue as string;
            // UIA font sizes are points; FormattedText measures in 1/96-inch DIPs.
            // Missing metrics are not evidence of clipping. In particular, two wrapped
            // 10-DIP lines can be shorter than the old 25-pixel "single line" cutoff.
            if (string.IsNullOrWhiteSpace(family) || sizeValue is not double size || size is < 4d or > 72d)
                return null;
            return (family, size * 96d / 72d);
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

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
            ? new[] { "设置", "录制", "截图", "选择目录", "选择位置", "重试保存", "历史记录", "剪贴板历史" }
            : language is "ja-JP" or "ko-KR"
                ? new[] { "保存与截图后操作", "复制到剪贴板", "还没有符合条件的记录", "选择位置", "重试保存", "保持打开", "历史记录", "剪贴板历史" }
                : new[] { "保存与截图后操作", "保存截图", "复制到剪贴板", "还没有符合条件的记录", "选择位置", "重试保存", "保持打开", "历史记录", "剪贴板历史" };
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
        internal static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        internal static extern uint GetDpiForWindow(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        internal static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extraInfo);
    }
}
