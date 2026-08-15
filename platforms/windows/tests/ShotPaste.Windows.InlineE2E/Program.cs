using System.Diagnostics;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Data.Sqlite;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace ShotPaste.Windows.InlineE2E;

internal static class Program
{
    private static readonly TimeSpan UiTimeout = TimeSpan.FromSeconds(30);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
            Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            var executable = Path.GetFullPath(args.FirstOrDefault() ?? throw new ArgumentException(
                "Pass the ShotPaste.exe path as the first argument."));
            if (!File.Exists(executable)) throw new FileNotFoundException("ShotPaste executable was not found.", executable);
            var evidenceRoot = Path.GetFullPath(args.Skip(1).FirstOrDefault() ??
                                                Path.Combine("build", "e2e", "inline-annotation", "automated"));
            Directory.CreateDirectory(evidenceRoot);

            var requestedScenario = args.Skip(2).FirstOrDefault();
            var plans = new (string Name, ScenarioAction Action, bool Draw)[]
            {
                ("done_enter", ScenarioAction.DoneWithEnter, true),
                ("pan_toolbar_recovery", ScenarioAction.PanToolbarRecovery, false),
                ("cancel_escape", ScenarioAction.CancelWithEscape, false),
                ("dirty_return_discard", ScenarioAction.DirtyReturnAndDiscard, true),
                ("dirty_save", ScenarioAction.DirtySave, true),
                ("dirty_exit_return_discard", ScenarioAction.DirtyExitReturnAndDiscard, true),
                ("dirty_exit_save", ScenarioAction.DirtyExitSave, true),
                ("pin", ScenarioAction.Pin, false),
                ("quick_access", ScenarioAction.QuickAccess, false),
                ("quick_access_drag", ScenarioAction.QuickAccessDrag, false),
                ("quick_access_delete", ScenarioAction.QuickAccessDelete, false),
                ("editor_removed", ScenarioAction.EditorRemoved, false),
                ("copy_recovery", ScenarioAction.CopyRecovery, false),
                ("selection_size_badge_default", ScenarioAction.SelectionSizeBadgeDefault, false),
                ("selection_size_badge_edge", ScenarioAction.SelectionSizeBadgeEdge, false),
                ("toolbar_default_below", ScenarioAction.ToolbarDefaultBelow, false),
                ("one_shot_selection_move", ScenarioAction.OneShotSelectionMove, false),
                ("one_shot_scrolling_selection_move", ScenarioAction.OneShotScrollingSelectionMove, false),
                ("one_shot_recording_selection_move", ScenarioAction.OneShotRecordingSelectionMove, false),
                ("one_shot_toolbar_drag", ScenarioAction.OneShotToolbarDrag, false),
                ("performance_baseline", ScenarioAction.PerformanceBaseline, false)
            };
            var results = plans
                .Where(plan => string.IsNullOrWhiteSpace(requestedScenario) ||
                               plan.Name.Equals(requestedScenario, StringComparison.OrdinalIgnoreCase))
                .Select(plan => RunScenario(executable, evidenceRoot, plan.Name, plan.Action, plan.Draw))
                .ToList();
            if (results.Count == 0)
                throw new ArgumentException($"Unknown Inline E2E scenario: {requestedScenario}.");

            var synthetic4K = BenchmarkSynthetic4K(evidenceRoot);
            var summaryPath = Path.Combine(evidenceRoot, "summary.json");
            File.WriteAllText(summaryPath, JsonSerializer.Serialize(new
            {
                Executable = executable,
                GeneratedAt = DateTimeOffset.Now,
                VirtualScreen = Forms.SystemInformation.VirtualScreen,
                Synthetic4K = synthetic4K,
                Results = results
            }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine(File.ReadAllText(summaryPath));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }

    private static ScenarioResult RunScenario(
        string executable,
        string evidenceRoot,
        string name,
        ScenarioAction action,
        bool drawAnnotation = false)
    {
        var root = Path.Combine(evidenceRoot, name);
        Directory.CreateDirectory(root);
        var captureDirectory = Path.Combine(root, "Captures");
        WriteSettings(root, captureDirectory, action);
        foreach (var oldCapture in Directory.Exists(captureDirectory)
                     ? Directory.EnumerateFiles(captureDirectory, "*.png")
                     : [])
            File.Delete(oldCapture);
        var database = Path.Combine(root, "history.sqlite3");
        if (File.Exists(database)) File.Delete(database);

        var startupClock = Stopwatch.StartNew();
        using var process = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList =
            {
                "--ui-test", "--data-root", root, "--one-shot"
            }
        }) ?? throw new InvalidOperationException("Failed to start ShotPaste.");

