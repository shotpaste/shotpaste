using System.Diagnostics;
using System.Collections.Concurrent;
using System.Text.Json;
using System.Security.Cryptography;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ShotPaste.Windows.Services;

public sealed record AudioRecordingOptions(bool SystemAudio, bool Microphone, string MicrophoneDeviceId,
    double SystemVolume, double MicrophoneVolume, string OutputDirectory,
    RecordingTranscriptionConfiguration? TranscriptionConfiguration = null);
public sealed record AudioRecordingResult(string Path, TimeSpan Duration,
    RecordingTranscriptionConfiguration? TranscriptionConfiguration = null);
public sealed record AudioRecordingSource(string Path, string Role);
public sealed class AudioCaptureStoppedEventArgs(long generation) : EventArgs
{
    public long Generation { get; } = generation;
}

/// <summary>WASAPI captures audio directly. Recoverable PCM never contains screen pixels.</summary>
public sealed class AudioRecordingService : IDisposable
{
    // Microsoft's AAC MFT accepts 44.1/48 kHz PCM input, not 16 kHz speech PCM.
    // Keep capture and recovery at the supported rate; no lossy upsampling is needed at save time.
    private static readonly WaveFormat Format = new(48000, 16, 1);
    private static readonly ConcurrentDictionary<string, byte> ActiveSessions = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();
    private readonly Stopwatch _clock = new();
    private readonly List<SourceCapture> _sources = [];
    private Receipt? _receipt;
    private string? _sessionDirectory;
    private Task<AudioRecordingResult>? _stopTask;
    private bool _paused;
    private bool _stopping;
    private long _captureGeneration;
    public long CaptureGeneration => Interlocked.Read(ref _captureGeneration);
    public bool IsRecording { get; private set; }
    public bool IsPaused => _paused;
    public TimeSpan Elapsed { get { lock (_sync) return _clock.Elapsed; } }
    public event EventHandler? StateChanged;
    public event EventHandler<AudioCaptureStoppedEventArgs>? CaptureStopped;
    public Exception? CaptureError { get; private set; }
    private static string SessionsDirectory => Path.Combine(AppPaths.Root, "AudioRecordingSessions");

