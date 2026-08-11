using System.Diagnostics;
using Drawing = System.Drawing;
using ScreenRecorderLib;
using LiteScreen.Windows.Models;

namespace LiteScreen.Windows.Services;

public sealed record RecordingAudioDevice(string DeviceId, string DisplayName);
internal sealed record RecordingSourcePlan(RecordingSourceBase Source, Drawing.Rectangle Bounds, Drawing.Size OutputSize);
internal sealed record RecordingFrameDiagnostics(
    int FrameCount,
    int FirstFrameNumber,
    int LastFrameNumber,
    long FirstTimestamp,
    long LastTimestamp)
{
    public int MissingFrameNumbers => FrameCount == 0
        ? 0
        : Math.Max(0, LastFrameNumber - FirstFrameNumber + 1 - FrameCount);
}

public sealed class ScreenRecordingService : IDisposable
{
    private Recorder? _recorder;
    private Stopwatch? _stopwatch;
    private TaskCompletionSource<string>? _completion;
    private readonly GifEncodingService _gifEncoder = new();
    private string? _gifDestination;
    private int _gifFrameRate = 15;
    private bool _recoveryEnabled;
    private int _diagnosticFrameCount;
    private int _diagnosticFirstFrameNumber;
    private int _diagnosticLastFrameNumber;
    private long _diagnosticFirstTimestamp;
    private long _diagnosticLastTimestamp;

    public bool IsRecording { get; private set; }
    public bool IsPaused { get; private set; }
    public TimeSpan Elapsed => _stopwatch?.Elapsed ?? TimeSpan.Zero;
    public Drawing.Rectangle CurrentRegion { get; private set; }
    public bool IsPostProcessing { get; private set; }
    public double PostProcessingProgress { get; private set; }
    public RecordingFormatDecision? LastFormatDecision { get; private set; }
    internal bool FrameDiagnosticsEnabled { get; set; }
    internal RecordingFrameDiagnostics FrameDiagnostics => new(
        Volatile.Read(ref _diagnosticFrameCount),
        Volatile.Read(ref _diagnosticFirstFrameNumber),
        Volatile.Read(ref _diagnosticLastFrameNumber),
        Volatile.Read(ref _diagnosticFirstTimestamp),
        Volatile.Read(ref _diagnosticLastTimestamp));
    public event EventHandler? StateChanged;

    public Task<string> StartAsync(Drawing.Rectangle region, AppSettings settings, bool recordAsGif = false)
        => StartAsync(RecordingTarget.Region(region), settings, recordAsGif);

