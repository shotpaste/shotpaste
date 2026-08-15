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
            if (args.Length < 1) throw new ArgumentException(
                "Usage: HistoryE2E <ShotPaste.exe> [output-root] [--clipboard-only|--database-recovery-only|--direct-launch-only]");
            var executable = Path.GetFullPath(args[0]);
            var outputRoot = Path.GetFullPath(args.ElementAtOrDefault(1) ?? Path.Combine("build", "e2e", "history-ui"));
            var clipboardOnly = args.Any(value => value.Equals("--clipboard-only", StringComparison.OrdinalIgnoreCase));
            var databaseRecoveryOnly = args.Any(value =>
                value.Equals("--database-recovery-only", StringComparison.OrdinalIgnoreCase));
            var directLaunchOnly = args.Any(value =>
                value.Equals("--direct-launch-only", StringComparison.OrdinalIgnoreCase));
            var language = args.FirstOrDefault(value => value.StartsWith("--language=", StringComparison.OrdinalIgnoreCase))?
                .Split('=', 2)[1] ?? "en-US";
            var result = databaseRecoveryOnly
                ? RunDatabaseRecoverySessionAsync(executable, outputRoot, language).GetAwaiter().GetResult()
                : directLaunchOnly
                    ? RunDirectExecutableLaunchSessionAsync(executable, outputRoot).GetAwaiter().GetResult()
                    : RunAsync(executable, outputRoot, clipboardOnly).GetAwaiter().GetResult();
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
        var restart = await RunRestartSessionAsync(executable, dataRoot, outputRoot, persisted);
        var deletion = await RunDeletionSessionAsync(executable, outputRoot);
        var clear = await RunClearSessionAsync(executable, outputRoot);
        var settingsDeepLinks = await RunSettingsDeepLinkSessionAsync(executable, outputRoot);
        var directExecutableLaunch = await RunDirectExecutableLaunchSessionAsync(executable, outputRoot);
        var databaseRecovery = await RunDatabaseRecoverySessionAsync(executable, outputRoot, "en-US");
        var clipboard = await RunClipboardSessionAsync(executable, outputRoot);
        return new
        {
            SeededItems = 500,
            CountAfterFirstSession = countAfterFirstSession,
            FirstSession = first,
            Persisted = new
            {
                persisted.HistoryExpandedWidth,
                persisted.HistoryExpandedHeight,
                persisted.HistoryExpandedLeft,
                persisted.HistoryExpandedTop
            },
            RestartSession = restart,
            DeletionSession = deletion,
            ClearSession = clear,
            SettingsDeepLinks = settingsDeepLinks,
            DirectExecutableLaunch = directExecutableLaunch,
            DatabaseRecovery = databaseRecovery,
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
            var expanded = await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");
            await WaitUntilAsync(() => VisibleListItems(expanded).Length > 0,
                "Full history grid did not realize any cards at startup.");
            startup.Stop();
            var initialRealized = VisibleListItems(expanded).Length;
            var screenshotItemCount = Enumerable.Range(0, 500).Count(index => index % 7 == 0);
            if (initialRealized >= screenshotItemCount)
                throw new InvalidOperationException("Full history grid realized every screenshot item; virtualization is not active.");
            product.Refresh();
            var workingSetAtStartup = product.WorkingSet64;
            var window = AncestorWindow(expanded);
            var screenshotFilter = await WaitForAutomationIdAsync(product.Id, "ScreenshotHistoryFilter");
            if (string.IsNullOrWhiteSpace(screenshotFilter.Current.ItemStatus))
                throw new InvalidOperationException("The configured Screenshot default was not selected at startup.");
            if (FindByAutomationId(product.Id, "HistoryModeToggle") is not null ||
                FindByAutomationId(product.Id, "CompactHistoryCarousel") is not null)
                throw new InvalidOperationException("Removed compact-history controls are still exposed through UI Automation.");

            var firstItem = VisibleListItems(expanded).First();
            ((SelectionItemPattern)firstItem.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            var scroll = (ScrollPattern)expanded.GetCurrentPattern(ScrollPattern.Pattern);
            scroll.Scroll(ScrollAmount.NoAmount, ScrollAmount.LargeIncrement);
            await Task.Delay(350);
            if (VisibleListItems(expanded).Length == 0)
                throw new InvalidOperationException("Full history grid became blank after the first large scroll.");
            scroll.Scroll(ScrollAmount.NoAmount, ScrollAmount.LargeIncrement);
            await Task.Delay(350);
            if (VisibleListItems(expanded).Length == 0)
                throw new InvalidOperationException("Full history grid became blank after the second large scroll.");
            var scrolledPercent = scroll.Current.VerticalScrollPercent;
            if (scrolledPercent <= 0)
                throw new InvalidOperationException("Full history grid did not scroll vertically.");

            window = AncestorWindow(expanded);
            var handle = new IntPtr(window.Current.NativeWindowHandle);
            var dpiScale = Native.GetDpiForWindow(handle) / 96d;
            Native.SetWindowPos(handle, IntPtr.Zero,
                (int)Math.Round(140 * dpiScale), (int)Math.Round(115 * dpiScale),
                (int)Math.Round(1120 * dpiScale), (int)Math.Round(740 * dpiScale),
                Native.SwpNoZOrder | Native.SwpShowWindow);
            await WaitUntilAsync(() => VisibleListItems(expanded).Length > 0,
                "Full history grid became blank after scrolling and resizing.");
            var fullBounds = PhysicalBounds(window);
            var fullScreenshot = Path.Combine(outputRoot, "history-full-screenshot.png");
            SaveWindowScreenshot(fullBounds, fullScreenshot);

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

            var filteredBounds = PhysicalBounds(window);
            var filteredScreenshot = Path.Combine(outputRoot, "history-full-filtered.png");
            SaveWindowScreenshot(filteredBounds, filteredScreenshot);
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
                FullBounds = fullBounds,
                FilteredBounds = filteredBounds,
                FullScreenshot = fullScreenshot,
                FilteredScreenshot = filteredScreenshot
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
            var workArea = Forms.Screen.FromHandle(handle).WorkingArea;
            var expectedLeft = workArea.Left + (workArea.Width - bounds.Width) / 2;
            var expectedTop = workArea.Top + 24 * scale;
            AssertNear(expectedLeft, bounds.Left, 14, "top-centered left");
            AssertNear(expectedTop, bounds.Top, 14, "top-centered top");
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
                    ClickMoreAction(matchingCard);
                    Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryOpenItem"));
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
            ArgumentList = { "--ui-test", "--ui-test-clipboard", "--data-root", dataRoot, "--history" }
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

    private static void WriteSettings(
        string path,
        string root,
        bool clipboardHistoryEnabled = false,
        string language = "en-US")
    {
        var settings = new AppSettings
        {
            SaveDirectory = Path.Combine(root, "Captures"),
            HistoryExpandedWidth = 980,
            HistoryExpandedHeight = 680,
            Language = language,
            ClipboardHistoryEnabled = clipboardHistoryEnabled,
            HistoryDefaultFilter = clipboardHistoryEnabled ? "Clipboard" : "Screenshot",
            HistoryPosition = "TopCenter",
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
            var text = index == 21
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
            insert.Parameters.AddWithValue("$text", kind == 5 || index == 21 ? text : DBNull.Value);
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

    private static void SetClipboardText(string text) => RetryClipboard(() =>
    {
        var data = new Forms.DataObject();
        data.SetText(text, Forms.TextDataFormat.UnicodeText);
        data.SetData("CanIncludeInClipboardHistory", false, BitConverter.GetBytes(1u));
        Forms.Clipboard.SetDataObject(data, true);
    });

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

    private static async Task<object> RunDeletionSessionAsync(string executable, string outputRoot)
    {
        var dataRoot = Path.Combine(outputRoot, "deletion-data");
        if (Directory.Exists(dataRoot)) Directory.Delete(dataRoot, true);
        Directory.CreateDirectory(dataRoot);
        var database = Path.Combine(dataRoot, "history.sqlite3");
        SeedHistory(database, 1);
        WriteSettings(Path.Combine(dataRoot, "settings.json"), dataRoot);
        var file = Path.Combine(dataRoot, "history-fixtures", "fixture-0000.jpg");
        if (!File.Exists(file)) throw new InvalidOperationException("Deletion fixture file was not created.");

        using var product = Launch(executable, dataRoot);
        try
        {
            var expanded = await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");
            await WaitUntilAsync(() => VisibleListItems(expanded).Length == 1,
                "Deletion fixture history card did not appear.");
            var card = VisibleListItems(expanded).Single();

            ClickMoreAction(card);
            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryDeleteItem"));
            var dialog = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var confirmationScreenshot = Path.Combine(outputRoot, "history-delete-confirmation.png");
            SaveWindowScreenshot(PhysicalBounds(dialog), confirmationScreenshot);
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogSecondary"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "ShotPasteDialog") is null,
                "Cancelling history deletion did not close the confirmation.");
            if (!File.Exists(file) || CountHistoryRows(database) != 1 || VisibleListItems(expanded).Length != 1)
                throw new InvalidOperationException("Cancelling history deletion did not preserve file, database row and card.");

            card = VisibleListItems(expanded).Single();
            ClickMoreAction(card);
            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryDeleteItem"));
            await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogPrimary"));
            await WaitUntilAsync(() => TryCountHistoryRows(database) == 0,
                "Confirmed history deletion did not remove the database row.");
            await WaitUntilAsync(() => !File.Exists(file),
                "Confirmed history deletion did not move the file out of its original path.");
            await WaitUntilAsync(() => VisibleListItems(expanded).Length == 0,
                "Confirmed history deletion did not remove the UI card.");
            return new
            {
                CancelPreservedFileAndRecord = true,
                ConfirmedMovedFileToRecycleBin = true,
                RemainingRows = CountHistoryRows(database),
                ConfirmationScreenshot = confirmationScreenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunClearSessionAsync(string executable, string outputRoot)
    {
        var dataRoot = Path.Combine(outputRoot, "clear-data");
        if (Directory.Exists(dataRoot)) Directory.Delete(dataRoot, true);
        Directory.CreateDirectory(dataRoot);
        var database = Path.Combine(dataRoot, "history.sqlite3");
        SeedHistory(database, 2);
        WriteSettings(Path.Combine(dataRoot, "settings.json"), dataRoot);
        var files = new[]
        {
            Path.Combine(dataRoot, "history-fixtures", "fixture-0000.jpg"),
            Path.Combine(dataRoot, "history-fixtures", "fixture-0001.jpg")
        };
        if (files.Any(path => !File.Exists(path)))
            throw new InvalidOperationException("Clear-history fixture files were not created.");

        using var product = Launch(executable, dataRoot);
        try
        {
            var clear = await WaitForAutomationIdAsync(product.Id, "HistoryClearAll");
            Invoke(clear);
            var dialog = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var confirmationScreenshot = Path.Combine(outputRoot, "history-clear-confirmation.png");
            SaveWindowScreenshot(PhysicalBounds(dialog), confirmationScreenshot);
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogSecondary"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "ShotPasteDialog") is null,
                "Cancelling clear history did not close the confirmation.");
            if (CountHistoryRows(database) != 2 || files.Any(path => !File.Exists(path)))
                throw new InvalidOperationException("Cancelling clear history did not preserve every row and file.");

            Invoke(await WaitForAutomationIdAsync(product.Id, "HistoryClearAll"));
            await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogPrimary"));
            await WaitUntilAsync(() => TryCountHistoryRows(database) == 0,
                "Confirmed clear history did not remove every database row.");
            await WaitUntilAsync(() => files.All(path => !File.Exists(path)),
                "Confirmed clear history left saved capture files at their original paths.");
            return new
            {
                CancelPreservedAllRowsAndFiles = true,
                ConfirmedRecycledAllFiles = true,
                RemainingRows = CountHistoryRows(database),
                ConfirmationScreenshot = confirmationScreenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunSettingsDeepLinkSessionAsync(string executable, string outputRoot)
    {
        var shortcuts = await VerifySettingsDeepLinkAsync(
            executable, outputRoot, "shortcuts", "SettingsShortcutsTab");
        var capture = await VerifySettingsDeepLinkAsync(
            executable, outputRoot, "capture", "SettingsCaptureRecordingTab");
        return new { Shortcuts = shortcuts, Capture = capture };
    }

    private static async Task<object> RunDirectExecutableLaunchSessionAsync(string executable, string outputRoot)
    {
        var dataRoot = Path.Combine(outputRoot, "direct-executable-launch-data");
        if (Directory.Exists(dataRoot)) Directory.Delete(dataRoot, true);
        Directory.CreateDirectory(dataRoot);
        var saveDirectory = Path.Combine(dataRoot, "Captures");
        Directory.CreateDirectory(saveDirectory);
        File.WriteAllText(Path.Combine(dataRoot, "settings.json"), JsonSerializer.Serialize(new
        {
            SaveDirectory = saveDirectory,
            Language = "en-US",
            ShortcutsEnabled = false,
            ShowQuickAccess = false
        }, new JsonSerializerOptions { WriteIndented = true }));
        using var product = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList =
            {
                "--ui-test",
                "--data-root",
                dataRoot,
                "--ui-test-direct-launch"
            }
        }) ?? throw new InvalidOperationException("Could not launch the direct executable fixture.");
        try
        {
            var settings = await WaitForAutomationIdAsync(product.Id, "SettingsWindow");
            var generalTab = await WaitForAutomationIdAsync(product.Id, "SettingsGeneralTab");
            if (generalTab.GetCurrentPattern(SelectionItemPattern.Pattern) is not SelectionItemPattern selection ||
                !selection.Current.IsSelected)
                throw new InvalidOperationException(
                    "A direct executable launch did not open the General page in the actual settings window.");
            var screenshot = Path.Combine(outputRoot, "settings-direct-executable-launch.png");
            SaveWindowScreenshot(PhysicalBounds(settings), screenshot);

            using (var forwarded = Process.Start(new ProcessStartInfo(executable)
                   {
                       UseShellExecute = false,
                       ArgumentList =
                       {
                           "--ui-test",
                           "--data-root",
                           dataRoot,
                           "--settings=shortcuts"
                       }
                   }) ?? throw new InvalidOperationException("Could not launch the repeated settings fixture."))
            {
                if (!forwarded.WaitForExit(5000))
                    throw new InvalidOperationException("The repeated settings request was not forwarded.");
            }
            var shortcutsTab = await WaitForAutomationIdAsync(product.Id, "SettingsShortcutsTab");
            await WaitUntilAsync(() =>
            {
                if (shortcutsTab.GetCurrentPattern(SelectionItemPattern.Pattern) is not SelectionItemPattern selected ||
                    !selected.Current.IsSelected) return false;
                var settingsWindows = AutomationElement.RootElement.FindAll(
                    TreeScope.Descendants,
                    new AndCondition(
                        new PropertyCondition(AutomationElement.ProcessIdProperty, product.Id),
                        new PropertyCondition(AutomationElement.AutomationIdProperty, "SettingsWindow")));
                return settingsWindows.Count == 1;
            }, "A repeated settings request opened another window or did not navigate the existing window.");

            var captureTab = await WaitForAutomationIdAsync(product.Id, "SettingsCaptureRecordingTab");
            ((SelectionItemPattern)captureTab.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            var excludeOwnApplication = await WaitForAutomationIdAsync(
                product.Id, "SettingsExcludeOwnApplication");
            var ocrSuccessNotifications = await WaitForAutomationIdAsync(
                product.Id, "SettingsOcrSuccessNotifications");
            if (GetToggleState(excludeOwnApplication) != System.Windows.Automation.ToggleState.Off)
                throw new InvalidOperationException(
                    "A fresh settings profile enabled ShotPaste window exclusion by default.");
            if (GetToggleState(ocrSuccessNotifications) != System.Windows.Automation.ToggleState.On)
                throw new InvalidOperationException(
                    "A fresh settings profile disabled OCR success notifications by default.");
            ScrollIntoView(ocrSuccessNotifications);
            await Task.Delay(180);
            var captureDefaultsScreenshot = Path.Combine(outputRoot, "settings-default-capture-options.png");
            SaveWindowScreenshot(PhysicalBounds(settings), captureDefaultsScreenshot);

            var historyTab = await WaitForAutomationIdAsync(product.Id, "SettingsHistoryTab");
            ((SelectionItemPattern)historyTab.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            var clipboardHistory = await WaitForAutomationIdAsync(
                product.Id, "SettingsClipboardHistoryEnabled");
            if (GetToggleState(clipboardHistory) != System.Windows.Automation.ToggleState.On)
                throw new InvalidOperationException(
                    "A fresh settings profile disabled clipboard history by default.");
            var clipboardDefaultScreenshot = Path.Combine(outputRoot, "settings-default-clipboard-history.png");
            SaveWindowScreenshot(PhysicalBounds(settings), clipboardDefaultScreenshot);

            Invoke(await WaitForAutomationIdAsync(product.Id, "SettingsSave"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "SettingsWindow") is null,
                "The direct-launch settings window did not close.");
            return new
            {
                DirectLaunchOpenedSettings = true,
                RepeatedRequestReusedWindow = true,
                RepeatedRequestSelectedAutomationId = "SettingsShortcutsTab",
                SelectedAutomationId = "SettingsGeneralTab",
                ExcludeOwnApplicationDefault = false,
                OcrSuccessNotificationsDefault = true,
                ClipboardHistoryDefault = true,
                Screenshot = screenshot,
                CaptureDefaultsScreenshot = captureDefaultsScreenshot,
                ClipboardDefaultScreenshot = clipboardDefaultScreenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> VerifySettingsDeepLinkAsync(
        string executable,
        string outputRoot,
        string requestedTab,
        string expectedAutomationId)
    {
        var dataRoot = Path.Combine(outputRoot, "settings-deep-link-" + requestedTab);
        if (Directory.Exists(dataRoot)) Directory.Delete(dataRoot, true);
        Directory.CreateDirectory(dataRoot);
        WriteSettings(Path.Combine(dataRoot, "settings.json"), dataRoot);
        using var product = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", dataRoot, $"--settings={requestedTab}" }
        }) ?? throw new InvalidOperationException("Could not launch the settings deep-link fixture.");
        try
        {
            var settings = await WaitForAutomationIdAsync(product.Id, "SettingsWindow");
            var tab = await WaitForAutomationIdAsync(product.Id, expectedAutomationId);
            if (tab.GetCurrentPattern(SelectionItemPattern.Pattern) is not SelectionItemPattern selection ||
                !selection.Current.IsSelected)
                throw new InvalidOperationException(
                    $"--settings={requestedTab} did not select {expectedAutomationId} in the actual settings window.");
            var screenshot = Path.Combine(outputRoot, $"settings-deep-link-{requestedTab}.png");
            SaveWindowScreenshot(PhysicalBounds(settings), screenshot);
            Invoke(await WaitForAutomationIdAsync(product.Id, "SettingsSave"));
            await WaitUntilAsync(() => FindByAutomationId(product.Id, "SettingsWindow") is null,
                $"The {requestedTab} deep-link settings window did not close.");
            return new
            {
                Requested = requestedTab,
                SelectedAutomationId = expectedAutomationId,
                FinalPageSelected = true,
                Screenshot = screenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<object> RunDatabaseRecoverySessionAsync(
        string executable,
        string outputRoot,
        string language)
    {
        var dataRoot = Path.Combine(outputRoot, "database-recovery-data");
        if (Directory.Exists(dataRoot)) Directory.Delete(dataRoot, true);
        Directory.CreateDirectory(dataRoot);
        WriteSettings(Path.Combine(dataRoot, "settings.json"), dataRoot, language: language);
        var database = Path.Combine(dataRoot, "history.sqlite3");
        var corruptBytes = "ShotPaste intentionally corrupt startup database"u8.ToArray();
        await File.WriteAllBytesAsync(database, corruptBytes);
        var capture = Path.Combine(dataRoot, "Captures", "preserve-capture.png");
        var clipboardDirectory = Path.Combine(dataRoot, "ClipboardFiles");
        Directory.CreateDirectory(clipboardDirectory);
        var clipboard = Path.Combine(clipboardDirectory, "preserve-clipboard.txt");
        await File.WriteAllTextAsync(capture, "capture must survive database reset");
        await File.WriteAllTextAsync(clipboard, "clipboard must survive database reset");

        using var product = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            ArgumentList = { "--ui-test", "--data-root", dataRoot, "--history" }
        }) ?? throw new InvalidOperationException("Could not launch the corrupt-database recovery fixture.");
        try
        {
            var firstDialog = await WaitForAutomationIdAsync(product.Id, "ShotPasteDialog");
            var screenshot = Path.Combine(outputRoot, "database-recovery-startup.png");
            SaveWindowScreenshot(PhysicalBounds(firstDialog), screenshot);
            var visibleDialogText = string.Join("\n", firstDialog
                .FindAll(TreeScope.Descendants, Condition.TrueCondition)
                .Cast<AutomationElement>()
                .Where(element => !element.Current.IsOffscreen)
                .Select(element => element.Current.Name)
                .Where(name => !string.IsNullOrWhiteSpace(name)));
            if (language is "en-US" or "de-DE" or "fr-FR" or "es-ES" or "ru-RU" or "vi-VN" &&
                System.Text.RegularExpressions.Regex.IsMatch(visibleDialogText, "[\\u3400-\\u9fff]"))
                throw new InvalidOperationException(
                    $"The {language} startup database recovery entry still contains Chinese text:\n{visibleDialogText}");
            var repair = await WaitForAutomationIdAsync(product.Id, "DialogPrimary");
            var repairLabel = LocalizationService.TranslatePhrase("尝试修复", language);
            if (!repair.Current.Name.Contains(repairLabel, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The startup database dialog did not offer repair first.");
            Invoke(repair);
            await Task.Delay(350);

            var resetChoice = await WaitForAutomationIdAsync(product.Id, "DialogSecondary");
            var resetLabel = LocalizationService.TranslatePhrase("重置数据库…", language).TrimEnd('…', '.');
            if (!resetChoice.Current.Name.Contains(resetLabel, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The failed repair flow did not retain the reset option.");
            Invoke(resetChoice);
            await WaitUntilAsync(() =>
            {
                var primary = FindByAutomationId(product.Id, "DialogPrimary");
                return primary is not null &&
                       primary.Current.Name.Contains(
                           LocalizationService.TranslatePhrase("重置数据库", language),
                           StringComparison.OrdinalIgnoreCase);
            }, "The startup recovery flow did not show reset confirmation.");
            Invoke(await WaitForAutomationIdAsync(product.Id, "DialogPrimary"));
            await WaitForAutomationIdAsync(product.Id, "ExpandedHistoryGrid");

            var archiveDirectory = Directory.GetDirectories(dataRoot, "DatabaseRecovery-*").SingleOrDefault()
                ?? throw new InvalidOperationException("Database reset did not create a recovery archive.");
            var archivedDatabase = Path.Combine(archiveDirectory, Path.GetFileName(database));
            if (!File.Exists(archivedDatabase) ||
                !File.ReadAllBytes(archivedDatabase).SequenceEqual(corruptBytes))
                throw new InvalidOperationException("The corrupt database was not preserved byte-for-byte in the recovery archive.");
            if (CountHistoryRows(database) != 0)
                throw new InvalidOperationException("Database reset did not create a valid empty SQLite history database.");
            if (!File.Exists(capture) || !File.Exists(clipboard))
                throw new InvalidOperationException("Database reset removed capture or managed clipboard content.");
            return new
            {
                RepairWasAttempted = true,
                ResetWasConfirmed = true,
                ArchivedDatabase = archivedDatabase,
                FreshDatabaseIsValid = true,
                CaptureFilePreserved = true,
                ClipboardFilePreserved = true,
                Screenshot = screenshot
            };
        }
        finally { StopExactProcess(product); }
    }

    private static async Task<AutomationElement> WaitForAutomationIdAsync(int processId, string id)
    {
        AutomationElement? result = null;
        await WaitUntilAsync(() =>
        {
            result = FindByAutomationId(processId, id);
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

    private static System.Windows.Automation.ToggleState GetToggleState(AutomationElement element) =>
        ((TogglePattern)element.GetCurrentPattern(TogglePattern.Pattern)).Current.ToggleState;

    private static void ScrollIntoView(AutomationElement element)
    {
        if (element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out var pattern))
            ((ScrollItemPattern)pattern).ScrollIntoView();
    }

    private static Drawing.Rectangle PhysicalBounds(AutomationElement element)
    {
        var bounds = element.Current.BoundingRectangle;
        return Drawing.Rectangle.FromLTRB((int)Math.Round(bounds.Left), (int)Math.Round(bounds.Top),
            (int)Math.Round(bounds.Right), (int)Math.Round(bounds.Bottom));
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

    private static void ClickMoreAction(AutomationElement card)
    {
        var bounds = PhysicalBounds(card);
        var window = AncestorWindow(card);
        var scale = Native.GetDpiForWindow(new IntPtr(window.Current.NativeWindowHandle)) / 96d;
        Native.SetForegroundWindow(new IntPtr(window.Current.NativeWindowHandle));
        Native.SetCursorPos(bounds.Right - (int)Math.Round(28 * scale),
            bounds.Bottom - (int)Math.Round(31 * scale));
        Native.mouse_event(Native.MouseeventfLeftdown, 0, 0, 0, UIntPtr.Zero);
        Native.mouse_event(Native.MouseeventfLeftup, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(180);
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
