using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using LiteScreen.Windows.Models;
using LiteScreen.Windows.Services;
using Drawing = System.Drawing;

internal static class EdgeScrollingCapture
{
    private const uint MouseWheel = 0x0800;
    private const uint MouseLeftDown = 0x0002;
    private const uint MouseLeftUp = 0x0004;
    private const uint WmClose = 0x0010;

    internal static async Task<int> RunAsync(string[] args, bool fastManualScroll)
    {
        SetProcessDpiAwarenessContext(new IntPtr(-4));
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (args.Length != 1)
        {
            Console.Error.WriteLine("Usage: --edge|--edge-fast <output.png>");
            return 2;
        }

        var output = Path.GetFullPath(args[0]);
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        var root = Path.Combine(Path.GetDirectoryName(output)!, Path.GetFileNameWithoutExtension(output) + "-edge-profile");
        Directory.CreateDirectory(root);
        var fixture = Path.Combine(AppContext.BaseDirectory, "fixtures", "scrolling-capture-e2e.html");
        if (!File.Exists(fixture)) throw new FileNotFoundException("Scrolling fixture was not copied.", fixture);
        var edge = FindEdgeExecutable();
        var knownEdgeProcesses = Process.GetProcessesByName("msedge").Select(process => process.Id).ToHashSet();
        using var launched = Process.Start(new ProcessStartInfo(edge)
        {
            UseShellExecute = false,
            ArgumentList =
            {
                $"--user-data-dir={root}",
                "--no-default-browser-check",
                "--guest",
                "--disable-sync",
                "--disable-background-mode",
                "--disable-features=msEdgeFirstRunExperience,msEdgeFirstRunExperienceV2,EdgeIdentity",
                "--window-position=70,70",
                "--window-size=900,720",
                $"--app={new Uri(fixture).AbsoluteUri}"
            }
        }) ?? throw new InvalidOperationException("Could not launch Microsoft Edge.");

        var window = IntPtr.Zero;
        try
        {
            window = await WaitForEdgeWindowAsync(knownEdgeProcesses);
            var region = GetClientBounds(window);
            if (region.Width < 600 || region.Height < 400)
                throw new InvalidOperationException($"Edge viewport is unexpectedly small: {region}.");
            SetForegroundWindow(window);
            SetCursorPos(region.Left + region.Width / 2, region.Top + region.Height / 2);
            mouse_event(MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
            mouse_event(MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
            // A cold Edge profile resolves the CJK fallback font after the first
            // paint. Starting from that transient frame makes every glyph appear
            // changed after the first wheel step and is indistinguishable from a
            // broken overlap. Wait for the fixture's layout and font paint to settle.
            await Task.Delay(1800);
            SetForegroundWindow(window);
            SetCursorPos(region.Left + region.Width / 2, region.Top + region.Height / 2);
            mouse_event(MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
            mouse_event(MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
            await Task.Delay(200);

            var capture = new ScreenCaptureService();
            region = await WaitForFixtureContentAsync(
                region,
                capture,
                Path.ChangeExtension(output, ".probe.png"));
            SetCursorPos(region.Left + region.Width / 2, region.Top + region.Height / 2);
            using var wheel = new MouseWheelMonitor();
            wheel.Start(region);
            var progressEvents = new List<ScrollingCaptureProgress>();
            var progress = new Progress<ScrollingCaptureProgress>(item => progressEvents.Add(item));
            var service = new ScrollingCaptureService(
                capture,
                maximumHeight: 20_000,
                previewMaxHeight: 420,
                autoScrollIntervalMs: 40,
                detectFixedBars: true,
                safetyGuardEnabled: true,
                captureOptionsProvider: () => new ScreenCaptureOptions(IncludeCursor: false, ExcludeOwnApplication: false));
            var finish = 0;
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            var driver = fastManualScroll
                ? DriveFastWheelAsync(region, () => Interlocked.Exchange(ref finish, 1), cancellation.Token)
                : Task.CompletedTask;
            using var result = await service.CaptureAsync(
                region,
                window,
                wheel,
                progress,
                cancellation.Token,
                autoScrollEnabled: () => !fastManualScroll,
                discardRequested: () => false,
                finishRequested: () => Volatile.Read(ref finish) == 1);
            await driver;
            if (result is null) throw new InvalidOperationException("Edge scrolling capture returned no output.");
            result.Save(output, ImageFormat.Png);
            if (result.Width != region.Width)
                throw new InvalidOperationException($"Edge output width changed from {region.Width} to {result.Width}.");
            var minimumHeight = fastManualScroll ? region.Height * 5 / 4 : region.Height * 4;
            if (result.Height <= minimumHeight)
                throw new InvalidOperationException($"Edge output is not a long image: {result.Width}x{result.Height}.");

            var dpiScale = GetDpiForWindow(window) / 96d;
            var validationRows = fastManualScroll
                ? LiveScrollingCapture.VerifyValidationRowPrefix(result, dpiScale, minimumRows: 4)
                : LiveScrollingCapture.VerifyValidationRows(result, dpiScale);
            var chrome = VerifyChromeAndSentinels(result, dpiScale, requireBottom: !fastManualScroll);
            var summary = new
            {
                Passed = true,
                Browser = "Microsoft Edge",
                Executable = edge,
                Fixture = fixture,
                Mode = fastManualScroll ? "fast-manual-wheel" : "automatic-wheel",
                Region = region,
                Output = output,
                OutputWidth = result.Width,
                OutputHeight = result.Height,
                DpiScale = dpiScale,
                FullPageExpected = !fastManualScroll,
                SafeContiguousPrefix = fastManualScroll,
                ValidationRows = validationRows,
                Chrome = chrome,
                ProgressEvents = progressEvents.Count,
                LastStatus = progressEvents.LastOrDefault()?.Status,
                RecoveryObserved = progressEvents.Any(item =>
                    item.Safety == ScrollingCaptureSafety.Unsafe ||
                    item.PreviewTruth == ScrollingPreviewTruth.PausedRecovery),
                SavingObserved = progressEvents.Any(item => item.PreviewTruth == ScrollingPreviewTruth.Saving)
            };
            File.WriteAllText(Path.ChangeExtension(output, ".json"),
                JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine(JsonSerializer.Serialize(summary, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
        finally
        {
            if (window != IntPtr.Zero && IsWindow(window)) PostMessage(window, WmClose, IntPtr.Zero, IntPtr.Zero);
        }
    }

    private static async Task DriveFastWheelAsync(
        Drawing.Rectangle region,
        Action finish,
        CancellationToken cancellationToken)
    {
        await Task.Delay(300, cancellationToken);
        SetCursorPos(region.Left + region.Width / 2, region.Top + region.Height / 2);
        // Deliberately outrun one capture window, then stop. The expected contract is
        // a safe contiguous prefix plus recovery guidance—not fabricated rows after
        // a gap that no screenshot pipeline observed.
        for (var burst = 0; burst < 1; burst++)
        {
            for (var index = 0; index < 5; index++)
            {
                mouse_event(MouseWheel, 0, 0, -120, UIntPtr.Zero);
                await Task.Delay(7, cancellationToken);
            }
            await Task.Delay(150, cancellationToken);
        }
        await Task.Delay(1000, cancellationToken);
        finish();
    }

    private static object VerifyChromeAndSentinels(
        Drawing.Bitmap result,
        double dpiScale,
        bool requireBottom)
    {
        var purple = Drawing.ColorTranslator.FromHtml("#5637c7");
        var rail = Drawing.ColorTranslator.FromHtml("#202942");
        var yellow = Drawing.ColorTranslator.FromHtml("#ffdd57");
        var headerX = Math.Clamp((int)Math.Round(300 * dpiScale), 0, result.Width - 1);
        var headerRun = FindFirstVerticalRun(
            result,
            headerX,
            purple,
            tolerance: 6,
            minimumLength: Math.Max(24, (int)Math.Round(40 * dpiScale)),
            searchLimit: Math.Min(result.Height, (int)Math.Round(160 * dpiScale)));
        if (headerRun is null || headerRun.Value.Start > Math.Round(80 * dpiScale))
            throw new InvalidOperationException("The fixed Edge header was not preserved at the top.");

        var railX = Math.Clamp((int)Math.Round(42 * dpiScale), 0, result.Width - 1);
        var railMatches = 0;
        var railSamples = 0;
        for (var y = Math.Max(headerRun.Value.End + 1, 80); y < result.Height; y += 31)
        {
            railSamples++;
            if (Near(result.GetPixel(railX, y), rail, 7)) railMatches++;
        }
        var railRatio = railMatches / (double)Math.Max(1, railSamples);
        var requiredRailRatio = requireBottom ? 0.88 : 0.80;
        if (railRatio < requiredRailRatio)
            throw new InvalidOperationException($"The fixed Edge side rail was cropped or fragmented ({railRatio:P1}).");

        var sentinelX = Math.Clamp((int)Math.Round((112 + 24 + 160) * dpiScale), 0, result.Width - 1);
        var yellowRuns = new List<(int Start, int End)>();
        var runStart = -1;
        for (var y = 0; y <= result.Height; y++)
        {
            var match = y < result.Height && Near(result.GetPixel(sentinelX, y), yellow, 7);
            if (match && runStart < 0) runStart = y;
            if (!match && runStart >= 0)
            {
                if (y - runStart >= Math.Max(20, 40 * dpiScale)) yellowRuns.Add((runStart, y - 1));
                runStart = -1;
            }
        }
        if (yellowRuns.Count < 1)
            throw new InvalidOperationException("The TOP · 0000 sentinel was not preserved.");
        if (requireBottom && yellowRuns.Count < 2)
            throw new InvalidOperationException($"Expected TOP and BOTTOM sentinels, found {yellowRuns.Count} yellow bands.");
        var bottomAtTail = yellowRuns.Count >= 2 &&
            yellowRuns[^1].End >= result.Height - Math.Max(120, (int)Math.Round(180 * dpiScale));
        if (requireBottom && !bottomAtTail)
            throw new InvalidOperationException("BOTTOM · 9999 was not preserved near the final output tail.");
        object? bottomSentinel = yellowRuns.Count >= 2
            ? new { yellowRuns[^1].Start, yellowRuns[^1].End }
            : null;
        return new
        {
            FixedHeader = true,
            FixedHeaderBand = new { headerRun.Value.Start, headerRun.Value.End },
            FixedSideRail = true,
            FixedSideRailCoverage = Math.Round(railRatio, 4),
            TopSentinel = new { yellowRuns[0].Start, yellowRuns[0].End },
            BottomSentinel = bottomSentinel,
            Bottom9999AtTail = bottomAtTail,
            FullPageRequired = requireBottom
        };

        static bool Near(Drawing.Color actual, Drawing.Color expected, int tolerance) =>
            Math.Abs(actual.R - expected.R) <= tolerance &&
            Math.Abs(actual.G - expected.G) <= tolerance &&
            Math.Abs(actual.B - expected.B) <= tolerance;

        static (int Start, int End)? FindFirstVerticalRun(
            Drawing.Bitmap bitmap,
            int x,
            Drawing.Color expected,
            int tolerance,
            int minimumLength,
            int searchLimit)
        {
            var start = -1;
            for (var y = 0; y <= searchLimit; y++)
            {
                var matches = y < searchLimit && Near(bitmap.GetPixel(x, y), expected, tolerance);
                if (matches && start < 0) start = y;
                if (!matches && start >= 0)
                {
                    if (y - start >= minimumLength) return (start, y - 1);
                    start = -1;
                }
            }
            return null;
        }
    }

    private static async Task<Drawing.Rectangle> WaitForFixtureContentAsync(
        Drawing.Rectangle windowRegion,
        ScreenCaptureService capture,
        string probePath)
    {
        var stopwatch = Stopwatch.StartNew();
        var savedProbe = false;
        while (stopwatch.Elapsed < TimeSpan.FromSeconds(15))
        {
            using var frame = capture.CaptureRectangle(
                windowRegion,
                new ScreenCaptureOptions(IncludeCursor: false, ExcludeOwnApplication: false));
            if (!savedProbe)
            {
                frame.Save(probePath, ImageFormat.Png);
                savedProbe = true;
            }
            if (TryFindFixtureTop(frame, out var contentTop))
            {
                return new Drawing.Rectangle(
                    windowRegion.Left,
                    windowRegion.Top + contentTop,
                    windowRegion.Width,
                    windowRegion.Height - contentTop);
            }
            await Task.Delay(200);
        }
        throw new InvalidOperationException("Could not locate the Edge fixture content below browser chrome.");

        static bool TryFindFixtureTop(Drawing.Bitmap frame, out int contentTop)
        {
            var purple = Drawing.ColorTranslator.FromHtml("#5637c7");
            var x = frame.Width / 2;
            var runStart = -1;
            var minimumRun = Math.Max(24, (int)Math.Round(40 * frame.VerticalResolution / 96d));
            var searchLimit = Math.Min(frame.Height, (int)Math.Round(180 * frame.VerticalResolution / 96d));
            for (var y = 0; y <= searchLimit; y++)
            {
                var matches = y < searchLimit && Near(frame.GetPixel(x, y), purple, 6);
                if (matches && runStart < 0) runStart = y;
                if (!matches && runStart >= 0)
                {
                    if (y - runStart >= minimumRun)
                    {
                        contentTop = runStart;
                        return true;
                    }
                    runStart = -1;
                }
            }
            contentTop = 0;
            return false;
        }

        static bool Near(Drawing.Color actual, Drawing.Color expected, int tolerance) =>
            Math.Abs(actual.R - expected.R) <= tolerance &&
            Math.Abs(actual.G - expected.G) <= tolerance &&
            Math.Abs(actual.B - expected.B) <= tolerance;
    }

    private static string FindEdgeExecutable()
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Edge", "Application", "msedge.exe")
        };
        return candidates.FirstOrDefault(File.Exists) ??
               throw new FileNotFoundException("Microsoft Edge is required for scrolling E2E.");
    }

    private static async Task<IntPtr> WaitForEdgeWindowAsync(HashSet<int> knownProcessIds)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < TimeSpan.FromSeconds(20))
        {
            var match = IntPtr.Zero;
            EnumWindows((window, _) =>
            {
                if (!IsWindowVisible(window)) return true;
                GetWindowThreadProcessId(window, out var processId);
                if (knownProcessIds.Contains((int)processId)) return true;
                var title = new StringBuilder(512);
                GetWindowText(window, title, title.Capacity);
                if (!title.ToString().Contains("LiteScreen Scrolling Capture E2E", StringComparison.OrdinalIgnoreCase)) return true;
                match = window;
                return false;
            }, IntPtr.Zero);
            if (match != IntPtr.Zero) return match;
            await Task.Delay(100);
        }
        throw new TimeoutException("The Edge scrolling fixture window did not appear.");
    }

    private static Drawing.Rectangle GetClientBounds(IntPtr window)
    {
        if (!GetClientRect(window, out var client)) throw new InvalidOperationException("Could not read Edge client bounds.");
        var origin = new Point();
        if (!ClientToScreen(window, ref origin)) throw new InvalidOperationException("Could not map Edge client bounds.");
        return new Drawing.Rectangle(origin.X, origin.Y, client.Right - client.Left, client.Bottom - client.Top);
    }

    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximumCount);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
