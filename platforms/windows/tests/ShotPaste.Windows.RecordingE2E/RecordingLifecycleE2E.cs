using System.Diagnostics;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using Microsoft.Data.Sqlite;
using ShotPaste.Windows.Models;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.RecordingE2E;

internal static class RecordingLifecycleE2E
{
    private static readonly TimeSpan UiTimeout = TimeSpan.FromSeconds(45);

    internal static async Task<object> RunAsync(string executable, string outputRoot)
    {
        executable = Path.GetFullPath(executable);
        var root = Path.Combine(outputRoot, "product-lifecycle");
        Directory.CreateDirectory(root);
        var restartDelete = await RunRestartDeleteAsync(executable, Path.Combine(root, "restart-delete"));
        var exitSave = await RunExitSaveAsync(executable, Path.Combine(root, "exit-save"));
        var exitDiscard = await RunExitDiscardAsync(executable, Path.Combine(root, "exit-discard"));
        return new { RestartDelete = restartDelete, ExitSave = exitSave, ExitDiscard = exitDiscard };
    }

    private static async Task<object> RunRestartDeleteAsync(string executable, string root)
    {
        PrepareRoot(root);
        using var product = Launch(executable, root);
        try
        {
            var firstToolbar = await StartRecordingAsync(product.Id);
            var firstHandle = firstToolbar.Current.NativeWindowHandle;

            Invoke(await WaitForAutomationIdAsync(product.Id, "RecordingRestart"));
            var prompt = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var restartPrompt = Path.Combine(root, "restart-confirmation.png");
            SaveElementScreenshot(prompt, restartPrompt);
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogSecondary"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "ShotPasteDialog") is null,
                "Cancelling restart did not close the confirmation.");
            if (FindByAutomationId(product.Id, "RecordingToolbarWindow") is null)
                throw new InvalidOperationException("Cancelling restart stopped the active recording.");

            Invoke(await WaitForAutomationIdAsync(product.Id, "RecordingRestart"));
            await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogPrimary"));
            AutomationElement? restartedToolbar = null;
            await WaitUntilAsync(() =>
            {
                restartedToolbar = FindByAutomationId(product.Id, "RecordingToolbarWindow");
                return restartedToolbar is not null && restartedToolbar.Current.NativeWindowHandle != firstHandle;
            }, "Confirmed restart did not create a new recording toolbar/workflow.");

            Invoke(await WaitForAutomationIdAsync(product.Id, "RecordingDelete"));
            prompt = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var deletePrompt = Path.Combine(root, "delete-confirmation.png");
            SaveElementScreenshot(prompt, deletePrompt);
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogSecondary"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "ShotPasteDialog") is null,
                "Cancelling recording deletion did not close the confirmation.");
            if (FindByAutomationId(product.Id, "RecordingToolbarWindow") is null)
                throw new InvalidOperationException("Cancelling recording deletion stopped the active recording.");

