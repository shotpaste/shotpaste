using WpfPoint = System.Windows.Point;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingAnnotationStateTests
{
    [Fact]
    public void Toolbar_CanBeConstructedWithoutInitializationEventCrash()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                var app = new ShotPaste.Windows.App();
                app.InitializeComponent();
                try
                {
                    var ink = new RecordingInkWindow(new System.Drawing.Rectangle(0, 0, 320, 180));
                    var toolbar = new RecordingInkToolbarWindow(ink);
                    toolbar.Close();
                    ink.Close();
                }
                finally
                {
                    app.Shutdown();
                }
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(5)), "WPF toolbar construction did not complete.");

        Assert.Null(failure);
    }

    [Fact]
    public void Toolbar_UsesWindowsCaptureExclusionAffinity()
    {
        Assert.Equal(0x00000011u, RecordingInkToolbarWindow.CaptureExclusionAffinity);
    }

    [Fact]
    public void MaximumCount_RemovesOldestAnnotations()
    {
        var state = new RecordingAnnotationState
        {
            ClearMode = RecordingAnnotationClearMode.MaximumCount,
            MaximumCount = 2
        };

        var first = state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(0, 0), new WpfPoint(1, 1)]);
        state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(2, 2), new WpfPoint(3, 3)]);
        state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(4, 4), new WpfPoint(5, 5)]);

        Assert.Equal(2, state.Annotations.Count);
        Assert.DoesNotContain(state.Annotations, annotation => annotation.Id == first.Id);
    }

    [Fact]
    public void MaximumCount_RaisesRemovalEventForVisualSynchronization()
    {
        var state = new RecordingAnnotationState
        {
            ClearMode = RecordingAnnotationClearMode.MaximumCount,
            MaximumCount = 1
        };
        var removed = new List<Guid>();
        state.Annotations.CollectionChanged += (_, change) =>
        {
            if (change.OldItems is not null)
                removed.AddRange(change.OldItems.Cast<RecordingAnnotation>().Select(annotation => annotation.Id));
        };
        var first = state.Add(RecordingAnnotationTool.Line, [new WpfPoint(0, 0), new WpfPoint(2, 2)]);

        state.Add(RecordingAnnotationTool.Line, [new WpfPoint(4, 4), new WpfPoint(6, 6)]);

        Assert.Contains(first.Id, removed);
    }

    [Fact]
    public void AfterSeconds_RemovesOnlyExpiredAnnotations()
    {
        var state = new RecordingAnnotationState
        {
            ClearMode = RecordingAnnotationClearMode.AfterSeconds,
            ClearAfter = TimeSpan.FromSeconds(5)
        };
        var now = DateTimeOffset.UtcNow;
        state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(0, 0)], now.AddSeconds(-6));
        var current = state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(1, 1)], now.AddSeconds(-2));

        state.Tick(now);

        var remaining = Assert.Single(state.Annotations);
        Assert.Equal(current.Id, remaining.Id);
    }

    [Fact]
    public void ToolPolicies_ExpireAndLimitEachToolIndependently()
    {
        var state = new RecordingAnnotationState();
        state.SetPolicy(RecordingAnnotationTool.Pencil,
            new RecordingAnnotationPolicy(RecordingAnnotationClearMode.MaximumCount, TimeSpan.FromSeconds(5), 1));
        state.SetPolicy(RecordingAnnotationTool.Arrow,
            new RecordingAnnotationPolicy(RecordingAnnotationClearMode.AfterSeconds, TimeSpan.FromSeconds(2), 20));
        var now = DateTimeOffset.UtcNow;
        state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(0, 0)], now.AddSeconds(-5));
        var pencil = state.Add(RecordingAnnotationTool.Pencil, [new WpfPoint(1, 1)], now);
        state.Add(RecordingAnnotationTool.Arrow, [new WpfPoint(2, 2)], now.AddSeconds(-3));

        state.Tick(now);

        var remaining = Assert.Single(state.Annotations);
        Assert.Equal(pencil.Id, remaining.Id);
    }

    [Fact]
    public void TimedPolicy_FadeIsDeterministic()
    {
        var state = new RecordingAnnotationState
        {
            FadeEnabled = true,
            FadeDuration = TimeSpan.FromSeconds(1)
        };
        state.SetPolicy(RecordingAnnotationTool.Line,
            new RecordingAnnotationPolicy(RecordingAnnotationClearMode.AfterSeconds, TimeSpan.FromSeconds(2), 10));
        var now = DateTimeOffset.UtcNow;
        var annotation = state.Add(RecordingAnnotationTool.Line, [new WpfPoint(1, 1)], now);

        Assert.Equal(RecordingAnnotationClearMode.AfterSeconds, annotation.ClearMode);
        Assert.Equal(0.5d, state.GetOpacity(annotation, now.AddSeconds(1.5)), 3);
    }
}
