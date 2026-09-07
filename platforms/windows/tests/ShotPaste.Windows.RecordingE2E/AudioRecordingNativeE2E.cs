using System.IO;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using ShotPaste.Windows.Services;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace ShotPaste.Windows.RecordingE2E;

/// <summary>
/// Exercises the actual render endpoint, WASAPI loopback, recovery PCM and AAC encoder.
/// Only a generated tone is played; microphone and paid cloud work are deliberately excluded.
/// Product tray/controller interaction remains covered separately from these service checks.
/// </summary>
internal static class AudioRecordingNativeE2E
{
    private const double ToneFrequency = 997;

    internal static async Task<object> RunAsync(string outputRoot)
    {
        var root = Path.Combine(outputRoot, "audio-native");
        Directory.CreateDirectory(root);
        // A fresh root prevents earlier recovery fixtures from changing this run's evidence.
        var dataRoot = Path.Combine(root, Guid.NewGuid().ToString("N"));
        var originalRoot = AppPaths.Root;
        AppPaths.ConfigureTestRoot(dataRoot);
        AppPaths.EnsureCreated();
        try
        {
            using var devices = new MMDeviceEnumerator();
            using var endpoint = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            using var playback = new WasapiOut(endpoint, AudioClientShareMode.Shared, false, 100);
            playback.Init(new SignalGenerator(48000, 2)
            {
                Type = SignalGeneratorType.Sin,
                Frequency = ToneFrequency,
                Gain = 0.04
            }.ToWaveProvider16());
            playback.Play();
            await Task.Delay(350);

            var pauseAndSave = await VerifyPauseAndSaveAsync();
            var discardAndRestart = await VerifyDiscardAndRestartAsync();
            playback.Stop();

            var outputs = Directory.GetFiles(AppPaths.Captures);
            if (outputs.Length != 2 || outputs.Any(path => Path.GetExtension(path) != ".m4a"))
                throw new InvalidOperationException("Native audio lifecycle should save exactly two audio-only M4A files.");
            if (Directory.EnumerateFiles(dataRoot, "*.pcm", SearchOption.AllDirectories).Any() ||
                Directory.EnumerateFiles(dataRoot, "*.pending.m4a", SearchOption.AllDirectories).Any())
                throw new InvalidOperationException("Successful native audio saving retained PCM or incomplete encoding files.");
            if ((await AudioRecordingService.RecoverAsync()).Count != 0)
                throw new InvalidOperationException("Completed local-only audio sessions were offered as new recovery work.");
            var ui = await AudioRecordingUiE2E.RunAsync(root);

            var result = new
            {
                GeneratedAt = DateTimeOffset.Now,
                Evidence = "Real Windows WASAPI loopback capture of a locally generated tone; native AAC encoding and decoding",
                Endpoint = endpoint.FriendlyName,
                EndpointState = endpoint.State.ToString(),
                ToneFrequencyHertz = ToneFrequency,
                PauseAndSave = pauseAndSave,
                DiscardAndRestart = discardAndRestart,
                Ui = ui,
                SuccessfulRecoveryPcmCleanup = true,
                NoRepeatedRecovery = true,
                Microphone = "Not recorded: requires a controlled microphone fixture or separate manual hardware acceptance",
                Cloud = "Not contacted",
                ProductUi = "Production preparation and results windows with local fixtures; tray, shortcut and controller routing are not asserted"
            };
            File.WriteAllText(Path.Combine(root, "summary.json"),
                JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
            return result;
        }
        finally
        {
            AppPaths.ConfigureTestRoot(originalRoot);
        }
    }

    private static AudioRecordingOptions Options() => new(
        SystemAudio: true, Microphone: false, MicrophoneDeviceId: "",
        SystemVolume: 1, MicrophoneVolume: 1, OutputDirectory: AppPaths.Captures);

    private static async Task<object> VerifyPauseAndSaveAsync()
    {
        using var recording = new AudioRecordingService();
        var unexpectedStops = 0;
        recording.CaptureStopped += (_, _) => Interlocked.Increment(ref unexpectedStops);
        recording.Start(Options());
        await Task.Delay(1400);
        if (!recording.IsRecording || recording.CaptureError is not null)
            throw new InvalidOperationException("WASAPI capture did not remain active.");

        recording.TogglePause();
        var pausedAt = recording.Elapsed;
        var pcm = Directory.GetFiles(AppPaths.Root, "system.pcm", SearchOption.AllDirectories).Single();
        var pausedBytes = new FileInfo(pcm).Length;
        await Task.Delay(1000);
        if (!recording.IsPaused || recording.Elapsed != pausedAt || new FileInfo(pcm).Length != pausedBytes)
            throw new InvalidOperationException("Pausing audio did not freeze elapsed time and recorded PCM.");
        recording.TogglePause();
        await Task.Delay(1100);
        if (recording.IsPaused || recording.Elapsed <= pausedAt + TimeSpan.FromMilliseconds(700))
            throw new InvalidOperationException("Resuming audio did not resume the recording clock.");

        var stop = recording.StopAsync();
        if (!ReferenceEquals(stop, recording.StopAsync()))
            throw new InvalidOperationException("Duplicate audio stop did not share a single finalizer.");
        var saved = await stop.WaitAsync(TimeSpan.FromSeconds(30));
        if (recording.IsRecording || recording.IsPaused || recording.CaptureError is not null || unexpectedStops != 0)
            throw new InvalidOperationException("Intentional stop left an active/error state or emitted an unexpected stop event.");
        var encoded = await InspectAudioAsync(saved, recording.Elapsed);
        return new
        {
            Saved = encoded,
            PausedClockAndPcmFrozen = true,
            ResumeContinuedCapture = true,
            StopFinalizerShared = true,
            UnexpectedStopEvents = unexpectedStops
        };
    }

    private static async Task<object> VerifyDiscardAndRestartAsync()
    {
        using var recording = new AudioRecordingService();
        var existingSessions = Directory.GetDirectories(Path.Combine(AppPaths.Root, "AudioRecordingSessions"));
        recording.Start(Options());
        var generation = recording.CaptureGeneration;
        await Task.Delay(600);
        recording.TogglePause();
        await recording.DiscardAsync().WaitAsync(TimeSpan.FromSeconds(20));
        var remainingSessions = Directory.GetDirectories(Path.Combine(AppPaths.Root, "AudioRecordingSessions"));
        if (recording.IsRecording || recording.IsPaused ||
            !existingSessions.Order().SequenceEqual(remainingSessions.Order()) ||
            Directory.GetFiles(AppPaths.Captures).Length != 1)
            throw new InvalidOperationException("Discarding paused audio did not remove only the current scratch session.");

        recording.Start(Options());
        if (recording.CaptureGeneration <= generation || recording.IsPaused)
            throw new InvalidOperationException("Restarted native capture retained its old generation or pause state.");
        await Task.Delay(1400);
        var saved = await recording.StopAsync().WaitAsync(TimeSpan.FromSeconds(30));
        if (recording.CaptureError is not null)
            throw new InvalidOperationException("The restarted WASAPI recording stopped with a capture error.");
        return new
        {
            Saved = await InspectAudioAsync(saved, recording.Elapsed),
            PausedDiscardRemovedOnlyCurrentSession = true,
            RestartUsedNewCaptureGeneration = true
        };
    }

    private static async Task<object> InspectAudioAsync(AudioRecordingResult saved, TimeSpan activeDuration)
    {
        var file = await StorageFile.GetFileFromPathAsync(saved.Path);
        var profile = await MediaEncodingProfile.CreateFromFileAsync(file);
        if (profile.Audio is null || profile.Video is { Width: > 0 } ||
            !profile.Audio.Subtype.Equals(MediaEncodingSubtypes.Aac, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Standalone native audio did not produce an audio-only AAC asset.");

        var sources = AudioRecordingService.GetTranscriptionSources(saved.Path);
        if (sources.Count != 1 || sources[0].Role != "system")
            throw new InvalidOperationException("Saved audio did not retain exactly the selected system source attribution.");
        using var reader = new MediaFoundationReader(saved.Path);
        if (Math.Abs((reader.TotalTime - activeDuration).TotalSeconds) > 0.45)
            throw new InvalidOperationException($"Saved audio duration {reader.TotalTime} differs from active time {activeDuration}; pause time may have leaked into output.");
        var samples = reader.ToSampleProvider();
        var channels = samples.WaveFormat.Channels;
        var sampleRate = samples.WaveFormat.SampleRate;
        var buffer = new float[Math.Max(1, sampleRate / 10) * channels];
        double maximumToneFraction = 0;
        double maximumRms = 0;
        int read;
        while ((read = samples.Read(buffer, 0, buffer.Length)) > 0)
        {
            var frames = read / channels;
            if (frames < sampleRate / 20) continue;
            double energy = 0, sine = 0, cosine = 0;
            for (var frame = 0; frame < frames; frame++)
            {
                double sample = 0;
                for (var channel = 0; channel < channels; channel++) sample += buffer[frame * channels + channel];
                sample /= channels;
                var phase = 2 * Math.PI * ToneFrequency * frame / sampleRate;
                energy += sample * sample;
                sine += sample * Math.Sin(phase);
                cosine += sample * Math.Cos(phase);
            }
            maximumRms = Math.Max(maximumRms, Math.Sqrt(energy / frames));
            if (energy > 1e-8)
                maximumToneFraction = Math.Max(maximumToneFraction, 2 * (sine * sine + cosine * cosine) / (frames * energy));
        }
        // Merely decoding nonempty AAC can accept synthesized silence. Require the played tone.
        if (maximumRms < 0.0005 || maximumToneFraction < 0.45)
            throw new InvalidOperationException($"Native loopback did not preserve the generated tone (RMS={maximumRms:F5}, tone fraction={maximumToneFraction:F3}).");
        return new
        {
            Path = saved.Path,
            AudioSubtype = profile.Audio.Subtype,
            AudioOnly = true,
            Duration = reader.TotalTime,
            ActiveDuration = activeDuration,
            SourceRole = sources.Single().Role,
            MaximumRms = maximumRms,
            MaximumToneFraction = maximumToneFraction,
            NativeDecodeSucceeded = true
        };
    }
}
