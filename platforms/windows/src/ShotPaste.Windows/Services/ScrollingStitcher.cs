using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Drawing = System.Drawing;

namespace ShotPaste.Windows.Services;

public enum StitchResult { Added, Duplicate, NoMatch, HeightLimit }

/// <summary>
/// Real-time scrolling stitcher. Each accepted frame is converted to a small
/// grayscale pyramid for band-voted NCC motion tracking; only the newly exposed
/// strip is copied into a bidirectional canvas. Result materialization happens
/// once at completion, while previews use the canvas' incremental thumbnail.
/// </summary>
public sealed class ScrollingStitcher : IDisposable
{
    public const int DefaultMaximumHeight = 32768;
    private const int MinimumFixedEdgeHeight = 4;
    private const double ActiveColumnThreshold = 48.0;
    private const double StationaryDifferenceThreshold = 0.15;
    private const double MinimumMotionPixels = 0.75;
    private const int MinimumInitialMotionPixels = 8;

    private readonly int _maximumHeight;
    private readonly bool _detectFixedBars;
    private readonly ScrollingMotionTracker _motionTracker = new();

    private ScrollingCanvas? _canvas;
    private GrayFrame? _previousGray;
    private byte[]? _previousPixels;
    private int _frameWidth;
    private int _frameHeight;
    private int _fixedTop;
    private int _fixedBottom;
    private int _fixedLeft;
    private int _fixedRight;
    private bool _fixedEdgesLocked;
    private double? _lastMotionDelta;
    private ScrollDirection? _firstDirection;

    public ScrollingStitcher(int maximumHeight = DefaultMaximumHeight, bool detectFixedBars = true)
    {
        _maximumHeight = Math.Clamp(maximumHeight, 1024, 100000);
        _detectFixedBars = detectFixedBars;
    }

    public int OutputHeight => _canvas?.UsedHeight ?? 0;
    public int MaximumHeight => _maximumHeight;
    public (int Left, int Right) FixedSideBars => (_fixedLeft, _fixedRight);
    public (int Top, int Bottom) FixedHorizontalBars => (_fixedTop, _fixedBottom);
    public Drawing.Bitmap? Result => _canvas?.ComposeResult();

    /// <summary>
    /// Direction of the first accepted movement. This is diagnostic state only;
    /// reverse motion remains valid and can grow the opposite canvas extent.
    /// </summary>
    internal ScrollDirection? LockedDirection => _firstDirection;
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
        var pixels = ReadPixels(normalized);

        if (_canvas is null)
        {
            _frameWidth = normalized.Width;
            _frameHeight = normalized.Height;
            _canvas = new ScrollingCanvas(_frameWidth, _frameHeight, _maximumHeight);
            _canvas.Seed(pixels, Math.Min(_frameHeight, _maximumHeight));
            _previousPixels = pixels;
            _previousGray = GrayFrame.FromPixels(pixels, _frameWidth, _frameHeight);
            LastFailureDiagnostics = null;
            LastMatchDiagnostics = $"initial height={OutputHeight}";
            return StitchResult.Added;
        }

        if (normalized.Width != _frameWidth || normalized.Height != _frameHeight ||
            _previousGray is null || _previousPixels is null)
        {
            LastFailureDiagnostics =
                $"size-mismatch expected={_frameWidth}x{_frameHeight} " +
                $"actual={normalized.Width}x{normalized.Height}";
            return StitchResult.NoMatch;
        }

        var frameDifference = SampledDifference(_previousPixels, pixels, _frameWidth, _frameHeight);
        if (frameDifference < StationaryDifferenceThreshold &&
            (!_fixedEdgesLocked || frameDifference < 0.001))
        {
            LastFailureDiagnostics = null;
            LastMatchDiagnostics = $"duplicate difference={frameDifference:F3}";
            return StitchResult.Duplicate;
        }

