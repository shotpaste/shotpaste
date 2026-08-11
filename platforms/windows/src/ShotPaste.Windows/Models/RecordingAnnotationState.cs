using System.Collections.ObjectModel;
using WpfPoint = System.Windows.Point;

namespace ShotPaste.Windows.Models;

public sealed record RecordingAnnotation(
    Guid Id,
    RecordingAnnotationTool Tool,
    string Color,
    double StrokeWidth,
    IReadOnlyList<WpfPoint> Points,
    DateTimeOffset CreatedAt,
    RecordingAnnotationClearMode ClearMode,
    TimeSpan ClearAfter,
    int MaximumCount);

public sealed record RecordingAnnotationPolicy(
    RecordingAnnotationClearMode ClearMode,
    TimeSpan ClearAfter,
    int MaximumCount)
{
    public static RecordingAnnotationPolicy Default { get; } =
        new(RecordingAnnotationClearMode.Manual, TimeSpan.FromSeconds(5), 12);
}

/// <summary>
/// Platform-neutral state for live recording annotations. The WPF overlay only
/// renders this state; expiry and count limits stay deterministic and testable.
/// </summary>
public sealed class RecordingAnnotationState
{
    public ObservableCollection<RecordingAnnotation> Annotations { get; } = [];
    public RecordingAnnotationTool SelectedTool { get; set; } = RecordingAnnotationTool.Pencil;
    public string StrokeColor { get; set; } = "#FF7C3AED";
    public double StrokeWidth { get; set; } = 4;
    public RecordingAnnotationClearMode ClearMode { get; set; } = RecordingAnnotationClearMode.Manual;
    public TimeSpan ClearAfter { get; set; } = TimeSpan.FromSeconds(5);
    public int MaximumCount { get; set; } = 12;
    public Dictionary<RecordingAnnotationTool, RecordingAnnotationPolicy> ToolPolicies { get; } = [];
    public bool FadeEnabled { get; set; } = true;
    public TimeSpan FadeDuration { get; set; } = TimeSpan.FromMilliseconds(350);

    public RecordingAnnotationPolicy GetPolicy(RecordingAnnotationTool tool)
    {
        if (ToolPolicies.TryGetValue(tool, out var policy)) return Normalize(policy);
        return Normalize(new RecordingAnnotationPolicy(ClearMode, ClearAfter, MaximumCount));
    }

    public void SetPolicy(RecordingAnnotationTool tool, RecordingAnnotationPolicy policy)
    {
        policy = Normalize(policy);
        ToolPolicies[tool] = policy;
        if (tool == SelectedTool)
        {
            ClearMode = policy.ClearMode;
            ClearAfter = policy.ClearAfter;
            MaximumCount = policy.MaximumCount;
        }
        EnforceCountLimit(tool, policy.MaximumCount);
    }

    public RecordingAnnotation Add(
        RecordingAnnotationTool tool,
        IEnumerable<WpfPoint> points,
        DateTimeOffset? createdAt = null)
    {
        var policy = GetPolicy(tool);
        var annotation = new RecordingAnnotation(
            Guid.NewGuid(),
            tool,
            StrokeColor,
            Math.Clamp(StrokeWidth, 1, 40),
            points.ToArray(),
            createdAt ?? DateTimeOffset.UtcNow,
            policy.ClearMode,
            policy.ClearAfter,
            policy.MaximumCount);
        Annotations.Add(annotation);
        EnforceCountLimit(tool, policy.MaximumCount);
        return annotation;
    }

    public int RemoveExpired(DateTimeOffset now)
    {
        var expired = Annotations
            .Where(annotation => annotation.ClearMode == RecordingAnnotationClearMode.AfterSeconds &&
                                 annotation.ClearAfter > TimeSpan.Zero &&
                                 now - annotation.CreatedAt >= annotation.ClearAfter)
            .ToArray();
        foreach (var annotation in expired) Annotations.Remove(annotation);
        return expired.Length;
    }

    public void Tick(DateTimeOffset now)
    {
        RemoveExpired(now);
        foreach (var tool in Enum.GetValues<RecordingAnnotationTool>())
            EnforceCountLimit(tool, GetPolicy(tool).MaximumCount);
    }

    public double GetOpacity(RecordingAnnotation annotation, DateTimeOffset now)
    {
        if (!FadeEnabled || annotation.ClearMode != RecordingAnnotationClearMode.AfterSeconds ||
            annotation.ClearAfter <= TimeSpan.Zero || FadeDuration <= TimeSpan.Zero)
            return 1d;
        var remaining = annotation.ClearAfter - (now - annotation.CreatedAt);
        if (remaining <= TimeSpan.Zero) return 0d;
        var fade = FadeDuration > annotation.ClearAfter ? annotation.ClearAfter : FadeDuration;
        if (remaining >= fade) return 1d;
        return Math.Clamp(remaining.TotalMilliseconds / Math.Max(1d, fade.TotalMilliseconds), 0d, 1d);
    }

    public void Clear() => Annotations.Clear();

    private void EnforceCountLimit(RecordingAnnotationTool tool, int requestedLimit)
    {
        var limited = Annotations
            .Where(annotation => annotation.Tool == tool &&
                                 annotation.ClearMode == RecordingAnnotationClearMode.MaximumCount)
            .OrderBy(annotation => annotation.CreatedAt)
            .ToList();
        var limit = Math.Clamp(requestedLimit, 1, 200);
        while (limited.Count > limit)
        {
            var oldest = limited[0];
            limited.RemoveAt(0);
            Annotations.Remove(oldest);
        }
    }

    private static RecordingAnnotationPolicy Normalize(RecordingAnnotationPolicy policy) => policy with
    {
        ClearAfter = TimeSpan.FromSeconds(Math.Clamp(policy.ClearAfter.TotalSeconds, 1d, 3600d)),
        MaximumCount = Math.Clamp(policy.MaximumCount, 1, 200)
    };
}
