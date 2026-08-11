using Drawing = System.Drawing;

namespace ShotPaste.Windows.Models;

public sealed record SensitiveRegion(string Text, Drawing.Rectangle Bounds, SensitiveRegionKind Kind);

public enum SensitiveRegionKind
{
    Email,
    Phone,
    Url,
    CreditCard,
    IdentityNumber,
    ApiKey,
    Unknown
}

public enum RecordingAnnotationTool
{
    Selection,
    Rectangle,
    Oval,
    Arrow,
    Line,
    Pencil,
    Highlighter
}

public enum RecordingAnnotationClearMode
{
    Manual,
    AfterSeconds,
    MaximumCount
}