            Invoke(await WaitForAutomationIdAsync(product.Id, "RecordingDelete"));
            await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogPrimary"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "RecordingToolbarWindow") is null,
                "Confirmed recording deletion did not end the recording workflow.");
            await WaitUntilAsync(() => CaptureFiles(root).Length == 0,
                "Restart/delete left a recording at its original path instead of moving it to the Recycle Bin.");
            if (HistoryRows(root) != 0)
                throw new InvalidOperationException("Restart/delete inserted a discarded recording into history.");

            RequestUiTestExit(executable, root);
            await WaitUntilAsync(() => product.HasExited, "ShotPaste did not exit after the recording workflow ended.");
            return new
            {
                CancelRestartPreservedRecording = true,
                ConfirmRestartCreatedNewWorkflow = true,
                CancelDeletePreservedRecording = true,
                ConfirmDeleteRecycledFiles = true,
                RestartPrompt = restartPrompt,
                DeletePrompt = deletePrompt
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunExitSaveAsync(string executable, string root)
    {
        PrepareRoot(root);
        using var product = Launch(executable, root);
        try
        {
            await StartRecordingAsync(product.Id);
            RequestUiTestExit(executable, root);
            var prompt = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var exitPrompt = Path.Combine(root, "exit-save-confirmation.png");
            SaveElementScreenshot(prompt, exitPrompt);
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogTertiary"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "ShotPasteDialog") is null,
                "Cancelling application exit did not close the recording prompt.");
            if (product.HasExited || FindByAutomationId(product.Id, "RecordingToolbarWindow") is null)
                throw new InvalidOperationException("Cancelling application exit did not preserve recording.");

            RequestUiTestExit(executable, root);
            await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogPrimary"));
            await WaitUntilAsync(() => product.HasExited, "Stop-and-save exit did not wait for recording finalization.");
            var files = CaptureFiles(root);
            if (files.Length != 1 || HistoryRows(root) != 1)
                throw new InvalidOperationException(
                    $"Stop-and-save exit produced files={files.Length}, history={HistoryRows(root)}; expected 1/1.");
            return new
            {
                CancelPreservedRecording = true,
                StopAndSaveWaitedForExit = true,
                SavedFile = files.Single(),
                HistoryRows = 1,
                ExitPrompt = exitPrompt
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunExitDiscardAsync(string executable, string root)
    {
        PrepareRoot(root);
        using var product = Launch(executable, root);
        try
        {
            await StartRecordingAsync(product.Id);
            RequestUiTestExit(executable, root);
            var prompt = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var exitPrompt = Path.Combine(root, "exit-discard-confirmation.png");
            SaveElementScreenshot(prompt, exitPrompt);
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogSecondary"));
            await WaitUntilAsync(() => product.HasExited, "Discard-and-exit did not wait for recording disposal.");
            if (CaptureFiles(root).Length != 0 || HistoryRows(root) != 0)
                throw new InvalidOperationException("Discard-and-exit retained a file at its original path or inserted history.");
            return new
            {
                DiscardExited = true,
                FilesAtOriginalPath = 0,
                HistoryRows = 0,
                ExitPrompt = exitPrompt
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<AutomationElement> StartRecordingAsync(int processId)
    {
        await WaitForAutomationIdAsync(processId, "InlineAnnotateWindow");
        Invoke(await WaitForAutomationIdAsync(processId, "OneShotRecording"));
        var screen = Forms.Screen.FromPoint(Forms.Cursor.Position).WorkingArea;
        var start = new Drawing.Point(screen.Left + Math.Max(100, screen.Width / 5), screen.Top + Math.Max(120, screen.Height / 5));
        var end = new Drawing.Point(Math.Min(screen.Right - 260, start.X + 520), Math.Min(screen.Bottom - 240, start.Y + 330));
        await DragAsync(start, end);
        Invoke(await WaitForAutomationIdAsync(processId, "OneShotStartRecording"));
        var toolbar = await WaitForAutomationIdAsync(processId, "RecordingToolbarWindow");
        await Task.Delay(1100);
        return toolbar;
    }

    private static void PrepareRoot(string root)
    {
        if (Directory.Exists(root)) Directory.Delete(root, true);
        Directory.CreateDirectory(root);
        var captures = Path.Combine(root, "Captures");
        Directory.CreateDirectory(captures);
        var settings = new AppSettings
        {
            SaveDirectory = captures,
            Language = "en-US",
            ClipboardHistoryEnabled = false,
            ShortcutsEnabled = false,
            ShowQuickAccess = false,
            ShowRecordingToolbar = true,
            RecordingOutputMode = RecordingOutputMode.Video,
            RecordingVideoCodec = "H264",
            RecordSystemAudio = false,
            RecordMicrophone = false,
            HighlightMouseClicks = false,
            ShowKeystrokes = false,
            CopyRecordings = false,
            ShowCaptureNotifications = false
        };
        File.WriteAllText(Path.Combine(root, "settings.json"),
            JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static Process Launch(string executable, string root) =>
        Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", root, "--one-shot" }
        }) ?? throw new InvalidOperationException("Could not launch ShotPaste recording lifecycle fixture.");

    private static void RequestUiTestExit(string executable, string root)
    {
        using var forwarder = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", root, "--ui-test-exit" }
        }) ?? throw new InvalidOperationException("Could not launch the exit command forwarder.");
        if (!forwarder.WaitForExit(5000))
        {
            forwarder.Kill(entireProcessTree: true);
            throw new TimeoutException("Exit command forwarder did not finish.");
        }
    }

    private static string[] CaptureFiles(string root)
    {
        var directory = Path.Combine(root, "Captures");
        return Directory.Exists(directory)
            ? Directory.GetFiles(directory).Where(path => Path.GetExtension(path) is ".mp4" or ".gif").ToArray()
            : [];
    }

    private static int HistoryRows(string root)
    {
        var database = Path.Combine(root, "history.sqlite3");
        if (!File.Exists(database)) return 0;
        SqliteConnection.ClearAllPools();
        using var connection = new SqliteConnection($"Data Source={database};Mode=ReadOnly");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM history_items;";
        return Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture);
    }

    private static AutomationElement? FindByAutomationId(int processId, string id)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.AutomationIdProperty, id));
        var matches = AutomationElement.RootElement.FindAll(TreeScope.Descendants, condition)
            .Cast<AutomationElement>()
            .ToArray();
        return matches.FirstOrDefault(element => !element.Current.IsOffscreen) ?? matches.FirstOrDefault();
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
        await Task.Delay(300);
    }

    private static void SaveElementScreenshot(AutomationElement element, string path)
    {
        var bounds = element.Current.BoundingRectangle;
        var rectangle = Drawing.Rectangle.FromLTRB((int)Math.Round(bounds.Left), (int)Math.Round(bounds.Top),
            (int)Math.Round(bounds.Right), (int)Math.Round(bounds.Bottom));
        using var bitmap = new Drawing.Bitmap(Math.Max(1, rectangle.Width), Math.Max(1, rectangle.Height));
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(rectangle.Left, rectangle.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, ImageFormat.Png);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, string failure)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < UiTimeout)
        {
            try { if (predicate()) return; }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }
            await Task.Delay(90);
        }
        throw new TimeoutException(failure);
    }

    private static void StopExactProcess(Process process)
    {
        try
        {
            if (process.HasExited) return;
            process.Kill(entireProcessTree: true);
            process.WaitForExit(5000);
        }
        catch (InvalidOperationException) { }
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
