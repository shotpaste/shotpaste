using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Drawing = System.Drawing;

namespace LiteScreen.Windows.Services;

public enum StitchResult { Added, Duplicate, NoMatch, HeightLimit }

public sealed class ScrollingStitcher : IDisposable
{
    public const int DefaultMaximumHeight = 32768;
    private const int MinimumFixedEdgeHeight = 4;
    private const double ActiveColumnThreshold = 48.0;
    private const double ActiveFeatureMatchThreshold = 24.0;
    private const double RequiredMatchRatio = 0.6;
    // Repeated list/card layouts share borders and most glyph rows while only their
    // identifiers differ. Whole-row averages dilute those identifiers, so the
    // high-contrast feature points must independently agree almost exactly.
    private const double RequiredFeatureMatchRatio = 0.65;
    private const double TinyOverlapThreshold = 2.0;
    private const int RefineCandidateCount = 4;
    private const int RefineRadius = 6;
    private const double ReverseAmbiguityMargin = 0.75;
    private readonly List<Drawing.Bitmap> _contentSlices = [];
    private Drawing.Bitmap? _previousFrame;
    private readonly int _maximumHeight;
    private readonly bool _detectFixedBars;
    private Drawing.Bitmap? _headerSlice;
    private Drawing.Bitmap? _footerSlice;
    private int _frameWidth;
    private int _fixedTop;
    private int _fixedBottom;
    private int _fixedLeft;
    private int _fixedRight;
    private bool _fixedEdgesLocked;
    private int? _lastAdvance;
    private ScrollDirection? _lastDirection;

    public int OutputHeight => _contentSlices.Sum(slice => slice.Height) +
                               (_headerSlice?.Height ?? 0) +
                               (_footerSlice?.Height ?? 0);
    public int MaximumHeight => _maximumHeight;
    public (int Left, int Right) FixedSideBars => (_fixedLeft, _fixedRight);
    public (int Top, int Bottom) FixedHorizontalBars => (_fixedTop, _fixedBottom);

    public ScrollingStitcher(int maximumHeight = DefaultMaximumHeight, bool detectFixedBars = true)
    {
        _maximumHeight = Math.Clamp(maximumHeight, 1024, 100000);
        _detectFixedBars = detectFixedBars;
    }

    public Drawing.Bitmap? Result => ComposeResult();

    /// <summary>
    /// Direction of the first accepted movement. Once locked, frames moving the
    /// opposite way are rejected (macOS parity) so scrolling back over content that
    /// is already in the merged image cannot duplicate it.
    /// </summary>
    internal ScrollDirection? LockedDirection => _lastDirection;
    internal string? LastFailureDiagnostics { get; private set; }
    public string? LastMatchDiagnostics { get; private set; }

    public StitchResult Append(Drawing.Bitmap frame, int expectedWheelDirection = 0) =>
        Append(frame, expectedWheelDirection, allowLargeGap: true);

    internal StitchResult Append(
        Drawing.Bitmap frame,
        int expectedWheelDirection,
        bool allowLargeGap)
    {
        using var normalized = Normalize(frame);
        if (_contentSlices.Count == 0)
        {
            var initialHeight = Math.Min(normalized.Height, _maximumHeight);
            _frameWidth = normalized.Width;
            _contentSlices.Add(CropRows(normalized, 0, initialHeight));
            _previousFrame = new Drawing.Bitmap(normalized);
            LastMatchDiagnostics = $"initial height={initialHeight}";
            return StitchResult.Added;
        }
        if (_frameWidth != normalized.Width || _previousFrame is null ||
            _previousFrame.Size != normalized.Size)
            return StitchResult.NoMatch;

        var detectedEdges = _detectFixedBars
            ? FindStationaryEdges(_previousFrame, normalized)
            : new FixedEdges(0, 0);
        if (!_fixedEdgesLocked)
        {
            _fixedTop = detectedEdges.Top;
            _fixedBottom = detectedEdges.Bottom;
        }
        if (_fixedTop + _fixedBottom > normalized.Height / 2)
        {
            _fixedTop = 0;
            _fixedBottom = 0;
        }
        if (_detectFixedBars && !_fixedEdgesLocked)
        {
            var sideEdges = FindStationarySideEdges(_previousFrame, normalized);
            _fixedLeft = sideEdges.Left;
            _fixedRight = sideEdges.Right;
            if (_fixedLeft + _fixedRight > normalized.Width / 2)
            {
                _fixedLeft = 0;
                _fixedRight = 0;
            }
        }

        var match = FindOverlap(
            _previousFrame,
            normalized,
            _fixedTop,
            _fixedBottom,
            _fixedLeft,
            _fixedRight,
            expectedWheelDirection,
            allowLargeGap);
        if (match is null) return StitchResult.NoMatch;
        LastMatchDiagnostics =
            $"direction={match.Value.Direction} advance={match.Value.NewContentHeight} " +
            $"overlap={match.Value.Overlap} score={match.Value.Score:F2} " +
            $"features={match.Value.FeatureMatchRatio:F2} " +
            $"previousAdvance={_lastAdvance?.ToString() ?? "none"} largeGap={allowLargeGap}";
        if (match.Value.NewContentHeight == 0 ||
            (match.Value.NewContentHeight < 8 && !_fixedEdgesLocked))
            return StitchResult.Duplicate;

        var existingContentHeight = _contentSlices.Sum(slice => slice.Height);
        if (_lastDirection is null) existingContentHeight -= _fixedTop + _fixedBottom;
        if (existingContentHeight <= 0) return StitchResult.NoMatch;
        var nextHeight = _fixedTop + existingContentHeight + match.Value.NewContentHeight + _fixedBottom;
        if (nextHeight > _maximumHeight) return StitchResult.HeightLimit;

        if (_lastDirection is null)
            BootstrapSlices(_previousFrame, _fixedTop, _fixedBottom);

        Drawing.Bitmap newSlice;
        if (match.Value.Direction == ScrollDirection.Down)
        {
            newSlice = CropRows(
                normalized,
                _fixedTop + match.Value.Overlap,
                match.Value.NewContentHeight);
            _contentSlices.Add(newSlice);
            ReplaceSlice(ref _footerSlice, normalized, normalized.Height - _fixedBottom, _fixedBottom);
        }
        else
        {
            newSlice = CropRows(normalized, _fixedTop, match.Value.NewContentHeight);
            _contentSlices.Insert(0, newSlice);
            ReplaceSlice(ref _headerSlice, normalized, 0, _fixedTop);
        }

        _previousFrame.Dispose();
        _previousFrame = new Drawing.Bitmap(normalized);
        _lastAdvance = match.Value.NewContentHeight;
        _lastDirection = match.Value.Direction;
        _fixedEdgesLocked = true;
        return StitchResult.Added;
    }