        if (_detectFixedBars && !_fixedEdgesLocked)
        {
            var horizontal = FindStationaryEdges(_previousPixels, pixels, _frameWidth, _frameHeight);
            _fixedTop = horizontal.Top;
            _fixedBottom = horizontal.Bottom;
            if (_fixedTop + _fixedBottom > _frameHeight / 2)
                _fixedTop = _fixedBottom = 0;

            var sides = FindStationarySideEdges(_previousPixels, pixels, _frameWidth, _frameHeight);
            _fixedLeft = sides.Left;
            _fixedRight = sides.Right;
            if (_fixedLeft + _fixedRight > _frameWidth / 2)
                _fixedLeft = _fixedRight = 0;
        }

        var currentGray = GrayFrame.FromPixels(pixels, _frameWidth, _frameHeight);
        var searchDirection = expectedWheelDirection switch
        {
            < 0 => MotionSearchDirection.DownOnly,
            > 0 => MotionSearchDirection.UpOnly,
            _ => MotionSearchDirection.Both,
        };
        var estimate = _motionTracker.Estimate(
            _previousGray,
            currentGray,
            new MotionGuidance(
                _fixedTop,
                _fixedBottom,
                _fixedLeft,
                _fixedRight,
                searchDirection,
                Math.Abs(_lastMotionDelta ?? 0),
                allowLargeGap));

        var pixelContext = new PixelMatchContext(
            _previousPixels,
            pixels,
            _frameWidth,
            _frameHeight,
            _fixedTop,
            _fixedBottom,
            _fixedLeft,
            _fixedRight);
        MotionEstimate? resolvedEstimate = null;
        if (estimate is { } tracked)
        {
            var integerDelta = (int)Math.Round(tracked.DeltaY);
            var validation = pixelContext.Measure(integerDelta);
            var continuityValid = _lastMotionDelta is not { } previousMotion ||
                Math.Abs(Math.Abs(integerDelta) - Math.Abs(previousMotion)) <=
                Math.Max(48, pixelContext.BodyHeight / 8);
            if (validation.IsStrongFastMatch && continuityValid)
                resolvedEstimate = tracked with { DeltaY = integerDelta };
        }

        if (resolvedEstimate is null)
        {
            var fallback = FindPixelMotion(
                pixelContext,
                searchDirection,
                Math.Abs(_lastMotionDelta ?? 0),
                allowLargeGap,
                out var pixelDiagnostics);
            if (fallback is null)
            {
                LastFailureDiagnostics =
                    $"tracker={_motionTracker.LastDiagnostics ?? "none"}; pixel={pixelDiagnostics}";
                return StitchResult.NoMatch;
            }
            resolvedEstimate = new MotionEstimate(
                0,
                fallback.Value.DeltaY,
                fallback.Value.ActiveCount,
                fallback.Value.ActiveCount,
                Math.Clamp(1 - fallback.Value.OverallAverage / 255.0, 0, 1),
                fallback.Value.FeatureMatchRatio,
                true);
        }

        var motion = resolvedEstimate.Value;
        if (Math.Abs(motion.DeltaY) < MinimumMotionPixels)
        {
            LastFailureDiagnostics = null;
            LastMatchDiagnostics =
                $"duplicate dy={motion.DeltaY:F2} peak={motion.PeakCorrelation:F3}";
            return StitchResult.Duplicate;
        }

        // Do not lock sticky edges on a one-to-seven-pixel compositor transition.
        // Keeping the older reference lets that motion accumulate into the next
        // stable frame; once edges are locked, tiny advances are safe to commit.
        if (!_fixedEdgesLocked && Math.Abs(motion.DeltaY) < MinimumInitialMotionPixels)
        {
            LastFailureDiagnostics = null;
            LastMatchDiagnostics = $"deferred-initial-motion dy={motion.DeltaY:F2}";
            return StitchResult.Duplicate;
        }

        var direction = motion.DeltaY >= 0 ? ScrollDirection.Down : ScrollDirection.Up;
        if (!_fixedEdgesLocked)
        {
            _firstDirection = direction;
            _fixedEdgesLocked = true;
        }

