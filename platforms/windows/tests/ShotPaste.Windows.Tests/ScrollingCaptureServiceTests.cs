using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class ScrollingCaptureServiceTests
{
    [Theory]
    [InlineData(100, 100, 100, 100)]
    [InlineData(1000, 500, 220, 110)]
    [InlineData(1000, 4000, 105, 420)]
    public void GetPreviewSizeFitsInsideLivePreviewRail(int width, int height, int expectedWidth, int expectedHeight)
    {
        var size = ScrollingCaptureService.GetPreviewSize(width, height);

        Assert.Equal(expectedWidth, size.Width);
        Assert.Equal(expectedHeight, size.Height);
    }

    [Fact]
    public void GetPreviewSizeRejectsInvalidDimensions()
    {
        Assert.True(ScrollingCaptureService.GetPreviewSize(0, 100).IsEmpty);
        Assert.True(ScrollingCaptureService.GetPreviewSize(100, -1).IsEmpty);
    }

    [Fact]
    public void ResolveWheelBurstDirection_UsesAccumulatedVerticalDelta()
    {
        var snapshot = new MouseWheelSnapshot(
            SequenceNumber: 4,
            Timestamp: 1,
            CumulativeDelta: -480,
            PositiveEventCount: 0,
            NegativeEventCount: 4,
            Direction: -1);

        var direction = ScrollingCaptureService.ResolveWheelBurstDirection(
            snapshot, 0, 0, 0, out var mixedDirections);

        Assert.Equal(-1, direction);
        Assert.False(mixedDirections);
    }

    [Fact]
    public void ResolveWheelBurstDirection_RejectsMixedDirectionBatch()
    {
        var snapshot = new MouseWheelSnapshot(
            SequenceNumber: 5,
            Timestamp: 1,
            CumulativeDelta: -120,
            PositiveEventCount: 2,
            NegativeEventCount: 3,
            Direction: -1);

        _ = ScrollingCaptureService.ResolveWheelBurstDirection(
            snapshot, 0, 0, 0, out var mixedDirections);

        Assert.True(mixedDirections);
    }

    [Theory]
    [InlineData(1, false)]
    [InlineData(2, false)]
    [InlineData(3, true)]
    [InlineData(5, true)]
    public void IsConfirmedBoundary_RequiresRepeatedDuplicateFrames(int streak, bool expected)
    {
        Assert.Equal(expected, ScrollingCaptureService.IsConfirmedBoundary(streak));
    }

    [Theory]
    [InlineData(false, 3, false)]
    [InlineData(false, 20, false)]
    [InlineData(true, 2, false)]
    [InlineData(true, 3, true)]
    public void ShouldConfirmAutomaticBoundary_RequiresObservedMovement(
        bool hasAcceptedMovement,
        int streak,
        bool expected)
    {
        Assert.Equal(
            expected,
            ScrollingCaptureService.ShouldConfirmAutomaticBoundary(hasAcceptedMovement, streak));
    }

    [Theory]
    [InlineData(false, false, false, false)]
    [InlineData(true, false, false, true)]
    [InlineData(false, true, false, true)]
    [InlineData(false, false, true, true)]
    public void ShouldLeaveWheelWait_RespondsToWheelAutomaticModeOrFinish(
        bool hasNewWheelEvent,
        bool automaticScrollEnabled,
        bool finishRequested,
        bool expected)
    {
        Assert.Equal(
            expected,
            ScrollingCaptureService.ShouldLeaveWheelWait(
                hasNewWheelEvent,
                automaticScrollEnabled,
                finishRequested));
    }

    [Fact]
    public void AppendFrameBatch_PreservesIntermediateFramesDuringFastScroll()
    {
        const int width = 180;
        const int viewportHeight = 500;
        using var content = MakePattern(width, 1_100);
        using var first = content.Clone(
            new System.Drawing.Rectangle(0, 0, width, viewportHeight), content.PixelFormat);
        using var intermediate = content.Clone(
            new System.Drawing.Rectangle(0, 300, width, viewportHeight), content.PixelFormat);
        using var latest = content.Clone(
            new System.Drawing.Rectangle(0, 600, width, viewportHeight), content.PixelFormat);

        using (var latestOnly = new ScrollingStitcher())
        {
            Assert.Equal(StitchResult.Added, latestOnly.Append(first));
            Assert.Equal(StitchResult.NoMatch, latestOnly.Append(latest, expectedWheelDirection: -1));
        }

        using var stitcher = new ScrollingStitcher();
        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        var batch = ScrollingCaptureService.AppendFrameBatch(
            stitcher,
            new[] { intermediate, latest },
            expectedWheelDirection: -1);

        Assert.Equal(StitchResult.Added, batch.Result);
        Assert.Equal(2, batch.AddedCount);
        Assert.Equal(2, batch.CandidateCount);
        Assert.Equal(1_100, stitcher.OutputHeight);
    }

    [Fact]
    public void AppendFrameBatch_ReportsUnmatchedNewestFrameAfterPartialSuccess()
    {
        const int width = 180;
        const int viewportHeight = 500;
        using var content = MakePattern(width, 1_400);
        using var first = content.Clone(
            new System.Drawing.Rectangle(0, 0, width, viewportHeight), content.PixelFormat);
        using var intermediate = content.Clone(
            new System.Drawing.Rectangle(0, 300, width, viewportHeight), content.PixelFormat);
        using var unmatchedLatest = content.Clone(
            new System.Drawing.Rectangle(0, 900, width, viewportHeight), content.PixelFormat);
        using var laterCandidate = content.Clone(
            new System.Drawing.Rectangle(0, 600, width, viewportHeight), content.PixelFormat);

        using var stitcher = new ScrollingStitcher();
        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        var batch = ScrollingCaptureService.AppendFrameBatch(
            stitcher,
            new[] { intermediate, unmatchedLatest, laterCandidate },
            expectedWheelDirection: -1);

        Assert.Equal(StitchResult.Added, batch.Result);
        Assert.Equal(StitchResult.NoMatch, batch.LastResult);
        Assert.True(batch.HasTrailingNoMatch);
        Assert.Equal(1, batch.AddedCount);
        Assert.Equal(2, batch.CandidateCount);
        Assert.Equal(800, stitcher.OutputHeight);
    }

    [Fact]
    public void PrependUnprocessedFrames_PreservesChronologicalOrderAheadOfPendingQueue()
    {
        using var processed = new System.Drawing.Bitmap(8, 8);
        using var remainderOne = new System.Drawing.Bitmap(8, 8);
        using var remainderTwo = new System.Drawing.Bitmap(8, 8);
        using var pendingOne = new System.Drawing.Bitmap(8, 8);
        using var pendingTwo = new System.Drawing.Bitmap(8, 8);
        var pending = new Queue<System.Drawing.Bitmap>(new[] { pendingOne, pendingTwo });

        ScrollingCaptureService.PrependUnprocessedFrames(
            pending,
            new[] { processed, remainderOne, remainderTwo },
            processedCandidateCount: 1);

        Assert.Equal(
            new[] { remainderOne, remainderTwo, pendingOne, pendingTwo },
            pending.ToArray());
    }

    [Fact]
    public void TakeNextStitchBatch_PreservesOldestFramesForTheNextBatch()
    {
        var frames = Enumerable.Range(0, 8)
            .Select(_ => new System.Drawing.Bitmap(8, 8))
            .ToArray();
        try
        {
            var pending = new Queue<System.Drawing.Bitmap>(frames);
            var selected = ScrollingCaptureService.TakeNextStitchBatch(
                pending,
                maximumCandidates: 3);

            Assert.Equal(3, selected.Count);
            Assert.Same(frames[0], selected[0]);
            Assert.Same(frames[1], selected[1]);
            Assert.Same(frames[2], selected[2]);
            Assert.Equal(5, pending.Count);
        }
        finally
        {
            foreach (var frame in frames) frame.Dispose();
        }
    }

    [Fact]
    public void TakeNextStitchBatch_DefaultNeverDropsRecoveryFrames()
    {
        var frames = Enumerable.Range(0, 21)
            .Select(_ => new System.Drawing.Bitmap(8, 8))
            .ToArray();
        try
        {
            var pending = new Queue<System.Drawing.Bitmap>(frames);
            var selected = new List<System.Drawing.Bitmap>();
            var batchSizes = new List<int>();
            while (pending.Count > 0)
            {
                var batch = ScrollingCaptureService.TakeNextStitchBatch(pending);
                batchSizes.Add(batch.Count);
                selected.AddRange(batch);
            }

            Assert.Equal(new[] { 8, 8, 5 }, batchSizes);
            Assert.Equal(frames.Length, selected.Count);
            for (var index = 0; index < frames.Length; index++)
                Assert.Same(frames[index], selected[index]);
        }
        finally
        {
            foreach (var frame in frames) frame.Dispose();
        }
    }

    [Fact]
    public async Task CaptureAsync_FinishRequestSealsStableTailFrame()
    {
        const int width = 180;
        const int viewportHeight = 500;
        using var content = MakePattern(width, 800);
        using var first = content.Clone(
            new System.Drawing.Rectangle(0, 0, width, viewportHeight), content.PixelFormat);
        using var tail = content.Clone(
            new System.Drawing.Rectangle(0, 300, width, viewportHeight), content.PixelFormat);
        var captureCount = 0;
        using var serviceResult = await new ScrollingCaptureService(
            new ScreenCaptureService(),
            frameCapture: (_, _) =>
                new System.Drawing.Bitmap(Interlocked.Increment(ref captureCount) == 1 ? first : tail))
            .CaptureAsync(
                new System.Drawing.Rectangle(0, 0, width, viewportHeight),
                IntPtr.Zero,
                wheelMonitor: null,
                progress: null,
                CancellationToken.None,
                finishRequested: () => true);

        Assert.NotNull(serviceResult);
        Assert.Equal(width, serviceResult.Width);
        Assert.Equal(800, serviceResult.Height);
        Assert.True(captureCount >= 2);
    }

    [Fact]
    public async Task CaptureFrameStream_RemainsIdleUntilScrollBurstIsArmed()
    {
        var captureCount = 0;
        using var stream = new ScrollingCaptureService.CaptureFrameStream(
            (_, _) =>
            {
                var sequence = Interlocked.Increment(ref captureCount);
                var frame = new System.Drawing.Bitmap(16, 16);
                frame.SetPixel(8, 8, System.Drawing.Color.FromArgb(sequence % 255, 0, 0));
                return frame;
            },
            new System.Drawing.Rectangle(0, 0, 16, 16),
            optionsProvider: null,
            CancellationToken.None);

        await Task.Delay(100);
        Assert.Equal(0, Volatile.Read(ref captureCount));

        stream.ArmForBurst(80);
        await Task.Delay(120);
        var frames = stream.StopAndDrain();
        try
        {
            Assert.True(Volatile.Read(ref captureCount) > 0);
            Assert.NotEmpty(frames);
        }
        finally
        {
            foreach (var frame in frames) frame.Dispose();
        }
    }

    [Fact]
    public void CaptureFrameStream_ArmForBurst_DoesNotBlockOnFrameCapture()
    {
        using var captureStarted = new ManualResetEventSlim();
        using var releaseCapture = new ManualResetEventSlim();
        using var stream = new ScrollingCaptureService.CaptureFrameStream(
            (_, _) =>
            {
                captureStarted.Set();
                Assert.True(releaseCapture.Wait(TimeSpan.FromSeconds(2)));
                return new System.Drawing.Bitmap(16, 16);
            },
            new System.Drawing.Rectangle(0, 0, 16, 16),
            optionsProvider: null,
            CancellationToken.None);

        stream.ArmForBurst(80);
        Assert.True(captureStarted.Wait(TimeSpan.FromSeconds(2)));
        releaseCapture.Set();
        var frames = stream.StopAndDrain();
        try
        {
            Assert.NotEmpty(frames);
        }
        finally
        {
            foreach (var frame in frames) frame.Dispose();
        }
    }

    [Fact]
    public async Task CaptureFrameStream_RapidWheelSignalsKeepSamplingRenderedFrames()
    {
        var captureCount = 0;
        using var stream = new ScrollingCaptureService.CaptureFrameStream(
            (_, _) =>
            {
                var sequence = Interlocked.Increment(ref captureCount);
                var frame = new System.Drawing.Bitmap(16, 16);
                frame.SetPixel(8, 8, System.Drawing.Color.FromArgb(sequence % 255, 0, 0));
                return frame;
            },
            new System.Drawing.Rectangle(0, 0, 16, 16),
            optionsProvider: null,
            CancellationToken.None);

        for (var index = 0; index < 4; index++)
        {
            stream.ArmForBurst(80);
            await Task.Delay(10);
        }
        await Task.Delay(100);

        var frames = stream.StopAndDrain();
        try
        {
            Assert.True(Volatile.Read(ref captureCount) >= 3);
            Assert.Equal(Volatile.Read(ref captureCount), frames.Count);
        }
        finally
        {
            foreach (var frame in frames) frame.Dispose();
        }
    }

    [Fact]
    public async Task CaptureFrameStream_StaticRenderedViewportIsQueuedOnlyOnce()
    {
        var captureCount = 0;
        using var stream = new ScrollingCaptureService.CaptureFrameStream(
            (_, _) =>
            {
                Interlocked.Increment(ref captureCount);
                return new System.Drawing.Bitmap(32, 32);
            },
            new System.Drawing.Rectangle(0, 0, 32, 32),
            optionsProvider: null,
            CancellationToken.None);

        stream.ArmForBurst(100);
        await Task.Delay(140);
        var frames = stream.StopAndDrain();
        try
        {
            Assert.True(Volatile.Read(ref captureCount) >= 3);
            Assert.Single(frames);
        }
        finally
        {
            foreach (var frame in frames) frame.Dispose();
        }
    }

    [Fact]
    public async Task CaptureFrameStream_DisarmAndDiscard_FencesInFlightStaleFrame()
    {
        using var captureStarted = new ManualResetEventSlim();
        using var releaseCapture = new ManualResetEventSlim();
        var captureCount = 0;
        using var stream = new ScrollingCaptureService.CaptureFrameStream(
            (_, _) =>
            {
                Interlocked.Increment(ref captureCount);
                captureStarted.Set();
                Assert.True(releaseCapture.Wait(TimeSpan.FromSeconds(2)));
                return new System.Drawing.Bitmap(16, 16);
            },
            new System.Drawing.Rectangle(0, 0, 16, 16),
            optionsProvider: null,
            CancellationToken.None);

        stream.ArmForBurst(500);
        Assert.True(captureStarted.Wait(TimeSpan.FromSeconds(2)));
        var discardTask = Task.Run(stream.DisarmAndDiscard);
        releaseCapture.Set();

        Assert.Equal(1, await discardTask.WaitAsync(TimeSpan.FromSeconds(2)));
        await Task.Delay(80);
        Assert.Empty(stream.Drain());
        Assert.Equal(1, Volatile.Read(ref captureCount));

        // Disarming only resets the stale burst; later scrolling can arm the
        // producer again and capture fresh, chronologically valid frames.
        stream.ArmForBurst(80);
        await Task.Delay(120);
        var freshFrames = stream.StopAndDrain();
        try
        {
            Assert.NotEmpty(freshFrames);
            Assert.True(Volatile.Read(ref captureCount) > 1);
        }
        finally
        {
            foreach (var frame in freshFrames) frame.Dispose();
        }
    }

    [Fact]
    public async Task CaptureAsync_CancelWithDiscardReturnsNoImage()
    {
        using var frame = MakePattern(180, 500);
        using var cancellation = new CancellationTokenSource();
        var discard = 0;
        var initialCaptured = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var captureTask = new ScrollingCaptureService(
            new ScreenCaptureService(),
            frameCapture: (_, _) =>
            {
                initialCaptured.TrySetResult();
                return new System.Drawing.Bitmap(frame);
            })
            .CaptureAsync(
                new System.Drawing.Rectangle(0, 0, frame.Width, frame.Height),
                IntPtr.Zero,
                wheelMonitor: null,
                progress: null,
                cancellation.Token,
                discardRequested: () => Volatile.Read(ref discard) == 1);

        await initialCaptured.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Volatile.Write(ref discard, 1);
        cancellation.Cancel();

        using var result = await captureTask;
        Assert.Null(result);
    }

    private static System.Drawing.Bitmap MakePattern(int width, int height)
    {
        var bitmap = new System.Drawing.Bitmap(
            width,
            height,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var hash = unchecked((uint)(x * 73856093) ^ (uint)(y * 19349663));
                bitmap.SetPixel(x, y, System.Drawing.Color.FromArgb(
                    255,
                    (byte)hash,
                    (byte)(hash >> 8),
                    (byte)(hash >> 16)));
            }
        }
        return bitmap;
    }

}