    private Match? FindOverlap(
        Drawing.Bitmap previous,
        Drawing.Bitmap current,
        int fixedTop,
        int fixedBottom,
        int fixedLeft,
        int fixedRight,
        int expectedWheelDirection,
        bool allowLargeGap)
    {
        LastFailureDiagnostics = null;
        var a = ReadPixels(previous);
        var b = ReadPixels(current);
        var width = current.Width;
        var bodyHeight = current.Height - fixedTop - fixedBottom;
        if (bodyHeight < 48) return null;

        // Ignore shell/navigation rails that stay fixed while the central
        // content scrolls. Asymmetric bounds preserve usable signal on the
        // opposite edge when only one side contains fixed chrome.
        var (xStart, xEnd) = MatchingColumnBounds(width, fixedLeft, fixedRight);
        var duplicateScore = Difference(a, previous.Width, fixedTop, b, width, fixedTop,
            width, bodyHeight, xStart, xEnd);
        if (duplicateScore < 0.15)
            return new Match(ScrollDirection.Down, bodyHeight, 0, duplicateScore);

        // Rows that carry visible content (text, markers, separators). Blank rows
        // match at every offset, so scoring only these rows prevents sparse pages
        // from aligning at wrong positions.
        var activeRows = ComputeActiveRows(a, previous.Width, fixedTop, bodyHeight, xStart, xEnd);
        var totalActiveRows = 0;
        foreach (var active in activeRows) if (active) totalActiveRows++;

        var searchDirections = _lastDirection is { } lockedSearchDirection
            ? new[] { lockedSearchDirection }
            : expectedWheelDirection < 0
                ? new[] { ScrollDirection.Down }
                : expectedWheelDirection > 0
                    ? new[] { ScrollDirection.Up }
                    : new[] { ScrollDirection.Down, ScrollDirection.Up };

        // The first Chromium compositor sample after a wheel event can move only
        // one-to-seven pixels. The main matcher starts at eight because larger
        // candidates need ambiguity/refinement scoring. Handle this tiny range
        // separately: otherwise a repeated card one period away can be the first
        // viable candidate and append content that is still on screen.
        Match? tinyMatch = null;
        foreach (var direction in searchDirections)
        {
            for (var advance = 1; advance < 8; advance++)
            {
                var overlap = bodyHeight - advance;
                var score = direction == ScrollDirection.Down
                    ? Difference(
                        a, previous.Width, fixedTop + advance,
                        b, width, fixedTop,
                        width, overlap, xStart, xEnd)
                    : Difference(
                        a, previous.Width, fixedTop,
                        b, width, fixedTop + advance,
                        width, overlap, xStart, xEnd);
                var activeMetrics = direction == ScrollDirection.Down
                    ? MeasureActive(
                        a, previous.Width, fixedTop + advance,
                        b, width, fixedTop,
                        width, overlap, xStart, xEnd, activeRows, advance)
                    : MeasureActive(
                        a, previous.Width, fixedTop,
                        b, width, fixedTop + advance,
                        width, overlap, xStart, xEnd, activeRows, 0);
                var distinctiveRowsAgree = activeMetrics.ActiveCount > 0
                    ? activeMetrics.MatchRatio >= 0.98 &&
                      activeMetrics.FeatureMatchRatio >= RequiredFeatureMatchRatio
                    : totalActiveRows == 0 && score < 0.15;
                if (!distinctiveRowsAgree || score > TinyOverlapThreshold ||
                    tinyMatch is { } existingTiny && existingTiny.Score <= score)
                    continue;
                tinyMatch = new Match(direction, overlap, advance, score, activeMetrics.FeatureMatchRatio);
            }
        }
        if (tinyMatch is not null) return tinyMatch;

        var minOverlap = Math.Max(24, bodyHeight / 12);
        var maxOverlap = Math.Max(minOverlap, bodyHeight - 8);
        var maximumContinuousAdvance = allowLargeGap
            ? int.MaxValue
            : MaximumContinuousAdvance(bodyHeight, minOverlap);
        var smallestRejectedAdvance = int.MaxValue;
        var candidates = new List<(double Rank, Match Match, ActiveMetrics Metrics)>();
        var coarseStep = Math.Max(4, bodyHeight / 160);
        for (var overlap = maxOverlap; overlap >= minOverlap; overlap -= coarseStep)
        {
            foreach (var searchDirection in searchDirections)
            {
                Consider(searchDirection, overlap,
                    searchDirection == ScrollDirection.Down
                        ? MeasureActive(a, previous.Width, fixedTop + bodyHeight - overlap,
                            b, width, fixedTop, width, overlap, xStart, xEnd, activeRows, bodyHeight - overlap)
                        : MeasureActive(a, previous.Width, fixedTop,
                            b, width, fixedTop + bodyHeight - overlap,
                            width, overlap, xStart, xEnd, activeRows, 0));
            }
        }

        // Refine the best few coarse candidates to exact-pixel alignment. A single
        // best candidate can be a spurious low-score match on repetitive content,
        // and its refinement window would then never reach the true offset.
        foreach (var candidate in candidates.ToArray())
        {
            var refinedDirection = candidate.Match.Direction;
            var refinedLow = Math.Max(minOverlap, candidate.Match.Overlap - RefineRadius);
            var refinedHigh = Math.Min(maxOverlap, candidate.Match.Overlap + RefineRadius);
            for (var overlap = refinedLow; overlap <= refinedHigh; overlap++)
            {
                Consider(refinedDirection, overlap,
                    refinedDirection == ScrollDirection.Down
                        ? MeasureActive(a, previous.Width, fixedTop + bodyHeight - overlap,
                            b, width, fixedTop, width, overlap, xStart, xEnd, activeRows, bodyHeight - overlap)
                        : MeasureActive(a, previous.Width, fixedTop,
                            b, width, fixedTop + bodyHeight - overlap,
                            width, overlap, xStart, xEnd, activeRows, 0));
            }
        }

        if (candidates.Count == 0)
        {
            var recovery = FindRecoveryOverlap(
                a, b, width, fixedTop, bodyHeight, xStart, xEnd,
                expectedWheelDirection, allowLargeGap);
            if (recovery is null)
                LastFailureDiagnostics = smallestRejectedAdvance == int.MaxValue
                    ? "primary-empty/recovery-none"
                    : $"continuous-gap-rejected advance={smallestRejectedAdvance} max={maximumContinuousAdvance}";
            return recovery;
        }
        var (bestRank, bestMatch, bestMetrics) = candidates[0];
        var runnerUp = candidates.Skip(1).FirstOrDefault(candidate =>
            candidate.Match.Direction != bestMatch.Direction ||
            Math.Abs(candidate.Match.NewContentHeight - bestMatch.NewContentHeight) > Math.Max(8, bodyHeight / 50));
        var continuitySeparatesRunner =
            expectedWheelDirection != 0 &&
            _lastAdvance is { } continuityAnchor &&
            runnerUp.Match.Direction == bestMatch.Direction &&
            Math.Abs(bestMatch.NewContentHeight - continuityAnchor) + Math.Max(8, bodyHeight / 50) <
            Math.Abs(runnerUp.Match.NewContentHeight - continuityAnchor);
        if (runnerUp.Match.NewContentHeight > 0 &&
            runnerUp.Rank - bestRank < 1.25 &&
            !continuitySeparatesRunner)
        {
            var recovery = FindRecoveryOverlap(
                a, b, width, fixedTop, bodyHeight, xStart, xEnd,
                expectedWheelDirection, allowLargeGap);
            if (recovery is null)
                LastFailureDiagnostics =
                    $"primary-ambiguous best={bestMatch.Direction}/{bestMatch.NewContentHeight}/{bestRank:F2} " +
                    $"runner={runnerUp.Match.Direction}/{runnerUp.Match.NewContentHeight}/{runnerUp.Rank:F2}";
            return recovery;
        }
        if (_lastDirection is { } lockedDirection && expectedWheelDirection == 0)
        {
            var oppositeDirection = lockedDirection == ScrollDirection.Down
                ? ScrollDirection.Up
                : ScrollDirection.Down;
            var reverseMatch = FindRecoveryOverlap(
                a,
                b,
                width,
                fixedTop,
                bodyHeight,
                xStart,
                xEnd,
                expectedWheelDirection: 0,
                allowLargeGap,
                forcedDirection: oppositeDirection);
            var reverseAdvanceTolerance = Math.Max(32, bodyHeight / 4);
            var reverseAdvanceAnchor = _lastAdvance ?? bestMatch.NewContentHeight;
            if (reverseMatch is { Score: <= 8.0 } reverse)
            {
                var reverseAdvanceIsPlausible =
                    Math.Abs(reverse.NewContentHeight - reverseAdvanceAnchor) <= reverseAdvanceTolerance;
                var reverseIsAmbiguous =
                    reverseAdvanceIsPlausible &&
                    reverse.Score <= bestMatch.Score + ReverseAmbiguityMargin;
                if (reverseIsAmbiguous)
                {
                    LastFailureDiagnostics =
                        $"reverse-ambiguous best={bestMatch.Direction}/{bestMatch.NewContentHeight}/{bestMatch.Score:F2} " +
                        $"reverse={reverse.Direction}/{reverse.NewContentHeight}/{reverse.Score:F2} " +
                        $"anchor={reverseAdvanceAnchor}";
                    return null;
                }
            }
        }
        var acceptable = bestMetrics.ActiveCount > 0
            ? bestMetrics.MatchRatio >= RequiredMatchRatio &&
              bestMetrics.FeatureMatchRatio >= RequiredFeatureMatchRatio
            : totalActiveRows == 0 && bestMetrics.OverallAverage < 24.0;
        var finalMatch = acceptable
            ? bestMatch
            : FindRecoveryOverlap(
                a, b, width, fixedTop, bodyHeight, xStart, xEnd,
                expectedWheelDirection, allowLargeGap);
        if (finalMatch is null)
            LastFailureDiagnostics =
                $"unacceptable best={bestMatch.Direction}/{bestMatch.NewContentHeight}/{bestRank:F2} " +
                $"ratio={bestMetrics.MatchRatio:F2} features={bestMetrics.FeatureMatchRatio:F2} " +
                $"active={bestMetrics.ActiveCount}";
        return finalMatch;

        void Consider(ScrollDirection direction, int overlap, ActiveMetrics metrics)
        {
            var advance = bodyHeight - overlap;
            if (advance > maximumContinuousAdvance)
            {
                if (advance < smallestRejectedAdvance) smallestRejectedAdvance = advance;
                return;
            }
            var continuityPenalty = _lastAdvance is null
                ? 0
                : Math.Abs(advance - _lastAdvance.Value) * 12.0 / bodyHeight;
            var score = metrics.ActiveCount > 0
                ? (1 - metrics.MatchRatio) * 100 +
                  Math.Min(metrics.OverallAverage, 24.0) * 1.25
                : totalActiveRows == 0
                    ? metrics.OverallAverage
                    : double.MaxValue;
            var rank = score + continuityPenalty;
            var candidate = (rank, new Match(
                direction,
                overlap,
                advance,
                score,
                metrics.FeatureMatchRatio), metrics);
            if (candidates.Count < RefineCandidateCount)
            {
                candidates.Add(candidate);
                candidates.Sort(static (x, y) => x.Rank.CompareTo(y.Rank));
                return;
            }
            if (rank < candidates[^1].Rank)
            {
                candidates[^1] = candidate;
                candidates.Sort(static (x, y) => x.Rank.CompareTo(y.Rank));
            }
        }
    }