    public Task<string> StartAsync(
        RecordingTarget target,
        AppSettings settings,
        bool recordAsGif = false)
    {
        if (IsRecording) throw new InvalidOperationException("录屏已在进行中。");
        var plan = CreateRecordingSource(target);
        CurrentRegion = plan.Bounds;
        var source = plan.Source;
        source.IsVideoFramePreviewEnabled = FrameDiagnosticsEnabled;
        var outputSize = plan.OutputSize;
        var formatDecision = RecordingFormatCapabilityService.Resolve(
            settings.RecordingVideoFormat,
            settings.RecordingVideoCodec,
            RecordingFormatCapabilityService.Current,
            gifIntermediate: recordAsGif);
        LastFormatDecision = formatDecision;
        var options = new RecorderOptions
        {
            SourceOptions = new SourceOptions { RecordingSources = [source] },
            OverlayOptions = new OverLayOptions(),
            OutputOptions = new OutputOptions
            {
                RecorderMode = RecorderMode.Video,
                OutputFrameSize = new ScreenSize(outputSize.Width, outputSize.Height),
                Stretch = StretchMode.Fill
            },
            AudioOptions = new AudioOptions
            {
                IsAudioEnabled = settings.RecordSystemAudio || settings.RecordMicrophone,
                IsOutputDeviceEnabled = settings.RecordSystemAudio,
                IsInputDeviceEnabled = settings.RecordMicrophone,
                AudioInputDevice = string.IsNullOrWhiteSpace(settings.RecordingMicrophoneDeviceId) ? null : settings.RecordingMicrophoneDeviceId,
                InputVolume = (float)Math.Clamp(settings.RecordingMicrophoneVolume, 0d, 1d),
                OutputVolume = (float)Math.Clamp(settings.RecordingSystemAudioVolume, 0d, 1d)
            },
            VideoEncoderOptions = new VideoEncoderOptions
            {
                Framerate = Math.Clamp(settings.RecordingFps, 15, 60),
                Bitrate = GetVideoBitrate(outputSize.Width, outputSize.Height, settings.RecordingFps, settings.RecordingQualityPreset),
                IsFixedFramerate = true,
                Encoder = CreateVideoEncoder(formatDecision.ActualCodec, settings.RecordingQualityPreset),
                Quality = GetEncoderQuality(settings.RecordingQualityPreset),
                IsHardwareEncodingEnabled = true,
                IsMp4FastStartEnabled = true
            },
            MouseOptions = new MouseOptions
            {
                IsMousePointerEnabled = settings.IncludeCursorInRecording,
                // LiteScreen renders click effects in a shared overlay so region
                // video and GIF recording use the same configurable rings.
                IsMouseClicksDetected = false
            },
            SnapshotOptions = new SnapshotOptions()
        };

        var outputDirectory = settings.SaveRecordings ? settings.SaveDirectory : AppPaths.Captures;
        var path = CaptureOutputNaming.NewPath(outputDirectory, CaptureKind.Recording, formatDecision.Extension, settings.RecordingNameTemplate);
        _gifDestination = null;
        _recoveryEnabled = true;
        _gifFrameRate = Math.Clamp(settings.RecordingGifFps, 5, 30);
        if (recordAsGif)
        {
            _gifDestination = CaptureOutputNaming.NewPath(outputDirectory, CaptureKind.Gif, ".gif", settings.RecordingNameTemplate);
        }
        _completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _diagnosticFrameCount = 0;
        _diagnosticFirstFrameNumber = 0;
        _diagnosticLastFrameNumber = 0;
        _diagnosticFirstTimestamp = 0;
        _diagnosticLastTimestamp = 0;
        _recorder = Recorder.CreateRecorder(options);
        if (FrameDiagnosticsEnabled)
        {
            _recorder.OnFrameRecorded += (_, args) =>
            {
                if (Interlocked.Increment(ref _diagnosticFrameCount) == 1)
                {
                    Volatile.Write(ref _diagnosticFirstFrameNumber, args.FrameNumber);
                    Volatile.Write(ref _diagnosticFirstTimestamp, args.Timestamp);
                }
                Volatile.Write(ref _diagnosticLastFrameNumber, args.FrameNumber);
                Volatile.Write(ref _diagnosticLastTimestamp, args.Timestamp);
            };
        }
        _recorder.OnRecordingComplete += (_, args) => _ = CompleteAsync(args.FilePath);
        _recorder.OnRecordingFailed += (_, args) =>
        {
            var message = string.IsNullOrWhiteSpace(args.Error)
                ? "录制失败，录制组件未返回错误信息。"
                : args.Error.Trim();
            Fail(new InvalidOperationException(message));
        };
        _recorder.Record(path);
        if (_recoveryEnabled) RecordingRecoveryService.Begin(path, _gifDestination, CurrentRegion);
        _stopwatch = Stopwatch.StartNew();
        IsRecording = true;
        IsPaused = false;
        IsPostProcessing = false;
        PostProcessingProgress = 0;
        StateChanged?.Invoke(this, EventArgs.Empty);
        return _completion.Task;
    }

    internal static RecordingSourcePlan CreateRecordingSource(RecordingTarget target)
    {
        if (target.Kind != RecordingTargetKind.Region)
            throw new ArgumentOutOfRangeException(nameof(target));

        var screen = System.Windows.Forms.Screen.FromRectangle(target.Bounds);
        var bounds = ClampToScreen(target.Bounds, screen.Bounds);
        var local = new Drawing.Rectangle(
            bounds.X - screen.Bounds.X, bounds.Y - screen.Bounds.Y, bounds.Width, bounds.Height);
        var source = new DisplayRecordingSource(screen.DeviceName)
        {
            SourceRect = new ScreenRect(local.X, local.Y, local.Width, local.Height),
            OutputSize = new ScreenSize(local.Width, local.Height),
            Stretch = StretchMode.Fill
        };
        return new RecordingSourcePlan(source, bounds, bounds.Size);
    }

