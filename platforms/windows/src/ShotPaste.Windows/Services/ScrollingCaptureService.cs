using Drawing = System.Drawing;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Utilities;
using System.Diagnostics;
using System.Windows.Media.Imaging;

namespace ShotPaste.Windows.Services;

public enum ScrollingCaptureSafety { Confirmed, Tentative, Unsafe }
public enum ScrollingPreviewTruth { Ready, CommittedOnly, LiveAhead, PausedRecovery, Finalizing, Saving }

public sealed record ScrollingCaptureProgress(
    int Frames,
    int Height,
    BitmapSource? Preview,
    string Status,
    ScrollingCaptureSafety Safety = ScrollingCaptureSafety.Confirmed,
    ScrollingPreviewTruth PreviewTruth = ScrollingPreviewTruth.CommittedOnly);

public sealed class ScrollingCaptureService(
    ScreenCaptureService capture,
    int maximumHeight = ScrollingStitcher.DefaultMaximumHeight,
    int previewMaxHeight = 420,
    int autoScrollIntervalMs = 40,
    bool detectFixedBars = true,
    bool safetyGuardEnabled = true,
    Func<ScreenCaptureOptions>? captureOptionsProvider = null,
    Func<Drawing.Rectangle, ScreenCaptureOptions?, Drawing.Bitmap>? frameCapture = null)
{
    private const int FallbackPollIntervalMs = 90;
    private const int WheelQuietPeriodMs = 35;
    private const int AutoScrollWheelDelta = -120;
    private const int WheelMaximumBurstMs = 60;
    private const int WheelIdlePollMs = 10;
    private const int AutomaticScrollSettleMs = 120;
    private const int ManualPreRollRefreshMs = 250;
    private const int RecoverySettleDelayMs = 140;
    private const int BoundaryConfirmationCount = 3;
    private const int FallbackDuplicateGate = 8;
    private const int FallbackIdleProbeMs = 1500;
    private const int MaxNoMatchBeforeGuidance = 2;
    private const int MaximumStitchCandidatesPerBatch = 8;
    private readonly int _maximumHeight = Math.Clamp(maximumHeight, 1024, 100000);
    private readonly int _previewMaxHeight = Math.Clamp(previewMaxHeight, 120, 1200);
    private readonly int _autoScrollIntervalMs = Math.Clamp(autoScrollIntervalMs, 40, 500);
    private readonly bool _detectFixedBars = detectFixedBars;
    private readonly bool _safetyGuardEnabled = safetyGuardEnabled;
    private Drawing.Bitmap CaptureFrame(Drawing.Rectangle region) =>
        frameCapture?.Invoke(region, captureOptionsProvider?.Invoke()) ??
        capture.CaptureRectangle(region, captureOptionsProvider?.Invoke());

    public async Task<Drawing.Bitmap?> CaptureAsync(Drawing.Rectangle region, IntPtr scrollTarget,
        MouseWheelMonitor? wheelMonitor,
        IProgress<ScrollingCaptureProgress>? progress,
        CancellationToken cancellationToken,
        Func<bool>? autoScrollEnabled = null,
        Func<bool>? discardRequested = null,
        Func<bool>? finishRequested = null)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Lock the page state before focus changes, window activation, or an eager first wheel event
        // can move it. This frame is also what lets an upward scroll recover content above the start.
        using var initialFrame = CaptureFrame(region);
        try
        {
            return await Task.Run(
                () => CaptureLoopAsync(
                    region,
                    scrollTarget,
                    initialFrame,
                    wheelMonitor,
                    progress,
                    cancellationToken,
                    autoScrollEnabled,
                    discardRequested,
                    finishRequested),
                cancellationToken);
        }
        catch (OperationCanceledException) when (discardRequested?.Invoke() == true)
        {
            // Cancellation can win the race before Task.Run starts executing, so
            // CaptureLoopAsync never gets a chance to apply discard semantics.
            return null;
        }
    }

    private async Task<Drawing.Bitmap?> CaptureLoopAsync(Drawing.Rectangle region, IntPtr scrollTarget,
        Drawing.Bitmap initialFrame,
        MouseWheelMonitor? wheelMonitor,
        IProgress<ScrollingCaptureProgress>? progress,
        CancellationToken cancellationToken,
        Func<bool>? autoScrollEnabled,
        Func<bool>? discardRequested,
        Func<bool>? finishRequested)
    {
        using var stitcher = new ScrollingStitcher(_maximumHeight, _detectFixedBars);
        var misses = 0;
        var frames = 1;
        var duplicateStreak = 0;
        var boundaryReported = false;
        var lastHandledWheel = 0L;
        var lastPositiveWheelEvents = 0L;
        var lastNegativeWheelEvents = 0L;
        var lastCumulativeWheelDelta = 0L;
        var direction = 0;
        var hasAcceptedMovement = false;
        var forceCapture = false;
        var retriedNoMatch = false;
        var wheelDriven = wheelMonitor?.IsActive == true;
        var autoBoundaryStreak = 0;
        var pendingFrames = new Queue<Drawing.Bitmap>();
        using var frameStream = new CaptureFrameStream(
            (captureRegion, _) => CaptureFrame(captureRegion),
            region,
            captureOptionsProvider,
            cancellationToken,
            continuous: true);
        var startsInAutomaticMode = autoScrollEnabled?.Invoke() == true;
        Action? armFrameStream = wheelDriven && !startsInAutomaticMode
            ? frameStream.ArmForBurst
            : null;
        if (armFrameStream is not null)
        {
            wheelMonitor!.WheelObserved += armFrameStream;
            // Keep a short ring warm before the first wheel event. Waiting until
            // the hook callback is too late for a dense touchpad/wheel burst: the
            // viewport can move past the overlap window before the first GDI frame
            // has entered the queue.
            frameStream.ArmForBurst(2000);
        }
        try
        {
            stitcher.Append(initialFrame);
            ReportSnapshot("已锁定首帧，可向上补齐顶部或向下继续滚动", ScrollingPreviewTruth.Ready);
            if (scrollTarget != IntPtr.Zero) NativeMethods.SetForegroundWindow(scrollTarget);
            await DelayUntilFinishedAsync(220, finishRequested, cancellationToken);
            while (!cancellationToken.IsCancellationRequested && finishRequested?.Invoke() != true)
            {
                var automaticScroll = autoScrollEnabled?.Invoke() == true;
                var processingPendingFrames = pendingFrames.Count > 0;
                var stableRecovery = forceCapture && !processingPendingFrames;
                if (processingPendingFrames)
                {
                    // Drain already-captured frames before asking the page to move
                    // again. Matching stays bounded per batch, while every bridge
                    // frame remains queued in chronological order.
                }
                else if (stableRecovery)
                {
                    forceCapture = false;
                    var discardedRecoveryFrames = frameStream.DisarmAndDiscard();
                    if (discardedRecoveryFrames > 0)
                        App.WriteQuickAccessLog($"ScrollingCapture recovery discarded transition frames={discardedRecoveryFrames}");
                    await Task.Delay(RecoverySettleDelayMs, cancellationToken);
                    frameStream.DisarmAndDiscard();
                }
                else if (automaticScroll)
                {
                    if (!IsCursorInside(region))
                    {
                        progress?.Report(new ScrollingCaptureProgress(frames, stitcher.OutputHeight, null,
                            "自动滚动已暂停：请把鼠标放回选区", ScrollingCaptureSafety.Tentative, ScrollingPreviewTruth.PausedRecovery));
                        await Task.Delay(150, cancellationToken);
                        continue;
                    }
                    if (scrollTarget != IntPtr.Zero) NativeMethods.SetForegroundWindow(scrollTarget);
                    // Automatic scrolling has a known settle point and therefore
                    // starts without the manual burst sampler. Capture one stable
                    // observation after the injected notch instead of compositor
                    // transition frames that can poison the stitch anchor.
                    NativeMethods.mouse_event(
                        NativeMethods.MouseeventfWheel,
                        0,
                        0,
                        AutoScrollWheelDelta,
                        UIntPtr.Zero);
                    direction = -1;
                    await Task.Delay(
                        Math.Max(_autoScrollIntervalMs, AutomaticScrollSettleMs),
                        cancellationToken);
                    if (wheelMonitor?.IsActive == true)
                    {
                        var automaticSnapshot = wheelMonitor.Snapshot;
                        lastHandledWheel = automaticSnapshot.SequenceNumber;
                        lastPositiveWheelEvents = automaticSnapshot.PositiveEventCount;
                        lastNegativeWheelEvents = automaticSnapshot.NegativeEventCount;
                        lastCumulativeWheelDelta = automaticSnapshot.CumulativeDelta;
                    }
                }
                else if (wheelDriven)
                {
                    var wheel = await WaitForWheelBurstAsync(
                        wheelMonitor!,
                        lastHandledWheel,
                        autoScrollEnabled,
                        finishRequested,
                        frameStream.ArmForBurst,
                        cancellationToken);
                    // Switching to automatic mode must wake an idle manual wait.
                    // Otherwise the button says "stop automatic" while no wheel
                    // event is ever emitted and capture appears frozen.
                    if (wheel is null) continue;
                    direction = ResolveWheelBurstDirection(
                        wheel.Value,
                        lastPositiveWheelEvents,
                        lastNegativeWheelEvents,
                        lastCumulativeWheelDelta,
                        out var mixedDirections);
                    lastHandledWheel = wheel.Value.SequenceNumber;
                    lastPositiveWheelEvents = wheel.Value.PositiveEventCount;
                    lastNegativeWheelEvents = wheel.Value.NegativeEventCount;
                    lastCumulativeWheelDelta = wheel.Value.CumulativeDelta;

                    if (mixedDirections)
                    {
                        direction = 0;
                        duplicateStreak = 0;
                        boundaryReported = false;
                        progress?.Report(new ScrollingCaptureProgress(
                            frames, stitcher.OutputHeight, null,
                            "检测到滚动方向变化，正在按当前位置继续拼接",
                            ScrollingCaptureSafety.Tentative, ScrollingPreviewTruth.LiveAhead));
                    }
                }
                else
                {
                    // Fallback without a wheel hook: poll, but stop hammering once
                    // the content has stopped changing.
                    var delay = duplicateStreak >= FallbackDuplicateGate
                        ? FallbackIdleProbeMs
                        : FallbackPollIntervalMs;
                    await Task.Delay(delay, cancellationToken);
                    if (cancellationToken.IsCancellationRequested) break;
                }

                List<Drawing.Bitmap> incomingFrames;
                if (processingPendingFrames)
                {
                    incomingFrames = [];
                }
                else
                {
                    incomingFrames = stableRecovery
                        ? []
                        : frameStream.Drain();
                    if (stableRecovery)
                    {
                        incomingFrames.Add(CaptureFrame(region));
                    }
                    else if (!automaticScroll && wheelDriven)
                    {
                        // The burst sampler protects against a fast jump, but its
                        // newest frame can still be mid-composition. A synchronous
                        // observation after the quiet period anchors every manual
                        // burst at its settled viewport; duplicates are harmless.
                        incomingFrames.Add(CaptureFrame(region));
                    }
                    else if (incomingFrames.Count == 0)
                    {
                        incomingFrames.Add(CaptureFrame(region));
                    }

                    foreach (var incomingFrame in incomingFrames)
                        pendingFrames.Enqueue(incomingFrame);
                }
                var queuedBeforeBatch = pendingFrames.Count;
                var candidateFrames = TakeNextStitchBatch(pendingFrames);
                progress?.Report(new ScrollingCaptureProgress(
                    frames,
                    stitcher.OutputHeight,
                    null,
                    processingPendingFrames
                        ? "正在补齐已捕获的连续帧"
                        : stableRecovery ? "正在验证稳定恢复帧" : "正在验证最新画面",
                    ScrollingCaptureSafety.Tentative,
                    stableRecovery ? ScrollingPreviewTruth.PausedRecovery : ScrollingPreviewTruth.LiveAhead));
                FrameBatchAppendResult batch;
                var processedCandidateCount = candidateFrames.Count;
                try
                {
                    batch = AppendFrameBatch(
                        stitcher,
                        candidateFrames,
                        direction,
                        allowLargeGap: false);
                    processedCandidateCount = batch.CandidateCount;
                    if (processedCandidateCount < candidateFrames.Count)
                    {
                        PrependUnprocessedFrames(
                            pendingFrames,
                            candidateFrames,
                            processedCandidateCount);
                    }
                }
                finally
                {
                    for (var index = 0; index < processedCandidateCount; index++)
                        candidateFrames[index].Dispose();
                }
                var result = batch.HasTrailingNoMatch ? StitchResult.NoMatch : batch.Result;
                var fixedHorizontal = stitcher.FixedHorizontalBars;
                var fixedSides = stitcher.FixedSideBars;
                App.WriteQuickAccessLog(
                    $"ScrollingCapture stitch result={result} frames={frames} height={stitcher.OutputHeight} " +
                    $"direction={direction} incoming={incomingFrames.Count} queued={queuedBeforeBatch} " +
                    $"batch={batch.CandidateCount} pending={pendingFrames.Count} added={batch.AddedCount} " +
                    $"advances=[{string.Join(',', batch.AcceptedAdvances)}] " +
                    $"fixed={fixedHorizontal.Top}/{fixedHorizontal.Bottom}/{fixedSides.Left}/{fixedSides.Right} " +
                    $"misses={misses} duplicates={duplicateStreak} diagnostic={stitcher.LastFailureDiagnostics} " +
                    $"match={stitcher.LastMatchDiagnostics}");
                if (batch.AddedCount > 0)
                {
                    hasAcceptedMovement = true;
                    frames += batch.AddedCount;
                    misses = 0;
                    duplicateStreak = 0;
                    autoBoundaryStreak = 0;
                    boundaryReported = false;
                    retriedNoMatch = false;
                    using var preview = stitcher.CreatePreviewBitmap(220, _previewMaxHeight);
                    if (preview is not null)
                    {
                        progress?.Report(new ScrollingCaptureProgress(
                            frames,
                            stitcher.OutputHeight,
                            BitmapSourceFactory.FromBitmap(preview),
                            automaticScroll ? "自动滚动中 · 实时预览已更新" : "实时预览已更新，可继续滚动",
                            ScrollingCaptureSafety.Confirmed,
                            ScrollingPreviewTruth.CommittedOnly));
                    }
                }
                if (result == StitchResult.Added)
                {
                    continue;
                }
                if (result == StitchResult.Duplicate)
                {
                    misses = 0;
                    duplicateStreak++;
                    retriedNoMatch = false;
                    if (automaticScroll)
                    {
                        autoBoundaryStreak++;
                        if (ShouldConfirmAutomaticBoundary(hasAcceptedMovement, autoBoundaryStreak))
                        {
                            ReportSnapshot("自动滚动已连续三次确认内容边界，正在完成");
                            break;
                        }
                        ReportSnapshot(hasAcceptedMovement
                            ? "暂未检测到新内容，正在继续确认滚动边界"
                            : "正在等待目标窗口开始滚动");
                    }
                    else if (wheelDriven)
                    {
                        if (IsConfirmedBoundary(duplicateStreak) && !boundaryReported)
                        {
                            boundaryReported = true;
                            ReportSnapshot("已连续检测到无新内容，可能到达滚动边界；可点击完成保存");
                        }
                        else if (!boundaryReported)
                        {
                            ReportSnapshot("暂未检测到新内容，可继续向任一方向滚动");
                        }
                    }
                    else if (duplicateStreak == FallbackDuplicateGate && !boundaryReported)
                    {
                        boundaryReported = true;
                        ReportSnapshot("内容不再变化，已暂停连续截屏；继续滚动后会自动恢复");
                    }
                }
                else if (result == StitchResult.NoMatch)
                {
                    misses++;
                    duplicateStreak = 0;
                    autoBoundaryStreak = 0;
                    boundaryReported = false;
                    if (!retriedNoMatch)
                    {
                        // Keep the accepted frame as the stitch anchor, but never let
                        // later transition frames leap over a failed candidate. On a
                        // repeated page they can look like a short valid overlap and
                        // silently omit rows. Retry only one settled observation.
                        while (pendingFrames.Count > 0)
                            pendingFrames.Dequeue().Dispose();
                        frameStream.DisarmAndDiscard();
                        retriedNoMatch = true;
                        forceCapture = true;
                        continue;
                    }
                    if (misses >= MaxNoMatchBeforeGuidance)
                    {
                        retriedNoMatch = false;
                        var safety = _safetyGuardEnabled ? ScrollingCaptureSafety.Unsafe : ScrollingCaptureSafety.Tentative;
                        var truth = _safetyGuardEnabled ? ScrollingPreviewTruth.PausedRecovery : ScrollingPreviewTruth.LiveAhead;
                        progress?.Report(new ScrollingCaptureProgress(
                            frames,
                            stitcher.OutputHeight,
                            null,
                            _safetyGuardEnabled
                                ? "暂时无法对齐，请放慢滚动速度"
                                : "正在继续尝试对齐，建议放慢滚动速度",
                            safety,
                            truth));
                        if (automaticScroll && _safetyGuardEnabled) break;
                    }
                }
                else if (result == StitchResult.HeightLimit)
                {
                    progress?.Report(new ScrollingCaptureProgress(frames, _maximumHeight, null, "已达到长图高度上限，正在完成", ScrollingCaptureSafety.Confirmed, ScrollingPreviewTruth.Finalizing));
                    break;
                }
            }
            if (!cancellationToken.IsCancellationRequested && discardRequested?.Invoke() != true)
                await SealTailAsync();
            return discardRequested?.Invoke() == true
                ? null
                : FinalResult("正在保存已确认内容");
        }
        catch (OperationCanceledException)
        {
            return discardRequested?.Invoke() == true
                ? null
                : FinalResult("正在保存已确认内容");
        }
        catch (Exception exception)
        {
            App.WriteQuickAccessLog($"ScrollingCapture failed: {exception}");
            throw;
        }
        finally
        {
            if (armFrameStream is not null)
                wheelMonitor!.WheelObserved -= armFrameStream;
            while (pendingFrames.Count > 0)
                pendingFrames.Dequeue().Dispose();
        }

        void ReportSnapshot(string status, ScrollingPreviewTruth truth = ScrollingPreviewTruth.CommittedOnly)
        {
            using var preview = stitcher.CreatePreviewBitmap(220, _previewMaxHeight);
            if (preview is null) return;
            progress?.Report(new ScrollingCaptureProgress(
                frames, stitcher.OutputHeight, BitmapSourceFactory.FromBitmap(preview), status,
                ScrollingCaptureSafety.Confirmed, truth));
        }

        Drawing.Bitmap? FinalResult(string status)
        {
            using var preview = stitcher.CreatePreviewBitmap(220, _previewMaxHeight);
            var previewSource = preview is null ? null : BitmapSourceFactory.FromBitmap(preview);
            var result = stitcher.Result;
            if (result is not null)
            {
                progress?.Report(new ScrollingCaptureProgress(
                    frames, result.Height, previewSource, status,
                    ScrollingCaptureSafety.Confirmed, ScrollingPreviewTruth.Saving));
            }
            return result;
        }

        async Task SealTailAsync()
        {
            ReportSnapshot("正在补齐最后一屏并校验拼接", ScrollingPreviewTruth.Finalizing);
            var tailFrames = frameStream.StopAndDrain();
            foreach (var tailFrame in tailFrames)
                pendingFrames.Enqueue(tailFrame);
            await Task.Delay(RecoverySettleDelayMs, cancellationToken);
            pendingFrames.Enqueue(CaptureFrame(region));

            var tailBatchIndex = 0;
            var lastTailResult = StitchResult.Duplicate;
            while (pendingFrames.Count > 0)
            {
                var queuedBeforeBatch = pendingFrames.Count;
                var candidates = TakeNextStitchBatch(pendingFrames);
                var processedCandidateCount = candidates.Count;
                try
                {
                    var batch = AppendFrameBatch(stitcher, candidates, direction);
                    processedCandidateCount = batch.CandidateCount;
                    if (processedCandidateCount < candidates.Count)
                        PrependUnprocessedFrames(pendingFrames, candidates, processedCandidateCount);
                    frames += batch.AddedCount;
                    lastTailResult = batch.LastResult;
                    App.WriteQuickAccessLog(
                        $"ScrollingCapture tail batch={++tailBatchIndex} result={batch.Result} last={batch.LastResult} " +
                        $"frames={frames} height={stitcher.OutputHeight} queued={queuedBeforeBatch} " +
                        $"candidates={batch.CandidateCount} pending={pendingFrames.Count} " +
                        $"added={batch.AddedCount} advances=[{string.Join(',', batch.AcceptedAdvances)}] " +
                        $"diagnostic={stitcher.LastFailureDiagnostics} match={stitcher.LastMatchDiagnostics}");

                    if (batch.Result == StitchResult.HeightLimit)
                        break;
                }
                finally
                {
                    for (var index = 0; index < processedCandidateCount; index++)
                        candidates[index].Dispose();
                }
            }

            if (lastTailResult == StitchResult.NoMatch)
            {
                await Task.Delay(RecoverySettleDelayMs, cancellationToken);
                using var retry = CaptureFrame(region);
                var retryResult = stitcher.Append(retry, direction, allowLargeGap: false);
                if (retryResult == StitchResult.Added) frames++;
                App.WriteQuickAccessLog(
                    $"ScrollingCapture tail retry result={retryResult} frames={frames} height={stitcher.OutputHeight}");
            }
            ReportSnapshot("尾帧校验完成，正在保存已确认内容", ScrollingPreviewTruth.Finalizing);
        }
    }

    private static async Task DelayUntilFinishedAsync(
        int milliseconds,
        Func<bool>? finishRequested,
        CancellationToken cancellationToken)
    {
        var started = Stopwatch.GetTimestamp();
        while (Stopwatch.GetElapsedTime(started).TotalMilliseconds < milliseconds &&
               finishRequested?.Invoke() != true)
        {
            await Task.Delay(Math.Min(WheelIdlePollMs, milliseconds), cancellationToken);
        }
    }

    private static async Task<MouseWheelSnapshot?> WaitForWheelBurstAsync(
        MouseWheelMonitor wheelMonitor,
        long handledSequenceNumber,
        Func<bool>? autoScrollEnabled,
        Func<bool>? finishRequested,
        Action onWheelDetected,
        CancellationToken cancellationToken)
    {
        // Refresh the pre-roll while manual capture is idle. This mirrors the
        // macOS frame ring and guarantees that the first rendered step of a burst
        // is available even when the user pauses before scrolling.
        onWheelDetected();
        var preRollRefreshed = Stopwatch.GetTimestamp();
        while (!cancellationToken.IsCancellationRequested && !ShouldLeaveWheelWait(
                   wheelMonitor.HasWheelSince(handledSequenceNumber),
                   autoScrollEnabled?.Invoke() == true,
                   finishRequested?.Invoke() == true))
        {
            await Task.Delay(WheelIdlePollMs, cancellationToken);
            if (Stopwatch.GetElapsedTime(preRollRefreshed).TotalMilliseconds >= ManualPreRollRefreshMs)
            {
                onWheelDetected();
                preRollRefreshed = Stopwatch.GetTimestamp();
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (finishRequested?.Invoke() == true) return null;
        if (autoScrollEnabled?.Invoke() == true &&
            !wheelMonitor.HasWheelSince(handledSequenceNumber))
            return null;
        onWheelDetected();
        var burstStarted = Stopwatch.GetTimestamp();
        var snapshot = wheelMonitor.Snapshot;
        while (!cancellationToken.IsCancellationRequested)
        {
            var quietMilliseconds = Stopwatch.GetElapsedTime(snapshot.Timestamp).TotalMilliseconds;
            var burstMilliseconds = Stopwatch.GetElapsedTime(burstStarted).TotalMilliseconds;
            if (quietMilliseconds >= WheelQuietPeriodMs || burstMilliseconds >= WheelMaximumBurstMs)
                return snapshot;

            await Task.Delay(WheelIdlePollMs, cancellationToken);
            var latest = wheelMonitor.Snapshot;
            if (latest.SequenceNumber != snapshot.SequenceNumber) snapshot = latest;
        }

        cancellationToken.ThrowIfCancellationRequested();
        return snapshot;
    }

    internal static bool ShouldLeaveWheelWait(
        bool hasNewWheelEvent,
        bool automaticScrollEnabled,
        bool finishRequested = false) =>
        hasNewWheelEvent || automaticScrollEnabled || finishRequested;

    internal static int ResolveWheelBurstDirection(
        MouseWheelSnapshot snapshot,
        long previousPositiveEventCount,
        long previousNegativeEventCount,
        long previousCumulativeDelta,
        out bool mixedDirections)
    {
        var positiveEvents = snapshot.PositiveEventCount - previousPositiveEventCount;
        var negativeEvents = snapshot.NegativeEventCount - previousNegativeEventCount;
        mixedDirections = positiveEvents > 0 && negativeEvents > 0;
        var direction = Math.Sign(snapshot.CumulativeDelta - previousCumulativeDelta);
        return direction == 0 ? snapshot.Direction : direction;
    }

    internal static bool IsConfirmedBoundary(int duplicateStreak) =>
        duplicateStreak >= BoundaryConfirmationCount;

    internal static bool ShouldConfirmAutomaticBoundary(bool hasAcceptedMovement, int duplicateStreak) =>
        hasAcceptedMovement && IsConfirmedBoundary(duplicateStreak);

    internal static FrameBatchAppendResult AppendFrameBatch(
        ScrollingStitcher stitcher,
        IReadOnlyList<Drawing.Bitmap> candidates,
        int expectedWheelDirection = 0,
        bool allowLargeGap = false)
    {
        var addedCount = 0;
        var processedCount = 0;
        var acceptedAdvances = new List<int>();
        var lastResult = StitchResult.NoMatch;
        foreach (var candidate in candidates)
        {
            processedCount++;
            var previousHeight = stitcher.OutputHeight;
            lastResult = stitcher.Append(candidate, expectedWheelDirection, allowLargeGap);
            if (lastResult == StitchResult.Added)
            {
                addedCount++;
                acceptedAdvances.Add(stitcher.OutputHeight - previousHeight);
            }
            if (lastResult == StitchResult.HeightLimit)
                return new FrameBatchAppendResult(
                    lastResult, addedCount, processedCount, lastResult, acceptedAdvances);
            if (lastResult == StitchResult.NoMatch)
                break;
        }

        return new FrameBatchAppendResult(
            addedCount > 0 ? StitchResult.Added : lastResult,
            addedCount,
            processedCount,
            lastResult,
            acceptedAdvances);
    }

    internal static List<Drawing.Bitmap> TakeNextStitchBatch(
        Queue<Drawing.Bitmap> candidates,
        int maximumCandidates = MaximumStitchCandidatesPerBatch)
    {
        maximumCandidates = Math.Max(1, maximumCandidates);
        var batch = new List<Drawing.Bitmap>(Math.Min(candidates.Count, maximumCandidates));
        while (batch.Count < maximumCandidates && candidates.Count > 0)
            batch.Add(candidates.Dequeue());
        return batch;
    }

    internal static void PrependUnprocessedFrames(
        Queue<Drawing.Bitmap> pendingFrames,
        IReadOnlyList<Drawing.Bitmap> candidates,
        int processedCandidateCount)
    {
        processedCandidateCount = Math.Clamp(processedCandidateCount, 0, candidates.Count);
        if (processedCandidateCount >= candidates.Count) return;
        var existing = pendingFrames.ToArray();
        pendingFrames.Clear();
        for (var index = processedCandidateCount; index < candidates.Count; index++)
            pendingFrames.Enqueue(candidates[index]);
        foreach (var frame in existing)
            pendingFrames.Enqueue(frame);
    }

    internal static Drawing.Size GetPreviewSize(int width, int height, int maxWidth = 220, int maxHeight = 420)
    {
        if (width <= 0 || height <= 0 || maxWidth <= 0 || maxHeight <= 0) return Drawing.Size.Empty;
        var scale = Math.Min(1d, Math.Min((double)maxWidth / width, (double)maxHeight / height));
        return new Drawing.Size(Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    }

    private static bool IsCursorInside(Drawing.Rectangle region)
    {
        if (!NativeMethods.GetCursorPos(out var point)) return false;
        return point.X >= region.Left && point.X <= region.Right && point.Y >= region.Top && point.Y <= region.Bottom;
    }

    internal sealed class CaptureFrameStream : IDisposable
    {
        // GDI capture is substantially more expensive than DXGI duplication;
        // 30 fps keeps motion samples dense without monopolizing a CPU core.
        private const int StreamIntervalMs = 33;
        private const int DefaultBurstWindowMs = 360;
        private const int MinimumCapacity = 6;
        private const int MaximumCapacity = 64;
        private const long FrameMemoryBudgetBytes = 256L * 1024 * 1024;
        private readonly Func<Drawing.Rectangle, ScreenCaptureOptions?, Drawing.Bitmap> _captureFrame;
        private readonly Drawing.Rectangle _region;
        private readonly Func<ScreenCaptureOptions>? _optionsProvider;
        private readonly CancellationTokenSource _cancellation;
        private readonly SemaphoreSlim _armSignal = new(0, 1);
        private readonly Queue<Drawing.Bitmap> _frames = [];
        private readonly object _gate = new();
        private readonly object _captureGate = new();
        private readonly Task _producer;
        private readonly int _capacity;
        private readonly bool _continuous;
        private long _armedUntil;
        private ulong? _lastQueuedSignature;
        private int _stopped;

        public CaptureFrameStream(
            Func<Drawing.Rectangle, ScreenCaptureOptions?, Drawing.Bitmap> captureFrame,
            Drawing.Rectangle region,
            Func<ScreenCaptureOptions>? optionsProvider,
            CancellationToken cancellationToken,
            bool continuous = false)
        {
            _captureFrame = captureFrame;
            _region = region;
            _optionsProvider = optionsProvider;
            _capacity = ResolveCapacity(region);
            _continuous = continuous;
            _cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _producer = Task.Run(ProduceAsync);
        }

        public void ArmForBurst() => ArmForBurst(DefaultBurstWindowMs);

        internal void ArmForBurst(int durationMs)
        {
            if (Volatile.Read(ref _stopped) != 0) return;
            if (_continuous) return;
            var until = Environment.TickCount64 + Math.Clamp(durationMs, StreamIntervalMs, 2000);
            long observed;
            do
            {
                observed = Volatile.Read(ref _armedUntil);
                if (observed >= until) break;
            } while (Interlocked.CompareExchange(ref _armedUntil, until, observed) != observed);

            if (_armSignal.CurrentCount == 0)
            {
                try { _armSignal.Release(); }
                catch (SemaphoreFullException) { }
            }
        }

        public List<Drawing.Bitmap> Drain()
        {
            lock (_gate)
            {
                var result = new List<Drawing.Bitmap>(_frames.Count);
                while (_frames.Count > 0) result.Add(_frames.Dequeue());
                return result;
            }
        }

        internal int DisarmAndDiscard()
        {
            // Synchronize with the capture itself, not only the queue. A frame can
            // be in flight when Drain observes an empty queue; without this fence
            // it may be enqueued after a newer synchronous recovery frame and be
            // processed out of order on the next wheel burst.
            lock (_captureGate)
            {
                Interlocked.Exchange(ref _armedUntil, 0);
                lock (_gate)
                {
                    var discarded = _frames.Count;
                    while (_frames.Count > 0) _frames.Dequeue().Dispose();
                    _lastQueuedSignature = null;
                    return discarded;
                }
            }
        }

        internal List<Drawing.Bitmap> DisarmAndDrain()
        {
            // Fence the in-flight capture before taking ownership of the queue so
            // every returned frame is ordered before any later re-armed burst.
            lock (_captureGate)
            {
                Interlocked.Exchange(ref _armedUntil, 0);
                return Drain();
            }
        }

        private async Task ProduceAsync()
        {
            while (!_cancellation.IsCancellationRequested)
            {
                try
                {
                    if (!_continuous)
                        await _armSignal.WaitAsync(_cancellation.Token);
                    while (!_cancellation.IsCancellationRequested &&
                           (_continuous || Environment.TickCount64 < Volatile.Read(ref _armedUntil)))
                    {
                        lock (_captureGate)
                        {
                            if (_cancellation.IsCancellationRequested ||
                                !_continuous && Environment.TickCount64 >= Volatile.Read(ref _armedUntil))
                                break;

                            var frame = _captureFrame(_region, _optionsProvider?.Invoke());
                            lock (_gate)
                            {
                                EnqueueFrameLocked(frame);
                            }
                        }
                        await Task.Delay(StreamIntervalMs, _cancellation.Token);
                    }
                }
                catch (OperationCanceledException) { break; }
                catch
                {
                    try { await Task.Delay(FallbackPollIntervalMs, _cancellation.Token); }
                    catch (OperationCanceledException) { break; }
                }
            }
        }

        public List<Drawing.Bitmap> StopAndDrain()
        {
            StopProducer();
            return Drain();
        }

        public void Dispose()
        {
            StopProducer();
            lock (_gate)
            {
                while (_frames.Count > 0) _frames.Dequeue().Dispose();
            }
            _armSignal.Dispose();
            _cancellation.Dispose();
        }

        private void StopProducer()
        {
            if (Interlocked.Exchange(ref _stopped, 1) != 0) return;
            _cancellation.Cancel();
            try { _producer.GetAwaiter().GetResult(); } catch (OperationCanceledException) { }
        }

        private static int ResolveCapacity(Drawing.Rectangle region)
        {
            var frameBytes = Math.Max(1L, (long)region.Width * region.Height * 4);
            return Math.Clamp(
                (int)(FrameMemoryBudgetBytes / frameBytes),
                MinimumCapacity,
                MaximumCapacity);
        }

        private void CompactFramesLocked()
        {
            // Preserve the oldest bridge frame and temporal coverage through the
            // newest observation. Dropping the oldest frame (a conventional ring
            // buffer) disconnects the queue from the stitcher's committed anchor.
            var frames = _frames.ToArray();
            _frames.Clear();
            for (var index = 0; index < frames.Length; index++)
            {
                var keep = index == 0 || index == frames.Length - 1 || index % 2 == 0;
                if (keep) _frames.Enqueue(frames[index]);
                else frames[index].Dispose();
            }
        }

        private void EnqueueFrameLocked(Drawing.Bitmap frame)
        {
            var signature = ComputeFrameSignature(frame);
            if (_lastQueuedSignature == signature)
            {
                frame.Dispose();
                return;
            }

            _lastQueuedSignature = signature;
            if (_frames.Count >= _capacity) CompactFramesLocked();
            _frames.Enqueue(frame);
        }

        private static ulong ComputeFrameSignature(Drawing.Bitmap frame)
        {
            var bounds = new Drawing.Rectangle(0, 0, frame.Width, frame.Height);
            var data = frame.LockBits(
                bounds,
                System.Drawing.Imaging.ImageLockMode.ReadOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                // Ignore the outer eighth where fixed browser chrome, counters, and
                // side rails commonly change without the scrollable viewport being
                // repainted. A 64x64 content sample is cheap enough for every frame
                // while still distinguishing text and repeated-card identifiers.
                var xStart = frame.Width / 8;
                var xEnd = Math.Max(xStart + 1, frame.Width - frame.Width / 8);
                var yStart = frame.Height / 8;
                var yEnd = Math.Max(yStart + 1, frame.Height - frame.Height / 8);
                var xStep = Math.Max(1, (xEnd - xStart) / 64);
                var yStep = Math.Max(1, (yEnd - yStart) / 64);
                var hash = 1469598103934665603UL;
                hash = (hash ^ (uint)frame.Width) * 1099511628211UL;
                hash = (hash ^ (uint)frame.Height) * 1099511628211UL;
                for (var y = yStart; y < yEnd; y += yStep)
                {
                    var row = IntPtr.Add(data.Scan0, y * data.Stride);
                    for (var x = xStart; x < xEnd; x += xStep)
                    {
                        var rgb = (uint)System.Runtime.InteropServices.Marshal.ReadInt32(row, x * 4) & 0x00FFFFFF;
                        hash = (hash ^ rgb) * 1099511628211UL;
                    }
                }
                return hash;
            }
            finally
            {
                frame.UnlockBits(data);
            }
        }
    }
}

internal readonly record struct FrameBatchAppendResult(
    StitchResult Result,
    int AddedCount,
    int CandidateCount,
    StitchResult LastResult,
    IReadOnlyList<int> AcceptedAdvances)
{
    public bool HasTrailingNoMatch => AddedCount > 0 && LastResult == StitchResult.NoMatch;
}
