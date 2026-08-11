using Windows.Media.Core;
using Windows.Media.MediaProperties;

namespace LiteScreen.Windows.Services;

public sealed record RecordingMediaSupport(
    bool ProbeCompleted,
    bool HevcEncoderAvailable,
    int HevcEncoderCount,
    string Detail);

public sealed record RecordingFormatDecision(
    string RequestedContainer,
    string RequestedCodec,
    string ActualContainer,
    string ActualCodec,
    string Extension,
    string? FallbackReason)
{
    public bool UsedFallback => !string.IsNullOrWhiteSpace(FallbackReason);
}

/// <summary>
/// Queries the Media Foundation codec inventory exposed by Windows and turns
/// cross-platform format preferences into a recording plan that this Windows
/// build can actually produce. ScreenRecorderLib 6.6 writes ISO MP4 only.
/// </summary>
public static class RecordingFormatCapabilityService
{
    public const string MovUnavailable = "mov-container-unavailable";
    public const string HevcUnavailable = "hevc-encoder-unavailable";
    public const string GifIntermediate = "gif-intermediate-requires-h264";

    private static readonly object Sync = new();
    private static Task<RecordingMediaSupport>? _probe;
    private static RecordingMediaSupport _current = new(false, false, 0, "Codec probe has not completed.");

    public static RecordingMediaSupport Current => Volatile.Read(ref _current);

    public static Task<RecordingMediaSupport> ProbeAsync(bool force = false)
    {
        lock (Sync)
        {
            if (force || _probe is null) _probe = ProbeCoreAsync();
            return _probe;
        }
    }

    private static async Task<RecordingMediaSupport> ProbeCoreAsync()
    {
        RecordingMediaSupport result;
        try
        {
            var codecs = await new CodecQuery().FindAllAsync(
                CodecKind.Video,
                CodecCategory.Encoder,
                MediaEncodingSubtypes.Hevc);
            result = new RecordingMediaSupport(
                ProbeCompleted: true,
                HevcEncoderAvailable: codecs.Count > 0,
                HevcEncoderCount: codecs.Count,
                Detail: codecs.Count > 0
                    ? $"Windows reported {codecs.Count} HEVC encoder(s)."
                    : "Windows did not report an HEVC encoder. H.264 will be used.");
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or InvalidOperationException or NotSupportedException or System.Runtime.InteropServices.COMException)
        {
            result = new RecordingMediaSupport(
                ProbeCompleted: true,
                HevcEncoderAvailable: false,
                HevcEncoderCount: 0,
                Detail: $"Codec query failed ({exception.GetType().Name}). H.264 will be used.");
        }

        Volatile.Write(ref _current, result);
        return result;
    }

    public static RecordingFormatDecision Resolve(
        string? requestedContainer,
        string? requestedCodec,
        RecordingMediaSupport support,
        bool gifIntermediate = false)
    {
        var container = requestedContainer?.Equals("Mov", StringComparison.OrdinalIgnoreCase) == true ? "Mov" : "Mp4";
        var codec = requestedCodec?.Equals("Hevc", StringComparison.OrdinalIgnoreCase) == true ? "Hevc" : "H264";
        var reasons = new List<string>();

        if (container == "Mov") reasons.Add(MovUnavailable);
        var actualCodec = codec;
        if (gifIntermediate && codec == "Hevc")
        {
            actualCodec = "H264";
            reasons.Add(GifIntermediate);
        }
        else if (codec == "Hevc" && !support.HevcEncoderAvailable)
        {
            actualCodec = "H264";
            reasons.Add(HevcUnavailable);
        }

        return new RecordingFormatDecision(
            container,
            codec,
            "Mp4",
            actualCodec,
            ".mp4",
            reasons.Count == 0 ? null : string.Join(',', reasons));
    }
}
