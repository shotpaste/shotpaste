using Drawing = System.Drawing;

namespace ShotPaste.Windows.Models;

public enum OneShotMode
{
    Screenshot,
    Scrolling,
    Recording,
    Ocr,
    Clipboard
}

public sealed record OneShotRecordingOptions(
    RecordingOutputMode OutputMode,
    bool IncludeCursor,
    bool SystemAudio,
    bool Microphone);

public sealed class OneShotResult(
    OneShotMode mode,
    Drawing.Rectangle rectangle,
    Drawing.Bitmap? image = null,
    bool pinRequested = false,
    OneShotRecordingOptions? recordingOptions = null,
    bool screenshotCommitted = false) : IDisposable
{
    public OneShotMode Mode { get; } = mode;
    public Drawing.Rectangle Rectangle { get; } = rectangle;
    public Drawing.Bitmap? Image { get; } = image;
    public bool PinRequested { get; } = pinRequested;
    public OneShotRecordingOptions? RecordingOptions { get; } = recordingOptions;
    public bool ScreenshotCommitted { get; } = screenshotCommitted;

    public void Dispose() => Image?.Dispose();
}