    /// <summary>
    /// Marks rows of the previous frame's content region that visibly differ from
    /// their vertical neighbor. Only these rows carry alignment information; blank
    /// rows match at any offset and must not dilute the score.
    /// </summary>
    private static bool[] ComputeActiveRows(
        byte[] a, int aWidth, int fixedTop, int bodyHeight, int xStart, int xEnd)
    {
        var active = new bool[bodyHeight];
        var width = aWidth;
        var xStep = Math.Max(2, (xEnd - xStart) / 256);
        for (var y = 0; y < bodyHeight; y++)
        {
            if (RowHasContrast(a, width, fixedTop + y, xStart, xEnd, xStep))
            {
                active[y] = true;
                continue;
            }
            // Uniform separator rows have no internal contrast but still carry
            // alignment information when they stand out from both neighbors.
            var differsFromPrevious = y > 0 &&
                RowsDiffer(a, width, fixedTop + y - 1, fixedTop + y, xStart, xEnd, xStep);
            var differsFromNext = y + 1 < bodyHeight &&
                RowsDiffer(a, width, fixedTop + y, fixedTop + y + 1, xStart, xEnd, xStep);
            if (differsFromPrevious && differsFromNext) active[y] = true;
        }
        return active;
    }

    private static bool RowHasContrast(byte[] a, int width, int y, int xStart, int xEnd, int xStep)
    {
        var minR = 255;
        var minG = 255;
        var minB = 255;
        var maxR = 0;
        var maxG = 0;
        var maxB = 0;
        for (var x = xStart; x < xEnd; x += xStep)
        {
            var i = (y * width + x) * 4;
            if (a[i] < minR) minR = a[i];
            if (a[i] > maxR) maxR = a[i];
            if (a[i + 1] < minG) minG = a[i + 1];
            if (a[i + 1] > maxG) maxG = a[i + 1];
            if (a[i + 2] < minB) minB = a[i + 2];
            if (a[i + 2] > maxB) maxB = a[i + 2];
        }
        return (maxR - minR) + (maxG - minG) + (maxB - minB) > ActiveColumnThreshold;
    }

