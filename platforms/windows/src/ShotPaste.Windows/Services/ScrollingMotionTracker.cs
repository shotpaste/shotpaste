using Drawing = System.Drawing;

namespace ShotPaste.Windows.Services;

/// <summary>
/// Which scroll directions the motion tracker may consider for a frame pair.
/// A wheel hint may narrow one frame's search, but later frames can freely
/// reverse because the canvas tracks both historical extents.
/// </summary>
internal enum MotionSearchDirection { Both, DownOnly, UpOnly }

/// <summary>
/// Per-frame hints for the motion tracker. All edge values are full-resolution
/// pixels of the capture region; the tracker scales them into its pyramid.
/// </summary>
internal readonly record struct MotionGuidance(
    int FixedTop,
    int FixedBottom,
    int FixedLeft,
    int FixedRight,
    MotionSearchDirection SearchDirection,
    double LastAdvance,
    bool AllowLargeGap);

/// <summary>
/// Estimated content motion between two frames, in full-resolution pixels.
/// DeltaY is positive when the content moved up (the user scrolled down) and
/// negative when the content moved down (the user scrolled up).
/// </summary>
internal readonly record struct MotionEstimate(
    double DeltaX,
    double DeltaY,
    int ConfidentBandCount,
    int BandCount,
    double PeakCorrelation,
    double PeakSeparation,
    bool UsedGlobalFallback);

/// <summary>
/// Single-channel frame used for motion estimation. Frames are downsampled to
/// roughly 480 px wide so per-band NCC stays cheap enough to run on every
/// captured frame during the scroll.
/// </summary>
internal sealed class GrayFrame
{
    internal GrayFrame(int width, int height, byte[] pixels, double scale)
    {
        Width = width;
        Height = height;
        Pixels = pixels;
        Scale = scale;
    }

    internal int Width { get; }
    internal int Height { get; }
    internal byte[] Pixels { get; }

    /// <summary>Gray pixels per full-resolution pixel (at most 1).</summary>
    internal double Scale { get; }

    /// <summary>
    /// Converts a 32bpp BGRA pixel buffer into a luma frame no wider than
    /// <paramref name="maxWidth"/>. Center sampling keeps this O(output pixels).
    /// </summary>
    internal static GrayFrame FromPixels(
        byte[] bgra,
        int width,
        int height,
        int maxWidth = ScrollingMotionTracker.DefaultMaxWidth)
    {
        var scale = Math.Min(1d, maxWidth / (double)Math.Max(1, width));
        var destWidth = Math.Max(1, (int)Math.Round(width * scale));
        var destHeight = Math.Max(1, (int)Math.Round(height * scale));
        var pixels = new byte[destWidth * destHeight];
        for (var y = 0; y < destHeight; y++)
        {
            var sourceY = Math.Min(height - 1, (int)((y + 0.5) * height / (double)destHeight));
            var sourceRow = sourceY * width;
            var destRow = y * destWidth;
            for (var x = 0; x < destWidth; x++)
            {
                var sourceX = Math.Min(width - 1, (int)((x + 0.5) * width / (double)destWidth));
                var index = (sourceRow + sourceX) * 4;
                // Format32bppArgb memory layout is B, G, R, A.
                pixels[destRow + x] = (byte)(
                    (77 * bgra[index + 2] + 150 * bgra[index + 1] + 29 * bgra[index]) >> 8);
            }
        }
        return new GrayFrame(destWidth, destHeight, pixels, destWidth / (double)Math.Max(1, width));
    }

    /// <summary>Half-resolution level used for the coarse band search.</summary>
    internal GrayFrame Downsample2()
    {
        var destWidth = Math.Max(1, Width / 2);
        var destHeight = Math.Max(1, Height / 2);
        var pixels = new byte[destWidth * destHeight];
        for (var y = 0; y < destHeight; y++)
        {
            var sourceY = y * 2;
            var nextY = Math.Min(Height - 1, sourceY + 1);
            var destRow = y * destWidth;
            for (var x = 0; x < destWidth; x++)
            {
                var sourceX = x * 2;
                var nextX = Math.Min(Width - 1, sourceX + 1);
                var sum = Pixels[sourceY * Width + sourceX] +
                          Pixels[sourceY * Width + nextX] +
                          Pixels[nextY * Width + sourceX] +
                          Pixels[nextY * Width + nextX];
                pixels[destRow + x] = (byte)(sum >> 2);
            }
        }
        return new GrayFrame(destWidth, destHeight, pixels, Scale * (destWidth / (double)Width));
    }
}

