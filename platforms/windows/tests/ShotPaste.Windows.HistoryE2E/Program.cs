using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Microsoft.Data.Sqlite;
using Windows.Media.Editing;
using Windows.Media.Transcoding;
using Windows.Storage;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.HistoryE2E;

internal static class Program
{
    private static readonly TimeSpan UiTimeout = TimeSpan.FromSeconds(25);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1) throw new ArgumentException("Usage: HistoryE2E <ShotPaste.exe> [output-root]");
            var executable = Path.GetFullPath(args[0]);
            var outputRoot = Path.GetFullPath(args.ElementAtOrDefault(1) ?? Path.Combine("build", "e2e", "history-ui"));
            var clipboardOnly = args.Any(value => value.Equals("--clipboard-only", StringComparison.OrdinalIgnoreCase));
            var result = RunAsync(executable, outputRoot, clipboardOnly).GetAwaiter().GetResult();
            var summary = Path.Combine(outputRoot, "summary.json");
            Directory.CreateDirectory(outputRoot);
            File.WriteAllText(summary, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine(JsonSerializer.Serialize(result));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }

    private static async Task<object> RunAsync(string executable, string outputRoot, bool clipboardOnly)
    {
        if (!File.Exists(executable)) throw new FileNotFoundException("Product executable was not found.", executable);
        Directory.CreateDirectory(outputRoot);
        if (clipboardOnly) return await RunClipboardSessionAsync(executable, outputRoot);
        var thumbnailCache = BenchmarkThumbnailCache(outputRoot);
        var dataRoot = Path.Combine(outputRoot, "data");
        Directory.CreateDirectory(dataRoot);
        var database = Path.Combine(dataRoot, "history.sqlite3");
        var settingsFile = Path.Combine(dataRoot, "settings.json");
        if (File.Exists(database)) File.Delete(database);
        var crashLog = Path.Combine(dataRoot, "crash.log");
        if (File.Exists(crashLog)) File.Delete(crashLog);
        SeedHistory(database, 500);
        WriteSettings(settingsFile, dataRoot);

        var first = await RunFirstSessionAsync(executable, dataRoot, outputRoot);
        var countAfterFirstSession = CountHistoryRows(database);
        if (countAfterFirstSession != 500)
            throw new InvalidOperationException($"History database changed during layout E2E: {countAfterFirstSession}/500 rows remain.");
        var persisted = JsonSerializer.Deserialize<AppSettings>(await File.ReadAllTextAsync(settingsFile)) ??
                        throw new InvalidOperationException("Persisted settings could not be read.");
        if (Math.Abs(persisted.HistoryCompactHeight - 230) > 8)
            throw new InvalidOperationException(
                $"Compact history height was contaminated by expanded-mode constraints: {persisted.HistoryCompactHeight}.");
        if (persisted.HistoryExpandedLeft is null || persisted.HistoryExpandedTop is null)
            throw new InvalidOperationException("Expanded history position was not persisted.");

        var restart = await RunRestartSessionAsync(executable, dataRoot, outputRoot, persisted);
        var clipboard = await RunClipboardSessionAsync(executable, outputRoot);
        return new
        {
            SeededItems = 500,
            CountAfterFirstSession = countAfterFirstSession,
            FirstSession = first,
            Persisted = new
            {
                persisted.HistoryCompactWidth,
                persisted.HistoryCompactHeight,
                persisted.HistoryExpandedWidth,
                persisted.HistoryExpandedHeight,
                persisted.HistoryExpandedLeft,
                persisted.HistoryExpandedTop
            },
            RestartSession = restart,
            ClipboardSession = clipboard,
            ThumbnailCache = thumbnailCache
        };
    }

    private static object BenchmarkThumbnailCache(string outputRoot)
    {
        var root = Path.Combine(outputRoot, "thumbnail-cache-fixture");
        Directory.CreateDirectory(root);
        var paths = Enumerable.Range(0, 12)
            .Select(index => Path.Combine(root, $"cache-{index:00}.png"))
            .ToArray();
        for (var index = 0; index < paths.Length; index++)
        {
            using var bitmap = new Drawing.Bitmap(160, 100, PixelFormat.Format32bppArgb);
            using var graphics = Drawing.Graphics.FromImage(bitmap);
            graphics.Clear(Drawing.Color.FromArgb(255, 30 + index * 10, 70 + index * 6, 120 + index * 5));
            bitmap.Save(paths[index], ImageFormat.Png);
        }

        var cache = new HistoryThumbnailCache(8, 8L * 160 * 100 * 4);
        foreach (var path in paths.Take(8)) cache.Add(path, LoadBitmap(path));
        var hitClock = Stopwatch.StartNew();
        for (var pass = 0; pass < 100; pass++)
            foreach (var path in paths.Take(8))
                if (!cache.TryGet(path, out _))
                    throw new InvalidOperationException($"Expected thumbnail cache hit for {path}.");
        hitClock.Stop();
        foreach (var path in paths.Skip(8)) cache.Add(path, LoadBitmap(path));
        var oldestWasReclaimed = !cache.TryGet(paths[0], out _);
        var newestRemained = cache.TryGet(paths[^1], out _);
        var metrics = cache.Metrics;
        if (!oldestWasReclaimed || !newestRemained || metrics.Count > 8 || metrics.Evictions < 4)
            throw new InvalidOperationException($"Thumbnail cache did not reclaim LRU entries: {metrics}.");
        return new
        {
            FixtureDirectory = root,
            Inputs = paths.Length,
            RepeatedHitCount = 800,
            RepeatedHitMilliseconds = Math.Round(hitClock.Elapsed.TotalMilliseconds, 2),
            OldestWasReclaimed = oldestWasReclaimed,
            NewestRemained = newestRemained,
            Metrics = metrics
        };
    }

    private static BitmapImage LoadBitmap(string path)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.UriSource = new Uri(path, UriKind.Absolute);
        image.EndInit();
        image.Freeze();
        return image;
    }

    private static async Task<object> RunFirstSessionAsync(string executable, string dataRoot, string outputRoot)
    {
        using var product = Launch(executable, dataRoot);
        try
        {
            var startup = Stopwatch.StartNew();
            var compact = await WaitForAutomationIdAsync(product.Id, "CompactHistoryCarousel");
            await WaitUntilAsync(() => VisibleListItems(compact).Length > 0,
                "Compact history did not realize any cards.");
            startup.Stop();
            product.Refresh();
            var workingSetAtStartup = product.WorkingSet64;
            var window = AncestorWindow(compact);
            var compactBounds = PhysicalBounds(window);
            AssertTopCentered(window, compactBounds);
            var compactScreenshot = Path.Combine(outputRoot, "history-compact-500-items.png");
            SaveWindowScreenshot(compactBounds, compactScreenshot);

            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryModeToggle"));
            var expanded = await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");
            await WaitUntilAsync(() => VisibleListItems(expanded).Length > 0,
                "Expanded history did not realize any cards.");
            var initialRealized = VisibleListItems(expanded).Length;
            if (initialRealized >= 500)
                throw new InvalidOperationException("Expanded grid realized every history item; virtualization is not active.");

            var firstItem = VisibleListItems(expanded).First();
            ((SelectionItemPattern)firstItem.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            var scroll = (ScrollPattern)expanded.GetCurrentPattern(ScrollPattern.Pattern);
            scroll.Scroll(ScrollAmount.NoAmount, ScrollAmount.LargeIncrement);
            scroll.Scroll(ScrollAmount.NoAmount, ScrollAmount.LargeIncrement);
            await Task.Delay(350);
            var scrolledPercent = scroll.Current.VerticalScrollPercent;
            if (scrolledPercent <= 0)
                throw new InvalidOperationException("Expanded history did not scroll vertically.");

            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryModeToggle"));
            compact = await WaitForAutomationIdAsync(product.Id, "CompactHistoryCarousel");
            await Task.Delay(250);
            if (!VisibleListItems(compact).Any(item => IsSelected(item)))
                throw new InvalidOperationException("Selected history item was not preserved when switching to compact mode.");
            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryModeToggle"));
            expanded = await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");
            await Task.Delay(350);
            scroll = (ScrollPattern)expanded.GetCurrentPattern(ScrollPattern.Pattern);
            if (Math.Abs(scroll.Current.VerticalScrollPercent - scrolledPercent) > 8)
                throw new InvalidOperationException(
                    $"Expanded scroll position changed across mode switches: {scrolledPercent} -> {scroll.Current.VerticalScrollPercent}.");

            window = AncestorWindow(expanded);
            var handle = new IntPtr(window.Current.NativeWindowHandle);
            var dpiScale = Native.GetDpiForWindow(handle) / 96d;
            Native.SetWindowPos(handle, IntPtr.Zero,
                (int)Math.Round(140 * dpiScale), (int)Math.Round(115 * dpiScale),
                (int)Math.Round(1120 * dpiScale), (int)Math.Round(740 * dpiScale),
                Native.SwpNoZOrder | Native.SwpShowWindow);
            await Task.Delay(600);

            var search = await WaitForAutomationIdAsync(product.Id, "HistorySearch");
            var filterClock = Stopwatch.StartNew();
            ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).SetValue("needle-history-item");
            await WaitUntilAsync(() => VisibleListItems(expanded).Length == 1,
                "Large-history search did not converge to one item.");
            filterClock.Stop();
            if (filterClock.Elapsed > TimeSpan.FromSeconds(3))
                throw new InvalidOperationException($"Large-history search was too slow: {filterClock.Elapsed}.");
            var resultItem = VisibleListItems(expanded).Single();
            if (!resultItem.Current.Name.Contains("needle-history-item", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Unexpected search result: {resultItem.Current.Name}.");

            var expandedBounds = PhysicalBounds(window);
            var expandedScreenshot = Path.Combine(outputRoot, "history-expanded-filtered.png");
            SaveWindowScreenshot(expandedBounds, expandedScreenshot);
            await Task.Delay(750);
            product.Refresh();
            var peakWorkingSet = product.PeakWorkingSet64;
            if (peakWorkingSet > 768L * 1024 * 1024)
                throw new InvalidOperationException($"Bounded history cache exceeded the 768 MiB regression guard: {peakWorkingSet:N0} bytes.");
            ((WindowPattern)window.GetCurrentPattern(WindowPattern.Pattern)).Close();
            await Task.Delay(900);
            return new
            {
                Startup = startup.Elapsed,
                InitialRealizedItems = initialRealized,
                ScrolledPercent = scrolledPercent,
                SearchDuration = filterClock.Elapsed,
                SearchResults = 1,
                WorkingSetAtStartupBytes = workingSetAtStartup,
                PeakWorkingSetBytes = peakWorkingSet,
                CompactBounds = compactBounds,
                ExpandedBounds = expandedBounds,
                CompactScreenshot = compactScreenshot,
                ExpandedScreenshot = expandedScreenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunRestartSessionAsync(
        string executable,
        string dataRoot,
        string outputRoot,
        AppSettings persisted)
    {
        using var product = Launch(executable, dataRoot);
        try
        {
            var compact = await WaitForAutomationIdAsync(product.Id, "CompactHistoryCarousel");
            await WaitUntilAsync(() => VisibleListItems(compact).Length > 0,
                "Compact history did not restore after restart.");
            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryModeToggle"));
            var expanded = await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");
            try
            {
                await WaitUntilAsync(() => VisibleListItems(expanded).Length > 0,
                    "Expanded history did not restore after restart.");
            }
            catch (TimeoutException)
            {
                var diagnosticWindow = AncestorWindow(expanded);
                var diagnosticBounds = PhysicalBounds(diagnosticWindow);
                SaveWindowScreenshot(diagnosticBounds, Path.Combine(outputRoot, "history-expanded-restart-failure.png"));
                var allItems = expanded.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem)).Count;
                throw new TimeoutException(
                    $"Expanded history did not restore after restart; UIA items={allItems}, bounds={diagnosticBounds}.");
            }
            var window = AncestorWindow(expanded);
            var bounds = PhysicalBounds(window);
            var handle = new IntPtr(window.Current.NativeWindowHandle);
            var scale = Native.GetDpiForWindow(handle) / 96d;
            AssertNear(persisted.HistoryExpandedWidth, bounds.Width / scale, 12, "restored width");
            AssertNear(persisted.HistoryExpandedHeight, bounds.Height / scale, 12, "restored height");
            AssertNear(persisted.HistoryExpandedLeft!.Value, bounds.Left / scale, 12, "restored left");
            AssertNear(persisted.HistoryExpandedTop!.Value, bounds.Top / scale, 12, "restored top");
            var realized = VisibleListItems(expanded).Length;
            if (realized >= 500) throw new InvalidOperationException("Restarted grid lost virtualization.");
            var screenshot = Path.Combine(outputRoot, "history-expanded-restart.png");
            SaveWindowScreenshot(bounds, screenshot);
            return new { Bounds = bounds, DpiScale = scale, RealizedItems = realized, Screenshot = screenshot };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunClipboardSessionAsync(string executable, string outputRoot)
    {
        var dataRoot = Path.Combine(outputRoot, "clipboard-data");
        if (Directory.Exists(dataRoot)) Directory.Delete(dataRoot, true);
        Directory.CreateDirectory(dataRoot);
        var database = Path.Combine(dataRoot, "history.sqlite3");
        WriteSettings(Path.Combine(dataRoot, "settings.json"), dataRoot, clipboardHistoryEnabled: true);
        var fixtures = await CreateClipboardFixturesAsync(Path.Combine(outputRoot, "clipboard-fixtures"));
        var originalClipboard = CaptureClipboardBackup();

        try
        {
            IReadOnlyList<HistoryDbRow> fileRows;
            HistoryDbRow textRow;
            string viewerScreenshot;
            long peakWorkingSet;
            var largePrefix = "history-e2e-large-text-" + Guid.NewGuid().ToString("N");
            var largeText = largePrefix + "\n" + new string('文', 100_000) + "\nEND-" + largePrefix;
            using (var product = Launch(executable, dataRoot))
            {
                try
                {
                    await WaitForAutomationIdAsync(product.Id, "CompactHistoryCarousel");
                    Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryModeToggle"));
                    var expanded = await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");
                    SetClipboardFiles(fixtures.AllPaths);
                    await WaitUntilAsync(() => TryCountHistoryRows(database) == fixtures.AllPaths.Count,
                        "Multi-file clipboard event did not create one history row per path.");
                    fileRows = ReadHistoryRows(database);
                    AssertClipboardFileRows(fileRows, fixtures, dataRoot);

                    SetClipboardFiles(fixtures.AllPaths);
                    await Task.Delay(1300);
                    if (CountHistoryRows(database) != fixtures.AllPaths.Count)
                        throw new InvalidOperationException("Replaying an identical multi-file clipboard event bypassed SHA-256 deduplication.");

                    SetClipboardText(largeText);
                    await WaitUntilAsync(() => TryCountHistoryRows(database) == fixtures.AllPaths.Count + 1,
                        "Large clipboard text was not persisted.");
                    textRow = ReadHistoryRows(database).Single(row => row.Kind == (int)CaptureKind.ClipboardText);
                    if (textRow.TextValue is null || textRow.TextValue.Length > 8193 || !textRow.TextValue.StartsWith(largePrefix, StringComparison.Ordinal))
                        throw new InvalidOperationException("Large clipboard text was not reduced to the bounded database preview.");
                    if (!textRow.TextIsTruncated || textRow.TextLength != largeText.Length ||
                        string.IsNullOrWhiteSpace(textRow.TextStoragePath) || !File.Exists(textRow.TextStoragePath))
                        throw new InvalidOperationException("Large clipboard text did not retain an on-demand full-text backing file.");

                    var search = await WaitForAutomationIdAsync(product.Id, "HistorySearch");
                    ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).SetValue(largePrefix);
                    await WaitUntilAsync(() => VisibleListItems(expanded).Length == 1,
                        "Large text history search did not converge to the matching card.");
                    var matchingCard = VisibleListItems(expanded).Single();
                    var openButton = matchingCard.FindFirst(TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.AutomationIdProperty, "HistoryOpenItem")) ??
                        throw new InvalidOperationException("The large-text history card had no Open action.");
                    Invoke(openButton);
                    var fullTextElement = await WaitForAutomationIdAsync(product.Id, "ClipboardFullText");
                    string? displayed = null;
                    await WaitUntilAsync(() =>
                    {
                        displayed = GetAutomationText(fullTextElement);
                        return displayed.Length >= largeText.Length;
                    }, "The full-text viewer did not load the complete clipboard payload on demand.");
                    if (!NormalizeNewlines(displayed!).Equals(NormalizeNewlines(largeText), StringComparison.Ordinal))
                        throw new InvalidOperationException("The on-demand full-text viewer content differed from the clipboard payload.");
                    var viewer = AncestorWindow(fullTextElement);
                    viewerScreenshot = Path.Combine(outputRoot, "history-large-text-viewer.png");
                    SaveWindowScreenshot(PhysicalBounds(viewer), viewerScreenshot);
                    ((WindowPattern)viewer.GetCurrentPattern(WindowPattern.Pattern)).Close();
                    product.Refresh();
                    peakWorkingSet = product.PeakWorkingSet64;
                    if (peakWorkingSet > 768L * 1024 * 1024)
                        throw new InvalidOperationException($"Clipboard history session exceeded the 768 MiB regression guard: {peakWorkingSet:N0} bytes.");
                }
                finally { StopExactProcess(product); }
            }

            var countBeforeRestart = CountHistoryRows(database);
            using (var restart = Launch(executable, dataRoot))
            {
                try
                {
                    await WaitForAutomationIdAsync(restart.Id, "CompactHistoryCarousel");
                    Invoke(await WaitForAutomationIdAsync(restart.Id, "HistoryModeToggle"));
                    var expanded = await WaitForAutomationIdAsync(restart.Id, "ExpandedHistoryGrid");
                    var search = await WaitForAutomationIdAsync(restart.Id, "HistorySearch");
                    ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).SetValue(largePrefix);
                    await WaitUntilAsync(() => VisibleListItems(expanded).Length == 1,
                        "Large clipboard text was not searchable after restart.");
                    SaveWindowScreenshot(PhysicalBounds(AncestorWindow(expanded)),
                        Path.Combine(outputRoot, "history-clipboard-restart.png"));
                }
                finally { StopExactProcess(restart); }
            }
            if (CountHistoryRows(database) != countBeforeRestart)
                throw new InvalidOperationException("Clipboard history row count changed across restart.");

            return new
            {
                MultiFileInputCount = fixtures.AllPaths.Count,
                IndependentRows = fileRows.Count,
                Kinds = fileRows.Select(row => ((CaptureKind)row.Kind).ToString()).OrderBy(value => value).ToArray(),
                Sha256Hashes = fileRows.Select(row => row.ContentHash).ToArray(),
                ValidVideoDurationTicks = fileRows.Single(row => row.TextValue == Path.GetFileName(fixtures.Video)).DurationTicks,
                CorruptVideoError = fileRows.Single(row => row.TextValue == Path.GetFileName(fixtures.BrokenVideo)).PreviewError,
                LargeTextCharacters = largeText.Length,
                DatabasePreviewCharacters = textRow.TextValue?.Length ?? 0,
                FullTextStoragePath = textRow.TextStoragePath,
                CountBeforeRestart = countBeforeRestart,
                PeakWorkingSetBytes = peakWorkingSet,
                ViewerScreenshot = viewerScreenshot
            };
        }
        finally
        {
            RetryClipboard(() =>
            {
                if (!originalClipboard.HadData) Forms.Clipboard.Clear();
                else Forms.Clipboard.SetDataObject(originalClipboard.Data, true);
            });
        }
    }

    private static Process Launch(string executable, string dataRoot) =>
        Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", dataRoot, "--history" }
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

    private static void WriteSettings(string path, string root, bool clipboardHistoryEnabled = false)
    {
        var settings = new AppSettings
        {
            SaveDirectory = Path.Combine(root, "Captures"),
            HistoryPanelPosition = "TopCenter",
            HistoryCompactWidth = 860,
            HistoryCompactHeight = 230,
            HistoryExpandedWidth = 980,
            HistoryExpandedHeight = 680,
            HistoryPanelMaxItems = 50,
            Language = "en-US",
            ClipboardHistoryEnabled = clipboardHistoryEnabled,
            ShortcutsEnabled = false,
            ShowQuickAccess = false
        };
        Directory.CreateDirectory(settings.SaveDirectory);
        File.WriteAllText(path, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void SeedHistory(string database, int count)
    {
        var fixtureRoot = Path.Combine(Path.GetDirectoryName(database)!, "history-fixtures");
        Directory.CreateDirectory(fixtureRoot);
        byte[] thumbnailBytes;
        using (var bitmap = new Drawing.Bitmap(640, 360))
        {
            using var graphics = Drawing.Graphics.FromImage(bitmap);
            graphics.Clear(Drawing.Color.FromArgb(35, 45, 62));
            graphics.FillRectangle(Drawing.Brushes.CornflowerBlue, 24, 24, 592, 312);
            graphics.DrawString("ShotPaste history cache fixture", new Drawing.Font("Segoe UI", 24),
                Drawing.Brushes.White, new Drawing.PointF(58, 145));
            using var stream = new MemoryStream();
            bitmap.Save(stream, ImageFormat.Jpeg);
            thumbnailBytes = stream.ToArray();
        }
        using var connection = new SqliteConnection($"Data Source={database}");
        connection.Open();
        using (var schema = connection.CreateCommand())
        {
            schema.CommandText = """
                CREATE TABLE history_items (
                    id TEXT PRIMARY KEY, kind INTEGER NOT NULL, created_at TEXT NOT NULL,
                    file_path TEXT NULL, thumbnail_path TEXT NULL, text_value TEXT NULL,
                    size_bytes INTEGER NOT NULL, pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL,
                    duration_ticks INTEGER NULL, is_pinned INTEGER NOT NULL DEFAULT 0,
                    file_paths_json TEXT NULL, content_hash TEXT NULL
                );
                CREATE INDEX idx_history_created_at ON history_items(created_at DESC);
                """;
            schema.ExecuteNonQuery();
        }
        using var transaction = connection.BeginTransaction();
        for (var index = 0; index < count; index++)
        {
            using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText = """
                INSERT INTO history_items
                (id, kind, created_at, file_path, thumbnail_path, text_value, size_bytes, pixel_width,
                 pixel_height, duration_ticks, is_pinned, file_paths_json, content_hash)
                VALUES ($id, $kind, $created, $path, $thumbnail, $text, $size, $width, $height, $duration, 0, $paths, $hash);
                """;
            var kind = index % 7;
            var imageBacked = kind is 0 or 1 or 2 or 3 or 4;
            var fixturePath = Path.Combine(fixtureRoot, $"fixture-{index:D4}.jpg");
            if (imageBacked) File.WriteAllBytes(fixturePath, thumbnailBytes);
            var text = index == 17
                ? "needle-history-item · unique searchable clipboard payload"
                : $"history fixture item {index:D4} · " + new string((char)('a' + index % 26), index % 8 + 8);
            insert.Parameters.AddWithValue("$id", Guid.NewGuid().ToString("D"));
            insert.Parameters.AddWithValue("$kind", kind);
            insert.Parameters.AddWithValue("$created", DateTimeOffset.Now.AddSeconds(-index).ToString("O"));
            insert.Parameters.AddWithValue("$path", kind is 0 or 1 or 3 or 4
                ? fixturePath
                : kind is 2 or 6
                    ? Path.Combine(Path.GetDirectoryName(database)!, $"fixture-{index:D4}.dat")
                    : DBNull.Value);
            insert.Parameters.AddWithValue("$thumbnail", kind == 2 ? fixturePath : DBNull.Value);
            insert.Parameters.AddWithValue("$text", kind == 5 || index == 17 ? text : DBNull.Value);
            insert.Parameters.AddWithValue("$size", index * 37L);
            insert.Parameters.AddWithValue("$width", kind is 0 or 1 or 4 ? 1280 : 0);
            insert.Parameters.AddWithValue("$height", kind is 0 or 1 or 4 ? 720 : 0);
            insert.Parameters.AddWithValue("$duration", kind is 2 or 3 ? TimeSpan.FromSeconds(3 + index % 20).Ticks : DBNull.Value);
            insert.Parameters.AddWithValue("$paths", kind == 6
                ? JsonSerializer.Serialize(new[] { $"fixture-{index}.txt" })
                : DBNull.Value);
            insert.Parameters.AddWithValue("$hash", $"fixture-{index:D4}");
            insert.ExecuteNonQuery();
        }
        transaction.Commit();
    }

    private static async Task<ClipboardFixtures> CreateClipboardFixturesAsync(string root)
    {
        Directory.CreateDirectory(root);
        var png = Path.Combine(root, "still.png");
        var gif = Path.Combine(root, "animation.gif");
        var video = Path.Combine(root, "video.mp4");
        var brokenVideo = Path.Combine(root, "broken.mp4");
        var text = Path.Combine(root, "notes.txt");
        using (var bitmap = new Drawing.Bitmap(320, 180))
        {
            using var graphics = Drawing.Graphics.FromImage(bitmap);
            graphics.Clear(Drawing.Color.DarkSlateBlue);
            graphics.FillEllipse(Drawing.Brushes.Gold, 90, 25, 140, 130);
            graphics.DrawString("history", new Drawing.Font("Segoe UI", 20, Drawing.FontStyle.Bold),
                Drawing.Brushes.Black, new Drawing.PointF(112, 74));
            bitmap.Save(png, ImageFormat.Png);
            bitmap.Save(gif, ImageFormat.Gif);
        }
        await CreateVideoFixtureAsync(png, video);
        await File.WriteAllBytesAsync(brokenVideo, "not-a-valid-media-container"u8.ToArray());
        await File.WriteAllTextAsync(text, "ShotPaste clipboard file fixture");
        return new ClipboardFixtures(png, gif, video, brokenVideo, text);
    }

    private static async Task CreateVideoFixtureAsync(string imagePath, string outputPath)
    {
        var imageFile = await StorageFile.GetFileFromPathAsync(imagePath);
        var outputFolder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(outputPath)!);
        var outputFile = await outputFolder.CreateFileAsync(Path.GetFileName(outputPath), CreationCollisionOption.ReplaceExisting);
        var composition = new MediaComposition();
        composition.Clips.Add(await MediaClip.CreateFromImageFileAsync(imageFile, TimeSpan.FromSeconds(1.25)));
        var result = await composition.RenderToFileAsync(outputFile, MediaTrimmingPreference.Precise);
        if (result != TranscodeFailureReason.None)
            throw new InvalidOperationException($"Could not create the history MP4 fixture: {result}.");
    }

    private static void SetClipboardFiles(IReadOnlyList<string> paths) => RetryClipboard(() =>
    {
        var files = new System.Collections.Specialized.StringCollection();
        files.AddRange(paths.ToArray());
        Forms.Clipboard.SetFileDropList(files);
    });

    private static void SetClipboardText(string text) => RetryClipboard(() => Forms.Clipboard.SetText(text));

    private static ClipboardBackup CaptureClipboardBackup() => RunSta(() =>
    {
        var source = Forms.Clipboard.GetDataObject();
        var backup = new Forms.DataObject();
        if (source is null) return new ClipboardBackup(backup, false);
        var formats = source.GetFormats(autoConvert: false);
        var copied = 0;
        foreach (var format in formats)
        {
            try
            {
                var value = CloneClipboardValue(source.GetData(format, autoConvert: false));
                if (value is null) continue;
                backup.SetData(format, autoConvert: false, value);
                copied++;
            }
            catch (Exception exception) when (exception is ExternalException or IOException or UnauthorizedAccessException or ArgumentException)
            {
                // Continue materializing the remaining formats. We refuse to
                // overwrite the clipboard below if none can be made durable.
            }
        }
        if (formats.Length > 0 && copied == 0)
            throw new InvalidOperationException("The current clipboard uses formats that cannot be backed up safely for history E2E.");
        return new ClipboardBackup(backup, copied > 0);
    });

    private static object? CloneClipboardValue(object? value)
    {
        return value switch
        {
            null => null,
            byte[] bytes => bytes.ToArray(),
            string text => text,
            string[] values => values.ToArray(),
            System.Collections.Specialized.StringCollection values => CloneStringCollection(values),
            Drawing.Image image => new Drawing.Bitmap(image),
            MemoryStream stream => new MemoryStream(stream.ToArray(), writable: false),
            Stream stream => CloneStream(stream),
            ICloneable cloneable => cloneable.Clone(),
            int or uint or long or ulong or short or ushort or byte or sbyte or bool or float or double or decimal or DateTime => value,
            _ => null
        };
    }

    private static System.Collections.Specialized.StringCollection CloneStringCollection(
        System.Collections.Specialized.StringCollection source)
    {
        var clone = new System.Collections.Specialized.StringCollection();
        clone.AddRange(source.Cast<string>().ToArray());
        return clone;
    }

    private static MemoryStream CloneStream(Stream source)
    {
        var originalPosition = source.CanSeek ? source.Position : 0;
        if (source.CanSeek) source.Position = 0;
        var clone = new MemoryStream();
        source.CopyTo(clone);
        clone.Position = 0;
        if (source.CanSeek) source.Position = originalPosition;
        return clone;
    }

    private static void RetryClipboard(Action action)
    {
        Exception? failure = null;
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                RunSta(() =>
                {
                    action();
                    return true;
                });
                return;
            }
            catch (ExternalException exception)
            {
                failure = exception;
                Thread.Sleep(60);
            }
        }
        throw new InvalidOperationException("The clipboard remained busy during history E2E.", failure);
    }

    private static T RunSta<T>(Func<T> action)
    {
        T? result = default;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { result = action(); }
            catch (Exception exception) { failure = exception; }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) throw failure;
        return result!;
    }

    private static void AssertClipboardFileRows(
        IReadOnlyList<HistoryDbRow> rows,
        ClipboardFixtures fixtures,
        string dataRoot)
    {
        if (rows.Count != fixtures.AllPaths.Count)
            throw new InvalidOperationException($"Expected {fixtures.AllPaths.Count} clipboard rows, found {rows.Count}.");
        var expectedKinds = new Dictionary<string, CaptureKind>(StringComparer.OrdinalIgnoreCase)
        {
            [Path.GetFileName(fixtures.Png)] = CaptureKind.ClipboardImage,
            [Path.GetFileName(fixtures.Gif)] = CaptureKind.ClipboardGif,
            [Path.GetFileName(fixtures.Video)] = CaptureKind.ClipboardVideo,
            [Path.GetFileName(fixtures.BrokenVideo)] = CaptureKind.ClipboardVideo,
            [Path.GetFileName(fixtures.Text)] = CaptureKind.ClipboardFile
        };
        foreach (var row in rows)
        {
            if (row.TextValue is null || !expectedKinds.TryGetValue(row.TextValue, out var expected) || row.Kind != (int)expected)
                throw new InvalidOperationException($"Clipboard path was classified incorrectly: {row.TextValue} => {(CaptureKind)row.Kind}.");
            var paths = JsonSerializer.Deserialize<string[]>(row.FilePathsJson ?? "[]") ?? [];
            if (paths.Length != 1 || !File.Exists(paths[0]))
                throw new InvalidOperationException($"Clipboard row {row.TextValue} did not own exactly one persisted path.");
            var relative = Path.GetRelativePath(Path.Combine(dataRoot, "ClipboardFiles"), paths[0]);
            if (relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                throw new InvalidOperationException($"Clipboard row {row.TextValue} was not copied into managed storage.");
            if (string.IsNullOrWhiteSpace(row.ContentHash) || row.ContentHash.Length != 64)
                throw new InvalidOperationException($"Clipboard row {row.TextValue} has no SHA-256 fingerprint.");
        }
        if (rows.Select(row => row.ContentHash).Distinct(StringComparer.Ordinal).Count() != rows.Count)
            throw new InvalidOperationException("Independent clipboard paths did not receive independent fingerprints.");
        foreach (var previewName in new[] { Path.GetFileName(fixtures.Png), Path.GetFileName(fixtures.Gif), Path.GetFileName(fixtures.Video) })
        {
            var row = rows.Single(candidate => candidate.TextValue == previewName);
            if (string.IsNullOrWhiteSpace(row.ThumbnailPath) || !File.Exists(row.ThumbnailPath))
                throw new InvalidOperationException($"No asynchronous thumbnail was generated for {previewName}.");
        }
        var validVideo = rows.Single(row => row.TextValue == Path.GetFileName(fixtures.Video));
        if (validVideo.DurationTicks is null or <= 0)
            throw new InvalidOperationException("The valid clipboard video has no decoded duration metadata.");
        var brokenVideo = rows.Single(row => row.TextValue == Path.GetFileName(fixtures.BrokenVideo));
        if (string.IsNullOrWhiteSpace(brokenVideo.PreviewError))
            throw new InvalidOperationException("The corrupt clipboard video did not expose an explicit preview error.");
    }

    private static IReadOnlyList<HistoryDbRow> ReadHistoryRows(string database)
    {
        using var connection = new SqliteConnection($"Data Source={database};Mode=ReadOnly");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT kind, file_path, thumbnail_path, text_value, duration_ticks, file_paths_json,
                   content_hash, text_storage_path, text_length, text_is_truncated, preview_error
            FROM history_items ORDER BY created_at DESC;
            """;
        using var reader = command.ExecuteReader();
        var rows = new List<HistoryDbRow>();
        while (reader.Read())
        {
            rows.Add(new HistoryDbRow(
                reader.GetInt32(0),
                reader.IsDBNull(1) ? null : reader.GetString(1),
                reader.IsDBNull(2) ? null : reader.GetString(2),
                reader.IsDBNull(3) ? null : reader.GetString(3),
                reader.IsDBNull(4) ? null : reader.GetInt64(4),
                reader.IsDBNull(5) ? null : reader.GetString(5),
                reader.IsDBNull(6) ? null : reader.GetString(6),
                reader.IsDBNull(7) ? null : reader.GetString(7),
                reader.IsDBNull(8) ? 0 : reader.GetInt32(8),
                !reader.IsDBNull(9) && reader.GetInt32(9) != 0,
                reader.IsDBNull(10) ? null : reader.GetString(10)));
        }
        return rows;
    }

    private static int TryCountHistoryRows(string database)
    {
        try { return File.Exists(database) ? CountHistoryRows(database) : -1; }
        catch (SqliteException) { return -1; }
        catch (IOException) { return -1; }
    }

    private static int CountHistoryRows(string database)
    {
        using var connection = new SqliteConnection($"Data Source={database};Mode=ReadOnly");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM history_items;";
        return Convert.ToInt32(command.ExecuteScalar());
    }

    private static async Task<AutomationElement> WaitForAutomationIdAsync(int processId, string id)
    {
        AutomationElement? result = null;
        await WaitUntilAsync(() =>
        {
            var condition = new AndCondition(
                new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
                new PropertyCondition(AutomationElement.AutomationIdProperty, id));
            result = AutomationElement.RootElement.FindFirst(TreeScope.Descendants, condition);
            return result is not null && !result.Current.IsOffscreen;
        }, $"Automation element {id} did not appear.");
        return result!;
    }

    private static AutomationElement[] VisibleListItems(AutomationElement list) =>
        list.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem))
            .Cast<AutomationElement>()
            .Where(item => !item.Current.IsOffscreen)
            .ToArray();

    private static AutomationElement AncestorWindow(AutomationElement element)
    {
        var walker = TreeWalker.ControlViewWalker;
        for (var current = element; current is not null; current = walker.GetParent(current))
            if (current.Current.ControlType == ControlType.Window) return current;
        throw new InvalidOperationException("History list had no window ancestor.");
    }

    private static void Invoke(AutomationElement element) =>
        ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();

    private static bool IsSelected(AutomationElement item) =>
        (bool)item.GetCurrentPropertyValue(SelectionItemPattern.IsSelectedProperty);

    private static Drawing.Rectangle PhysicalBounds(AutomationElement element)
    {
        var bounds = element.Current.BoundingRectangle;
        return Drawing.Rectangle.FromLTRB((int)Math.Round(bounds.Left), (int)Math.Round(bounds.Top),
            (int)Math.Round(bounds.Right), (int)Math.Round(bounds.Bottom));
    }

    private static void AssertTopCentered(AutomationElement window, Drawing.Rectangle bounds)
    {
        var screen = Forms.Screen.FromHandle(new IntPtr(window.Current.NativeWindowHandle));
        var centerDelta = Math.Abs(bounds.Left + bounds.Width / 2d -
                                   (screen.WorkingArea.Left + screen.WorkingArea.Width / 2d));
        if (centerDelta > 24)
            throw new InvalidOperationException($"Compact history was not horizontally centered: delta={centerDelta:N1}px.");
        if (Math.Abs(bounds.Top - screen.WorkingArea.Top) > 48)
            throw new InvalidOperationException($"Compact history was not positioned near the top work area: {bounds.Top}.");
        if (bounds.Right > screen.WorkingArea.Right || bounds.Bottom > screen.WorkingArea.Bottom)
            throw new InvalidOperationException("Compact history extended outside the working area.");
    }

    private static void SaveWindowScreenshot(Drawing.Rectangle bounds, string path)
    {
        using var bitmap = new Drawing.Bitmap(bounds.Width, bounds.Height);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, ImageFormat.Png);
    }

    private static void AssertNear(double expected, double actual, double tolerance, string label)
    {
        if (Math.Abs(expected - actual) > tolerance)
            throw new InvalidOperationException($"History {label} was not restored: expected {expected:N1}, actual {actual:N1}.");
    }

    private static void DoubleClickCenter(AutomationElement element)
    {
        var bounds = PhysicalBounds(element);
        var window = AncestorWindow(element);
        Native.SetForegroundWindow(new IntPtr(window.Current.NativeWindowHandle));
        Native.SetCursorPos(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height / 2);
        for (var click = 0; click < 2; click++)
        {
            Native.mouse_event(Native.MouseeventfLeftdown, 0, 0, 0, UIntPtr.Zero);
            Native.mouse_event(Native.MouseeventfLeftup, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(75);
        }
    }

    private static string GetAutomationText(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var textPattern))
            return ((TextPattern)textPattern).DocumentRange.GetText(-1);
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern))
            return ((ValuePattern)valuePattern).Current.Value;
        return string.Empty;
    }

    private static string NormalizeNewlines(string value) => value.Replace("\r\n", "\n", StringComparison.Ordinal);

    private static async Task WaitUntilAsync(Func<bool> predicate, string failure)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.Elapsed < UiTimeout)
        {
            try { if (predicate()) return; }
            catch (ElementNotAvailableException) { }
            await Task.Delay(90);
        }
        throw new TimeoutException(failure);
    }

    private static class Native
    {
        internal const uint SwpNoZOrder = 0x0004;
        internal const uint SwpShowWindow = 0x0040;
        internal const uint MouseeventfLeftdown = 0x0002;
        internal const uint MouseeventfLeftup = 0x0004;

        [DllImport("user32.dll")]
        internal static extern uint GetDpiForWindow(IntPtr window);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetWindowPos(
            IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        internal static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    }

    private sealed record ClipboardFixtures(string Png, string Gif, string Video, string BrokenVideo, string Text)
    {
        internal IReadOnlyList<string> AllPaths => [Png, Gif, Video, BrokenVideo, Text];
    }

    private sealed record ClipboardBackup(Forms.DataObject Data, bool HadData);

    private sealed record HistoryDbRow(
        int Kind,
        string? FilePath,
        string? ThumbnailPath,
        string? TextValue,
        long? DurationTicks,
        string? FilePathsJson,
        string? ContentHash,
        string? TextStoragePath,
        int TextLength,
        bool TextIsTruncated,
        string? PreviewError);
}
