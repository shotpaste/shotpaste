using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Storage;
using Windows.Storage.Streams;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.RecordingE2E;

internal static class RecordingEffectsE2E
{
    internal static async Task<object> RunAsync(string outputRoot)
    {
        var root = Path.Combine(outputRoot, "recording-effects");
        Directory.CreateDirectory(root);
        var target = CreateTarget();
        target.Show();
        await target.Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        await Task.Delay(250);
        var targetBounds = GetBounds(target);
        try
        {
            var region = await RecordRegionGifAsync(target, targetBounds, root);
            var fullScreenRegion = await RecordFullScreenRegionMp4Async(targetBounds, root);
            var microphone = await RecordMutedMicrophoneMp4Async(targetBounds, root);
            return new { RegionGif = region, FullScreenRegionMp4 = fullScreenRegion, MutedMicrophoneMp4 = microphone };
        }
        finally
        {
            target.Close();
        }
    }

    private static async Task<object> RecordRegionGifAsync(Window target, Drawing.Rectangle bounds, string root)
    {
        var settings = CreateSettings(root, "Effects_Region_{datetime}");
        string path;
        using (var clicks = new MouseClickOverlayService(bounds, settings))
        using (var keys = new KeystrokeOverlayService(bounds, settings))
        using (var recording = new ScreenRecordingService())
        {
            var completion = recording.StartAsync(RecordingTarget.Region(bounds), settings, recordAsGif: true);
            await Task.Delay(500);
            await EmitEffectsAsync(new Drawing.Point(bounds.Left + bounds.Width / 2, bounds.Top + bounds.Height * 2 / 3), 0x4B);
            await Task.Delay(1250);

            recording.TogglePause();
            clicks.SetPaused(true);
            keys.SetPaused(true);
            await EmitEffectsAsync(new Drawing.Point(bounds.Left + bounds.Width * 3 / 4, bounds.Top + bounds.Height * 2 / 3), 0x58);
            await Task.Delay(450);
            recording.TogglePause();
            clicks.SetPaused(false);
            keys.SetPaused(false);
            await EmitEffectsAsync(new Drawing.Point(bounds.Left + bounds.Width * 2 / 3, bounds.Top + bounds.Height * 2 / 3), 0x59);
            await Task.Delay(1250);
            recording.Stop();
            path = await completion.WaitAsync(TimeSpan.FromSeconds(45));
        }
        var inspection = InspectGif(path, Path.Combine(root, "region-effects-frame.png"));
        if (inspection.ClickFrames < 2)
            throw new InvalidOperationException($"Region GIF click rings missing: {inspection.ClickFrames} frames.");
        if (inspection.KeystrokeFrames < 2)
            throw new InvalidOperationException($"Region GIF keystroke panel missing: {inspection.KeystrokeFrames} frames.");
        return new
        {
            Output = path,
            inspection.FrameCount,
            inspection.Width,
            inspection.Height,
            inspection.ClickFrames,
            inspection.KeystrokeFrames,
            inspection.EvidenceFrame,
            PauseResume = true
        };
    }

    private static async Task<object> RecordFullScreenRegionMp4Async(Drawing.Rectangle targetBounds, string root)
    {
        var screen = Forms.Screen.FromRectangle(targetBounds);
        var bounds = screen.Bounds;
        var settings = CreateSettings(root, "Effects_FullScreenRegion_{datetime}");
        settings.RecordingQualityPreset = RecordingQuality.Low;
        settings.RecordingFps = 15;
        string path;
        using (var clicks = new MouseClickOverlayService(bounds, settings))
        using (var keys = new KeystrokeOverlayService(bounds, settings))
        using (var recording = new ScreenRecordingService())
        {
            var completion = recording.StartAsync(
                RecordingTarget.Region(bounds), settings, recordAsGif: false);
            await Task.Delay(450);
            await EmitEffectsAsync(new Drawing.Point(targetBounds.Left + targetBounds.Width / 2,
                targetBounds.Top + targetBounds.Height * 2 / 3), 0x44);
            await Task.Delay(1400);
            recording.Stop();
            path = await completion.WaitAsync(TimeSpan.FromSeconds(30));
        }
        var inspection = await InspectMp4Async(path, Path.Combine(root, "full-screen-region-effects-frame.jpg"));
        if (inspection.ClickFrames < 1)
            throw new InvalidOperationException("Full-screen region MP4 did not contain the configured click rings.");
        if (inspection.KeystrokeFrames < 1)
            throw new InvalidOperationException("Full-screen region MP4 did not contain the configured keystroke panel.");
        return new
        {
            Output = path,
            inspection.Duration,
            inspection.Width,
            inspection.Height,
            inspection.ClickFrames,
            inspection.KeystrokeFrames,
            inspection.EvidenceFrame
        };
    }

