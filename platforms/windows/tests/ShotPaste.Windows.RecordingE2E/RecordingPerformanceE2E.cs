using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Storage;
using Windows.Storage.Streams;
using Drawing = System.Drawing;

namespace ShotPaste.Windows.RecordingE2E;

internal static class RecordingPerformanceE2E
{
    internal static async Task<object> RunAsync(string outputRoot, int seconds)
    {
        var root = Path.Combine(outputRoot, "performance-baseline");
        Directory.CreateDirectory(root);
        var samplesPath = Path.Combine(root, "memory-samples.jsonl");
        if (File.Exists(samplesPath)) File.Delete(samplesPath);

        var (target, timer) = CreateAnimatedTarget();
        target.Show();
        await target.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        await Task.Delay(350);
        var bounds = GetBounds(target);
        var settings = new AppSettings
        {
            SaveDirectory = root,
            SaveRecordings = true,
            RecordingNameTemplate = "Performance_Region_{datetime}",
            RecordingFps = 30,
            RecordingQualityPreset = RecordingQuality.Medium,
            RecordingVideoFormat = "Mp4",
            RecordingVideoCodec = "H264",
            RecordSystemAudio = true,
            RecordMicrophone = false,
            IncludeCursorInRecording = false,
            HighlightMouseClicks = false,
            ShowKeystrokes = false
        };

        var samples = new List<MemorySample>();
        var activeClock = Stopwatch.StartNew();
        string output;
        RecordingFrameDiagnostics diagnostics;
        TimeSpan recorderElapsed;
        double stopMilliseconds;
        using (var recording = new ScreenRecordingService { FrameDiagnosticsEnabled = true })
        {
            var completion = recording.StartAsync(RecordingTarget.Region(bounds), settings);
            for (var index = 0; index < seconds; index++)
            {
                await Task.Delay(1000);
                using var process = Process.GetCurrentProcess();
                process.Refresh();
                var sample = new MemorySample(
                    Math.Round(activeClock.Elapsed.TotalSeconds, 3),
                    process.WorkingSet64,
                    process.PrivateMemorySize64,
                    GC.GetTotalMemory(false));
                samples.Add(sample);
                File.AppendAllText(samplesPath, JsonSerializer.Serialize(sample) + Environment.NewLine);
            }
            recorderElapsed = recording.Elapsed;
            activeClock.Stop();
            var stopClock = Stopwatch.StartNew();
            recording.Stop();
            output = await completion.WaitAsync(TimeSpan.FromSeconds(45));
            stopClock.Stop();
            stopMilliseconds = stopClock.Elapsed.TotalMilliseconds;
            diagnostics = recording.FrameDiagnostics;
        }

        timer.Stop();
        target.Close();
        var evidenceFrame = Path.Combine(root, "recording-performance-frame.jpg");
        var media = await InspectMediaAsync(output, evidenceFrame);
        var expectedFrames = (int)Math.Round(media.Duration.TotalSeconds * media.FrameRate);
        var droppedFrameEstimate = Math.Max(
            diagnostics.MissingFrameNumbers,
            Math.Max(0, expectedFrames - diagnostics.FrameCount));
        var droppedRatio = expectedFrames == 0 ? 1d : droppedFrameEstimate / (double)expectedFrames;
        var mediaClockDrift = Math.Abs((media.Duration - recorderElapsed).TotalMilliseconds);
        var workingSetGrowth = samples.Count < 2 ? 0 : samples[^1].WorkingSetBytes - samples[0].WorkingSetBytes;
        var peakWorkingSet = samples.Count == 0 ? 0 : samples.Max(sample => sample.WorkingSetBytes);

        if (diagnostics.FrameCount <= 0)
            throw new InvalidOperationException("Recorder frame diagnostics did not observe any encoded frames.");
        if (media.FrameRate is < 20 or > 35)
            throw new InvalidOperationException($"Long recording reported an unexpected frame rate: {media.FrameRate:0.##} fps.");
        if (droppedRatio > 0.08)
            throw new InvalidOperationException(
                $"Long recording dropped-frame estimate exceeded 8%: {droppedFrameEstimate}/{expectedFrames}.");
        if (mediaClockDrift > 1500)
            throw new InvalidOperationException($"Long recording media clock drift exceeded 1.5 seconds: {mediaClockDrift:0} ms.");
        if (stopMilliseconds > 5000)
            throw new InvalidOperationException($"Long recording stop exceeded 5 seconds: {stopMilliseconds:0} ms.");
        if (workingSetGrowth > 256L * 1024 * 1024)
            throw new InvalidOperationException($"Long recording working-set growth exceeded 256 MiB: {workingSetGrowth:N0} bytes.");
        if (media.AudioTrackCount == 0 || string.IsNullOrWhiteSpace(media.AudioSubtype))
            throw new InvalidOperationException("Long recording did not contain the requested system-audio track.");

        var result = new
        {
            GeneratedAt = DateTimeOffset.Now,
            RequestedSeconds = seconds,
            TargetBounds = bounds,
            Output = output,
            EvidenceFrame = evidenceFrame,
            RawMemorySamples = samplesPath,
            RecorderElapsed = recorderElapsed,
            media.Duration,
            MediaClockDriftMilliseconds = Math.Round(mediaClockDrift, 2),
            media.Width,
            media.Height,
            media.FrameRate,
            media.Bitrate,
            media.AudioTrackCount,
            media.AudioSubtype,
            media.MidpointSeekDecoded,
            StopMilliseconds = Math.Round(stopMilliseconds, 2),
            FrameDiagnostics = diagnostics,
            ExpectedFrames = expectedFrames,
            DroppedFrameEstimate = droppedFrameEstimate,
            DroppedFrameEstimateRatio = Math.Round(droppedRatio, 5),
            WorkingSetGrowthBytes = workingSetGrowth,
            PeakWorkingSetBytes = peakWorkingSet,
            Samples = samples
        };
        var summaryPath = Path.Combine(root, "summary.json");
        File.WriteAllText(summaryPath, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        return result;
    }

    private static (Window Window, DispatcherTimer Timer) CreateAnimatedTarget()
    {
        var marker = new Border
        {
            Width = 110,
            Height = 110,
            CornerRadius = new CornerRadius(28),
            Background = new SolidColorBrush(Color.FromRgb(255, 69, 58)),
            Child = new TextBlock
            {
                Text = "30 FPS",
                Foreground = Brushes.White,
                FontWeight = FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        var canvas = new Canvas { Background = new SolidColorBrush(Color.FromRgb(22, 35, 62)) };
        canvas.Children.Add(new TextBlock
        {
            Text = "ShotPaste long window recording performance fixture",
            Foreground = Brushes.White,
            FontSize = 27,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(28)
        });
        canvas.Children.Add(marker);
        var window = new Window
        {
            Title = "ShotPaste Recording Performance Fixture",
            Width = 960,
            Height = 540,
            Left = 180,
            Top = 150,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Topmost = true,
            Content = canvas
        };
        var tick = 0;
        var timer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(33)
        };
        timer.Tick += (_, _) =>
        {
            tick++;
            var availableWidth = Math.Max(1, canvas.ActualWidth - marker.Width - 40);
            var availableHeight = Math.Max(1, canvas.ActualHeight - marker.Height - 40);
            Canvas.SetLeft(marker, 20 + (tick * 11 % availableWidth));
            Canvas.SetTop(marker, 80 + (tick * 7 % Math.Max(1, availableHeight - 60)));
        };
        timer.Start();
        return (window, timer);
    }

    private static Drawing.Rectangle GetBounds(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        var source = HwndSource.FromHwnd(handle);
        var toDevice = source?.CompositionTarget?.TransformToDevice ?? Matrix.Identity;
        var topLeft = toDevice.Transform(new Point(window.Left, window.Top));
        var bottomRight = toDevice.Transform(new Point(window.Left + window.ActualWidth, window.Top + window.ActualHeight));
        var bounds = Drawing.Rectangle.FromLTRB(
            (int)Math.Round(topLeft.X),
            (int)Math.Round(topLeft.Y),
            (int)Math.Round(bottomRight.X),
            (int)Math.Round(bottomRight.Y));
        if (bounds.Width % 2 != 0) bounds.Width--;
        if (bounds.Height % 2 != 0) bounds.Height--;
        return bounds;
    }

    private static async Task<MediaInspection> InspectMediaAsync(string path, string evidencePath)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        var profile = await MediaEncodingProfile.CreateFromFileAsync(file);
        var properties = await file.Properties.GetVideoPropertiesAsync();
        var clip = await MediaClip.CreateFromFileAsync(file);
        var composition = new MediaComposition();
        composition.Clips.Add(clip);
        using var thumbnail = await composition.GetThumbnailAsync(
            TimeSpan.FromTicks(Math.Max(0, composition.Duration.Ticks / 2)),
            960,
            0,
            VideoFramePrecision.NearestFrame);
        await File.WriteAllBytesAsync(evidencePath, await ReadBytesAsync(thumbnail));
        var frameRate = profile.Video.FrameRate.Denominator == 0
            ? 0d
            : profile.Video.FrameRate.Numerator / (double)profile.Video.FrameRate.Denominator;
        return new MediaInspection(
            composition.Duration,
            properties.Width,
            properties.Height,
            frameRate,
            properties.Bitrate,
            clip.EmbeddedAudioTracks.Count,
            profile.Audio?.Subtype,
            thumbnail.Size > 0);
    }

    private static async Task<byte[]> ReadBytesAsync(IRandomAccessStream stream)
    {
        var size = checked((uint)stream.Size);
        var bytes = new byte[size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync(size);
        reader.ReadBytes(bytes);
        return bytes;
    }

    private sealed record MemorySample(
        double ElapsedSeconds,
        long WorkingSetBytes,
        long PrivateMemoryBytes,
        long ManagedMemoryBytes);

    private sealed record MediaInspection(
        TimeSpan Duration,
        uint Width,
        uint Height,
        double FrameRate,
        uint Bitrate,
        int AudioTrackCount,
        string? AudioSubtype,
        bool MidpointSeekDecoded);
}
