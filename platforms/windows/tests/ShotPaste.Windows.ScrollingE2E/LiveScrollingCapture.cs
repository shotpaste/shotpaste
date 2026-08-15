using System.Drawing.Imaging;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Views;
using Drawing = System.Drawing;

internal static class LiveScrollingCapture
{
    public static async Task<int> RunAsync(string[] args, bool fastManualScroll)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine(
                "Usage: ShotPaste.Windows.ScrollingE2E --live|--live-fast <output.png>");
            return 2;
        }

        var outputPath = Path.GetFullPath(args[0]);
        var completion = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() => RunOnSta(outputPath, fastManualScroll, completion));
        // A stalled UI/capture path must not keep the E2E process alive after
        // the outer 90-second contract has already failed.
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        try
        {
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(90));
        }
        catch (TimeoutException)
        {
            Console.Error.WriteLine("Live scrolling capture exceeded the 90-second E2E timeout.");
            return 1;
        }
    }

    private static void RunOnSta(
        string outputPath,
        bool fastManualScroll,
        TaskCompletionSource<int> completion)
    {
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        // The E2E host is not started through ShotPaste's App.xaml. Provide the two
        // style keys needed to instantiate the real scrolling HUD and exercise its
        // routed click/state logic; production uses the full App.xaml definitions.
        application.Resources["HudTextButton"] = new Style(typeof(Button));
        application.Resources["AccentButton"] = new Style(typeof(Button));
        var window = BuildFixture(out var scrollViewer);
        var renderedOffsetBits = BitConverter.DoubleToInt64Bits(0);
        var capturedOffsets = new ConcurrentQueue<double>();
        scrollViewer.ScrollChanged += (_, _) =>
            Volatile.Write(
                ref renderedOffsetBits,
                BitConverter.DoubleToInt64Bits(scrollViewer.VerticalOffset));
        window.Loaded += async (_, _) =>
        {
            try
            {
                await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Render);
                scrollViewer.ScrollToTop();
                scrollViewer.Focus();
                await Task.Delay(220);

                var handle = new WindowInteropHelper(window).Handle;
                if (handle == IntPtr.Zero || !GetWindowRect(handle, out var bounds))
                    throw new InvalidOperationException("Unable to resolve the native fixture window bounds.");
                var region = Drawing.Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
                VerifyProgressHudState(region);
                if (!SetCursorPos(region.Left + region.Width / 2, region.Top + region.Height / 2))
                    throw new InvalidOperationException("Unable to position the cursor inside the live capture fixture.");

                using var wheelMonitor = new MouseWheelMonitor();
                wheelMonitor.Start(region);
                var progressEvents = new List<ScrollingCaptureProgress>();
                var progress = new Progress<ScrollingCaptureProgress>(item => progressEvents.Add(item));
                var capture = new ScreenCaptureService();
                var service = new ScrollingCaptureService(
                    capture,
                    maximumHeight: 20_000,
                    previewMaxHeight: 420,
                    autoScrollIntervalMs: 40,
                    detectFixedBars: true,
                    safetyGuardEnabled: true,
                    captureOptionsProvider: () => new ScreenCaptureOptions(
                        IncludeCursor: false,
                        ExcludeOwnApplication: false),
                    frameCapture: (captureRegion, options) =>
                    {
                        var frame = capture.CaptureRectangle(captureRegion, options);
                        capturedOffsets.Enqueue(BitConverter.Int64BitsToDouble(
                            Volatile.Read(ref renderedOffsetBits)));
                        return frame;
                    });

                var finishRequested = 0;
                var fastScrollDriver = fastManualScroll
                    ? DriveFastManualScrollAsync(
                        () => Interlocked.Exchange(ref finishRequested, 1))
                    : Task.CompletedTask;

                using var result = await service.CaptureAsync(
                    region,
                    handle,
                    wheelMonitor,
                    progress,
                    CancellationToken.None,
                    autoScrollEnabled: () => !fastManualScroll,
                    discardRequested: () => false,
                    finishRequested: () => Volatile.Read(ref finishRequested) == 1);
                await fastScrollDriver;
                if (result is null)
                    throw new InvalidOperationException("Live scrolling capture returned no image.");
                if (!fastManualScroll && scrollViewer.VerticalOffset < scrollViewer.ScrollableHeight - 1)
                    throw new InvalidOperationException(
                        $"Automatic scrolling stopped early at {scrollViewer.VerticalOffset:F1}/{scrollViewer.ScrollableHeight:F1}.");
                var dpiScale = region.Height / window.ActualHeight;
                var expectedHeight = region.Height +
                                     (int)Math.Round(scrollViewer.ScrollableHeight * dpiScale);
                var heightTolerance = Math.Max(8, (int)Math.Ceiling(dpiScale * 8));
                Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
                result.Save(outputPath, ImageFormat.Png);
                var sizeIsInvalid = fastManualScroll
                    ? result.Width != region.Width || result.Height <= region.Height * 6 / 5
                    : result.Width != region.Width || Math.Abs(result.Height - expectedHeight) > heightTolerance;
                if (sizeIsInvalid)
                {
                    var sampledOffsets = capturedOffsets
                        .Select(value => Math.Round(value, 1))
                        .Distinct()
                        .OrderBy(value => value)
                        .ToArray();
                    var maximumSampleGap = sampledOffsets
                        .Zip(sampledOffsets.Skip(1), (left, right) => right - left)
                        .DefaultIfEmpty(0)
                        .Max();
                    throw new InvalidOperationException(
                        $"Live output size is wrong: {result.Width}x{result.Height}; " +
                        $"expected {region.Width}x{expectedHeight} (tolerance {heightTolerance}); " +
                        $"captured offsets={sampledOffsets.Length}, maximum gap={maximumSampleGap:F1}.");
                }
                var validationRows = fastManualScroll
                    ? VerifyValidationRowPrefix(result, dpiScale, minimumRows: 4)
                    : VerifyValidationRows(result, dpiScale);

                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    passed = true,
                    output = outputPath,
                    regionWidth = region.Width,
                    regionHeight = region.Height,
                    outputWidth = result.Width,
                    outputHeight = result.Height,
                    expectedHeight,
                    heightTolerance,
                    fullPageExpected = !fastManualScroll,
                    safeContiguousPrefix = fastManualScroll,
                    verticalOffset = scrollViewer.VerticalOffset,
                    scrollableHeight = scrollViewer.ScrollableHeight,
                    mode = fastManualScroll ? "fast-manual-wheel" : "automatic-wheel",
                    validationRows,
                    hudStateVerified = true,
                    progressEvents = progressEvents.Count,
                    lastStatus = progressEvents.LastOrDefault()?.Status,
                    recoveryObserved = progressEvents.Any(item =>
                        item.Safety == ScrollingCaptureSafety.Unsafe ||
                        item.PreviewTruth == ScrollingPreviewTruth.PausedRecovery),
                    savingObserved = progressEvents.Any(item => item.PreviewTruth == ScrollingPreviewTruth.Saving)
                }, new JsonSerializerOptions { WriteIndented = true }));
                completion.TrySetResult(0);
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception);
                completion.TrySetResult(1);
            }
            finally
            {
                window.Close();
                application.Shutdown();
            }
        };
        window.Show();
        application.Run();
    }

    private static void VerifyProgressHudState(Drawing.Rectangle region)
    {
        var hud = new ScrollingProgressWindow();
        try
        {
            hud.ShowReady(region);
            hud.Show();
            hud.UpdateLayout();
            var primary = hud.FindName("PrimaryButton") as Button ??
                          throw new InvalidOperationException("Scrolling HUD primary button was not created.");
            var cancel = hud.FindName("CancelButton") as Button ??
                         throw new InvalidOperationException("Scrolling HUD cancel button was not created.");
            var autoScroll = hud.FindName("AutoScrollButton") as Button ??
                             throw new InvalidOperationException("Scrolling HUD auto-scroll button was not created.");
            if (!Equals(primary.Content, "开始截取") || !primary.IsEnabled || !cancel.IsEnabled ||
                autoScroll.Visibility != Visibility.Collapsed)
                throw new InvalidOperationException("Scrolling HUD did not enter the ready/start state.");
            if (Grid.GetColumn(cancel) >= Grid.GetColumn(autoScroll) ||
                Grid.GetColumn(autoScroll) >= Grid.GetColumn(primary))
                throw new InvalidOperationException(
                    "Scrolling HUD action order does not match macOS: Cancel, Auto Scroll, Done.");

            var startRequests = 0;
            hud.StartRequested += (_, _) => startRequests++;
            primary.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if (startRequests != 1 || !Equals(primary.Content, "准备中") || primary.IsEnabled)
                throw new InvalidOperationException(
                    "Scrolling HUD did not leave the start state synchronously after clicking.");

            hud.BeginCapture(autoScrollAvailable: true);
            hud.UpdateLayout();
            if (!Equals(primary.Content, "完成") || !primary.IsEnabled || !hud.IsCapturing)
                throw new InvalidOperationException("Scrolling HUD did not expose the finish action during capture.");

            hud.BeginFinalizing();
            if (!Equals(primary.Content, "完成中") || primary.IsEnabled || cancel.IsEnabled ||
                autoScroll.IsEnabled || !hud.IsInteractionLocked)
                throw new InvalidOperationException("Scrolling HUD did not enter the finalizing state.");

            hud.BeginSaving();
            if (!Equals(primary.Content, "保存中") || primary.IsEnabled || cancel.IsEnabled ||
                autoScroll.IsEnabled || !hud.IsInteractionLocked)
                throw new InvalidOperationException("Scrolling HUD did not enter the locked saving state.");

            var recovery = hud.WaitForSaveRecoveryActionAsync("Injected save failure for lifecycle verification.");
            hud.Close();
            if (!recovery.Wait(TimeSpan.FromSeconds(2)) || recovery.Result != ScrollingSaveRecoveryAction.Discard)
                throw new InvalidOperationException("External close did not complete the scrolling save-recovery wait.");
            if (!hud.IsVisible)
                throw new InvalidOperationException("External close destroyed the in-memory scrolling recovery HUD.");
        }
        finally
        {
            hud.CloseAfterWorkflow();
        }
    }

    private static async Task DriveFastManualScrollAsync(
        Action requestFinish)
    {
        // CaptureAsync first locks the initial frame and deliberately waits 220 ms
        // before accepting movement. Start just after that guard, then emulate a
        // user spinning the wheel in dense, short bursts while stitching is busy.
        await Task.Delay(280);
        for (var eventIndex = 0; eventIndex < 5; eventIndex++)
        {
            mouse_event(MouseeventfWheel, 0, 0, -120, UIntPtr.Zero);
            await Task.Delay(7);
        }

        await Task.Delay(1000);
        requestFinish();
    }

    internal static int VerifyValidationRows(Drawing.Bitmap result, double dpiScale)
    {
        var observed = ObserveValidationRows(result, dpiScale);
        if (observed.Count != 30 ||
            observed.Where((color, index) => color != index % 6).Any())
        {
            throw new InvalidOperationException(
                $"Validation-row continuity is wrong: found {observed.Count}/30 bands; " +
                $"sequence=[{string.Join(',', observed)}].");
        }
        return observed.Count;
    }

    internal static int VerifyValidationRowPrefix(
        Drawing.Bitmap result,
        double dpiScale,
        int minimumRows)
    {
        var observed = ObserveValidationRows(result, dpiScale);
        if (observed.Count < minimumRows ||
            observed.Count > 30 ||
            observed.Where((color, index) => color != index % 6).Any())
        {
            throw new InvalidOperationException(
                $"Fast-wheel output is not a safe contiguous prefix: found {observed.Count} bands; " +
                $"minimum={minimumRows}; sequence=[{string.Join(',', observed)}].");
        }
        return observed.Count;
    }

    private static List<int> ObserveValidationRows(Drawing.Bitmap result, double dpiScale)
    {
        var accentColors = new[]
        {
            Drawing.ColorTranslator.FromHtml("#E5484D"),
            Drawing.ColorTranslator.FromHtml("#2F6FEB"),
            Drawing.ColorTranslator.FromHtml("#2F9E44"),
            Drawing.ColorTranslator.FromHtml("#E67700"),
            Drawing.ColorTranslator.FromHtml("#9C36B5"),
            Drawing.ColorTranslator.FromHtml("#0B7285")
        };
        var sampleX = Math.Clamp(
            (int)Math.Round((112 + 24 + 9) * dpiScale),
            0,
            result.Width - 1);
        var maximumInternalGap = Math.Max(2, (int)Math.Round(6 * dpiScale));
        var minimumBandHeight = Math.Max(12, (int)Math.Round(60 * dpiScale));
        var observed = new List<int>();
        var activeColor = -1;
        var activeStart = -1;
        var lastMatch = -1;

        for (var y = 0; y <= result.Height; y++)
        {
            var colorIndex = y < result.Height
                ? Array.FindIndex(accentColors, expected => ColorsNear(result.GetPixel(sampleX, y), expected))
                : -1;
            if (colorIndex == activeColor && colorIndex >= 0)
            {
                lastMatch = y;
                continue;
            }
            if (colorIndex < 0 && activeColor >= 0 && y - lastMatch <= maximumInternalGap)
                continue;

            if (activeColor >= 0 && lastMatch - activeStart + 1 >= minimumBandHeight)
                observed.Add(activeColor);
            activeColor = colorIndex;
            activeStart = colorIndex >= 0 ? y : -1;
            lastMatch = colorIndex >= 0 ? y : -1;
        }

        return observed;

        static bool ColorsNear(Drawing.Color actual, Drawing.Color expected) =>
            Math.Abs(actual.R - expected.R) <= 3 &&
            Math.Abs(actual.G - expected.G) <= 3 &&
            Math.Abs(actual.B - expected.B) <= 3;
    }

    private static Window BuildFixture(out ScrollViewer scrollViewer)
    {
        var window = new Window
        {
            Title = "ShotPaste Native Scrolling E2E",
            Width = 760,
            Height = 620,
            Left = 40,
            Top = 40,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            Topmost = true,
            ShowInTaskbar = true,
            Background = Brush("#EEF1F7")
        };
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(56) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new Grid { Background = Brush("#5637C7") };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = "ShotPaste E2E · 固定页头",
            Foreground = Brushes.White,
            FontSize = 17,
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(24, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        });
        var positionText = new TextBlock
        {
            Text = "offset = 0",
            Foreground = Brushes.White,
            FontSize = 14,
            Margin = new Thickness(0, 0, 24, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(positionText, 1);
        header.Children.Add(positionText);
        root.Children.Add(header);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(112) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(body, 1);
        var rail = new StackPanel { Background = Brush("#202942") };
        rail.Children.Add(new TextBlock
        {
            Text = "固定侧栏",
            Foreground = Brush("#DCE2FF"),
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(14, 24, 0, 12)
        });
        for (var index = 0; index < 4; index++)
            rail.Children.Add(new Border
            {
                Height = 42,
                Margin = new Thickness(14, 0, 14, 12),
                CornerRadius = new CornerRadius(8),
                Background = Brush("#33405F")
            });
        body.Children.Add(rail);

        var content = new StackPanel { Margin = new Thickness(24, 20, 24, 40) };
        content.Children.Add(Sentinel("TOP · 0000"));
        var accents = new[] { "#E5484D", "#2F6FEB", "#2F9E44", "#E67700", "#9C36B5", "#0B7285" };
        for (var index = 1; index <= 30; index++)
            content.Children.Add(Card(index, accents[(index - 1) % accents.Length]));
        content.Children.Add(Sentinel("BOTTOM · 9999"));
        var fixtureScrollViewer = new ScrollViewer
        {
            Content = content,
            Background = Brush("#EEF1F7"),
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            PanningMode = PanningMode.VerticalOnly
        };
        fixtureScrollViewer.ScrollChanged += (_, _) =>
            positionText.Text = $"offset = {fixtureScrollViewer.VerticalOffset:F0}";
        Grid.SetColumn(fixtureScrollViewer, 1);
        body.Children.Add(fixtureScrollViewer);
        root.Children.Add(body);
        window.Content = root;
        scrollViewer = fixtureScrollViewer;
        return window;
    }

    private static Border Sentinel(string text) => new()
    {
        Height = 84,
        Margin = new Thickness(0, 0, 0, 14),
        CornerRadius = new CornerRadius(12),
        BorderThickness = new Thickness(5),
        BorderBrush = Brush("#172033"),
        Background = Brush("#FFDD57"),
        Child = new TextBlock
        {
            Text = text,
            FontSize = 28,
            FontWeight = FontWeights.ExtraBold,
            Foreground = Brush("#172033"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        }
    };

    private static Border Card(int index, string accent)
    {
        var id = index.ToString("00");
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(new Border { Background = Brush(accent) });
        var text = new StackPanel { Margin = new Thickness(24, 18, 18, 8) };
        text.Children.Add(new TextBlock
        {
            Text = $"验证行 {id}",
            FontSize = 22,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("#172033")
        });
        text.Children.Add(new TextBlock
        {
            Text = $"唯一序列 LS-{id}-A{index * 17}-B{index * 31}，用于检查顺序、漏帧、重复拼接和接缝。",
            Margin = new Thickness(0, 8, 0, 0),
            FontSize = 13,
            Foreground = Brush("#172033")
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return new Border
        {
            Height = 132,
            Margin = new Thickness(0, 0, 0, 10),
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(3),
            BorderBrush = Brush("#172033"),
            Background = Brushes.White,
            ClipToBounds = true,
            Child = grid
        };
    }

    private static SolidColorBrush Brush(string value) =>
        new((Color)ColorConverter.ConvertFromString(value));

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr window, out Rect bounds);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetCursorPos(int x, int y);

    private const uint MouseeventfWheel = 0x0800;

    [DllImport("user32.dll")]
    private static extern void mouse_event(
        uint flags,
        uint dx,
        uint dy,
        int data,
        UIntPtr extraInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