/// <summary>
/// Real-time motion estimator for scrolling capture. Splits the frame body into
/// horizontal bands and runs a per-band vertical NCC search guided by the last
/// accepted advance (with a broader recovery range when requested). The median
/// of the confident band votes is the frame delta, refined to subpixel accuracy
/// with parabolic interpolation on the NCC curve at the full pyramid level.
/// Bands whose windows do not move while the rest of the page scrolls (sticky
/// toolbars floating mid-page) are excluded from the vote; sticky headers,
/// footers and side rails arrive through <see cref="MotionGuidance"/> and are
/// excluded from the searched area entirely.
/// </summary>
internal sealed class ScrollingMotionTracker
{
    internal const int DefaultMaxWidth = 480;
    private const double MinimumPeakCorrelation = 0.55;
    private const double MinimumGlobalFallbackCorrelation = 0.60;
    private const double MinimumPeakSeparation = 0.04;
    private const int PeakExclusionRadius = 2;
    private const double MaximumHorizontalDrift = 8.0;
    private const int MinimumBodyRows = 24;

    internal string? LastDiagnostics { get; private set; }

    // The frame accepted as "current" usually becomes "previous" for the next
    // estimate, so its pyramid level and integral images are cached by reference.
    private PreparedFrame? _prepared;

    internal MotionEstimate? Estimate(GrayFrame previous, GrayFrame current, MotionGuidance guidance)
    {
        LastDiagnostics = null;
        if (previous.Width != current.Width || previous.Height != current.Height)
        {
            LastDiagnostics =
                $"size-mismatch previous={previous.Width}x{previous.Height} " +
                $"current={current.Width}x{current.Height}";
            return null;
        }

        var p = ReferenceEquals(_prepared?.Source, previous) ? _prepared! : Prepare(previous);
        var c = Prepare(current);
        _prepared = c;

        var level = p.Level1;
        var scale = level.Scale;
        var width = level.Width;
        var height = level.Height;
        var bodyTop = Math.Clamp((int)Math.Round(guidance.FixedTop * scale), 0, height - 1);
        var bodyBottom = Math.Clamp(
            height - (int)Math.Round(guidance.FixedBottom * scale), bodyTop + 1, height);
        var body = bodyBottom - bodyTop;
        if (body < MinimumBodyRows)
        {
            LastDiagnostics = $"body-too-small rows={body}";
            return null;
        }

        var (xStart, xEnd) = ColumnBounds(width, guidance.FixedLeft, guidance.FixedRight, scale);
        var columnStep = Math.Max(1, (xEnd - xStart) / 160);
        var minOverlap = Math.Max(8, body / 12);
        var maxDelta = body - minOverlap;
        if (maxDelta < 1)
        {
            LastDiagnostics = $"no-search-range body={body}";
            return null;
        }

        var bandCount = Math.Clamp(body / 16, 4, 8);
        var minBandRows = Math.Max(6, body / bandCount / 2);
        var searchDown = guidance.SearchDirection is MotionSearchDirection.Both or MotionSearchDirection.DownOnly;
        var searchUp = guidance.SearchDirection is MotionSearchDirection.Both or MotionSearchDirection.UpOnly;

        var context = new SearchContext(
            p, c, bodyTop, bodyBottom, xStart, xEnd, columnStep, bandCount, minBandRows, minOverlap);

        // dy = 0 must always be measurable: it is how stationary periods and
        // scroll boundaries report as duplicates instead of failed matches.
        context.Evaluate(0);
        foreach (var segment in PrimarySegments(guidance, scale, body, maxDelta, searchDown, searchUp))
            context.EvaluateRange(segment.Sign, segment.Lo, segment.Hi);

        var estimate = TryBuildEstimate(context, previous, current, guidance);
        if (estimate is not null) return estimate;

        if (guidance.AllowLargeGap)
        {
            // Broader recovery range: the whole plausible overlap. Used by the
            // offline/test Append path and by the settled retry after the
            // guided range has already failed.
            foreach (var segment in RecoverySegments(maxDelta, searchDown, searchUp))
                context.EvaluateRange(segment.Sign, segment.Lo, segment.Hi);
            estimate = TryBuildEstimate(context, previous, current, guidance);
            if (estimate is not null) return estimate;
        }

        LastDiagnostics = context.FailureDiagnostics;
        return null;
    }