    public void Start(AudioRecordingOptions options)
    {
        if (IsRecording || _receipt is not null) throw new InvalidOperationException("Finish the previous recording first.");
        if (!options.SystemAudio && !options.Microphone) throw new InvalidOperationException("Select an audio source.");
        try
        {
        _sessionDirectory = Path.Combine(SessionsDirectory, Guid.NewGuid().ToString("N"));
        ActiveSessions.TryAdd(_sessionDirectory, 0);
        Directory.CreateDirectory(_sessionDirectory);
        Directory.CreateDirectory(options.OutputDirectory);
        _receipt = new Receipt(Path.Combine(Path.GetFullPath(options.OutputDirectory),
            $"ShotPaste_Audio_{DateTime.Now:yyyyMMdd_HHmmss}_{Guid.NewGuid():N}.m4a"),
            options.SystemAudio, options.Microphone, Math.Clamp(options.SystemVolume, 0, 1),
            Math.Clamp(options.MicrophoneVolume, 0, 1), false,
            options.TranscriptionConfiguration is null ? null : ProtectConfiguration(options.TranscriptionConfiguration));
        SaveReceipt(_sessionDirectory, _receipt);
        _clock.Restart();
        IsRecording = true;
        _paused = false;
        _stopping = false;
        CaptureError = null;
        _stopTask = null;
        Interlocked.Increment(ref _captureGeneration);
            if (options.SystemAudio) AddSource(new WasapiLoopbackCapture(), "system");
            if (options.Microphone)
            {
                using var devices = new MMDeviceEnumerator();
                var device = string.IsNullOrWhiteSpace(options.MicrophoneDeviceId)
                    ? devices.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)
                    : devices.GetDevice(options.MicrophoneDeviceId);
                AddSource(new WasapiCapture(device), "microphone", device);
            }
            foreach (var source in _sources)
            {
                if (_stopping) throw new InvalidOperationException("An audio source stopped during startup.");
                source.Capture.StartRecording();
            }
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            _clock.Stop();
            IsRecording = false;
            _stopping = true;
            foreach (var source in _sources) source.Capture.StopRecording();
            // Dispose waits for native callbacks before closing PCM streams.
            DisposeSources();
            _receipt = null;
            if (_sessionDirectory is not null) ActiveSessions.TryRemove(_sessionDirectory, out _);
            throw;
        }
    }

    private void AddSource(WasapiCapture capture, string role, MMDevice? device = null)
    {
        var generation = CaptureGeneration;
        capture.WaveFormat = Format;
        var source = new SourceCapture(capture, device,
            new FileStream(Path.Combine(_sessionDirectory!, role + ".pcm"), FileMode.CreateNew, FileAccess.Write, FileShare.Read));
        _sources.Add(source);
        capture.DataAvailable += (_, args) =>
        {
            var unexpectedlyStopped = false;
            lock (_sync)
            {
                if (generation != CaptureGeneration || _paused || _stopping || !IsRecording) return;
                try
                {
                    // Loopback emits no packets during silence. Preserve those gaps and source alignment.
                    var target = AlignedLength(_clock.Elapsed);
                    var padding = Math.Max(0, target - args.BytesRecorded - source.Stream.Length);
                    if (padding > Format.AverageBytesPerSecond / 10) Pad(source.Stream, padding);
                    source.Stream.Write(args.Buffer, 0, args.BytesRecorded - args.BytesRecorded % Format.BlockAlign);
                    source.Stream.Flush();
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    CaptureError ??= error;
                    _clock.Stop();
                    _stopping = true;
                    foreach (var input in _sources) input.Capture.StopRecording();
                    unexpectedlyStopped = true;
                }
            }
            if (unexpectedlyStopped) CaptureStopped?.Invoke(this, new AudioCaptureStoppedEventArgs(generation));
        };
        capture.RecordingStopped += (_, args) =>
        {
            var unexpectedlyStopped = false;
            lock (_sync)
            {
                source.Stopped.TrySetResult(true);
                if (generation != CaptureGeneration) return;
                if (args.Exception is not null) CaptureError ??= args.Exception;
                if (!_stopping)
                {
                    _stopping = true;
                    _clock.Stop();
                    foreach (var input in _sources) input.Capture.StopRecording();
                    unexpectedlyStopped = true;
                }
            }
            // Deliberate Stop/Discard already has an owner. Posting another
            // completion can otherwise reach the UI after a restarted capture.
            if (unexpectedlyStopped) CaptureStopped?.Invoke(this, new AudioCaptureStoppedEventArgs(generation));
        };
    }

    internal static long AlignedLength(TimeSpan duration) =>
        Math.Max(0, (long)(duration.TotalSeconds * Format.SampleRate)) * Format.BlockAlign;

    public void TogglePause()
    {
        lock (_sync)
        {
            if (!IsRecording || _stopping) return;
            _paused = !_paused;
            if (_paused) _clock.Stop(); else _clock.Start();
        }
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public Task<AudioRecordingResult> StopAsync()
    {
        // Keep one finalizer per capture; a failed export may be retried from preserved PCM.
        if (_stopTask is null || _stopTask.IsFaulted) _stopTask = StopCoreAsync();
        return _stopTask;
    }

    private async Task<AudioRecordingResult> StopCoreAsync()
    {
        if (_receipt is null || _sessionDirectory is null) throw new InvalidOperationException("No recording to save.");
        lock (_sync)
        {
            _stopping = true;
            _clock.Stop();
            foreach (var source in _sources) source.Capture.StopRecording();
        }
        await Task.WhenAll(_sources.Select(source => source.Stopped.Task)).WaitAsync(TimeSpan.FromSeconds(15));
        lock (_sync)
        {
            foreach (var source in _sources)
            {
                Pad(source.Stream, Math.Max(0, AlignedLength(_clock.Elapsed) - source.Stream.Length));
                source.Stream.Flush(true);
            }
        }
        DisposeSources();
        IsRecording = false;
        _paused = false;
        StateChanged?.Invoke(this, EventArgs.Empty);
        var result = await Task.Run(() => FinalizeSession(_sessionDirectory, _receipt));
        _receipt = null;
        ActiveSessions.TryRemove(_sessionDirectory, out _);
        return result;
    }

    public async Task DiscardAsync()
    {
        lock (_sync)
        {
            _stopping = true;
            _clock.Stop();
            foreach (var source in _sources) source.Capture.StopRecording();
        }
        await Task.WhenAll(_sources.Select(source => source.Stopped.Task)).WaitAsync(TimeSpan.FromSeconds(15));
        DisposeSources();
        // Only this session's scratch files are removed; completed exports are never discarded here.
        if (_sessionDirectory is not null && _receipt?.Completed == false) Directory.Delete(_sessionDirectory, true);
        _receipt = null;
        if (_sessionDirectory is not null) ActiveSessions.TryRemove(_sessionDirectory, out _);
        IsRecording = false;
        _paused = false;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public static async Task<IReadOnlyList<AudioRecordingResult>> RecoverAsync()
    {
        if (!Directory.Exists(SessionsDirectory)) return [];
        return await Task.Run(() =>
        {
            var recovered = new List<AudioRecordingResult>();
            string[] directories;
            try { directories = Directory.GetDirectories(SessionsDirectory); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                App.WriteQuickAccessLog($"Audio recovery deferred: {error.GetType().Name}");
                return (IReadOnlyList<AudioRecordingResult>)recovered;
            }
            foreach (var directory in directories)
            {
                if (ActiveSessions.ContainsKey(directory)) continue;
                try
                {
                    var receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllText(Path.Combine(directory, "session.json")));
                    if (receipt is { Completed: false }) recovered.Add(FinalizeSession(directory, receipt));
                    else if (receipt is { Completed: true })
                    {
                        CleanupCompletedPCM(directory);
                        if (!receipt.TranscriptionHandedOff && receipt.ProtectedTranscriptionConfiguration is not null)
                        {
                            using var reader = new MediaFoundationReader(receipt.OutputPath);
                            if (reader.TotalTime <= TimeSpan.Zero) throw new InvalidDataException("Saved audio is incomplete.");
                            recovered.Add(Result(receipt, reader.TotalTime));
                        }
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or
                    ArgumentException or CryptographicException or FormatException or InvalidOperationException or
                    NotSupportedException or System.Runtime.InteropServices.COMException)
                {
                    // Keep the receipt and all PCM for a later retry, without logging sensitive media paths.
                    App.WriteQuickAccessLog($"Audio recovery retained: {error.GetType().Name}");
                }
            }
            return (IReadOnlyList<AudioRecordingResult>)recovered;
        });
    }

    public static void MarkTranscriptionHandedOff(string outputPath)
        => MarkTranscriptionHandedOff(outputPath, SessionsDirectory);

    internal static void MarkTranscriptionHandedOff(string outputPath, string sessionsDirectory)
    {
        if (!Directory.Exists(sessionsDirectory)) return;
        foreach (var directory in Directory.EnumerateDirectories(sessionsDirectory))
        {
            var receiptPath = Path.Combine(directory, "session.json");
            Receipt? receipt;
            try { receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllText(receiptPath)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { continue; }
            if (receipt?.Completed != true || !string.Equals(receipt.OutputPath, outputPath, StringComparison.OrdinalIgnoreCase)) continue;
            SaveReceipt(directory, receipt with { TranscriptionHandedOff = true, ProtectedTranscriptionConfiguration = null });
            return;
        }
    }

    public static IReadOnlyList<AudioRecordingSource> GetTranscriptionSources(string outputPath)
    {
        if (!Directory.Exists(SessionsDirectory)) return [];
        foreach (var directory in Directory.EnumerateDirectories(SessionsDirectory))
        {
            try
            {
                var receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllText(Path.Combine(directory, "session.json")));
                if (receipt?.Completed != true || !string.Equals(receipt.OutputPath, outputPath, StringComparison.OrdinalIgnoreCase)) continue;
                return new[] { "system", "microphone" }.Select(role => new AudioRecordingSource(Path.Combine(directory, role + ".m4a"), role))
                    .Where(source => File.Exists(source.Path)).ToArray();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return [];
    }

    private static AudioRecordingResult FinalizeSession(string directory, Receipt receipt)
    {
        var inputs = new List<RawSourceWaveStream>();
        var sourceFiles = new List<FileStream>();
        try
        {
            var samples = new List<ISampleProvider>();
            foreach (var (role, enabled, volume) in new[] { ("system", receipt.SystemAudio, receipt.SystemVolume),
                ("microphone", receipt.Microphone, receipt.MicrophoneVolume) })
            {
                if (!enabled) continue;
                // RawSourceWaveStream does not own or dispose its underlying Stream.
                // Retain the file handles explicitly so Windows can delete PCM after encoding.
                var sourceFile = File.OpenRead(Path.Combine(directory, role + ".pcm"));
                sourceFiles.Add(sourceFile);
                var raw = new RawSourceWaveStream(sourceFile, Format);
                inputs.Add(raw);
                if (raw.Length < Format.BlockAlign) throw new InvalidDataException("No recoverable audio samples.");
                var rolePath = Path.Combine(directory, role + ".m4a");
                if (!File.Exists(rolePath)) Encode(raw, rolePath);
                raw.Position = 0;
                samples.Add(new VolumeSampleProvider(raw.ToSampleProvider()) { Volume = (float)volume });
            }
            if (samples.Count == 0) throw new InvalidDataException("No audio source.");
            var expected = inputs.Max(input => input.TotalTime);
            if (!File.Exists(receipt.OutputPath))
            {
                var mixed = new MixingSampleProvider(samples) { ReadFully = false };
                Encode(new SampleToWaveProvider16(mixed), receipt.OutputPath);
            }
            using (var check = new MediaFoundationReader(receipt.OutputPath))
            {
                if (check.TotalTime <= TimeSpan.Zero || check.TotalTime + TimeSpan.FromSeconds(0.5) < expected ||
                    check.Read(new byte[4096], 0, 4096) == 0) throw new InvalidDataException("Saved audio is incomplete.");
            }
            SaveReceipt(directory, receipt with { Completed = true });
            foreach (var input in inputs) input.Dispose();
            inputs.Clear();
            foreach (var sourceFile in sourceFiles) sourceFile.Dispose();
            sourceFiles.Clear();
            CleanupCompletedPCM(directory);
            return Result(receipt, expected);
        }
        finally
        {
            foreach (var input in inputs) input.Dispose();
            foreach (var sourceFile in sourceFiles) sourceFile.Dispose();
        }
    }

    private static void Encode(IWaveProvider provider, string destination)
    {
        var temporary = destination + ".pending.m4a";
        try
        {
            MediaFoundationEncoder.EncodeToAac(provider, temporary, 96000);
            using (var check = new MediaFoundationReader(temporary))
                if (check.TotalTime <= TimeSpan.Zero || check.Read(new byte[4096], 0, 4096) == 0)
                    throw new InvalidDataException("Audio encoding produced no samples.");
            File.Move(temporary, destination, false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static void SaveReceipt(string directory, Receipt receipt)
    {
        var path = Path.Combine(directory, "session.json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(receipt));
        File.Move(path + ".tmp", path, true);
    }

    private static AudioRecordingResult Result(Receipt receipt, TimeSpan duration) =>
        new(receipt.OutputPath, duration,
            receipt.TranscriptionHandedOff || receipt.ProtectedTranscriptionConfiguration is null
                ? null : UnprotectConfiguration(receipt.ProtectedTranscriptionConfiguration));

    internal static string ProtectConfiguration(RecordingTranscriptionConfiguration configuration)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(configuration);
        try { return Convert.ToBase64String(ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    internal static RecordingTranscriptionConfiguration UnprotectConfiguration(string protectedConfiguration)
    {
        var encrypted = Convert.FromBase64String(protectedConfiguration);
        byte[]? bytes = null;
        try
        {
            bytes = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<RecordingTranscriptionConfiguration>(bytes) ?? throw new JsonException();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encrypted);
            if (bytes is not null) CryptographicOperations.ZeroMemory(bytes);
        }
    }

    // The saved M4A and completed receipt are already durable. A locked scratch
    // file must not turn that successful save into an unrecoverable export retry.
    // Startup revisits completed sessions and independently retries this cleanup.
    internal static bool CleanupCompletedPCM(string directory, Action<string>? delete = null)
    {
        var cleaned = true;
        try
        {
            foreach (var path in Directory.EnumerateFiles(directory, "*.pcm"))
            {
                try { (delete ?? File.Delete)(path); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    cleaned = false;
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { cleaned = false; }
        return cleaned;
    }

    private static void Pad(Stream stream, long bytes)
    {
        var silence = new byte[8192];
        while (bytes > 0)
        {
            var count = (int)Math.Min(bytes, silence.Length);
            stream.Write(silence, 0, count);
            bytes -= count;
        }
    }

    private void DisposeSources()
    {
        foreach (var source in _sources)
        {
            source.Capture.Dispose();
            source.Device?.Dispose();
            source.Stream.Dispose();
        }
        _sources.Clear();
    }

    public void Dispose()
    {
        _clock.Stop();
        _stopping = true;
        IsRecording = false;
        DisposeSources();
        if (_sessionDirectory is not null) ActiveSessions.TryRemove(_sessionDirectory, out _);
    }
    private sealed record Receipt(string OutputPath, bool SystemAudio, bool Microphone,
        double SystemVolume, double MicrophoneVolume, bool Completed,
        string? ProtectedTranscriptionConfiguration = null, bool TranscriptionHandedOff = false);
    private sealed record SourceCapture(WasapiCapture Capture, MMDevice? Device, FileStream Stream)
    {
        public TaskCompletionSource<bool> Stopped { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}