    /// <summary>
    /// True when any sampled column differs strongly between two adjacent rows.
    /// Row averages dilute thin content (a 4px marker in a wide row), so activity
    /// uses the strongest column instead.
    /// </summary>
    private static bool RowsDiffer(byte[] a, int width, int y1, int y2, int xStart, int xEnd, int xStep)
    {
        for (var x = xStart; x < xEnd; x += xStep)
        {
            var i1 = (y1 * width + x) * 4;
            var i2 = (y2 * width + x) * 4;
            var difference = Math.Abs(a[i1] - a[i2]) +
                             Math.Abs(a[i1 + 1] - a[i2 + 1]) +
                             Math.Abs(a[i1 + 2] - a[i2 + 2]);
            if (difference > ActiveColumnThreshold) return true;
        }
        return false;
    }

    /// <summary>
    /// Computes the difference between the candidate overlap regions, weighted
    /// toward the content rows of the previous frame. Blank regions fall back to
    /// the overall average so featureless pages can still stitch.
    /// </summary>
    private static ActiveMetrics MeasureActive(
        byte[] a, int aWidth, int aY,
        byte[] b, int bWidth, int bY,
        int width, int height, int xStart, int xEnd,
        bool[] activeRows, int activeOffset)
    {
        var xStep = Math.Max(2, (xEnd - xStart) / 256);
        var backgroundRowStep = Math.Max(1, height / 96);
        var activeCount = 0;
        var matchedActiveRows = 0;
        var featurePointCount = 0;
        var matchedFeaturePoints = 0;
        long overallTotal = 0;
        long overallSamples = 0;
        for (var y = 0; y < height; y++)
        {
            var rowActive = activeOffset + y >= 0 &&
                            activeOffset + y < activeRows.Length &&
                            activeRows[activeOffset + y];
            if (!rowActive && y % backgroundRowStep != 0) continue;
            long rowSamples = 0;
            long rowDifferenceTotal = 0;
            long featureDifferenceTotal = 0;
            long featureSamples = 0;
            var hasPreviousPixel = false;
            var previousB = 0;
            var previousG = 0;
            var previousR = 0;
            var previousDifference = 0;
            for (var x = xStart; x < xEnd; x += xStep)
            {
                var ai = ((aY + y) * aWidth + x) * 4;
                var bi = ((bY + y) * bWidth + x) * 4;
                var difference = Math.Abs(a[ai] - b[bi]) +
                                 Math.Abs(a[ai + 1] - b[bi + 1]) +
                                 Math.Abs(a[ai + 2] - b[bi + 2]);
                rowSamples += 3;
                rowDifferenceTotal += difference;
                if (hasPreviousPixel)
                {
                    var horizontalContrast = Math.Abs(a[ai] - previousB) +
                                             Math.Abs(a[ai + 1] - previousG) +
                                             Math.Abs(a[ai + 2] - previousR);
                    if (horizontalContrast >= ActiveColumnThreshold)
                    {
                        featureDifferenceTotal += previousDifference + difference;
                        featureSamples += 6;
                        featurePointCount++;
                        if ((previousDifference + difference) / 6.0 < ActiveFeatureMatchThreshold)
                            matchedFeaturePoints++;
                    }
                }
                previousB = a[ai];
                previousG = a[ai + 1];
                previousR = a[ai + 2];
                previousDifference = difference;
                hasPreviousPixel = true;
                overallTotal += difference;
                overallSamples += 3;
            }
            if (rowActive && rowSamples > 0)
            {
                activeCount++;
                // Browser zoom, fractional DPI, and compositor scaling can shift
                // glyph antialiasing by half a pixel. Score horizontal features as
                // a group instead of rejecting a row because one edge pixel moved;
                // unlike a whole-row average, this still catches tiny markers on
                // otherwise blank pages.
                var featureAverage = featureSamples > 0
                    ? (double)featureDifferenceTotal / featureSamples
                    : (double)rowDifferenceTotal / rowSamples;
                if (featureAverage < ActiveFeatureMatchThreshold)
                    matchedActiveRows++;
            }
        }
        var overallAverage = overallSamples == 0
            ? double.MaxValue
            : (double)overallTotal / overallSamples;
        var matchRatio = activeCount == 0
            ? 0d
            : (double)matchedActiveRows / activeCount;
        var featureMatchRatio = featurePointCount == 0
            ? matchRatio
            : (double)matchedFeaturePoints / featurePointCount;
        return new ActiveMetrics(overallAverage, matchRatio, featureMatchRatio, activeCount);
    }