    public void TogglePause()
    {
        if (!IsRecording || _recorder is null) return;
        if (IsPaused) { _recorder.Resume(); _stopwatch?.Start(); }
        else { _recorder.Pause(); _stopwatch?.Stop(); }
        IsPaused = !IsPaused;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Stop()
    {
        if (!IsRecording) return;
        _recorder?.Stop();
    }

    private async Task CompleteAsync(string path)
    {
        IsRecording = false;
        IsPaused = false;
        _stopwatch?.Stop();
        if (_gifDestination is not null)
        {
            try
            {
                IsPostProcessing = true;
                StateChanged?.Invoke(this, EventArgs.Empty);
                var progress = new Progress<double>(value =>
                {
                    PostProcessingProgress = Math.Clamp(value, 0d, 1d);
                    StateChanged?.Invoke(this, EventArgs.Empty);
                });
                await _gifEncoder.EncodeVideoAsync(path, _gifDestination, _gifFrameRate, progress);
                File.Delete(path);
                path = _gifDestination;
            }
            catch (Exception exception)
            {
                Fail(exception);
                return;
            }
        }
        IsPostProcessing = false;
        PostProcessingProgress = 1;
        if (_recoveryEnabled) RecordingRecoveryService.Complete();
        _completion?.TrySetResult(path);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Fail(Exception exception)
    {
        IsRecording = false;
        IsPaused = false;
        IsPostProcessing = false;
        _stopwatch?.Stop();
        _completion?.TrySetException(exception);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private static Drawing.Rectangle MakeEven(Drawing.Rectangle value) => new(value.X, value.Y,
        Math.Max(2, value.Width - value.Width % 2), Math.Max(2, value.Height - value.Height % 2));

    internal static Drawing.Rectangle ClampToScreen(Drawing.Rectangle region, Drawing.Rectangle screenBounds)
    {
        var intersection = Drawing.Rectangle.Intersect(region, screenBounds);
        if (intersection.Width < 2 || intersection.Height < 2)
            throw new ArgumentOutOfRangeException(nameof(region), "录制区域必须位于同一显示器内且至少为 2 × 2 像素。");
        return MakeEven(intersection);
    }

    internal static int GetVideoBitrate(int width, int height, int fps, RecordingQuality quality)
    {
        width = Math.Max(2, width);
        height = Math.Max(2, height);
        fps = Math.Clamp(fps, 15, 60);
        var (bitsPerPixelPerFrame, minimum, maximum) = quality switch
        {
            RecordingQuality.High => (0.20d, 2_500_000d, 60_000_000d),
            RecordingQuality.Medium => (0.13d, 1_600_000d, 35_000_000d),
            RecordingQuality.Low => (0.08d, 1_000_000d, 20_000_000d),
            _ => (0.13d, 1_600_000d, 35_000_000d)
        };
        var calculated = width * (double)height * fps * bitsPerPixelPerFrame;
        return (int)Math.Round(Math.Clamp(calculated, minimum, maximum));
    }

    internal static H264Profile GetEncoderProfile(RecordingQuality quality) => quality switch
    {
        RecordingQuality.High => H264Profile.High,
        RecordingQuality.Medium => H264Profile.Main,
        RecordingQuality.Low => H264Profile.Baseline,
        _ => H264Profile.Main
    };

    internal static int GetEncoderQuality(RecordingQuality quality) => quality switch
    {
        RecordingQuality.High => 90,
        RecordingQuality.Medium => 75,
        RecordingQuality.Low => 55,
        _ => 75
    };

    internal static IVideoEncoder CreateVideoEncoder(string codec, RecordingQuality quality) =>
        codec.Equals("Hevc", StringComparison.OrdinalIgnoreCase)
            ? new H265VideoEncoder
            {
                BitrateMode = H265BitrateControlMode.Quality,
                EncoderProfile = H265Profile.Main
            }
            : new H264VideoEncoder
            {
                BitrateMode = H264BitrateControlMode.UnconstrainedVBR,
                EncoderProfile = GetEncoderProfile(quality)
            };

    public static IReadOnlyList<RecordingAudioDevice> GetMicrophoneDevices()
    {
        try
        {
            return Recorder.GetSystemAudioDevices(AudioDeviceSource.InputDevices)
                .Where(device => !string.IsNullOrWhiteSpace(device.DeviceName))
                .Select(device => new RecordingAudioDevice(
                    device.DeviceName,
                    string.IsNullOrWhiteSpace(device.FriendlyName) ? device.DeviceName : device.FriendlyName))
                .DistinctBy(device => device.DeviceId, StringComparer.Ordinal)
                .OrderBy(device => device.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                .ToArray();
        }
        catch (Exception exception) when (exception is InvalidOperationException or DllNotFoundException or BadImageFormatException)
        {
            return [];
        }
    }

    public void Dispose()
    {
        if (IsRecording) _recorder?.Stop();
        _recorder?.Dispose();
    }
}