    private static IEnumerable<(int Sign, int Lo, int Hi)> PrimarySegments(
        MotionGuidance guidance,
        double scale,
        int body,
        int maxDelta,
        bool searchDown,
        bool searchUp)
    {
        int lo;
        int hi;
        if (guidance.LastAdvance > 0)
        {
            // Guided range: expected delta ±(1.5×lastDelta+24px), in pyramid units.
            var center = (int)Math.Round(guidance.LastAdvance * scale);
            var radius = Math.Max(3, (int)Math.Round((1.5 * guidance.LastAdvance + 24) * scale));
            lo = Math.Max(1, center - radius);
            hi = Math.Min(maxDelta, center + radius);
        }
        else
        {
            // No motion history yet. The default reach mirrors the previous
            // pipeline's continuous-advance allowance: 300 px or one third of
            // the viewport, whichever is larger, in full-resolution pixels.
            var fullResBody = body / Math.Max(scale, 0.01);
            var reach = (int)Math.Round(Math.Max(300, fullResBody / 3.0) * scale);
            lo = 1;
            hi = Math.Clamp(reach, Math.Min(8, maxDelta), maxDelta);
        }
        if (hi < lo) yield break;
        if (searchDown) yield return (1, lo, hi);
        if (searchUp) yield return (-1, lo, hi);
    }

    private static IEnumerable<(int Sign, int Lo, int Hi)> RecoverySegments(
        int maxDelta,
        bool searchDown,
        bool searchUp)
    {
        if (searchDown) yield return (1, 1, maxDelta);
        if (searchUp) yield return (-1, 1, maxDelta);
    }

    private static MotionEstimate? TryBuildEstimate(
        SearchContext context,
        GrayFrame previous,
        GrayFrame current,
        MotionGuidance guidance)
    {
        var votes = new List<double>();
        foreach (var curve in context.BandCurves)
        {
            var peak = BestPeaks(curve);
            if (peak.Ncc >= MinimumPeakCorrelation &&
                peak.Ncc - peak.Second >= MinimumPeakSeparation)
            {
                votes.Add(peak.Dy);
            }
        }

        // Sticky mid-page bands (floating toolbars, sticky table headers) vote
        // "no motion" while the page scrolls under them. When a clear majority
        // of the bands moved, drop the stationary votes instead of letting the
        // median collapse toward zero.
        var moved = votes.Where(vote => Math.Abs(vote) > 1).ToList();
        var effective = moved.Count >= 2 && moved.Count * 2 >= votes.Count ? moved : votes;
        var required = Math.Max(2, (context.BandCount + 2) / 3);
        double deltaLevel1;
        var fallback = false;
        if (effective.Count >= required)
        {
            effective.Sort();
            deltaLevel1 = effective.Count % 2 == 1
                ? effective[effective.Count / 2]
                : (effective[effective.Count / 2 - 1] + effective[effective.Count / 2]) / 2.0;
            // The band median must still describe the frame as a whole; a
            // disagreement here means the votes locked onto periodic aliases.
            var sanity = context.GlobalNccAt((int)Math.Round(deltaLevel1));
            if (sanity < MinimumPeakCorrelation - 0.1)
            {
                context.FailureDiagnostics =
                    $"band-global-disagree median={deltaLevel1:F1} global={sanity:F2} " +
                    $"votes={effective.Count}/{context.BandCount}";
                return null;
            }
        }
        else
        {
            // Geometrically constrained searches (a large delta on a short
            // viewport leaves few fully-valid bands) fall back to the NCC curve
            // of the whole overlap region, which is defined for every delta.
            var global = BestPeaks(context.GlobalCurve);
            if (global.Ncc < MinimumGlobalFallbackCorrelation ||
                global.Ncc - global.Second < MinimumPeakSeparation)
            {
                context.FailureDiagnostics =
                    $"low-confidence bands={votes.Count}/{context.BandCount} " +
                    $"peak={global.Ncc:F2} separation={global.Ncc - global.Second:F2} dy={global.Dy}";
                return null;
            }
            deltaLevel1 = global.Dy;
            fallback = true;
        }

        var globalPeak = BestPeaks(context.GlobalCurve);
        var deltaY = RefineVertical(previous, current, context, guidance, deltaLevel1, out var deltaLevel0);
        var deltaX = Math.Abs(deltaLevel1) < 0.5
            ? 0
            : EstimateHorizontalDrift(previous, current, guidance, deltaLevel0);
        return new MotionEstimate(
            deltaX,
            deltaY,
            effective.Count,
            context.BandCount,
            globalPeak.Ncc,
            globalPeak.Ncc - globalPeak.Second,
            fallback);
    }