    private static FixedEdges FindStationaryEdges(Drawing.Bitmap previous, Drawing.Bitmap current)
    {
        var a = ReadPixels(previous);
        var b = ReadPixels(current);
        var width = current.Width;
        var height = current.Height;
        var side = Math.Min(width / 3, Math.Max(24, width / 20));
        // Keep the mask conservative, matching the macOS implementation. A large
        // unchanged patch of page content must not be mistaken for fixed chrome.
        var limit = Math.Min(height / 5, 160);
        var top = CountStableRows(a, b, width, height, side, limit, fromTop: true);
        var bottom = CountStableRows(a, b, width, height, side, limit, fromTop: false);
        if (top < MinimumFixedEdgeHeight) top = 0;
        if (bottom < MinimumFixedEdgeHeight) bottom = 0;
        return new FixedEdges(top, bottom);
    }

    private static SideEdges FindStationarySideEdges(Drawing.Bitmap previous, Drawing.Bitmap current)
    {
        var a = ReadPixels(previous);
        var b = ReadPixels(current);
        var width = current.Width;
        var height = current.Height;
        // Browser navigation rails can occupy roughly one fifth of a narrow
        // capture. Probe far enough to reach the moving content; the caller's
        // combined-width guard still rejects symmetric page gutters that are not
        // fixed application chrome.
        var conservativeLimit = Math.Min(width / 6, 120);
        var limit = Math.Min(width / 3, 240);
        var left = CountStableColumns(a, b, width, height, limit, fromLeft: true);
        var right = CountStableColumns(a, b, width, height, limit, fromLeft: false);
        if (left > conservativeLimit && !HasWideSideRailSignal(a, width, height, left, fromLeft: true))
            left = 0;
        if (right > conservativeLimit && !HasWideSideRailSignal(a, width, height, right, fromLeft: false))
            right = 0;
        if (left < MinimumFixedEdgeHeight) left = 0;
        if (right < MinimumFixedEdgeHeight) right = 0;
        return new SideEdges(left, right);
    }

    private static bool HasWideSideRailSignal(
        byte[] pixels,
        int width,
        int height,
        int railWidth,
        bool fromLeft)
    {
        if (railWidth <= 0) return false;
        var xStep = Math.Max(1, railWidth / 64);
        var yStep = Math.Max(1, height / 128);
        var baseX = fromLeft ? 0 : width - 1;
        var baseIndex = baseX * 4;
        var baseB = pixels[baseIndex];
        var baseG = pixels[baseIndex + 1];
        var baseR = pixels[baseIndex + 2];
        var samples = 0;
        var contrasting = 0;
        for (var offset = 0; offset < railWidth; offset += xStep)
        {
            var x = fromLeft ? offset : width - 1 - offset;
            for (var y = 0; y < height; y += yStep)
            {
                var index = (y * width + x) * 4;
                var difference = Math.Abs(pixels[index] - baseB) +
                                 Math.Abs(pixels[index + 1] - baseG) +
                                 Math.Abs(pixels[index + 2] - baseR);
                samples++;
                if (difference >= ActiveColumnThreshold) contrasting++;
            }
        }
        return samples > 0 && (double)contrasting / samples >= 0.05;
    }

    private static int CountStableColumns(byte[] a, byte[] b, int width, int height, int limit, bool fromLeft)
    {
        var step = Math.Max(1, height / 512);
        for (var offset = 0; offset < limit; offset++)
        {
            var x = fromLeft ? offset : width - 1 - offset;
            var maximumDifference = 0;
            for (var y = 0; y < height; y += step)
            {
                var index = (y * width + x) * 4;
                var difference = Math.Abs(a[index] - b[index]) +
                                 Math.Abs(a[index + 1] - b[index + 1]) +
                                 Math.Abs(a[index + 2] - b[index + 2]);
                if (difference > maximumDifference) maximumDifference = difference;
            }
            if (maximumDifference >= ActiveColumnThreshold) return offset;
        }
        // Reaching the probe ceiling without finding moving content does not
        // prove that the whole strip is fixed chrome. Wide page gutters are a
        // common example: masking them as sidebars removes useful columns from
        // matching and can make a large scroll look like a tiny advance.
        return 0;
    }

