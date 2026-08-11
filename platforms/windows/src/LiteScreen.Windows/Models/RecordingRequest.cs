using Drawing = System.Drawing;

namespace LiteScreen.Windows.Models;

public enum RecordingOutputMode
{
    Video,
    Gif
}

public enum RecordingQuality
{
    High,
    Medium,
    Low
}

public enum RecordingTargetKind
{
    Region
}

/// <summary>
/// The One Shot recording handoff captures the selected region.
/// </summary>
public sealed record RecordingTarget(
    RecordingTargetKind Kind,
    Drawing.Rectangle Bounds)
{
    public static RecordingTarget Region(Drawing.Rectangle bounds) =>
        new(RecordingTargetKind.Region, bounds);
}

public sealed record RecordingRequest(
    RecordingTarget Target,
    RecordingOutputMode OutputMode,
    bool SystemAudio,
    bool Microphone,
    RecordingQuality Quality,
    bool IncludeCursor,
    bool HighlightMouseClicks,
    bool ShowKeystrokes,
    bool DimNonSelectedArea,
    string MicrophoneDeviceId = "",
    string MicrophoneDeviceName = "",
    double SystemAudioVolume = 0.8d,
    double MicrophoneVolume = 0.8d,
    bool IncludeLiteScreen = false)
{
    public bool Gif => OutputMode == RecordingOutputMode.Gif;
}