    /// <summary>
    /// Re-scores the whole overlap on the full pyramid level around the coarse
    /// delta and interpolates the NCC peak parabolically for subpixel accuracy.
    /// </summary>
    private static double RefineVertical(
        GrayFrame previous,
        GrayFrame current,
        SearchContext context,
        MotionGuidance guidance,
        double deltaLevel1,
        out int deltaLevel0)
    {
        var level1Width = Math.Max(1, context.PreviousLevel1Width);
        var center = deltaLevel1 * previous.Width / (double)level1Width;
        var rounded = (int)Math.Round(center);
        var sign = Math.Sign(deltaLevel1);
        deltaLevel0 = rounded;
        if (sign == 0) return 0;

        var scale0 = previous.Scale;
        var bodyTop = Math.Clamp((int)Math.Round(guidance.FixedTop * scale0), 0, previous.Height - 1);
        var bodyBottom = Math.Clamp(
            previous.Height - (int)Math.Round(guidance.FixedBottom * scale0), bodyTop + 1, previous.Height);
        var (xStart, xEnd) = ColumnBounds(previous.Width, guidance.FixedLeft, guidance.FixedRight, scale0);
        var minOverlap = Math.Max(12, (bodyBottom - bodyTop) / 12);

        var candidates = new List<(int Dy, double Ncc)>();
        for (var candidate = rounded - 2; candidate <= rounded + 2; candidate++)
        {
            if (candidate == 0 || Math.Sign(candidate) != sign) continue;
            var ncc = OverlapNcc(
                previous, current, bodyTop, bodyBottom, candidate, 0, xStart, xEnd, minOverlap);
            if (!double.IsNaN(ncc)) candidates.Add((candidate, ncc));
        }
        if (candidates.Count == 0)
            return deltaLevel1 / Math.Max(0.01, context.PreviousLevel1Scale);

        var bestIndex = 0;
        for (var index = 1; index < candidates.Count; index++)
            if (candidates[index].Ncc > candidates[bestIndex].Ncc) bestIndex = index;
        deltaLevel0 = candidates[bestIndex].Dy;
        var refined = (double)candidates[bestIndex].Dy;
        if (bestIndex > 0 && bestIndex < candidates.Count - 1)
        {
            refined += Math.Clamp(
                ParabolicOffset(
                    candidates[bestIndex - 1].Ncc,
                    candidates[bestIndex].Ncc,
                    candidates[bestIndex + 1].Ncc),
                -1,
                1);
        }
        return refined / Math.Max(0.01, scale0);
    }