    private static int CountStableRows(byte[] a, byte[] b, int width, int height, int side, int limit, bool fromTop)
    {
        // Dense horizontal sampling is still cheap for at most 160 candidate rows
        // and prevents narrow glyphs or card borders from disappearing between
        // samples on wide high-DPI captures.
        var xStep = Math.Max(1, (width - side * 2) / 512);
        var sampledColumns = Math.Max(1, (width - side * 2 + xStep - 1) / xStep);
        // Fixed browser chrome often contains a small live counter, caret, timer,
        // or loading indicator. Treating one changed glyph as a moving row cuts the
        // fixed header in the middle and makes every real content overlap fail.
        // Requiring a modest horizontal footprint still rejects page rows and card
        // borders while tolerating those localized updates.
        // A narrow capture makes a changing scroll counter occupy a much larger
        // percentage of the header than it does on a full monitor. Allow one
        // localized quarter-width status area to change; actual scrolling page
        // rows and card borders still span most of the usable width.
        var movingColumnThreshold = Math.Max(6, (int)Math.Ceiling(sampledColumns * 0.25));
        for (var offset = 0; offset < limit; offset++)
        {
            var y = fromTop ? offset : height - 1 - offset;
            var movingColumns = 0;
            for (var x = side; x < width - side; x += xStep)
            {
                var index = (y * width + x) * 4;
                var difference = Math.Abs(a[index] - b[index]) +
                                 Math.Abs(a[index + 1] - b[index + 1]) +
                                 Math.Abs(a[index + 2] - b[index + 2]);
                if (difference < ActiveColumnThreshold) continue;
                movingColumns++;
                if (movingColumns >= movingColumnThreshold) return offset;
            }
        }
        // Reaching the probe ceiling without observing a moving row is
        // inconclusive. Treating the entire ceiling as fixed would silently trim
        // sparse or periodic page content; keeping it in the body is safer.
        return 0;
    }

    private void BootstrapSlices(Drawing.Bitmap baseFrame, int fixedTop, int fixedBottom)
    {
        foreach (var slice in _contentSlices) slice.Dispose();
        _contentSlices.Clear();

        ReplaceSlice(ref _headerSlice, baseFrame, 0, fixedTop);
        var contentHeight = baseFrame.Height - fixedTop - fixedBottom;
        if (contentHeight > 0)
            _contentSlices.Add(CropRows(baseFrame, fixedTop, contentHeight));
        ReplaceSlice(ref _footerSlice, baseFrame, baseFrame.Height - fixedBottom, fixedBottom);
    }

    private static void ReplaceSlice(
        ref Drawing.Bitmap? destination,
        Drawing.Bitmap source,
        int sourceY,
        int height)
    {
        destination?.Dispose();
        destination = height > 0 ? CropRows(source, sourceY, height) : null;
    }

    private static Drawing.Bitmap CropRows(Drawing.Bitmap source, int sourceY, int height)
    {
        if (height <= 0) throw new ArgumentOutOfRangeException(nameof(height));
        var result = new Drawing.Bitmap(source.Width, height, PixelFormat.Format32bppArgb);
        CopyRows(source, sourceY, result, 0, height);
        return result;
    }

    private Drawing.Bitmap? ComposeResult()
    {
        if (_contentSlices.Count == 0 || _frameWidth <= 0 || OutputHeight <= 0) return null;
        var result = new Drawing.Bitmap(_frameWidth, OutputHeight, PixelFormat.Format32bppArgb);
        var destinationY = 0;
        if (_headerSlice is not null)
        {
            CopyRows(_headerSlice, 0, result, destinationY, _headerSlice.Height);
            destinationY += _headerSlice.Height;
        }
        foreach (var slice in _contentSlices)
        {
            CopyRows(slice, 0, result, destinationY, slice.Height);
            destinationY += slice.Height;
        }
        if (_footerSlice is not null)
            CopyRows(_footerSlice, 0, result, destinationY, _footerSlice.Height);
        return result;
    }

    public Drawing.Bitmap? CreatePreviewBitmap(int maxWidth, int maxHeight)
    {
        if (_contentSlices.Count == 0 || _frameWidth <= 0 || OutputHeight <= 0 ||
            maxWidth <= 0 || maxHeight <= 0)
            return null;

        // Fixed side bars are an alignment mask only. The selected region defines
        // the capture bounds, so previews and final output must keep its full width.
        var outputWidth = _frameWidth;
        var scale = Math.Min(1d, Math.Min((double)maxWidth / outputWidth, (double)maxHeight / OutputHeight));
        var targetWidth = Math.Max(1, (int)Math.Round(outputWidth * scale));
        var targetHeight = Math.Max(1, (int)Math.Round(OutputHeight * scale));
        var preview = new Drawing.Bitmap(targetWidth, targetHeight, PixelFormat.Format32bppPArgb);
        using var graphics = Drawing.Graphics.FromImage(preview);
        graphics.CompositingMode = Drawing.Drawing2D.CompositingMode.SourceCopy;
        graphics.InterpolationMode = Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = Drawing.Drawing2D.PixelOffsetMode.HighQuality;

        var sourceY = 0;
        if (_headerSlice is not null)
            DrawPreviewSlice(_headerSlice, ref sourceY);
        foreach (var slice in _contentSlices)
            DrawPreviewSlice(slice, ref sourceY);
        if (_footerSlice is not null)
            DrawPreviewSlice(_footerSlice, ref sourceY);
        return preview;

        void DrawPreviewSlice(Drawing.Bitmap slice, ref int accumulatedSourceY)
        {
            var top = (int)Math.Round((double)accumulatedSourceY * targetHeight / OutputHeight);
            accumulatedSourceY += slice.Height;
            var bottom = (int)Math.Round((double)accumulatedSourceY * targetHeight / OutputHeight);
            if (bottom <= top) return;
            graphics.DrawImage(
                slice,
                new Drawing.Rectangle(0, top, targetWidth, bottom - top),
                new Drawing.Rectangle(0, 0, outputWidth, slice.Height),
                Drawing.GraphicsUnit.Pixel);
        }
    }