    private static async Task<object> RecordMutedMicrophoneMp4Async(Drawing.Rectangle bounds, string root)
    {
        var settings = CreateSettings(root, "Effects_MutedMic_{datetime}");
        settings.RecordMicrophone = true;
        settings.RecordingMicrophoneVolume = 0;
        settings.ShowKeystrokes = false;
        settings.HighlightMouseClicks = false;
        string path;
        MicrophoneLevelSnapshot microphoneSnapshot;
        using (var recording = new ScreenRecordingService())
        using (var monitor = new MicrophoneLevelMonitor(settings))
        {
            var completion = recording.StartAsync(RecordingTarget.Region(bounds), settings, recordAsGif: false);
            await Task.Delay(750);
            microphoneSnapshot = monitor.Read();
            await Task.Delay(700);
            recording.Stop();
            path = await completion.WaitAsync(TimeSpan.FromSeconds(30));
        }
        if (microphoneSnapshot.State != MicrophoneFeedbackState.Muted || microphoneSnapshot.Level != 0)
            throw new InvalidOperationException($"Expected muted microphone feedback, got '{microphoneSnapshot.State}'.");
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        var profile = await MediaEncodingProfile.CreateFromFileAsync(file);
        if (profile.Audio is null)
            throw new InvalidOperationException("Muted microphone recording did not contain an audio stream.");
        return new
        {
            Output = path,
            MicrophoneState = microphoneSnapshot.State,
            MicrophoneLevel = microphoneSnapshot.Level,
            AudioChannels = profile.Audio.ChannelCount,
            AudioSampleRate = profile.Audio.SampleRate,
            AudioBitrate = profile.Audio.Bitrate,
            PrivacySafeInputGain = 0
        };
    }

    private static AppSettings CreateSettings(string root, string nameTemplate) => new()
    {
        SaveDirectory = root,
        SaveRecordings = true,
        RecordingNameTemplate = nameTemplate,
        RecordingFps = 24,
        RecordingGifFps = 12,
        RecordingQualityPreset = RecordingQuality.Medium,
        RecordSystemAudio = false,
        RecordMicrophone = false,
        IncludeCursorInRecording = false,
        HighlightMouseClicks = true,
        ShowKeystrokes = true,
        RecordingClickRadius = 44,
        RecordingClickLeftColor = "#FF39FF14",
        RecordingClickRightColor = "#FFFF9F0A",
        RecordingClickOpacity = 1,
        RecordingClickDurationMs = 1000,
        RecordingClickRippleCount = 3,
        RecordingKeystrokePosition = "TopCenter",
        RecordingKeystrokeFontSize = 28,
        RecordingKeystrokeDurationMs = 1300,
        RecordingKeystrokeVisibility = "All"
    };

    private static Window CreateTarget()
    {
        var grid = new System.Windows.Controls.Grid { Background = new SolidColorBrush(Color.FromRgb(18, 96, 168)) };
        grid.Children.Add(new System.Windows.Controls.TextBlock
        {
            Text = "REGION / DISPLAY EFFECT TARGET",
            Foreground = Brushes.White,
            FontSize = 25,
            FontWeight = FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        });
        return new Window
        {
            Title = "ShotPaste recording effects E2E",
            Width = 560,
            Height = 320,
            Left = 230,
            Top = 190,
            Topmost = true,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Content = grid
        };
    }

    private static async Task EmitEffectsAsync(Drawing.Point point, byte key)
    {
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Native.SetCursorPos(point.X, point.Y);
        await Task.Delay(100);
        Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
        Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
        Native.keybd_event(0x11, 0, 0, UIntPtr.Zero);
        Native.keybd_event(key, 0, 0, UIntPtr.Zero);
        Native.keybd_event(key, 0, Native.KeyUp, UIntPtr.Zero);
        Native.keybd_event(0x11, 0, Native.KeyUp, UIntPtr.Zero);
    }

    private static Drawing.Rectangle GetBounds(Window window)
    {
        var source = HwndSource.FromHwnd(new WindowInteropHelper(window).Handle);
        var transform = source?.CompositionTarget?.TransformToDevice ?? Matrix.Identity;
        var topLeft = transform.Transform(new System.Windows.Point(window.Left, window.Top));
        var bottomRight = transform.Transform(new System.Windows.Point(window.Left + window.ActualWidth, window.Top + window.ActualHeight));
        return Drawing.Rectangle.FromLTRB((int)Math.Round(topLeft.X), (int)Math.Round(topLeft.Y),
            (int)Math.Round(bottomRight.X), (int)Math.Round(bottomRight.Y));
    }