        try
        {
            var overlay = WaitForAutomationId(process.Id, "InlineAnnotateWindow");
            var firstFrameMilliseconds = startupClock.Elapsed.TotalMilliseconds;
            if (action == ScenarioAction.OneShotToolbarDrag)
            {
                var switcher = WaitForAutomationId(process.Id, "OneShotSwitcherDragHandle");
                var before = switcher.Current.BoundingRectangle;
                Drag(
                    new Drawing.Point(
                        (int)Math.Round(before.Left + before.Width / 2),
                        (int)Math.Round(before.Top + before.Height / 2)),
                    new Drawing.Point(
                        (int)Math.Round(before.Left + before.Width / 2 + 60),
                        (int)Math.Round(before.Top + before.Height / 2)));
                WaitUntil(() =>
                    {
                        var moved = FindByAutomationId(process.Id, "OneShotSwitcherDragHandle");
                        return moved is not null && moved.Current.BoundingRectangle.Left > before.Left + 20;
                    }, "One Shot mode switcher did not move.");
            }
            var screen = Forms.Screen.FromPoint(Forms.Cursor.Position).WorkingArea;
            var defaultBadgeScenario = action == ScenarioAction.SelectionSizeBadgeDefault;
            var edgeBadgeScenario = action == ScenarioAction.SelectionSizeBadgeEdge;
            var selectionStart = new Drawing.Point(
                screen.Left + Math.Max(80, screen.Width / 5),
                edgeBadgeScenario ? screen.Top + 6 : screen.Top + Math.Max(90, screen.Height / 5));
            var selectionEnd = new Drawing.Point(
                Math.Min(screen.Right - 240, selectionStart.X + Math.Max(420, screen.Width / 3)),
                Math.Min(screen.Bottom - 220, selectionStart.Y + Math.Max(280, screen.Height / 3)));
            var selectionBadgeScreenshot = Path.Combine(root, "selection-size-badge-during-drag.png");
            Drag(selectionStart, selectionEnd, () =>
            {
                WaitUntil(
                    () => FindVisibleByAutomationId(process.Id, "OneShotSwitcherDragHandle") is null,
                    "One Shot mode switcher remained visible while drawing the selection.");
                var badge = FindVisibleByAutomationId(process.Id, "SelectionSizeBadge") ??
                            throw new InvalidOperationException("The selection size badge was not visible while drawing.");
                if (!badge.Current.Name.Contains('×'))
                    throw new InvalidOperationException($"The selection size badge did not expose pixel dimensions: {badge.Current.Name}");
                var badgeBounds = badge.Current.BoundingRectangle;
                if (defaultBadgeScenario)
                {
                    if (Math.Abs(badgeBounds.Left - selectionStart.X) > 24 ||
                        badgeBounds.Bottom > selectionStart.Y - 2)
                        throw new InvalidOperationException(
                            $"The default size badge was not above the selection's left edge: badge={badgeBounds}, selection={selectionStart}-{selectionEnd}.");
                    SaveDesktopScreenshot(selectionBadgeScreenshot);
                }
                else if (edgeBadgeScenario)
                {
                    if (badgeBounds.Left < selectionStart.X - 2 ||
                        badgeBounds.Top < selectionStart.Y - 2 ||
                        badgeBounds.Right > selectionEnd.X + 2 ||
                        badgeBounds.Bottom > selectionEnd.Y + 2)
                        throw new InvalidOperationException(
                            $"The edge-aware size badge was not inside the selection: badge={badgeBounds}, selection={selectionStart}-{selectionEnd}.");
                    SaveDesktopScreenshot(selectionBadgeScreenshot);
                }
            });

            WaitUntil(
                () => FindVisibleByAutomationId(process.Id, "OneShotSwitcherDragHandle") is not null,
                "One Shot mode switcher did not return after the selection finished.");

            var selectionImage = WaitForAutomationId(process.Id, "SelectionImage");
            var selectionBounds = selectionImage.Current.BoundingRectangle;
            if (selectionBounds.Width < 40 || selectionBounds.Height < 40)
                throw new InvalidOperationException($"Inline selection did not enter annotate mode: {selectionBounds}.");

            if (action == ScenarioAction.OneShotScrollingSelectionMove)
            {
                Invoke(WaitForAutomationId(process.Id, "OneShotScrolling"));
                WaitForAutomationId(process.Id, "OneShotStartScrolling");
            }
            else if (action == ScenarioAction.OneShotRecordingSelectionMove)
            {
                Invoke(WaitForAutomationId(process.Id, "OneShotRecording"));
                WaitForAutomationId(process.Id, "OneShotStartRecording");
            }

            if (action is ScenarioAction.OneShotSelectionMove or
                ScenarioAction.OneShotScrollingSelectionMove or
                ScenarioAction.OneShotRecordingSelectionMove)
            {
                var before = selectionBounds;
                var start = new Drawing.Point(
                    (int)Math.Round(before.Left + Math.Max(32, before.Width * 0.12)),
                    (int)Math.Round(before.Top + Math.Max(32, before.Height * 0.12)));
                Drag(start, new Drawing.Point(start.X + 90, start.Y + 60));
                WaitUntil(() =>
                {
                    var moved = FindByAutomationId(process.Id, "SelectionImage");
                    if (moved is null) return false;
                    var bounds = moved.Current.BoundingRectangle;
                    return bounds.Left > before.Left + 45 &&
                           bounds.Top > before.Top + 30 &&
                           Math.Abs(bounds.Width - before.Width) < 3 &&
                           Math.Abs(bounds.Height - before.Height) < 3;
                }, "Dragging the uncommitted One Shot selection did not move the selected region.");
                WaitUntil(
                    () => FindVisibleByAutomationId(process.Id, "OneShotSwitcherDragHandle") is not null,
                    "Moving the uncommitted selection unexpectedly committed the One Shot mode.");
                selectionImage = WaitForAutomationId(process.Id, "SelectionImage");
                selectionBounds = selectionImage.Current.BoundingRectangle;

                if (action == ScenarioAction.OneShotSelectionMove)
                {
                    Invoke(WaitForAutomationId(process.Id, "InlineToolSelection"));
                    WaitUntil(
                        () => FindVisibleByAutomationId(process.Id, "OneShotSwitcherDragHandle") is null,
                        "Explicitly selecting the annotation selection tool did not commit the One Shot mode.");
                    var committedBounds = selectionBounds;
                    var marqueeStart = new Drawing.Point(
                        (int)Math.Round(committedBounds.Left + committedBounds.Width * 0.35),
                        (int)Math.Round(committedBounds.Top + committedBounds.Height * 0.35));
                    Drag(marqueeStart, new Drawing.Point(marqueeStart.X + 80, marqueeStart.Y + 55));
                    var afterMarquee = WaitForAutomationId(process.Id, "SelectionImage").Current.BoundingRectangle;
                    if (Math.Abs(afterMarquee.Left - committedBounds.Left) >= 3 ||
                        Math.Abs(afterMarquee.Top - committedBounds.Top) >= 3 ||
                        Math.Abs(afterMarquee.Width - committedBounds.Width) >= 3 ||
                        Math.Abs(afterMarquee.Height - committedBounds.Height) >= 3)
                        throw new InvalidOperationException(
                            $"The committed annotation selection tool moved the screenshot region: before={committedBounds}, after={afterMarquee}.");

                    var spaceDragStart = new Drawing.Point(
                        (int)Math.Round(committedBounds.Left + committedBounds.Width * 0.55),
                        (int)Math.Round(committedBounds.Top + committedBounds.Height * 0.55));
                    DragWhileHoldingKey(
                        overlay,
                        0x20,
                        spaceDragStart,
                        new Drawing.Point(spaceDragStart.X + 70, spaceDragStart.Y + 45));
                    var afterSpaceDrag = WaitForAutomationId(process.Id, "SelectionImage").Current.BoundingRectangle;
                    if (Math.Abs(afterSpaceDrag.Left - committedBounds.Left) >= 3 ||
                        Math.Abs(afterSpaceDrag.Top - committedBounds.Top) >= 3 ||
                        Math.Abs(afterSpaceDrag.Width - committedBounds.Width) >= 3 ||
                        Math.Abs(afterSpaceDrag.Height - committedBounds.Height) >= 3)
                        throw new InvalidOperationException(
                            $"Holding Space moved the committed screenshot region: before={committedBounds}, after={afterSpaceDrag}.");
                }
            }

            if (action == ScenarioAction.OneShotToolbarDrag)
            {
                var moveButton = WaitForAutomationId(process.Id, "OneShotMoveToolbar");
                var before = moveButton.Current.BoundingRectangle;
                var start = moveButton.TryGetClickablePoint(out var clickable)
                    ? new Drawing.Point((int)Math.Round(clickable.X), (int)Math.Round(clickable.Y))
                    : new Drawing.Point(
                        (int)Math.Round(before.Left + before.Width / 2),
                        (int)Math.Round(before.Top + before.Height / 2));
                Drag(start, new Drawing.Point(start.X + 70, start.Y + 28));
                WaitUntil(() =>
                    {
                        var moved = FindByAutomationId(process.Id, "OneShotMoveToolbar");
                        return moved is not null && moved.Current.BoundingRectangle.Left > before.Left + 25;
                    }, "One Shot screenshot toolbar did not move.");

                Invoke(WaitForAutomationId(process.Id, "InlineToolRectangle"));
                WaitUntil(
                    () => FindVisibleByAutomationId(process.Id, "OneShotSwitcherDragHandle") is null,
                    "One Shot mode switcher remained visible after the screenshot mode committed.");
            }

            if (drawAnnotation)
            {
                Invoke(WaitForAutomationId(process.Id, "InlineToolRectangle"));
                var drawStart = new Drawing.Point(
                    (int)Math.Round(selectionBounds.Left + selectionBounds.Width * 0.22),
                    (int)Math.Round(selectionBounds.Top + selectionBounds.Height * 0.25));
                var drawEnd = new Drawing.Point(
                    (int)Math.Round(selectionBounds.Left + selectionBounds.Width * 0.72),
                    (int)Math.Round(selectionBounds.Top + selectionBounds.Height * 0.72));
                Drag(drawStart, drawEnd);
            }

            if (action == ScenarioAction.PanToolbarRecovery)
            {
                var zoomPicker = WaitForAutomationId(process.Id, "InlineZoomPicker");
                string SelectedZoom()
                {
                    var selected = ((SelectionPattern)zoomPicker.GetCurrentPattern(SelectionPattern.Pattern))
                        .Current.GetSelection();
                    return selected.SingleOrDefault()?.Current.Name ?? string.Empty;
                }

                var zoomBefore = SelectedZoom();
                PhysicalClick(WaitForAutomationId(process.Id, "InlineToolPan"));
                PhysicalClick(WaitForAutomationId(process.Id, "InlineZoomIn"));
                WaitUntil(() => !string.Equals(SelectedZoom(), zoomBefore, StringComparison.Ordinal),
                    "Zoom In did not respond after the Pan tool was selected.");

                PhysicalClick(WaitForAutomationId(process.Id, "InlineToolRectangle"));
                WaitUntil(
                    () => FindVisibleByAutomationId(process.Id, "OneShotSwitcherDragHandle") is null,
                    "A physical Rectangle click did not leave the Pan tool or commit screenshot mode.");
                var drawStart = new Drawing.Point(
                    (int)Math.Round(selectionBounds.Left + selectionBounds.Width * 0.28),
                    (int)Math.Round(selectionBounds.Top + selectionBounds.Height * 0.30));
                var drawEnd = new Drawing.Point(
                    (int)Math.Round(selectionBounds.Left + selectionBounds.Width * 0.62),
                    (int)Math.Round(selectionBounds.Top + selectionBounds.Height * 0.62));
                Drag(drawStart, drawEnd);
            }

            double? interactionMilliseconds = null;
            if (action == ScenarioAction.PerformanceBaseline)
            {
                var interactionClock = Stopwatch.StartNew();
                DrawPerformanceAnnotations(process.Id, selectionBounds);
                interactionClock.Stop();
                interactionMilliseconds = interactionClock.Elapsed.TotalMilliseconds;
            }

            var screenshot = Path.Combine(root, "inline-before-action.png");
            SaveDesktopScreenshot(screenshot);
            string detail;
            double? exportMilliseconds = null;
            switch (action)
            {
                case ScenarioAction.DoneWithEnter:
                    SendKey(overlay, 0x0D);
                    WaitForCaptureCount(captureDirectory, 1);
                    detail = "Enter confirmed the inline editor.";
                    break;
                case ScenarioAction.PanToolbarRecovery:
                    SendKey(overlay, 0x0D);
                    WaitForCaptureCount(captureDirectory, 1);
                    detail = "After a physical Pan-tool click, Zoom In, Rectangle, drawing, and Enter completion all remained operable.";
                    break;
                case ScenarioAction.CancelWithEscape:
                    SendKey(overlay, 0x1B);
                    WaitUntil(() => FindByAutomationId(process.Id, "OneShotCancel") is null,
                        "Inline overlay did not close after Escape.");
                    detail = "Escape cancelled without output.";
                    break;
                case ScenarioAction.DirtyReturnAndDiscard:
                    SendKey(overlay, 0x1B);
                    Thread.Sleep(250);
                    if (FindByAutomationId(process.Id, "ShotPasteDialog") is null)
                        SendKey(overlay, 0x1B);
                    WaitForAutomationId(process.Id, "ShotPasteDialog");
                    SaveDesktopScreenshot(Path.Combine(root, "dirty-escape-prompt.png"));
                    Invoke(WaitForAutomationId(process.Id, "DialogTertiary"));
                    WaitUntil(() => FindByAutomationId(process.Id, "ShotPasteDialog") is null,
                        "Return did not dismiss the unsaved-annotation prompt.");
                    if (FindByAutomationId(process.Id, "OneShotCancel") is null)
                        throw new InvalidOperationException("Return did not preserve the dirty annotation editor.");
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitForAutomationId(process.Id, "ShotPasteDialog");
                    Invoke(WaitForAutomationId(process.Id, "DialogSecondary"));
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "Discard did not close the dirty annotation editor.");
                    detail = "Escape offered Save/Discard/Return; Return preserved the editor and toolbar Cancel then discarded without output.";
                    break;
                case ScenarioAction.DirtySave:
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitForAutomationId(process.Id, "ShotPasteDialog");
                    SaveDesktopScreenshot(Path.Combine(root, "dirty-save-prompt.png"));
                    Invoke(WaitForAutomationId(process.Id, "DialogPrimary"));
                    WaitForCaptureCount(captureDirectory, 1);
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "Save did not close the dirty annotation editor after the file was written.");
                    detail = "Toolbar Cancel offered Save/Discard/Return and Save wrote one output before closing.";
                    break;
                case ScenarioAction.DirtyExitReturnAndDiscard:
                    RequestUiTestExit(executable, root);
                    WaitForAutomationId(process.Id, "ShotPasteDialog");
                    SaveDesktopScreenshot(Path.Combine(root, "dirty-exit-prompt.png"));
                    Invoke(WaitForAutomationId(process.Id, "DialogTertiary"));
                    WaitUntil(() => FindByAutomationId(process.Id, "ShotPasteDialog") is null,
                        "Return did not dismiss the exit-time unsaved-annotation prompt.");
                    if (process.HasExited || FindByAutomationId(process.Id, "InlineAnnotateWindow") is null)
                        throw new InvalidOperationException("Return did not preserve the dirty editor during application exit.");
                    RequestUiTestExit(executable, root);
                    WaitForAutomationId(process.Id, "ShotPasteDialog");
                    Invoke(WaitForAutomationId(process.Id, "DialogSecondary"));
                    WaitUntil(() => process.HasExited, "Discard during application exit did not close ShotPaste.");
                    detail = "Tray-equivalent exit offered Save/Discard/Return; Return preserved the editor and Discard then exited without output.";
                    break;
                case ScenarioAction.DirtyExitSave:
                    RequestUiTestExit(executable, root);
                    WaitForAutomationId(process.Id, "ShotPasteDialog");
                    SaveDesktopScreenshot(Path.Combine(root, "dirty-exit-save-prompt.png"));
                    Invoke(WaitForAutomationId(process.Id, "DialogPrimary"));
                    WaitForCaptureCount(captureDirectory, 1);
                    WaitUntil(() => process.HasExited, "Save during application exit did not finish the write and close ShotPaste.");
                    detail = "Tray-equivalent exit saved the dirty annotation, committed history, and only then shut down.";
                    break;
                case ScenarioAction.Pin:
                    Invoke(WaitForAutomationId(process.Id, "OneShotPin"));
                    WaitForCaptureCount(captureDirectory, 1);
                    var pinVerification = ExercisePinnedImage(process.Id, root);
                    screenshot = pinVerification.Screenshot;
                    detail = $"Pin created one saved item; 50%={pinVerification.WidthAt50:0} px, 150%={pinVerification.WidthAt150:0} px; locked image hit-test={pinVerification.ImageHitTest}, lock hit-test={pinVerification.LockHitTest}.";
                    break;
                case ScenarioAction.QuickAccess:
                    SendKey(overlay, 0x0D);
                    WaitForCaptureCount(captureDirectory, 1);
                    var quickVerification = ExerciseQuickAccess(process.Id, root);
                    screenshot = quickVerification.Screenshot;
                    detail = $"Quick Access kept fixed action slots and resumed its saved countdown in {quickVerification.ResumeSeconds:0.00}s.";
                    break;
                case ScenarioAction.QuickAccessDrag:
                    SendKey(overlay, 0x0D);
                    WaitForCaptureCount(captureDirectory, 1);
                    screenshot = ExerciseQuickAccessDrag(process.Id, root, captureDirectory);
                    detail = "Quick Access performed a native cross-process file drag and closed only after the drop target accepted it.";
                    break;
                case ScenarioAction.QuickAccessDelete:
                    SendKey(overlay, 0x0D);
                    WaitForCaptureCount(captureDirectory, 1);
                    screenshot = ExerciseQuickAccessDelete(process.Id, root, captureDirectory);
                    detail = "Quick Access delete required confirmation; Cancel retained the file and card, then confirmation moved the file to the Recycle Bin and removed history.";
                    break;
                case ScenarioAction.EditorRemoved:
                    if (FindByAutomationId(process.Id, "InlineOpenEditor") is not null)
                        throw new InvalidOperationException("The removed full-editor action is still exposed in inline annotation.");
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "OneShotCancel") is null,
                        "Inline overlay did not close after validating the removed editor action.");
                    detail = "The screenshot annotation toolbar exposes no full-editor action.";
                    break;
                case ScenarioAction.CopyRecovery:
                    VerifyClipboardBusyRecovery(process.Id, Path.Combine(root, "clipboard-busy-recovery.png"));
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "OneShotCancel") is null,
                        "Inline overlay did not remain cancellable after clipboard recovery.");
                    detail = "Clipboard lock showed a recoverable error; retry copied without leaving the editor.";
                    break;
                case ScenarioAction.SelectionSizeBadgeDefault:
                    screenshot = selectionBadgeScreenshot;
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after default selection size badge validation.");
                    detail = "Selection size badge was positioned above the selection's left edge when screen space was available.";
                    break;
                case ScenarioAction.SelectionSizeBadgeEdge:
                    screenshot = selectionBadgeScreenshot;
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after selection size badge validation.");
                    detail = "Selection size badge showed physical pixel dimensions and moved inside the selection at the top screen edge.";
                    break;
                case ScenarioAction.ToolbarDefaultBelow:
                    var moveToolbar = WaitForAutomationId(process.Id, "OneShotMoveToolbar");
                    if (moveToolbar.Current.BoundingRectangle.Top < selectionBounds.Bottom + 6)
                        throw new InvalidOperationException(
                            $"The default toolbar was not below the selection: toolbar={moveToolbar.Current.BoundingRectangle}, selection={selectionBounds}.");
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after default toolbar placement validation.");
                    detail = "Screenshot toolbar defaulted below the selection while preserving its automatic edge fallback.";
                    break;
                case ScenarioAction.OneShotSelectionMove:
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after selection move validation.");
                    detail = "Dragging inside the uncommitted screenshot selection moved the region without locking the One Shot mode; after commit, ordinary and Space-modified drags kept the screenshot region locked.";
                    break;
                case ScenarioAction.OneShotScrollingSelectionMove:
                    SendKey(overlay, 0x1B);
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after scrolling selection move validation.");
                    detail = "Dragging inside the uncommitted scrolling-capture selection moved the region without locking the One Shot mode.";
                    break;
                case ScenarioAction.OneShotRecordingSelectionMove:
                    SendKey(overlay, 0x1B);
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after recording selection move validation.");
                    detail = "Dragging inside the uncommitted recording selection moved the region without locking the One Shot mode.";
                    break;
                case ScenarioAction.OneShotToolbarDrag:
                    Invoke(WaitForAutomationId(process.Id, "OneShotCancel"));
                    WaitUntil(() => FindByAutomationId(process.Id, "InlineAnnotateWindow") is null,
                        "One Shot overlay did not close after toolbar drag validation.");
                    detail = "One Shot mode switcher hid during selection, returned before commit, hid after commit, and both toolbars remained draggable.";
                    break;
                case ScenarioAction.PerformanceBaseline:
                    var exportClock = Stopwatch.StartNew();
                    SendKey(overlay, 0x0D);
                    WaitForCaptureCount(captureDirectory, 1);
                    exportClock.Stop();
                    exportMilliseconds = exportClock.Elapsed.TotalMilliseconds;
                    detail = "Measured first frame, six basic annotation interactions, PNG export, and process memory.";
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(action));
            }

            Thread.Sleep(500);
            var captures = Directory.Exists(captureDirectory)
                ? Directory.GetFiles(captureDirectory, "*.png")
                : [];
            var expectedCount = action is ScenarioAction.DoneWithEnter or ScenarioAction.PanToolbarRecovery or ScenarioAction.DirtySave or ScenarioAction.DirtyExitSave or ScenarioAction.Pin or
                ScenarioAction.QuickAccess or ScenarioAction.QuickAccessDrag or ScenarioAction.PerformanceBaseline ? 1 : 0;
            if (captures.Length != expectedCount)
                throw new InvalidOperationException($"{name}: expected {expectedCount} output file(s), got {captures.Length}.");
            var historyItems = process.HasExited ? PersistedHistoryItemCount(database) : HistoryItemCount(process.Id);
            if (historyItems != expectedCount)
                throw new InvalidOperationException($"{name}: expected {expectedCount} history item(s), got {historyItems}.");

            int? width = null;
            int? height = null;
            if (captures.Length == 1)
            {
                using var image = Drawing.Image.FromFile(captures[0]);
                width = image.Width;
                height = image.Height;
                var expectedWidth = (int)Math.Round(selectionBounds.Width);
                var expectedHeight = (int)Math.Round(selectionBounds.Height);
                if (Math.Abs(image.Width - expectedWidth) > 2 || Math.Abs(image.Height - expectedHeight) > 2)
                    throw new InvalidOperationException(
                        $"{name}: exported {image.Width}x{image.Height}, selection was {expectedWidth}x{expectedHeight} physical pixels.");
            }

            process.Refresh();
            var performance = action == ScenarioAction.PerformanceBaseline
                ? new InlinePerformanceSample(
                    Math.Round(firstFrameMilliseconds, 2),
                    Math.Round(interactionMilliseconds ?? 0, 2),
                    Math.Round(exportMilliseconds ?? 0, 2),
                    process.WorkingSet64,
                    process.PeakWorkingSet64,
                    6,
                    Forms.Screen.AllScreens.Length,
                    Forms.SystemInformation.VirtualScreen)
                : null;
            return new ScenarioResult(name, detail, screenshot, captures.SingleOrDefault(),
                captures.Length, historyItems, width, height, performance);
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
    }

    private static void DrawPerformanceAnnotations(int processId, System.Windows.Rect bounds)
    {
        var plans = new (string Tool, double StartX, double StartY, double EndX, double EndY)[]
        {
            ("InlineToolRectangle", 0.10, 0.16, 0.34, 0.42),
            ("InlineToolFilledRectangle", 0.40, 0.18, 0.59, 0.36),
            ("InlineToolOval", 0.65, 0.16, 0.88, 0.42),
            ("InlineToolArrow", 0.12, 0.58, 0.34, 0.78),
            ("InlineToolHighlighter", 0.40, 0.62, 0.62, 0.66),
            ("InlineToolPencil", 0.69, 0.57, 0.88, 0.80)
        };
        foreach (var plan in plans)
        {
            Invoke(WaitForAutomationId(processId, plan.Tool));
            Drag(
                new Drawing.Point(
                    (int)Math.Round(bounds.Left + bounds.Width * plan.StartX),
                    (int)Math.Round(bounds.Top + bounds.Height * plan.StartY)),
                new Drawing.Point(
                    (int)Math.Round(bounds.Left + bounds.Width * plan.EndX),
                    (int)Math.Round(bounds.Top + bounds.Height * plan.EndY)));
        }
    }

    private static Synthetic4KBenchmark BenchmarkSynthetic4K(string evidenceRoot)
    {
        const int width = 3840;
        const int height = 2160;
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        using var process = Process.GetCurrentProcess();
        process.Refresh();
        var workingSetBefore = process.WorkingSet64;
        var managedBefore = GC.GetTotalMemory(true);

        var firstFrameClock = Stopwatch.StartNew();
        var backgroundVisual = new DrawingVisual();
        using (var drawing = backgroundVisual.RenderOpen())
        {
            drawing.DrawRectangle(
                new LinearGradientBrush(
                    System.Windows.Media.Color.FromRgb(24, 28, 44),
                    System.Windows.Media.Color.FromRgb(48, 62, 92),
                    new System.Windows.Point(0, 0),
                    new System.Windows.Point(1, 1)),
                null,
                new System.Windows.Rect(0, 0, width, height));
            var gridPen = new System.Windows.Media.Pen(new SolidColorBrush(System.Windows.Media.Color.FromArgb(32, 255, 255, 255)), 2);
            for (var x = 0; x < width; x += 240)
                drawing.DrawLine(gridPen, new System.Windows.Point(x, 0), new System.Windows.Point(x, height));
            for (var y = 0; y < height; y += 180)
                drawing.DrawLine(gridPen, new System.Windows.Point(0, y), new System.Windows.Point(width, y));
        }
        var background = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        background.Render(backgroundVisual);
        firstFrameClock.Stop();

        var interactionClock = Stopwatch.StartNew();
        var annotatedVisual = new DrawingVisual();
        using (var drawing = annotatedVisual.RenderOpen())
        {
            drawing.DrawImage(background, new System.Windows.Rect(0, 0, width, height));
            var red = new SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 69, 58));
            var yellow = new SolidColorBrush(System.Windows.Media.Color.FromArgb(110, 255, 214, 10));
            var outline = new System.Windows.Media.Pen(red, 10);
            for (var index = 0; index < 48; index++)
            {
                var column = index % 8;
                var row = index / 8;
                var left = 180 + column * 430;
                var top = 150 + row * 310;
                if (index % 3 == 0)
                    drawing.DrawRoundedRectangle(null, outline,
                        new System.Windows.Rect(left, top, 290, 170), 22, 22);
                else if (index % 3 == 1)
                    drawing.DrawEllipse(null, outline,
                        new System.Windows.Point(left + 145, top + 85), 145, 85);
                else
                    drawing.DrawLine(new System.Windows.Media.Pen(yellow, 30),
                        new System.Windows.Point(left, top + 85),
                        new System.Windows.Point(left + 290, top + 85));
            }
            var text = new FormattedText(
                "ShotPaste · 4K Inline 基础标注性能夹具",
                CultureInfo.GetCultureInfo("zh-CN"),
                System.Windows.FlowDirection.LeftToRight,
                new Typeface("Microsoft YaHei UI"),
                54,
                System.Windows.Media.Brushes.White,
                1);
            drawing.DrawText(text, new System.Windows.Point(150, height - 130));
        }
        var rendered = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        rendered.Render(annotatedVisual);
        interactionClock.Stop();

        var output = Path.Combine(evidenceRoot, "synthetic-4k-inline-annotations.png");
        var exportClock = Stopwatch.StartNew();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(rendered));
        using (var stream = File.Create(output)) encoder.Save(stream);
        exportClock.Stop();
        process.Refresh();
        var workingSetDelta = Math.Max(0, process.WorkingSet64 - workingSetBefore);
        var managedDelta = Math.Max(0, GC.GetTotalMemory(false) - managedBefore);
        if (exportClock.Elapsed > TimeSpan.FromSeconds(15))
            throw new InvalidOperationException($"Synthetic 4K Inline export exceeded 15 seconds: {exportClock.Elapsed}.");
        if (workingSetDelta > 768L * 1024 * 1024)
            throw new InvalidOperationException($"Synthetic 4K Inline working-set delta exceeded 768 MiB: {workingSetDelta:N0} bytes.");
        return new Synthetic4KBenchmark(
            width,
            height,
            48,
            Math.Round(firstFrameClock.Elapsed.TotalMilliseconds, 2),
            Math.Round(interactionClock.Elapsed.TotalMilliseconds, 2),
            Math.Round(exportClock.Elapsed.TotalMilliseconds, 2),
            managedDelta,
            workingSetDelta,
            output);
    }

    private static void VerifyClipboardBusyRecovery(int processId, string evidencePath)
    {
        using var locked = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        Exception? lockFailure = null;
        var lockThread = new Thread(() =>
        {
            if (!Native.OpenClipboard(IntPtr.Zero))
            {
                lockFailure = new InvalidOperationException("Could not lock the clipboard for the recovery scenario.");
                locked.Set();
                return;
            }
            locked.Set();
            release.Wait(TimeSpan.FromSeconds(60));
            Native.CloseClipboard();
        }) { IsBackground = true, Name = "ShotPaste E2E clipboard lock" };
        lockThread.SetApartmentState(ApartmentState.STA);
        lockThread.Start();
        if (!locked.Wait(TimeSpan.FromSeconds(5)))
            throw new TimeoutException("Clipboard-lock helper did not start.");
        if (lockFailure is not null) throw lockFailure;
        try
        {
            Invoke(WaitForAutomationId(processId, "OneShotCopy"));
            Thread.Sleep(250);
            SaveDesktopScreenshot(evidencePath);
            Console.WriteLine($"copy_recovery status={FindByAutomationId(processId, "InlineStatusText")?.Current.Name ?? "<missing>"}");
            WaitUntil(() =>
                {
                    var status = FindByAutomationId(processId, "InlineStatusText")?.Current.Name ?? string.Empty;
                    return status.Contains("busy", StringComparison.OrdinalIgnoreCase) ||
                           status.Contains("剪贴板", StringComparison.Ordinal);
                },
                "Clipboard lock did not surface a localized recoverable status.");
        }
        finally
        {
            release.Set();
            lockThread.Join(TimeSpan.FromSeconds(5));
        }

        Invoke(WaitForAutomationId(processId, "OneShotCopy"));
        WaitUntil(System.Windows.Clipboard.ContainsImage,
            "Clipboard retry did not produce an image.");
        if (FindByAutomationId(processId, "OneShotCancel") is null)
            throw new InvalidOperationException("Copy unexpectedly closed the inline editor.");
    }

    private static PinVerification ExercisePinnedImage(int processId, string root)
    {
        var pinned = WaitForAutomationId(processId, "PinnedImageWindow");
        var handle = new IntPtr(pinned.Current.NativeWindowHandle);
        var zoom = WaitForAutomationId(processId, "PinnedZoom");
        var initialWidth = pinned.Current.BoundingRectangle.Width;

        SelectComboItem(zoom, "50%");
        WaitUntil(() => Math.Abs(pinned.Current.BoundingRectangle.Width - initialWidth) > 12,
            "The 50% pinned-image preset did not resize the window.");
        var widthAt50 = pinned.Current.BoundingRectangle.Width;

        SelectComboItem(zoom, "150%");
        WaitUntil(() => pinned.Current.BoundingRectangle.Width > widthAt50 * 2.5,
            "The 150% pinned-image preset did not produce the expected larger window.");
        var widthAt150 = pinned.Current.BoundingRectangle.Width;

        var lockButton = WaitForAutomationId(processId, "PinnedLock");
        Invoke(lockButton);
        WaitUntil(() => FindVisibleByAutomationId(processId, "PinnedZoom") is null,
            "Locked pinned image still exposed unlocked controls.");

        var windowBounds = pinned.Current.BoundingRectangle;
        var imagePoint = new Drawing.Point(
            (int)Math.Round(windowBounds.Left + windowBounds.Width / 2),
            (int)Math.Round(windowBounds.Top + windowBounds.Height / 2));
        var lockBounds = lockButton.Current.BoundingRectangle;
        var lockPoint = new Drawing.Point(
            (int)Math.Round(lockBounds.Left + lockBounds.Width / 2),
            (int)Math.Round(lockBounds.Top + lockBounds.Height / 2));
        Native.SetCursorPos(imagePoint.X, imagePoint.Y);
        var imageHitTest = Native.SendMessage(handle, Native.WmNcHitTest, IntPtr.Zero, PackPoint(imagePoint)).ToInt64();
        Native.SetCursorPos(lockPoint.X, lockPoint.Y);
        var lockHitTest = Native.SendMessage(handle, Native.WmNcHitTest, IntPtr.Zero, PackPoint(lockPoint)).ToInt64();
        if (imageHitTest != Native.HtTransparent || lockHitTest == Native.HtTransparent)
            throw new InvalidOperationException($"Locked pin hit-testing was incorrect: image={imageHitTest}, lock={lockHitTest}.");

        Invoke(lockButton);
        WaitForAutomationId(processId, "PinnedZoom");
        Native.SetForegroundWindow(handle);
        Thread.Sleep(180);
        var screenshot = Path.Combine(root, "pinned-lock-zoom.png");
        SaveDesktopScreenshot(screenshot);
        return new PinVerification(widthAt50, widthAt150, imageHitTest, lockHitTest, screenshot);
    }

    private static QuickVerification ExerciseQuickAccess(int processId, string root)
    {
        var quick = WaitForAutomationId(processId, "QuickAccessWindow");
        Thread.Sleep(700);
        var bounds = quick.Current.BoundingRectangle;
        Native.SetCursorPos((int)Math.Round(bounds.Left + bounds.Width / 2), (int)Math.Round(bounds.Top + bounds.Height / 2));
        Thread.Sleep(2800);
        if (FindVisibleByAutomationId(processId, "QuickAccessWindow") is null)
            throw new InvalidOperationException("Hover did not pause the Quick Access countdown.");

        var copy = WaitForAutomationId(processId, "QuickAccessCopy").Current.BoundingRectangle;
        var pin = WaitForAutomationId(processId, "QuickAccessPin").Current.BoundingRectangle;
        var close = WaitForAutomationId(processId, "QuickAccessClose").Current.BoundingRectangle;
        if (!(pin.Top > copy.Top + 5 && close.Top > pin.Top + 5) ||
            FindVisibleByAutomationId(processId, "QuickAccessSave") is not null)
            throw new InvalidOperationException("Quick Access actions shifted after disabled actions were removed.");

        var screenshot = Path.Combine(root, "quick-access-fixed-slots.png");
        SaveDesktopScreenshot(screenshot);
        var screen = Forms.Screen.FromPoint(Forms.Cursor.Position).WorkingArea;
        Native.SetCursorPos(screen.Left + 12, screen.Top + 12);
        var stopwatch = Stopwatch.StartNew();
        WaitUntil(() => FindVisibleByAutomationId(processId, "QuickAccessWindow") is null,
            "Quick Access did not resume its countdown after hover ended.");
        if (stopwatch.Elapsed < TimeSpan.FromSeconds(1) || stopwatch.Elapsed > TimeSpan.FromSeconds(2.9))
            throw new InvalidOperationException($"Quick Access resumed with the wrong remaining time: {stopwatch.Elapsed.TotalSeconds:0.00}s.");
        return new QuickVerification(stopwatch.Elapsed.TotalSeconds, screenshot);
    }

    private static string ExerciseQuickAccessDelete(int processId, string root, string captureDirectory)
    {
        var quick = WaitForAutomationId(processId, "QuickAccessWindow");
        var bounds = quick.Current.BoundingRectangle;
        Native.SetCursorPos((int)Math.Round(bounds.Left + bounds.Width / 2), (int)Math.Round(bounds.Top + bounds.Height / 2));
        Thread.Sleep(350);

        Invoke(WaitForAutomationId(processId, "QuickAccessDelete"));
        WaitForAutomationId(processId, "ShotPasteDialog");
        var screenshot = Path.Combine(root, "quick-access-delete-confirmation.png");
        SaveDesktopScreenshot(screenshot);
        Invoke(WaitForAutomationId(processId, "DialogSecondary"));
        WaitUntil(() => FindByAutomationId(processId, "ShotPasteDialog") is null,
            "Cancel did not dismiss the Quick Access deletion confirmation.");
        if (Directory.GetFiles(captureDirectory, "*.png").Length != 1 ||
            FindVisibleByAutomationId(processId, "QuickAccessWindow") is null)
            throw new InvalidOperationException("Cancelling Quick Access deletion did not preserve both file and card.");

        Invoke(WaitForAutomationId(processId, "QuickAccessDelete"));
        WaitForAutomationId(processId, "ShotPasteDialog");
        Invoke(WaitForAutomationId(processId, "DialogPrimary"));
        WaitUntil(() => Directory.GetFiles(captureDirectory, "*.png").Length == 0,
            "Confirmed Quick Access deletion did not move the saved screenshot out of its original path.");
        WaitUntil(() => FindVisibleByAutomationId(processId, "QuickAccessWindow") is null,
            "Quick Access card remained after confirmed deletion.");
        return screenshot;
    }

    private static string ExerciseQuickAccessDrag(int processId, string root, string captureDirectory)
    {
        var quick = WaitForAutomationId(processId, "QuickAccessWindow");
        var quickBounds = quick.Current.BoundingRectangle;
        Native.SetCursorPos(
            (int)Math.Round(quickBounds.Left + quickBounds.Width / 2),
            (int)Math.Round(quickBounds.Top + quickBounds.Height / 2));
        Thread.Sleep(350);
        var dragAction = WaitForAutomationId(processId, "QuickAccessDrag");
        var dragBounds = dragAction.Current.BoundingRectangle;
        using var target = new NativeFileDropTarget();
        var screenshot = Path.Combine(root, "quick-access-native-file-drag.png");
        SaveDesktopScreenshot(screenshot);
        Drag(
            new Drawing.Point(
                (int)Math.Round(dragBounds.Left + dragBounds.Width / 2),
                (int)Math.Round(dragBounds.Top + dragBounds.Height / 2)),
            target.DropPoint);

        var dropped = target.WaitForDrop();
        var expected = Path.GetFullPath(Directory.GetFiles(captureDirectory, "*.png").Single());
        if (dropped.Length != 1 || !Path.GetFullPath(dropped[0]).Equals(expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"Quick Access dropped [{string.Join(", ", dropped)}], expected {expected}.");
        WaitUntil(() => FindVisibleByAutomationId(processId, "QuickAccessWindow") is null,
            "Quick Access card did not close after a successful external file drop.");
        return screenshot;
    }

    private static void RequestUiTestExit(string executable, string root)
    {
        using var forwarder = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", root, "--ui-test-exit" }
        }) ?? throw new InvalidOperationException("Could not start the UI-test exit forwarder.");
        if (!forwarder.WaitForExit(5000))
        {
            forwarder.Kill(entireProcessTree: true);
            throw new TimeoutException("UI-test exit command was not forwarded to the active product instance.");
        }
    }

    private static int PersistedHistoryItemCount(string database)
    {
        if (!File.Exists(database)) return 0;
        SqliteConnection.ClearAllPools();
        using var connection = new SqliteConnection($"Data Source={database};Mode=ReadOnly");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM history_items;";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static IntPtr PackPoint(Drawing.Point point) => new(unchecked((int)(
        ((uint)(ushort)point.Y << 16) | (ushort)point.X)));

    private static void SelectComboItem(AutomationElement combo, string name)
    {
        ((ExpandCollapsePattern)combo.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
        AutomationElement? item = null;
        WaitUntil(() =>
        {
            item = combo.FindAll(TreeScope.Subtree,
                    new PropertyCondition(AutomationElement.NameProperty, name))
                .Cast<AutomationElement>()
                .FirstOrDefault(candidate => candidate.Current.ControlType == ControlType.ListItem);
            return item is not null;
        }, $"Pinned zoom option {name} did not appear.");
        ((SelectionItemPattern)item!.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
        ((ExpandCollapsePattern)combo.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Collapse();
        Thread.Sleep(260);
    }

    private static void WriteSettings(string root, string captureDirectory, ScenarioAction action)
    {
        Directory.CreateDirectory(captureDirectory);
        var settings = new
        {
            SaveDirectory = captureDirectory,
            SaveScreenshots = true,
            CopyScreenshots = false,
            CopyAfterCapture = false,
            ShowQuickAccess = action is ScenarioAction.QuickAccess or ScenarioAction.QuickAccessDrag or ScenarioAction.QuickAccessDelete,
            QuickAccessAutoDismissSeconds = 3,
            PauseQuickAccessOnHover = true,
            QuickAccessPosition = "BottomRight",
            QuickAccessActions = action switch
            {
                ScenarioAction.QuickAccess => new[] { "Copy", "None", "Pin", "None", "None", "Close" },
                ScenarioAction.QuickAccessDrag => new[] { "Drag", "None", "None", "None", "None", "Close" },
                ScenarioAction.QuickAccessDelete => new[] { "Delete", "None", "None", "None", "None", "Close" },
                _ => new[] { "Copy", "Save", "Pin", "Open", "Drag", "Close" }
            },
            ClipboardHistoryEnabled = false,
            HistoryDefaultFilter = "Screenshot",
            ShortcutsEnabled = false,
            ExcludeOwnApplicationFromScreenshots = true,
            Language = "en-US"
        };
        File.WriteAllText(Path.Combine(root, "settings.json"),
            JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void WaitForCaptureCount(string directory, int count) => WaitUntil(
        () => Directory.Exists(directory) && Directory.GetFiles(directory, "*.png").Length == count,
        $"Expected {count} capture file(s).");

    private static int HistoryItemCount(int processId)
    {
        var list = FindByAutomationId(processId, "ExpandedHistoryGrid");
        if (list is null) return 0;
        return list.FindAll(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem)).Count;
    }

    private static int TopLevelWindowCount(int processId) => TopLevelWindows(processId).Count;

    private static IReadOnlyList<AutomationElement> TopLevelWindows(int processId)
    {
        var processCondition = new PropertyCondition(AutomationElement.ProcessIdProperty, processId);
        return AutomationElement.RootElement.FindAll(TreeScope.Children, processCondition)
            .Cast<AutomationElement>()
            .Where(element => element.Current.ControlType == ControlType.Window && !element.Current.IsOffscreen)
            .ToArray();
    }

    private static AutomationElement WaitForAutomationId(int processId, string automationId) =>
        WaitForElement(processId, AutomationElement.AutomationIdProperty, automationId);

    private static AutomationElement WaitForElement(
        int processId,
        AutomationProperty property,
        object value,
        Func<AutomationElement, bool>? predicate = null)
    {
        AutomationElement? result = null;
        WaitUntil(() =>
        {
            var conditions = new AndCondition(
                new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
                new PropertyCondition(property, value));
            result = AutomationElement.RootElement.FindAll(TreeScope.Descendants, conditions)
                .Cast<AutomationElement>()
                .FirstOrDefault(element => predicate?.Invoke(element) ?? true);
            return result is not null;
        }, $"UI element {property.ProgrammaticName}={value} did not appear.");
        return result!;
    }

    private static AutomationElement? FindByAutomationId(int processId, string automationId)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.AutomationIdProperty, automationId));
        return AutomationElement.RootElement.FindFirst(TreeScope.Descendants, condition);
    }

    private static AutomationElement? FindVisibleByAutomationId(int processId, string automationId)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.AutomationIdProperty, automationId));
        return AutomationElement.RootElement.FindAll(TreeScope.Descendants, condition)
            .Cast<AutomationElement>()
            .FirstOrDefault(element => !element.Current.IsOffscreen);
    }

    private static void Invoke(AutomationElement element) =>
        ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();

    private static void PhysicalClick(AutomationElement element)
    {
        if (!element.TryGetClickablePoint(out var point))
            throw new InvalidOperationException(
                $"{element.Current.AutomationId} did not expose a clickable point.");
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Native.SetCursorPos((int)Math.Round(point.X), (int)Math.Round(point.Y));
        Thread.Sleep(90);
        Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
        Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(220);
    }

    private static void Drag(Drawing.Point start, Drawing.Point end, Action? duringDrag = null)
    {
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Native.SetCursorPos(start.X, start.Y);
        Thread.Sleep(90);
        Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
        try
        {
            for (var step = 1; step <= 14; step++)
            {
                Native.SetCursorPos(
                    start.X + (end.X - start.X) * step / 14,
                    start.Y + (end.Y - start.Y) * step / 14);
                Thread.Sleep(18);
            }
            duringDrag?.Invoke();
        }
        finally
        {
            Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
        }
        Thread.Sleep(300);
    }

    private static void SendKey(AutomationElement window, byte virtualKey)
    {
        Native.SetForegroundWindow(new IntPtr(window.Current.NativeWindowHandle));
        Thread.Sleep(80);
        Native.keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        Native.keybd_event(virtualKey, 0, Native.KeyUp, UIntPtr.Zero);
    }

    private static void DragWhileHoldingKey(
        AutomationElement window,
        byte virtualKey,
        Drawing.Point start,
        Drawing.Point end)
    {
        Native.SetForegroundWindow(new IntPtr(window.Current.NativeWindowHandle));
        window.SetFocus();
        Thread.Sleep(80);
        Native.keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        try
        {
            Drag(start, end);
        }
        finally
        {
            Native.keybd_event(virtualKey, 0, Native.KeyUp, UIntPtr.Zero);
        }
    }

    private static void SaveDesktopScreenshot(string path)
    {
        var bounds = Forms.SystemInformation.VirtualScreen;
        using var bitmap = new Drawing.Bitmap(bounds.Width, bounds.Height);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, ImageFormat.Png);
    }

    private static void WaitUntil(Func<bool> condition, string failure)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < UiTimeout)
        {
            try { if (condition()) return; }
            catch (ElementNotAvailableException) { }
            Thread.Sleep(80);
        }
        throw new TimeoutException(failure);
    }

    private enum ScenarioAction
    {
        DoneWithEnter,
        PanToolbarRecovery,
        CancelWithEscape,
        DirtyReturnAndDiscard,
        DirtySave,
        DirtyExitReturnAndDiscard,
        DirtyExitSave,
        Pin,
        QuickAccess,
        QuickAccessDrag,
        QuickAccessDelete,
        EditorRemoved,
        CopyRecovery,
        SelectionSizeBadgeDefault,
        SelectionSizeBadgeEdge,
        ToolbarDefaultBelow,
        OneShotSelectionMove,
        OneShotScrollingSelectionMove,
        OneShotRecordingSelectionMove,
        OneShotToolbarDrag,
        PerformanceBaseline
    }

    private sealed record PinVerification(double WidthAt50, double WidthAt150, long ImageHitTest, long LockHitTest, string Screenshot);
    private sealed record QuickVerification(double ResumeSeconds, string Screenshot);

    private sealed class NativeFileDropTarget : IDisposable
    {
        private readonly ManualResetEventSlim _ready = new();
        private readonly ManualResetEventSlim _dropped = new();
        private readonly Thread _thread;
        private Forms.Form? _form;
        private Exception? _failure;
        private string[] _droppedFiles = [];

        public NativeFileDropTarget()
        {
            _thread = new Thread(Run) { IsBackground = true };
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
            if (!_ready.Wait(UiTimeout)) throw new TimeoutException("Native file-drop target did not open.");
            if (_failure is not null) throw new InvalidOperationException("Native file-drop target failed to open.", _failure);
        }

        public Drawing.Point DropPoint { get; private set; }

        public string[] WaitForDrop()
        {
            if (!_dropped.Wait(UiTimeout)) throw new TimeoutException("Native file-drop target did not receive the Quick Access drag.");
            if (_failure is not null) throw new InvalidOperationException("Native file-drop target failed.", _failure);
            return _droppedFiles;
        }

        private void Run()
        {
            try
            {
                var screen = Forms.Screen.PrimaryScreen?.WorkingArea ?? new Drawing.Rectangle(0, 0, 1280, 720);
                using var form = new Forms.Form
                {
                    Text = "ShotPaste Quick Access native drop target",
                    StartPosition = Forms.FormStartPosition.Manual,
                    Bounds = new Drawing.Rectangle(screen.Left + 70, screen.Top + 180, 440, 280),
                    FormBorderStyle = Forms.FormBorderStyle.FixedDialog,
                    MaximizeBox = false,
                    MinimizeBox = false,
                    TopMost = true,
                    AllowDrop = true
                };
                _form = form;
                form.DragEnter += (_, eventArgs) =>
                {
                    eventArgs.Effect = eventArgs.Data?.GetDataPresent(Forms.DataFormats.FileDrop) == true
                        ? Forms.DragDropEffects.Copy
                        : Forms.DragDropEffects.None;
                };
                form.DragDrop += (_, eventArgs) =>
                {
                    _droppedFiles = eventArgs.Data?.GetData(Forms.DataFormats.FileDrop) as string[] ?? [];
                    eventArgs.Effect = _droppedFiles.Length > 0 ? Forms.DragDropEffects.Copy : Forms.DragDropEffects.None;
                    _dropped.Set();
                };
                form.Shown += (_, _) =>
                {
                    DropPoint = form.PointToScreen(new Drawing.Point(form.ClientSize.Width / 2, form.ClientSize.Height / 2));
                    _ready.Set();
                };
                Forms.Application.Run(form);
            }
            catch (Exception exception)
            {
                _failure = exception;
                _ready.Set();
                _dropped.Set();
            }
        }

        public void Dispose()
        {
            try
            {
                if (_form is { IsDisposed: false, IsHandleCreated: true })
                    _form.BeginInvoke(_form.Close);
            }
            catch (InvalidOperationException) { }
            _thread.Join(TimeSpan.FromSeconds(5));
            _ready.Dispose();
            _dropped.Dispose();
        }
    }
    private sealed record Synthetic4KBenchmark(
        int Width,
        int Height,
        int AnnotationCount,
        double FirstFrameMilliseconds,
        double InteractionRenderMilliseconds,
        double ExportMilliseconds,
        long ManagedMemoryDeltaBytes,
        long WorkingSetDeltaBytes,
        string Output);
    private sealed record InlinePerformanceSample(
        double FirstFrameMilliseconds,
        double InteractionMilliseconds,
        double ExportMilliseconds,
        long WorkingSetBytes,
        long PeakWorkingSetBytes,
        int AnnotationCount,
        int DisplayCount,
        Drawing.Rectangle VirtualScreen);

    private sealed record ScenarioResult(
        string Name,
        string Detail,
        string Screenshot,
        string? Output,
        int OutputCount,
        int HistoryItemCount,
        int? Width,
        int? Height,
        InlinePerformanceSample? Performance);

    private static class Native
    {
        internal const uint MouseLeftDown = 0x0002;
        internal const uint MouseLeftUp = 0x0004;
        internal const uint KeyUp = 0x0002;
        internal const uint WmNcHitTest = 0x0084;
        internal const long HtTransparent = -1;

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        internal static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        internal static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extraInfo);

        [DllImport("user32.dll")]
        internal static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        internal static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool OpenClipboard(IntPtr owner);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseClipboard();
    }
}