    private int MaximumContinuousAdvance(int bodyHeight, int minOverlap)
    {
        // CaptureFrameStream preserves wheel boundaries and samples the settling
        // animation, so adjacent queued frames should move by only a fraction of
        // the viewport. Repeated
        // cards can otherwise offer an excellent-looking overlap one or more card
        // periods away and append content that is already present. A genuinely
        // large jump is retried from a settled synchronous frame with this guard
        // explicitly disabled.
        // 300 px preserves fast wheel/touchpad steps on compact selections while
        // the one-third viewport bound keeps a repeated two-card alias (about
        // 420 px in the browser fixture) out of a normal sampled burst.
        var viewportAllowance = Math.Max(300, bodyHeight / 3);
        if (_lastAdvance is not { } lastAdvance)
            return Math.Min(bodyHeight - minOverlap, viewportAllowance);

        // Once movement is established, a single compositor sample must not jump
        // from a tiny transition (for example 3 px) to a repeated-card alias one
        // third of a viewport away. Real acceleration is represented by the burst
        // stream's bridge frames; without those frames, stopping is safer than
        // silently dropping content.
        var continuityAllowance = lastAdvance + Math.Max(48, bodyHeight / 8);
        return Math.Min(
            bodyHeight - minOverlap,
            Math.Min(viewportAllowance, continuityAllowance));
    }

    private Match? FindRecoveryOverlap(
        byte[] previous,
        byte[] current,
        int width,
        int fixedTop,
        int bodyHeight,
        int xStart,
        int xEnd,
        int expectedWheelDirection,
        bool allowLargeGap,
        ScrollDirection? forcedDirection = null)
    {
        if (bodyHeight < 64) return null;
        var minOverlap = Math.Max(48, bodyHeight / 12);
        var minDelta = 8;
        var maxDelta = bodyHeight - minOverlap;
        if (maxDelta < minDelta) return null;
        var maximumContinuousAdvance = allowLargeGap
            ? int.MaxValue
            : MaximumContinuousAdvance(bodyHeight, minOverlap);

        var activeRows = ComputeActiveRows(
            previous, width, fixedTop, bodyHeight, xStart, xEnd);
        var candidates = new List<(double Rank, Match Match)>();
        var directions = forcedDirection is { } forced
            ? new[] { forced }
            : _lastDirection is { } locked
            ? new[] { locked }
            : expectedWheelDirection < 0
                ? new[] { ScrollDirection.Down }
                : expectedWheelDirection > 0
                    ? new[] { ScrollDirection.Up }
                    : new[] { ScrollDirection.Down, ScrollDirection.Up };
        var coarseStep = Math.Max(2, bodyHeight / 180);
        foreach (var direction in directions)
        {
            for (var delta = minDelta; delta <= maxDelta; delta += coarseStep)
                Consider(direction, delta);
        }
        if (candidates.Count == 0) return null;

        var coarseBest = candidates[0].Match;
        var refineStart = Math.Max(minDelta, coarseBest.NewContentHeight - coarseStep * 2);
        var refineEnd = Math.Min(maxDelta, coarseBest.NewContentHeight + coarseStep * 2);
        for (var delta = refineStart; delta <= refineEnd; delta++)
            Consider(coarseBest.Direction, delta);

        candidates.Sort(static (left, right) => left.Rank.CompareTo(right.Rank));
        var best = candidates[0];
        var runnerUp = candidates.FirstOrDefault(candidate =>
            candidate.Match.Direction != best.Match.Direction ||
            Math.Abs(candidate.Match.NewContentHeight - best.Match.NewContentHeight) > 32);
        if (runnerUp.Match.NewContentHeight > 0 && runnerUp.Rank - best.Rank < 1.25)
            return null;
        return best.Match;

        void Consider(ScrollDirection direction, int delta)
        {
            if (delta > maximumContinuousAdvance) return;
            var overlap = bodyHeight - delta;
            var previousY = direction == ScrollDirection.Down ? fixedTop + delta : fixedTop;
            var currentY = direction == ScrollDirection.Down ? fixedTop : fixedTop + delta;
            var metrics = MeasureBands(
                previous, current, width, previousY, currentY, overlap, xStart, xEnd);
            if (metrics.BandCount == 0 || metrics.Average > 18.0 || metrics.Worst > 34.0 ||
                metrics.StrongBandCount < Math.Max(3, metrics.BandCount / 2))
                return;

            // Average band scores are intentionally tolerant of sparse pages,
            // but on repeated card layouts a wrong short offset can still look
            // mostly white. Recovery candidates must also align the distinctive
            // rows (text, borders, markers) from the previous viewport. Exact
            // scroll overlap should preserve almost all of them.
            var activeMetrics = MeasureActive(
                previous,
                width,
                previousY,
                current,
                width,
                currentY,
                width,
                overlap,
                xStart,
                xEnd,
                activeRows,
                direction == ScrollDirection.Down ? delta : 0);
            if (activeMetrics.ActiveCount > 0 &&
                (activeMetrics.MatchRatio < 0.80 ||
                 activeMetrics.FeatureMatchRatio < RequiredFeatureMatchRatio))
                return;

            var continuityPenalty = _lastAdvance is null
                ? 0
                : Math.Abs(delta - _lastAdvance.Value) * 12.0 / bodyHeight;
            var rank = metrics.Average + continuityPenalty + metrics.Variance * 0.08;
            candidates.Add((rank, new Match(
                direction,
                overlap,
                delta,
                metrics.Average,
                activeMetrics.FeatureMatchRatio)));
        }
    }