        var heightBudget = _maximumHeight - OutputHeight;
        if (heightBudget <= 0)
        {
            LastFailureDiagnostics = null;
            LastMatchDiagnostics = "height-limit";
            return StitchResult.HeightLimit;
        }

        var rows = _canvas.AdvanceCursor(motion.DeltaY, heightBudget);
        if (rows == 0)
        {
            // The user moved within the already captured coordinate range.
            _previousGray = currentGray;
            _previousPixels = pixels;
            _lastMotionDelta = motion.DeltaY;
            LastFailureDiagnostics = null;
            LastMatchDiagnostics =
                $"revisit direction={direction} dy={motion.DeltaY:F2} height={OutputHeight}";
            return StitchResult.Duplicate;
        }

        var committed = direction == ScrollDirection.Down
            ? _canvas.AppendDown(
                pixels,
                _frameHeight,
                _fixedTop,
                _fixedBottom,
                rows,
                (int)Math.Round(motion.DeltaX))
            : _canvas.AppendUp(
                pixels,
                _frameHeight,
                _fixedTop,
                _fixedBottom,
                rows,
                (int)Math.Round(motion.DeltaX));
        if (committed != rows)
        {
            LastFailureDiagnostics = $"strip-copy-failed planned={rows} committed={committed}";
            return StitchResult.NoMatch;
        }