    /// <summary>
    /// Small horizontal drift estimate (compositor sub-pixel pans), clamped to
    /// ±8 full-resolution pixels. Reported for diagnostics; the canvas blits
    /// whole rows and does not shift content horizontally.
    /// </summary>
    private static double EstimateHorizontalDrift(
        GrayFrame previous,
        GrayFrame current,
        MotionGuidance guidance,
        int deltaLevel0)
    {
        var scale0 = previous.Scale;
        var bodyTop = Math.Clamp((int)Math.Round(guidance.FixedTop * scale0), 0, previous.Height - 1);
        var bodyBottom = Math.Clamp(
            previous.Height - (int)Math.Round(guidance.FixedBottom * scale0), bodyTop + 1, previous.Height);
        var (xStart, xEnd) = ColumnBounds(previous.Width, guidance.FixedLeft, guidance.FixedRight, scale0);
        var minOverlap = Math.Max(12, (bodyBottom - bodyTop) / 12);
        var maxDrift = Math.Max(1, (int)Math.Ceiling(MaximumHorizontalDrift * scale0));
        // Keep enough columns on both sides for the shift to stay inside the frame.
        xStart += maxDrift;
        xEnd -= maxDrift;
        if (xEnd - xStart < 16) return 0;

        var bestDx = 0;
        var bestNcc = double.MinValue;
        var curve = new List<(int Dx, double Ncc)>();
        for (var dx = -maxDrift; dx <= maxDrift; dx++)
        {
            var ncc = OverlapNcc(
                previous, current, bodyTop, bodyBottom, deltaLevel0, dx, xStart, xEnd, minOverlap);
            if (double.IsNaN(ncc)) continue;
            curve.Add((dx, ncc));
            if (ncc > bestNcc)
            {
                bestNcc = ncc;
                bestDx = dx;
            }
        }
        if (curve.Count == 0) return 0;
        var bestIndex = curve.FindIndex(entry => entry.Dx == bestDx);
        var refined = (double)bestDx;
        if (bestIndex > 0 && bestIndex < curve.Count - 1)
        {
            refined += Math.Clamp(
                ParabolicOffset(
                    curve[bestIndex - 1].Ncc,
                    curve[bestIndex].Ncc,
                    curve[bestIndex + 1].Ncc),
                -1,
                1);
        }
        return Math.Clamp(refined / Math.Max(0.01, scale0), -MaximumHorizontalDrift, MaximumHorizontalDrift);
    }

    private static double ParabolicOffset(double left, double center, double right)
    {
        var denominator = left - 2 * center + right;
        if (Math.Abs(denominator) < 1e-9) return 0;
        return 0.5 * (left - right) / denominator;
    }

    private static (int Dy, double Ncc, double Second) BestPeaks(List<(int Dy, double Ncc)> curve)
    {
        if (curve.Count == 0) return (0, double.MinValue, double.MinValue);
        var bestIndex = 0;
        for (var index = 1; index < curve.Count; index++)
            if (curve[index].Ncc > curve[bestIndex].Ncc) bestIndex = index;
        var best = curve[bestIndex];
        var second = double.MinValue;
        foreach (var entry in curve)
        {
            if (Math.Abs(entry.Dy - best.Dy) <= PeakExclusionRadius) continue;
            if (entry.Ncc > second) second = entry.Ncc;
        }
        // A single-candidate curve is unambiguous by construction.
        if (second == double.MinValue) second = best.Ncc - 1;
        return (best.Dy, best.Ncc, second);
    }

    private static (int Start, int End) ColumnBounds(int width, int fixedLeft, int fixedRight, double scale)
    {
        var inset = Math.Max(2, width / 48);
        var start = Math.Clamp((int)Math.Round(fixedLeft * scale) + inset, 0, Math.Max(0, width - 1));
        var end = Math.Clamp(width - (int)Math.Round(fixedRight * scale) - inset, start + 1, width);
        if (end - start >= Math.Max(24, width / 6)) return (start, end);
        start = Math.Clamp((int)Math.Round(fixedLeft * scale), 0, Math.Max(0, width - 1));
        end = Math.Clamp(width - (int)Math.Round(fixedRight * scale), start + 1, width);
        return (start, end);
    }

    private static PreparedFrame Prepare(GrayFrame source)
    {
        var level1 = source.Downsample2();
        var width = level1.Width;
        var height = level1.Height;
        var stride = width + 1;
        var sum = new long[(height + 1) * stride];
        var squareSum = new long[(height + 1) * stride];
        for (var y = 1; y <= height; y++)
        {
            long rowSum = 0;
            long rowSquareSum = 0;
            var sourceRow = (y - 1) * width;
            var row = y * stride;
            var previousRow = (y - 1) * stride;
            for (var x = 1; x <= width; x++)
            {
                var value = level1.Pixels[sourceRow + x - 1];
                rowSum += value;
                rowSquareSum += value * value;
                sum[row + x] = sum[previousRow + x] + rowSum;
                squareSum[row + x] = squareSum[previousRow + x] + rowSquareSum;
            }
        }
        return new PreparedFrame(source, level1, sum, squareSum);
    }

