using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Storage;
using Drawing = System.Drawing;

namespace ShotPaste.Windows.RecordingE2E;

internal static class RecordingFormatE2E
{
    internal static async Task<object> RunAsync(string outputRoot)
    {
        var root = Path.Combine(outputRoot, "format-matrix");
        Directory.CreateDirectory(root);
        var support = await RecordingFormatCapabilityService.ProbeAsync(force: true);
        var target = CreateTarget();
        target.Show();
        await target.Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        await Task.Delay(250);
        try
        {
            var bounds = GetBounds(target);
            var h264 = await RecordAsync(root, bounds, "Mp4", "H264", "Format_MP4_H264_{datetime}");
            var movFallback = await RecordAsync(root, bounds, "Mov", "H264", "Format_MOV_Request_{datetime}");
            var hevc = await RecordAsync(root, bounds, "Mp4", "Hevc", "Format_MP4_HEVC_{datetime}");

            if (!h264.VideoSubtype.Equals(MediaEncodingSubtypes.H264, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"H.264 scenario produced '{h264.VideoSubtype}'.");
            if (!movFallback.Decision.UsedFallback ||
                !movFallback.Decision.FallbackReason!.Contains(RecordingFormatCapabilityService.MovUnavailable, StringComparison.Ordinal))
                throw new InvalidOperationException("MOV request was not explicitly mapped to MP4.");
            if (support.HevcEncoderAvailable)
            {
                if (!hevc.VideoSubtype.Equals(MediaEncodingSubtypes.Hevc, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException($"HEVC capability was reported but output subtype was '{hevc.VideoSubtype}'.");
            }
            else if (!hevc.VideoSubtype.Equals(MediaEncodingSubtypes.H264, StringComparison.OrdinalIgnoreCase) ||
                     !hevc.Decision.UsedFallback)
            {
                throw new InvalidOperationException("Unavailable HEVC did not safely produce H.264.");
            }

            var result = new
            {
                GeneratedAt = DateTimeOffset.Now,
                Support = support,
                ScreenRecorderLibContainer = "ISO MP4 only",
                H264 = h264,
                MovRequestFallback = movFallback,
                HevcRequest = hevc
            };
            File.WriteAllText(Path.Combine(root, "summary.json"),
                JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
            return result;
        }
        finally
        {
            target.Close();
        }
    }

    private static async Task<FormatEvidence> RecordAsync(
        string root,
        Drawing.Rectangle bounds,
        string container,
        string codec,
        string template)
    {
        var settings = new AppSettings
        {
            SaveDirectory = root,
            SaveRecordings = true,
            RecordingNameTemplate = template,
            RecordingFps = 24,
            RecordingQualityPreset = RecordingQuality.Medium,
            RecordingVideoFormat = container,
            RecordingVideoCodec = codec,
            RecordSystemAudio = false,
            RecordMicrophone = false,
            IncludeCursorInRecording = false,
            HighlightMouseClicks = false,
            ShowKeystrokes = false
        };

        string path;
        RecordingFormatDecision decision;
        using (var recording = new ScreenRecordingService())
        {
            var completion = recording.StartAsync(RecordingTarget.Region(bounds), settings);
            decision = recording.LastFormatDecision ?? throw new InvalidOperationException("Recorder did not expose a format decision.");
            await Task.Delay(2100);
            recording.Stop();
            path = await completion.WaitAsync(TimeSpan.FromSeconds(30));
        }

        if (!Path.GetExtension(path).Equals(decision.Extension, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Extension '{Path.GetExtension(path)}' does not match '{decision.Extension}'.");
        var header = new byte[12];
        await using (var stream = File.OpenRead(path))
        {
            if (await stream.ReadAsync(header) != header.Length) throw new InvalidOperationException("Recording output is truncated.");
        }
        var isoMp4 = System.Text.Encoding.ASCII.GetString(header, 4, 4) == "ftyp";
        if (!isoMp4) throw new InvalidOperationException("Output extension is MP4 but ISO BMFF ftyp header is missing.");

        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        var profile = await MediaEncodingProfile.CreateFromFileAsync(file);
        var properties = await file.Properties.GetVideoPropertiesAsync();
        var clip = await MediaClip.CreateFromFileAsync(file);
        var composition = new MediaComposition();
        composition.Clips.Add(clip);
        using var seekFrame = await composition.GetThumbnailAsync(
            TimeSpan.FromTicks(Math.Max(0, composition.Duration.Ticks / 2)),
            320,
            0,
            VideoFramePrecision.NearestFrame);
        if (seekFrame.Size == 0) throw new InvalidOperationException("Media Foundation could not seek and decode a midpoint frame.");

        var rate = profile.Video.FrameRate.Denominator == 0
            ? 0
            : profile.Video.FrameRate.Numerator / (double)profile.Video.FrameRate.Denominator;
        if (properties.Duration < TimeSpan.FromSeconds(1))
            throw new InvalidOperationException($"Recorded media is too short: {properties.Duration}.");
        if (profile.Video.Width != (uint)bounds.Width || profile.Video.Height != (uint)bounds.Height)
            throw new InvalidOperationException($"Unexpected output dimensions {profile.Video.Width}x{profile.Video.Height} for {bounds.Width}x{bounds.Height}.");

        return new FormatEvidence(
            decision,
            path,
            new FileInfo(path).Length,
            profile.Container.Subtype,
            profile.Video.Subtype,
            profile.Audio?.Subtype,
            profile.Video.Width,
            profile.Video.Height,
            properties.Duration,
            properties.Bitrate,
            rate,
            IsoMp4Header: isoMp4,
            MidpointSeekDecoded: true);
    }

    private static Window CreateTarget() => new()
    {
        Title = "ShotPaste format matrix target",
        Width = 640,
        Height = 360,
        Left = 240,
        Top = 210,
        WindowStartupLocation = WindowStartupLocation.Manual,
        Topmost = true,
        Background = new SolidColorBrush(Color.FromRgb(20, 112, 188)),
        Content = new System.Windows.Controls.TextBlock
        {
            Text = "MP4 · H.264 / HEVC · SEEK TEST",
            Foreground = Brushes.White,
            FontSize = 28,
            FontWeight = FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        }
    };

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

    private sealed record FormatEvidence(
        RecordingFormatDecision Decision,
        string Output,
        long SizeBytes,
        string ContainerSubtype,
        string VideoSubtype,
        string? AudioSubtype,
        uint Width,
        uint Height,
        TimeSpan Duration,
        uint Bitrate,
        double FrameRate,
        bool IsoMp4Header,
        bool MidpointSeekDecoded);
}
