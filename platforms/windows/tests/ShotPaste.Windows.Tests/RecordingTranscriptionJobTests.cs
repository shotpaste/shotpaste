using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingTranscriptionJobTests
{
    [Fact]
    public void FailedIntentPersistence_DoesNotMarkTaskAsSubmitted()
    {
        var previous = Guid.NewGuid();
        var part = new RecordingTranscriptionPart { RequestId = previous };
        Assert.Throws<IOException>(() => RecordingTranscriptionJobs.PersistSubmissionIntent(part, () => throw new IOException("disk full")));
        Assert.False(part.SubmitAttempted);
        Assert.Equal(previous, part.RequestId);
    }
    [Fact]
    public void FailedRawPersistence_DoesNotMakeCloudAudioEligibleForResultCleanup()
    {
        var part = new RecordingTranscriptionPart { CleanupPending = true };
        var transcript = new RecordingTranscript("original", 1000, [new("original", 0, 1000, null)]);
        Assert.Throws<IOException>(() => RecordingTranscriptionJobs.PersistTranscript(part, transcript, () => throw new IOException("disk full")));
        Assert.Null(part.Transcript);
        Assert.True(part.CleanupPending);
    }
    [Fact]
    public void Split_UsesNonoverlappingOffsetsAndKeepsOriginalSourceIdentity()
    {
        var config = new RecordingTranscriptionConfiguration("key", "ak", "sk", "shotpaste-tmp-fixture-debug", Guid.NewGuid().ToString("N"), "auto");
        var first = new RecordingTranscriptionPart { SourcePath = "C:\\recording.m4a", Role = "system", SourceHash = "hash", StartMilliseconds = 1234, DurationMilliseconds = 20_000_000 };
        var job = new RecordingTranscriptionJob { Parts = [first] };
        var originalList = job.Parts;
        RecordingTranscriptionJobs.SplitPreparedPart(job, 0, 14_399_900, config);
        Assert.NotSame(originalList, job.Parts);
        Assert.Equal(2, job.Parts.Count);
        var remainder = job.Parts[1];
        Assert.Equal(first.StartMilliseconds + first.DurationMilliseconds, remainder.StartMilliseconds);
        Assert.Equal(20_000_000, first.DurationMilliseconds + remainder.DurationMilliseconds);
        Assert.Equal(first.SourcePath, remainder.SourcePath);
        Assert.Equal(first.SourceHash, remainder.SourceHash);
        Assert.Equal("system", remainder.Role);
        Assert.StartsWith(config.Prefix, remainder.ObjectKey, StringComparison.Ordinal);
    }
    [Fact]
    public void TimedTranscript_UsesFullRecordingOffsetsWithoutTwentyFourHourRollover()
    {
        var job = new RecordingTranscriptionJob { Parts = [new() { Role = "system", StartMilliseconds = 90_000_000,
            Transcript = new("later", 1000, [new("later", 200, 800, null)]) }] };
        Assert.Contains("25:00:00.200", job.TimedText(), StringComparison.Ordinal);
        Assert.Contains("25:00:00.800", job.TimedText(), StringComparison.Ordinal);
    }
}