    private static double WindowSum(long[] integral, int stride, int rLo, int rHi, int cLo, int cHi) =>
        integral[rHi * stride + cHi] - integral[rLo * stride + cHi] -
        integral[rHi * stride + cLo] + integral[rLo * stride + cLo];

    private sealed class PreparedFrame(GrayFrame source, GrayFrame level1, long[] sum, long[] squareSum)
    {
        internal GrayFrame Source { get; } = source;
        internal GrayFrame Level1 { get; } = level1;
        internal long[] Sum { get; } = sum;
        internal long[] SquareSum { get; } = squareSum;
    }

    /// <summary>
    /// Accumulates the per-band and whole-overlap NCC curves for one frame pair.
    /// A positive dy means the content moved up (scrolled down): the previous
    /// row <c>r</c> then matches the current row <c>r - dy</c>.
    /// </summary>
    private sealed class SearchContext
    {
        private readonly PreparedFrame _previous;
        private readonly PreparedFrame _current;
        private readonly int _bodyTop;
        private readonly int _bodyBottom;
        private readonly int _xStart;
        private readonly int _xEnd;
        private readonly int _columnStep;
        private readonly int _minBandRows;
        private readonly int _minOverlap;

        internal SearchContext(
            PreparedFrame previous,
            PreparedFrame current,
            int bodyTop,
            int bodyBottom,
            int xStart,
            int xEnd,
            int columnStep,
            int bandCount,
            int minBandRows,
            int minOverlap)
        {
            _previous = previous;
            _current = current;
            _bodyTop = bodyTop;
            _bodyBottom = bodyBottom;
            _xStart = xStart;
            _xEnd = xEnd;
            _columnStep = columnStep;
            _minBandRows = minBandRows;
            _minOverlap = minOverlap;
            BandCount = bandCount;
            BandStarts = new int[bandCount];
            BandEnds = new int[bandCount];
            BandCurves = new List<(int Dy, double Ncc)>[bandCount];
            var body = bodyBottom - bodyTop;
            for (var index = 0; index < bandCount; index++)
            {
                BandCurves[index] = new List<(int Dy, double Ncc)>();
                BandStarts[index] = bodyTop + index * body / bandCount;
                BandEnds[index] = bodyTop + (index + 1) * body / bandCount;
            }
        }

        internal int BandCount { get; }
        internal int[] BandStarts { get; }
        internal int[] BandEnds { get; }
        internal List<(int Dy, double Ncc)>[] BandCurves { get; }
        internal List<(int Dy, double Ncc)> GlobalCurve { get; } = [];
        internal string? FailureDiagnostics { get; set; }
        internal int PreviousLevel1Width => _previous.Level1.Width;
        internal double PreviousLevel1Scale => _previous.Level1.Scale;

        internal void EvaluateRange(int sign, int lo, int hi)
        {
            for (var magnitude = lo; magnitude <= hi; magnitude++)
                Evaluate(sign * magnitude);
        }

        internal void Evaluate(int dy)
        {
            // Whole-overlap curve: valid for every delta, used for confidence
            // sanity checks, subpixel refinement, and the geometric fallback.
            var globalLo = Math.Max(_bodyTop, _bodyTop + dy);
            var globalHi = Math.Min(_bodyBottom, _bodyBottom + dy);
            if (globalHi - globalLo >= _minOverlap)
                GlobalCurve.Add((dy, BandNcc(globalLo, globalHi, dy)));
            for (var index = 0; index < BandCount; index++)
            {
                var lo = Math.Max(BandStarts[index], _bodyTop + dy);
                var hi = Math.Min(BandEnds[index], _bodyBottom + dy);
                if (hi - lo < _minBandRows) continue;
                BandCurves[index].Add((dy, BandNcc(lo, hi, dy)));
            }
        }