        _previousGray = currentGray;
        _previousPixels = pixels;
        _lastMotionDelta = motion.DeltaY;
        LastFailureDiagnostics = null;
        LastMatchDiagnostics =
            $"direction={direction} advance={rows} dy={motion.DeltaY:F2} dx={motion.DeltaX:F2} " +
            $"bands={motion.ConfidentBandCount}/{motion.BandCount} " +
            $"peak={motion.PeakCorrelation:F3} separation={motion.PeakSeparation:F3} " +
            $"fallback={motion.UsedGlobalFallback}";
        return StitchResult.Added;
    }

    public Drawing.Bitmap? CreatePreviewBitmap(int maxWidth, int maxHeight) =>
        _canvas?.CreatePreviewBitmap(maxWidth, maxHeight);

    public void Dispose()
    {
        _canvas = null;
        _previousGray = null;
        _previousPixels = null;
    }

    private static Drawing.Bitmap Normalize(Drawing.Bitmap image)
    {
        var result = new Drawing.Bitmap(image.Width, image.Height, PixelFormat.Format32bppArgb);
        using var graphics = Drawing.Graphics.FromImage(result);
        graphics.CompositingMode = Drawing.Drawing2D.CompositingMode.SourceCopy;
        graphics.DrawImageUnscaled(image, 0, 0);
        return result;
    }

    private static byte[] ReadPixels(Drawing.Bitmap bitmap)
    {
        var rect = new Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var rowBytes = bitmap.Width * 4;
            var pixels = new byte[rowBytes * bitmap.Height];
            for (var row = 0; row < bitmap.Height; row++)
            {
                var sourceRow = data.Stride >= 0
                    ? data.Scan0 + row * data.Stride
                    : data.Scan0 + (bitmap.Height - 1 - row) * -data.Stride;
                Marshal.Copy(sourceRow, pixels, row * rowBytes, rowBytes);
            }
            return pixels;
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    private static double SampledDifference(byte[] previous, byte[] current, int width, int height)
    {
        long total = 0;
        long samples = 0;
        var rowStep = Math.Max(1, height / 48);
        var columnStep = Math.Max(1, width / 120);
        for (var y = 0; y < height; y += rowStep)
        {
            for (var x = 0; x < width; x += columnStep)
            {
                var index = (y * width + x) * 4;
                total += Math.Abs(previous[index] - current[index]);
                total += Math.Abs(previous[index + 1] - current[index + 1]);
                total += Math.Abs(previous[index + 2] - current[index + 2]);
                samples += 3;
            }
        }
        return samples == 0 ? 255 : (double)total / samples;
    }

    /// <summary>
    /// Pixel-domain fallback for sparse pages, repeated cards, and large jumps.
    /// The NCC tracker remains the per-frame fast path; this search runs only
    /// when its candidate cannot reproduce the distinctive rows in the actual
    /// BGRA frames.
    /// </summary>
    private static PixelMatch? FindPixelMotion(
        PixelMatchContext context,
        MotionSearchDirection direction,
        double lastAdvance,
        bool allowLargeGap,
        out string diagnostics)
    {
        diagnostics = "not-run";
        var maximumDelta = context.MaximumDelta;
        if (maximumDelta < 1)
        {
            diagnostics = "no-range";
            return null;
        }

        var searchLimit = maximumDelta;
        if (!allowLargeGap)
        {
            searchLimit = lastAdvance > 0
                ? Math.Min(maximumDelta, (int)Math.Ceiling(lastAdvance + Math.Max(48, context.BodyHeight / 8.0)))
                : Math.Min(maximumDelta, Math.Max(300, context.BodyHeight / 3));
        }
        if (searchLimit < 1)
        {
            diagnostics = "empty-limit";
            return null;
        }

        var signs = direction switch
        {
            MotionSearchDirection.DownOnly => new[] { 1 },
            MotionSearchDirection.UpOnly => new[] { -1 },
            _ => new[] { 1, -1 },
        };
        // Pixel equality has a sharp one-row peak: a coarse stride can skip an
        // otherwise perfect large-gap match entirely. This path is already the
        // rare recovery lane, so evaluate every integer displacement.
        const int coarseStep = 1;
        var candidates = new List<PixelMatch>();
        var evaluated = new HashSet<int>();

        foreach (var sign in signs)
        {
            for (var magnitude = 1; magnitude <= searchLimit; magnitude += coarseStep)
                Consider(sign * magnitude);
            Consider(sign * searchLimit);
        }

        foreach (var coarse in candidates.Take(6).ToArray())
        {
            var sign = Math.Sign(coarse.DeltaY);
            var magnitude = Math.Abs(coarse.DeltaY);
            var lower = Math.Max(1, magnitude - coarseStep * 2);
            var upper = Math.Min(searchLimit, magnitude + coarseStep * 2);
            for (var refined = lower; refined <= upper; refined++)
                Consider(sign * refined);
        }

        var acceptable = candidates
            .Where(candidate => candidate.IsAcceptable)
            .OrderBy(candidate => candidate.Rank)
            .ToList();
        if (acceptable.Count == 0)
        {
            diagnostics = "unacceptable " + string.Join(
                ',',
                candidates.Take(5).Select(candidate =>
                    $"{candidate.DeltaY}/{candidate.OverallAverage:F2}/" +
                    $"{candidate.FeatureMatchRatio:F2}/{candidate.ActiveCount}/{candidate.Rank:F2}"));
            return null;
        }

        var best = acceptable[0];
        var ambiguityDistance = Math.Max(8, context.BodyHeight / 50);
        var runnerUp = acceptable.Skip(1).FirstOrDefault(candidate =>
            Math.Sign(candidate.DeltaY) != Math.Sign(best.DeltaY) ||
            Math.Abs(candidate.DeltaY - best.DeltaY) > ambiguityDistance);
        if (!best.IsStrongFastMatch &&
            runnerUp.DeltaY != 0 &&
            runnerUp.Rank - best.Rank < 1.0)
        {
            var continuitySeparates = lastAdvance > 0 &&
                Math.Abs(Math.Abs(best.DeltaY) - lastAdvance) + ambiguityDistance <
                Math.Abs(Math.Abs(runnerUp.DeltaY) - lastAdvance);
            if (!continuitySeparates)
            {
                diagnostics =
                    $"ambiguous best={best.DeltaY}/{best.Rank:F2} " +
                    $"runner={runnerUp.DeltaY}/{runnerUp.Rank:F2}";
                return null;
            }
        }
        diagnostics = $"accepted={best.DeltaY}/{best.Rank:F2}";
        return best;

        void Consider(int deltaY)
        {
            if (deltaY == 0 || !evaluated.Add(deltaY)) return;
            var candidate = context.Measure(deltaY);
            if (candidates.Count < 12)
            {
                candidates.Add(candidate);
                candidates.Sort(static (left, right) => left.Rank.CompareTo(right.Rank));
                return;
            }
            if (candidate.Rank >= candidates[^1].Rank) return;
            candidates[^1] = candidate;
            candidates.Sort(static (left, right) => left.Rank.CompareTo(right.Rank));
        }
    }

    private sealed class PixelMatchContext
    {
        private readonly byte[] _previous;
        private readonly byte[] _current;
        private readonly int _width;
        private readonly int _contentTop;
        private readonly int _xStart;
        private readonly int _xEnd;
        private readonly FeaturePoint[] _featurePoints;

        internal PixelMatchContext(
            byte[] previous,
            byte[] current,
            int width,
            int height,
            int fixedTop,
            int fixedBottom,
            int fixedLeft,
            int fixedRight)
        {
            _previous = previous;
            _current = current;
            _width = width;
            _contentTop = Math.Clamp(fixedTop, 0, height - 1);
            var contentBottom = Math.Clamp(height - fixedBottom, _contentTop + 1, height);
            BodyHeight = contentBottom - _contentTop;
            MaximumDelta = Math.Max(0, BodyHeight - Math.Max(24, BodyHeight / 12));

            var inset = Math.Max(2, width / 48);
            _xStart = Math.Clamp(fixedLeft + inset, 0, Math.Max(0, width - 1));
            _xEnd = Math.Clamp(width - fixedRight - inset, _xStart + 1, width);
            if (_xEnd - _xStart < Math.Max(24, width / 6))
            {
                _xStart = Math.Clamp(fixedLeft, 0, Math.Max(0, width - 1));
                _xEnd = Math.Clamp(width - fixedRight, _xStart + 1, width);
            }
            _featurePoints = ComputeFeaturePoints(ComputeActiveRows());
        }

        internal int BodyHeight { get; }
        internal int MaximumDelta { get; }

        internal PixelMatch Measure(int deltaY)
        {
            var previousStart = Math.Max(0, deltaY);
            var previousEnd = Math.Min(BodyHeight, BodyHeight + deltaY);
            var overlap = previousEnd - previousStart;
            if (overlap < 24)
                return PixelMatch.Invalid(deltaY);

            long overallTotal = 0;
            long overallSamples = 0;
            var rowStep = Math.Max(1, overlap / 48);
            var columnStep = Math.Max(1, (_xEnd - _xStart) / 72);
            for (var previousRow = previousStart; previousRow < previousEnd; previousRow += rowStep)
            {
                var currentRow = previousRow - deltaY;
                AccumulateRowDifference(
                    previousRow,
                    currentRow,
                    columnStep,
                    ref overallTotal,
                    ref overallSamples);
            }

            var featurePointCount = 0;
            var matchedFeaturePoints = 0;
            foreach (var point in _featurePoints)
            {
                if (point.Row < previousStart || point.Row >= previousEnd) continue;
                featurePointCount++;
                var currentRow = point.Row - deltaY;
                var previousIndex = ((_contentTop + point.Row) * _width + point.X) * 4;
                var currentIndex = ((_contentTop + currentRow) * _width + point.X) * 4;
                var difference = Math.Abs(_previous[previousIndex] - _current[currentIndex]) +
                                 Math.Abs(_previous[previousIndex + 1] - _current[currentIndex + 1]) +
                                 Math.Abs(_previous[previousIndex + 2] - _current[currentIndex + 2]);
                if (difference < 72) matchedFeaturePoints++;
            }

            var overallAverage = overallSamples == 0
                ? double.MaxValue
                : (double)overallTotal / overallSamples;
            var featureMatchRatio = featurePointCount > 0
                ? (double)matchedFeaturePoints / featurePointCount
                : 0;
            var rank = featurePointCount > 0
                ? (1 - featureMatchRatio) * 100 + Math.Min(overallAverage, 32) * 1.25
                : overallAverage;
            return new PixelMatch(
                deltaY,
                overallAverage,
                featureMatchRatio,
                featurePointCount,
                rank);
        }

        private bool[] ComputeActiveRows()
        {
            var active = new bool[BodyHeight];
            var xStep = Math.Max(1, (_xEnd - _xStart) / 96);
            for (var row = 0; row < BodyHeight; row++)
            {
                var absoluteRow = _contentTop + row;
                var neighborRow = _contentTop + Math.Min(BodyHeight - 1, row + 1);
                var contrastSamples = 0;
                for (var x = _xStart; x < _xEnd; x += xStep)
                {
                    var index = (absoluteRow * _width + x) * 4;
                    var nextX = Math.Min(_xEnd - 1, x + 1);
                    var horizontal = (absoluteRow * _width + nextX) * 4;
                    var vertical = (neighborRow * _width + x) * 4;
                    var contrast = Math.Abs(_previous[index] - _previous[horizontal]) +
                                   Math.Abs(_previous[index + 1] - _previous[horizontal + 1]) +
                                   Math.Abs(_previous[index + 2] - _previous[horizontal + 2]) +
                                   Math.Abs(_previous[index] - _previous[vertical]) +
                                   Math.Abs(_previous[index + 1] - _previous[vertical + 1]) +
                                   Math.Abs(_previous[index + 2] - _previous[vertical + 2]);
                    if (contrast >= 48) contrastSamples++;
                }
                active[row] = contrastSamples >= 2;
            }
            return active;
        }

        private FeaturePoint[] ComputeFeaturePoints(bool[] activeRows)
        {
            var points = new List<FeaturePoint>();
            var xStep = Math.Max(1, (_xEnd - _xStart) / 256);
            for (var row = 0; row < BodyHeight; row++)
            {
                if (!activeRows[row]) continue;
                var absoluteRow = _contentTop + row;
                var neighborRow = _contentTop + Math.Min(BodyHeight - 1, row + 1);
                for (var x = _xStart; x < _xEnd; x += xStep)
                {
                    var nextX = Math.Min(_xEnd - 1, x + 1);
                    var index = (absoluteRow * _width + x) * 4;
                    var horizontal = (absoluteRow * _width + nextX) * 4;
                    var vertical = (neighborRow * _width + x) * 4;
                    var contrast = Math.Abs(_previous[index] - _previous[horizontal]) +
                                   Math.Abs(_previous[index + 1] - _previous[horizontal + 1]) +
                                   Math.Abs(_previous[index + 2] - _previous[horizontal + 2]) +
                                   Math.Abs(_previous[index] - _previous[vertical]) +
                                   Math.Abs(_previous[index + 1] - _previous[vertical + 1]) +
                                   Math.Abs(_previous[index + 2] - _previous[vertical + 2]);
                    if (contrast >= 48) points.Add(new FeaturePoint(row, x));
                }
            }

            const int maximumFeaturePoints = 8192;
            if (points.Count <= maximumFeaturePoints) return points.ToArray();
            var sampled = new FeaturePoint[maximumFeaturePoints];
            for (var index = 0; index < sampled.Length; index++)
                sampled[index] = points[index * points.Count / sampled.Length];
            return sampled;
        }

        private void AccumulateRowDifference(
            int previousRow,
            int currentRow,
            int columnStep,
            ref long total,
            ref long samples)
        {
            var previousOffset = (_contentTop + previousRow) * _width * 4;
            var currentOffset = (_contentTop + currentRow) * _width * 4;
            for (var x = _xStart; x < _xEnd; x += columnStep)
            {
                var previousIndex = previousOffset + x * 4;
                var currentIndex = currentOffset + x * 4;
                total += Math.Abs(_previous[previousIndex] - _current[currentIndex]);
                total += Math.Abs(_previous[previousIndex + 1] - _current[currentIndex + 1]);
                total += Math.Abs(_previous[previousIndex + 2] - _current[currentIndex + 2]);
                samples += 3;
            }
        }

        private readonly record struct FeaturePoint(int Row, int X);
    }

    private readonly record struct PixelMatch(
        int DeltaY,
        double OverallAverage,
        double FeatureMatchRatio,
        int ActiveCount,
        double Rank)
    {
        internal bool IsStrongFastMatch =>
            ActiveCount > 0
                ? FeatureMatchRatio >= 0.995 && OverallAverage < 1.0
                : OverallAverage < 0.5;

        internal bool IsAcceptable => ActiveCount > 0
            ? FeatureMatchRatio >= 0.8 && OverallAverage < 12.0
            : OverallAverage < 4.0;

        internal static PixelMatch Invalid(int deltaY) =>
            new(deltaY, double.MaxValue, 0, 0, double.MaxValue);
    }

    private static FixedEdges FindStationaryEdges(byte[] previous, byte[] current, int width, int height)
    {
        var side = Math.Min(width / 3, Math.Max(24, width / 20));
        var limit = Math.Min(height / 5, 160);
        var top = CountStableRows(previous, current, width, height, side, limit, fromTop: true);
        var bottom = CountStableRows(previous, current, width, height, side, limit, fromTop: false);
        if (top < MinimumFixedEdgeHeight) top = 0;
        if (bottom < MinimumFixedEdgeHeight) bottom = 0;
        return new FixedEdges(top, bottom);
    }

    private static SideEdges FindStationarySideEdges(byte[] previous, byte[] current, int width, int height)
    {
        var conservativeLimit = Math.Min(width / 6, 120);
        var limit = Math.Min(width / 3, 240);
        var left = CountStableColumns(previous, current, width, height, limit, fromLeft: true);
        var right = CountStableColumns(previous, current, width, height, limit, fromLeft: false);
        if (left > conservativeLimit && !HasWideSideRailSignal(previous, width, height, left, fromLeft: true))
            left = 0;
        if (right > conservativeLimit && !HasWideSideRailSignal(previous, width, height, right, fromLeft: false))
            right = 0;
        if (left < MinimumFixedEdgeHeight) left = 0;
        if (right < MinimumFixedEdgeHeight) right = 0;
        return new SideEdges(left, right);
    }

    private static int CountStableRows(
        byte[] previous,
        byte[] current,
        int width,
        int height,
        int side,
        int limit,
        bool fromTop)
    {
        var xStep = Math.Max(1, (width - side * 2) / 512);
        var sampledColumns = Math.Max(1, (width - side * 2 + xStep - 1) / xStep);
        var movingColumnThreshold = Math.Max(6, (int)Math.Ceiling(sampledColumns * 0.25));
        for (var offset = 0; offset < limit; offset++)
        {
            var y = fromTop ? offset : height - 1 - offset;
            var movingColumns = 0;
            for (var x = side; x < width - side; x += xStep)
            {
                var index = (y * width + x) * 4;
                var difference = Math.Abs(previous[index] - current[index]) +
                                 Math.Abs(previous[index + 1] - current[index + 1]) +
                                 Math.Abs(previous[index + 2] - current[index + 2]);
                if (difference < ActiveColumnThreshold) continue;
                movingColumns++;
                if (movingColumns >= movingColumnThreshold) return offset;
            }
        }
        return 0;
    }

    private static int CountStableColumns(
        byte[] previous,
        byte[] current,
        int width,
        int height,
        int limit,
        bool fromLeft)
    {
        var step = Math.Max(1, height / 512);
        for (var offset = 0; offset < limit; offset++)
        {
            var x = fromLeft ? offset : width - 1 - offset;
            var maximumDifference = 0;
            for (var y = 0; y < height; y += step)
            {
                var index = (y * width + x) * 4;
                var difference = Math.Abs(previous[index] - current[index]) +
                                 Math.Abs(previous[index + 1] - current[index + 1]) +
                                 Math.Abs(previous[index + 2] - current[index + 2]);
                maximumDifference = Math.Max(maximumDifference, difference);
            }
            if (maximumDifference >= ActiveColumnThreshold) return offset;
        }
        return 0;
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

    internal enum ScrollDirection { Down, Up }
    private readonly record struct FixedEdges(int Top, int Bottom);
    private readonly record struct SideEdges(int Left, int Right);
}