    private static BandMetrics MeasureBands(
        byte[] previous,
        byte[] current,
        int width,
        int previousY,
        int currentY,
        int overlapHeight,
        int xStart,
        int xEnd)
    {
        var bandCount = Math.Min(10, Math.Max(6, overlapHeight / 80));
        var bandHeight = Math.Max(12, Math.Min(28, overlapHeight / Math.Max(3, bandCount + 1)));
        var columnStep = Math.Max(2, (xEnd - xStart) / 72);
        var differences = new List<double>(bandCount);
        for (var index = 0; index < bandCount; index++)
        {
            var ratio = (double)(index + 1) / (bandCount + 1);
            var rowOffset = Math.Min(
                Math.Max(0, overlapHeight - bandHeight),
                (int)(Math.Max(0, overlapHeight - bandHeight) * ratio));
            long total = 0;
            long samples = 0;
            for (var y = 0; y < bandHeight; y += 2)
            {
                for (var x = xStart; x < xEnd; x += columnStep)
                {
                    var a = ((previousY + rowOffset + y) * width + x) * 4;
                    var b = ((currentY + rowOffset + y) * width + x) * 4;
                    total += Math.Abs(previous[a] - current[b]);
                    total += Math.Abs(previous[a + 1] - current[b + 1]);
                    total += Math.Abs(previous[a + 2] - current[b + 2]);
                    samples += 3;
                }
            }
            if (samples > 0) differences.Add((double)total / samples);
        }
        if (differences.Count == 0) return default;
        var average = differences.Average();
        var variance = differences.Average(value => (value - average) * (value - average));
        return new BandMetrics(
            average,
            differences.Max(),
            variance,
            differences.Count(value => value <= 12.0),
            differences.Count);
    }

    /// <summary>
    /// Copies whole rows from one bitmap into another without any GDI+ scaling or
    /// interpolation. DrawImage slice composition blended the first/last row of each
    /// slice with its neighbor, which left a visible seam line at every scroll.
    /// </summary>
    private static void CopyRows(
        Drawing.Bitmap source,
        int sourceY,
        Drawing.Bitmap destination,
        int destinationY,
        int height)
    {
        if (height <= 0) return;
        var width = source.Width;
        var srcData = source.LockBits(
            new Drawing.Rectangle(0, sourceY, width, height),
            ImageLockMode.ReadOnly,
            PixelFormat.Format32bppArgb);
        var dstData = destination.LockBits(
            new Drawing.Rectangle(0, destinationY, width, height),
            ImageLockMode.WriteOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            var rowBytes = width * 4;
            if (srcData.Stride == rowBytes && dstData.Stride == rowBytes)
            {
                var buffer = new byte[rowBytes * height];
                Marshal.Copy(srcData.Scan0, buffer, 0, buffer.Length);
                Marshal.Copy(buffer, 0, dstData.Scan0, buffer.Length);
            }
            else
            {
                var buffer = new byte[rowBytes];
                for (var row = 0; row < height; row++)
                {
                    Marshal.Copy(srcData.Scan0 + row * srcData.Stride, buffer, 0, rowBytes);
                    Marshal.Copy(buffer, 0, dstData.Scan0 + row * dstData.Stride, rowBytes);
                }
            }
        }
        finally
        {
            source.UnlockBits(srcData);
            destination.UnlockBits(dstData);
        }
    }

    private static (int Start, int End) MatchingColumnBounds(int width, int fixedLeft, int fixedRight)
    {
        var safetyInset = Math.Max(10, width / 48);
        var start = Math.Clamp(fixedLeft + safetyInset, 0, Math.Max(0, width - 1));
        var end = Math.Clamp(width - fixedRight - safetyInset, start + 1, width);
        if (end - start >= Math.Max(40, width / 6)) return (start, end);

        start = Math.Clamp(fixedLeft, 0, Math.Max(0, width - 1));
        end = Math.Clamp(width - fixedRight, start + 1, width);
        return (start, end);
    }

    private static double Difference(byte[] a, int aWidth, int aY, byte[] b, int bWidth, int bY,
        int width, int height, int xStart, int xEnd)
    {
        long total = 0;
        long samples = 0;
        var xStep = Math.Max(2, (xEnd - xStart) / 256);
        var yStep = Math.Max(1, height / 48);
        for (var y = 0; y < height; y += yStep)
        {
            for (var x = xStart; x < xEnd; x += xStep)
            {
                var ai = ((aY + y) * aWidth + x) * 4;
                var bi = ((bY + y) * bWidth + x) * 4;
                total += Math.Abs(a[ai] - b[bi]) + Math.Abs(a[ai + 1] - b[bi + 1]) + Math.Abs(a[ai + 2] - b[bi + 2]);
                samples += 3;
            }
        }
        return samples == 0 ? double.MaxValue : (double)total / samples;
    }

    private static Drawing.Bitmap Normalize(Drawing.Bitmap image)
    {
        var result = new Drawing.Bitmap(image.Width, image.Height, PixelFormat.Format32bppArgb);
        using var graphics = Drawing.Graphics.FromImage(result);
        graphics.DrawImageUnscaled(image, 0, 0);
        return result;
    }

    private static byte[] ReadPixels(Drawing.Bitmap bitmap)
    {
        var rect = new Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[Math.Abs(data.Stride) * bitmap.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return bytes;
        }
        finally { bitmap.UnlockBits(data); }
    }

    public void Dispose()
    {
        foreach (var slice in _contentSlices) slice.Dispose();
        _contentSlices.Clear();
        _headerSlice?.Dispose();
        _footerSlice?.Dispose();
        _previousFrame?.Dispose();
    }

    internal enum ScrollDirection { Down, Up }
    private readonly record struct FixedEdges(int Top, int Bottom);
    private readonly record struct SideEdges(int Left, int Right);
    private readonly record struct Match(
        ScrollDirection Direction,
        int Overlap,
        int NewContentHeight,
        double Score,
        double FeatureMatchRatio = 1.0);
    private readonly record struct ActiveMetrics(
        double OverallAverage,
        double MatchRatio,
        double FeatureMatchRatio,
        int ActiveCount);
    private readonly record struct BandMetrics(
        double Average,
        double Worst,
        double Variance,
        int StrongBandCount,
        int BandCount);
}