    private static GifInspection InspectGif(string path, string evidence)
    {
        var decoder = new GifBitmapDecoder(new Uri(path), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var clickFrames = 0;
        var keyFrames = 0;
        var evidenceSaved = false;
        foreach (var frame in decoder.Frames)
        {
            var converted = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
            var stride = converted.PixelWidth * 4;
            var pixels = new byte[stride * converted.PixelHeight];
            converted.CopyPixels(pixels, stride, 0);
            var (click, keys) = DetectEffects(pixels, converted.PixelWidth, converted.PixelHeight, stride);
            if (click) clickFrames++;
            if (keys) keyFrames++;
            if (!evidenceSaved && click && keys)
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(frame));
                using var stream = File.Create(evidence);
                encoder.Save(stream);
                evidenceSaved = true;
            }
        }
        return new GifInspection(decoder.Frames.Count, decoder.Frames[0].PixelWidth,
            decoder.Frames[0].PixelHeight, clickFrames, keyFrames, evidence);
    }

    private static async Task<Mp4Inspection> InspectMp4Async(string path, string evidence)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        var properties = await file.Properties.GetVideoPropertiesAsync();
        var clip = await MediaClip.CreateFromFileAsync(file);
        var composition = new MediaComposition();
        composition.Clips.Add(clip);
        var clickFrames = 0;
        var keyFrames = 0;
        for (var index = 1; index <= 10; index++)
        {
            var position = TimeSpan.FromTicks(Math.Min(composition.Duration.Ticks - 1,
                composition.Duration.Ticks * index / 11));
            using var thumbnail = await composition.GetThumbnailAsync(position, 1280, 0, VideoFramePrecision.NearestFrame);
            var bytes = await ReadBytesAsync(thumbnail);
            using var stream = new MemoryStream(bytes);
            using var bitmap = new Drawing.Bitmap(stream);
            var click = false;
            var dark = 0;
            var bright = 0;
            for (var y = 0; y < bitmap.Height; y += 6)
            for (var x = 0; x < bitmap.Width; x += 6)
            {
                var color = bitmap.GetPixel(x, y);
                if (color.G > 175 && color.R < 150 && color.B < 130) click = true;
                if (y < bitmap.Height * 0.28 && x > bitmap.Width * 0.25 && x < bitmap.Width * 0.75)
                {
                    if (color.R < 55 && color.G < 55 && color.B < 60) dark++;
                    if (color.R > 175 && color.G > 175 && color.B > 175) bright++;
                }
            }
            var keys = dark > 25 && bright > 1;
            if (click) clickFrames++;
            if (keys) keyFrames++;
            if (index == 5 || click && keys && !File.Exists(evidence)) bitmap.Save(evidence, ImageFormat.Jpeg);
        }
        return new Mp4Inspection(composition.Duration, properties.Width, properties.Height,
            clickFrames, keyFrames, evidence);
    }

    private static (bool Click, bool Keys) DetectEffects(byte[] pixels, int width, int height, int stride)
    {
        var click = false;
        var dark = 0;
        var bright = 0;
        for (var y = 0; y < height; y += 5)
        for (var x = 0; x < width; x += 5)
        {
            var offset = y * stride + x * 4;
            var b = pixels[offset];
            var g = pixels[offset + 1];
            var r = pixels[offset + 2];
            if (g > 175 && r < 150 && b < 130) click = true;
            if (y < height * 0.42 && x > width * 0.18 && x < width * 0.82)
            {
                if (r < 55 && g < 55 && b < 60) dark++;
                if (r > 175 && g > 175 && b > 175) bright++;
            }
        }
        return (click, dark > 25 && bright > 1);
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

    private sealed record GifInspection(int FrameCount, int Width, int Height, int ClickFrames,
        int KeystrokeFrames, string EvidenceFrame);
    private sealed record Mp4Inspection(TimeSpan Duration, uint Width, uint Height, int ClickFrames,
        int KeystrokeFrames, string EvidenceFrame);

    private static class Native
    {
        internal const uint MouseLeftDown = 0x0002;
        internal const uint MouseLeftUp = 0x0004;
        internal const uint KeyUp = 0x0002;
        [DllImport("user32.dll")] internal static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] internal static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] internal static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
        [DllImport("user32.dll")] internal static extern void keybd_event(byte virtualKey, byte scan, uint flags, UIntPtr extraInfo);
    }
}