        internal double GlobalNccAt(int dy)
        {
            foreach (var entry in GlobalCurve)
                if (entry.Dy == dy) return entry.Ncc;
            var lo = Math.Max(_bodyTop, _bodyTop + dy);
            var hi = Math.Min(_bodyBottom, _bodyBottom + dy);
            return hi - lo >= _minOverlap ? BandNcc(lo, hi, dy) : 0;
        }

        /// <summary>
        /// NCC between previous rows [rLo, rHi) and current rows shifted by dy.
        /// Window sums come from the integral images; only the cross term walks
        /// the pixels, on a strided column grid, scaled back to full statistics.
        /// </summary>
        private double BandNcc(int rLo, int rHi, int dy)
        {
            var level = _previous.Level1;
            var width = level.Width;
            var stride = width + 1;
            var rows = rHi - rLo;
            var columns = _xEnd - _xStart;
            if (rows <= 0 || columns <= 0) return 0;
            var sumA = WindowSum(_previous.Sum, stride, rLo, rHi, _xStart, _xEnd);
            var squareA = WindowSum(_previous.SquareSum, stride, rLo, rHi, _xStart, _xEnd);
            var sumB = WindowSum(_current.Sum, stride, rLo - dy, rHi - dy, _xStart, _xEnd);
            var squareB = WindowSum(_current.SquareSum, stride, rLo - dy, rHi - dy, _xStart, _xEnd);

            long cross = 0;
            var samples = 0;
            for (var r = rLo; r < rHi; r++)
            {
                var aRow = r * width;
                var bRow = (r - dy) * width;
                for (var x = _xStart; x < _xEnd; x += _columnStep)
                {
                    cross += level.Pixels[aRow + x] * _current.Level1.Pixels[bRow + x];
                    samples++;
                }
            }
            if (samples == 0) return 0;

            var count = (double)rows * columns;
            var scaledCross = cross * (count / samples);
            var varianceA = squareA - sumA * sumA / count;
            var varianceB = squareB - sumB * sumB / count;
            if (varianceA <= 1e-3 || varianceB <= 1e-3) return 0;
            var numerator = scaledCross - sumA * sumB / count;
            return numerator / Math.Sqrt(varianceA * varianceB);
        }
    }

    /// <summary>
    /// Direct normalized cross-correlation of the overlap region at a full
    /// pyramid level, with all statistics sampled consistently. Used only for
    /// the final subpixel refinement and drift estimate, where few candidates
    /// are evaluated.
    /// </summary>
    private static double OverlapNcc(
        GrayFrame previous,
        GrayFrame current,
        int bodyTop,
        int bodyBottom,
        int dy,
        int dx,
        int xStart,
        int xEnd,
        int minOverlap)
    {
        var rLo = Math.Max(bodyTop, bodyTop + dy);
        var rHi = Math.Min(bodyBottom, bodyBottom + dy);
        if (rHi - rLo < minOverlap) return double.NaN;
        // Column validity for the horizontal shift: previous column x compares
        // against current column x - dx, so both must stay inside the window.
        var cLo = Math.Max(xStart, xStart + dx);
        var cHi = Math.Min(xEnd, xEnd + dx);
        if (cHi - cLo < 16) return double.NaN;

        var width = previous.Width;
        long sumA = 0;
        long sumB = 0;
        long squareA = 0;
        long squareB = 0;
        long cross = 0;
        long samples = 0;
        for (var r = rLo; r < rHi; r += 2)
        {
            var aRow = r * width;
            var bRow = (r - dy) * width;
            for (var x = cLo; x < cHi; x += 2)
            {
                var a = previous.Pixels[aRow + x];
                var b = current.Pixels[bRow + x - dx];
                sumA += a;
                sumB += b;
                squareA += a * a;
                squareB += b * b;
                cross += a * b;
                samples++;
            }
        }
        if (samples < 16) return double.NaN;
        var count = (double)samples;
        var varianceA = squareA - sumA * sumA / count;
        var varianceB = squareB - sumB * sumB / count;
        if (varianceA <= 1e-3 || varianceB <= 1e-3) return double.NaN;
        return (cross - sumA * sumB / count) / Math.Sqrt(varianceA * varianceB);
    }
}
