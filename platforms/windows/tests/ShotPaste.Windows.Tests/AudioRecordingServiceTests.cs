using ShotPaste.Windows.Services;
using System.Text.Json;

namespace ShotPaste.Windows.Tests;

public sealed class AudioRecordingServiceTests
{
    [Fact]
    public void CloudSnapshotUsesCurrentUserProtectionAndPreservesOriginalSettings()
    {
        var configuration = new RecordingTranscriptionConfiguration("speech-private-value", "access-private-value",
            "secret-private-value", "shotpaste-tmp-test-bucket", Guid.NewGuid().ToString(), "ja", true,
            "https://example.test/v1", "test-model", "agent-private-value");
        var protectedValue = AudioRecordingService.ProtectConfiguration(configuration);
        Assert.DoesNotContain(configuration.ApiKey, protectedValue);
        Assert.DoesNotContain(configuration.SecretKey, protectedValue);
        Assert.DoesNotContain(configuration.AgentApiKey, protectedValue);
        Assert.Equal(configuration, AudioRecordingService.UnprotectConfiguration(protectedValue));
    }

    [Fact]
    public void DurableHandoffClearsSnapshotOnlyForMatchingCompletedRecording()
    {
        var root = Path.Combine(Path.GetTempPath(), "ShotPaste-audio-handoff-" + Guid.NewGuid().ToString("N"));
        var completed = Path.Combine(root, "completed");
        var unfinished = Path.Combine(root, "unfinished");
        Directory.CreateDirectory(completed); Directory.CreateDirectory(unfinished);
        var output = Path.Combine(root, "audio.m4a");
        try
        {
            File.WriteAllText(output, "saved audio must remain untouched");
            foreach (var directory in new[] { completed, unfinished })
                File.WriteAllText(Path.Combine(directory, "session.json"), JsonSerializer.Serialize(new
                {
                    OutputPath = output, SystemAudio = true, Microphone = false,
                    SystemVolume = 1d, MicrophoneVolume = 1d, Completed = directory == completed,
                    ProtectedTranscriptionConfiguration = "protected original profile", TranscriptionHandedOff = false
                }));
            AudioRecordingService.MarkTranscriptionHandedOff(output, root);
            using var saved = JsonDocument.Parse(File.ReadAllText(Path.Combine(completed, "session.json")));
            using var active = JsonDocument.Parse(File.ReadAllText(Path.Combine(unfinished, "session.json")));
            Assert.True(saved.RootElement.GetProperty("TranscriptionHandedOff").GetBoolean());
            Assert.Equal(JsonValueKind.Null, saved.RootElement.GetProperty("ProtectedTranscriptionConfiguration").ValueKind);
            Assert.False(active.RootElement.GetProperty("TranscriptionHandedOff").GetBoolean());
            Assert.Equal("saved audio must remain untouched", File.ReadAllText(output));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void CompletedScratchCleanupRetainsLockedPCMAndCanRetryWithoutReencoding()
    {
        var directory = Path.Combine(Path.GetTempPath(), "ShotPaste-audio-cleanup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var locked = Path.Combine(directory, "microphone.pcm");
            var removable = Path.Combine(directory, "system.pcm");
            var transcriptSource = Path.Combine(directory, "system.m4a");
            File.WriteAllText(locked, "pcm");
            File.WriteAllText(removable, "pcm");
            File.WriteAllText(transcriptSource, "saved source");
            Assert.False(AudioRecordingService.CleanupCompletedPCM(directory, path =>
            {
                if (path == locked) throw new IOException("Locked by another process.");
                File.Delete(path);
            }));
            Assert.True(File.Exists(locked));
            Assert.False(File.Exists(removable));
            Assert.True(File.Exists(transcriptSource));
            Assert.True(AudioRecordingService.CleanupCompletedPCM(directory));
            Assert.False(File.Exists(locked));
            Assert.True(File.Exists(transcriptSource));
        }
        finally { Directory.Delete(directory, true); }
    }
}
