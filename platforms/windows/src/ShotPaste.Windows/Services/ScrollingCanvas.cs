using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Drawing = System.Drawing;

namespace ShotPaste.Windows.Services;

/// <summary>
/// Incremental pixel canvas for scrolling capture. The merged image lives in a
/// single preallocated BGRA buffer whose origin sits mid-buffer, so content can
/// grow in BOTH scroll directions without moving existing rows. Every accepted
/// frame contributes only its newly-visible strip; the strip is blitted with a
/// short cross-fade against the overlapped rows at the seam, and the fractional
/// part of the measured advance is accumulated so subpixel scroll steps do not
/// drift. A 220 px preview thumbnail is extended incrementally with each strip,
/// which keeps HUD preview updates off the full-resolution buffer.
/// </summary>
internal sealed class ScrollingCanvas
{
    internal const int ThumbnailTargetWidth = 220;
    private const int SeamFadeRows = 2;
    private const int ThumbnailBudgetRows = 12288;

    private readonly int _width;
    private readonly int _maximumHeight;
    private byte[] _buffer;
    private int _bufferRows;
    // Buffer row that holds seed-frame row 0. All thumbnail positions are
    // derived from this anchor, so recentring the buffer stays consistent.
    private int _origin;
    private int _usedTop = -1;
    private int _usedBottom = -1;
    private double _cursor;
    private double _downExtent;
    private double _upExtent;
    private int _horizontalOffsetPixels;
    private bool _lastGrowthWasUp;

    private byte[]? _thumbnail;
    private int _thumbnailWidth;
    private int _thumbnailRows;
    private int _thumbnailOrigin;
    private double _thumbnailScale;
    private bool _thumbnailOverflow;

    internal ScrollingCanvas(int width, int frameHeight, int maximumHeight)
    {
        _width = width;
        _maximumHeight = Math.Clamp(maximumHeight, 1024, 100000);
        var initialRows = Math.Min(Math.Max(1, frameHeight), _maximumHeight);
        // The buffer grows by doubling instead of committing width×maxHeight
        // up front: a wide 4K selection would otherwise allocate hundreds of
        // megabytes for a capture that may only scroll a few screens.
        _bufferRows = Math.Clamp(
            Math.Max(initialRows * 4, initialRows + 2048),
            initialRows,
            _maximumHeight);
        _buffer = new byte[(long)_bufferRows * _width * 4];
    }

    internal int Width => _width;
    internal int MaximumHeight => _maximumHeight;
    internal int UsedHeight => _usedTop >= 0 ? _usedBottom - _usedTop : 0;

    /// <summary>
    /// Advances the signed scroll cursor and returns only the rows that extend
    /// beyond a historical edge. Re-scrolling over content already present in
    /// the canvas is therefore free and never duplicates pixels.
    /// </summary>
    internal int AdvanceCursor(double measuredAdvance, int heightBudget)
    {
        _cursor += measuredAdvance;
        if (measuredAdvance >= 0)
        {
            var planned = (int)Math.Round(_cursor) - (int)Math.Round(_downExtent);
            var accepted = Math.Max(0, Math.Min(planned, Math.Max(0, heightBudget)));
            if (accepted > 0) _downExtent = _cursor;
            return accepted;
        }

        var upwardPlanned = (int)Math.Round(_upExtent) - (int)Math.Round(_cursor);
        var upwardAccepted = Math.Max(0, Math.Min(upwardPlanned, Math.Max(0, heightBudget)));
        if (upwardAccepted > 0) _upExtent = _cursor;
        return upwardAccepted;
    }

    internal void Seed(byte[] framePixels, int seedHeight)
    {
        seedHeight = Math.Clamp(seedHeight, 1, _maximumHeight);
        EnsureSpace(0);
        _origin = (_bufferRows - seedHeight) / 2;
        _usedTop = _origin;
        _usedBottom = _origin + seedHeight;
        _cursor = 0;
        _downExtent = 0;
        _upExtent = 0;
        _horizontalOffsetPixels = 0;
        _lastGrowthWasUp = false;
        CopyRows(framePixels, 0, _buffer, _origin, seedHeight);
        InitializeThumbnail(framePixels, seedHeight);
    }

    /// <summary>
    /// Appends the newly visible bottom strip of a downward-scrolled frame and
    /// refreshes the fixed footer from it. Returns the committed row count.
    /// </summary>
    internal int AppendDown(
        byte[] framePixels,
        int frameHeight,
        int fixedTop,
        int fixedBottom,
        int rows,
        int deltaX)
    {
        if (rows <= 0) return 0;
        var stripStart = frameHeight - fixedBottom - rows;
        if (stripStart < fixedTop) return 0;
        UpdateHorizontalOffset(deltaX);
        EnsureSpace(rows, growingDown: true);
        var dest = _usedBottom - fixedBottom;
        BlendSeam(framePixels, dest, stripStart, blendDownward: true, frameHeight);
        CopyRowsWithOffset(framePixels, stripStart, dest, rows);
        if (fixedBottom > 0)
            CopyRowsWithOffset(framePixels, frameHeight - fixedBottom, dest + rows, fixedBottom);
        _usedBottom += rows;
        _lastGrowthWasUp = false;
        ExtendThumbnail(framePixels, stripStart, dest, rows + fixedBottom);
        return rows;
    }

    /// <summary>
    /// Prepends the newly visible top strip of an upward-scrolled frame and
    /// refreshes the fixed header from it. Returns the committed row count.
    /// </summary>
    internal int AppendUp(
        byte[] framePixels,
        int frameHeight,
        int fixedTop,
        int fixedBottom,
        int rows,
        int deltaX)
    {
        if (rows <= 0) return 0;
        if (fixedTop + rows > frameHeight - fixedBottom) return 0;
        UpdateHorizontalOffset(deltaX);
        EnsureSpace(rows, growingDown: false);
        var newTop = _usedTop - rows;
        if (fixedTop > 0)
            CopyRowsWithOffset(framePixels, 0, newTop, fixedTop);
        CopyRowsWithOffset(framePixels, fixedTop, newTop + fixedTop, rows);
        BlendSeam(framePixels, _usedTop + fixedTop, fixedTop + rows, blendDownward: false, frameHeight);
        _usedTop = newTop;
        _lastGrowthWasUp = true;
        ExtendThumbnail(framePixels, 0, newTop, fixedTop + rows);
        return rows;
    }

    /// <summary>Crops the used range into a fresh bitmap. This is the only
    /// full-size materialization and runs once, when the capture finishes.</summary>
    internal Drawing.Bitmap? ComposeResult()
    {
        if (_usedTop < 0 || UsedHeight <= 0) return null;
        var height = UsedHeight;
        var result = new Drawing.Bitmap(_width, height, PixelFormat.Format32bppArgb);
        var data = result.LockBits(
            new Drawing.Rectangle(0, 0, _width, height),
            ImageLockMode.WriteOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            var rowBytes = _width * 4;
            if (data.Stride == rowBytes)
            {
                Marshal.Copy(_buffer, _usedTop * rowBytes, data.Scan0, height * rowBytes);
            }
            else
            {
                for (var row = 0; row < height; row++)
                    Marshal.Copy(
                        _buffer,
                        (_usedTop + row) * rowBytes,
                        data.Scan0 + row * data.Stride,
                        rowBytes);
            }
        }
        finally
        {
            result.UnlockBits(data);
        }
        return result;
    }

    internal Drawing.Bitmap? CreatePreviewBitmap(int maxWidth, int maxHeight)
    {
        if (_usedTop < 0 || UsedHeight <= 0 || maxWidth <= 0 || maxHeight <= 0) return null;
        var thumbTop = ThumbnailRow(_usedTop);
        var thumbBottom = ThumbnailRow(_usedBottom);
        if (_thumbnail is not null && !_thumbnailOverflow &&
            thumbTop >= 0 && thumbBottom <= _thumbnailRows && thumbBottom > thumbTop)
        {
            var thumbHeight = thumbBottom - thumbTop;
            var scale = Math.Min(1d, (double)maxWidth / _thumbnailWidth);
            var sourceHeightLimit = Math.Max(1, (int)Math.Floor(maxHeight / scale));
            var sourceHeight = Math.Min(thumbHeight, sourceHeightLimit);
            var viewportTop = thumbHeight <= sourceHeight || _lastGrowthWasUp
                ? thumbTop
                : thumbBottom - sourceHeight;
            using var region = CropThumbnail(viewportTop, viewportTop + sourceHeight);
            return ScalePreview(region, scale);
        }

        // Extremely narrow captures can outgrow the thumbnail budget. Copy only
        // the visible growth-edge viewport from the committed canvas, never the
        // full long image.
        var fallbackScale = Math.Min(1d, (double)maxWidth / _width);
        var fallbackSourceHeight = Math.Min(
            UsedHeight,
            Math.Max(1, (int)Math.Floor(maxHeight / fallbackScale)));
        var fallbackTop = UsedHeight <= fallbackSourceHeight || _lastGrowthWasUp
            ? _usedTop
            : _usedBottom - fallbackSourceHeight;
        using var fallbackRegion = CropBufferRows(fallbackTop, fallbackSourceHeight);
        return ScalePreview(fallbackRegion, fallbackScale);
    }

    private static Drawing.Bitmap ScalePreview(Drawing.Bitmap source, double scale)
    {
        var targetWidth = Math.Max(1, (int)Math.Round(source.Width * scale));
        var targetHeight = Math.Max(1, (int)Math.Round(source.Height * scale));
        if (targetWidth == source.Width && targetHeight == source.Height)
            return new Drawing.Bitmap(source);
        var preview = new Drawing.Bitmap(targetWidth, targetHeight, PixelFormat.Format32bppPArgb);
        using var graphics = Drawing.Graphics.FromImage(preview);
        graphics.CompositingMode = Drawing.Drawing2D.CompositingMode.SourceCopy;
        graphics.InterpolationMode = Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = Drawing.Drawing2D.PixelOffsetMode.HighQuality;
        graphics.DrawImage(
            source,
            new Drawing.Rectangle(0, 0, targetWidth, targetHeight),
            new Drawing.Rectangle(0, 0, source.Width, source.Height),
            Drawing.GraphicsUnit.Pixel);
        return preview;
    }

    /// <summary>
    /// Blends the overlapped rows next to a seam so compositor noise at the
    /// stitch boundary fades instead of stepping. The blended rows show the
    /// same content in both buffers when alignment is exact, so exact captures
    /// stay pixel-identical and opaque.
    /// </summary>
    private void BlendSeam(
        byte[] framePixels,
        int bufferRow,
        int frameRow,
        bool blendDownward,
        int frameHeight)
    {
        var rowBytes = _width * 4;
        for (var index = 0; index < SeamFadeRows; index++)
        {
            int bRow;
            int fRow;
            double t;
            if (blendDownward)
            {
                // Rows just above the new strip: older content, increasingly
                // replaced by the newer frame towards the seam.
                bRow = bufferRow - SeamFadeRows + index;
                fRow = frameRow - SeamFadeRows + index;
                t = (index + 1.0) / (SeamFadeRows + 1.0);
                if (bRow < _usedTop || fRow < 0) continue;
            }
            else
            {
                // Rows just below the new strip, mirrored for upward growth.
                bRow = bufferRow + index;
                fRow = frameRow + index;
                t = (SeamFadeRows - index) / (SeamFadeRows + 1.0);
                if (bRow >= _usedBottom || fRow >= frameHeight) continue;
            }
            var bufferOffset = bRow * rowBytes;
            var frameOffset = fRow * rowBytes;
            for (var x = 0; x < _width; x++)
            {
                var sourceX = Math.Clamp(x - _horizontalOffsetPixels, 0, _width - 1);
                for (var channel = 0; channel < 3; channel++)
                {
                    var destinationIndex = bufferOffset + x * 4 + channel;
                    var sourceIndex = frameOffset + sourceX * 4 + channel;
                    _buffer[destinationIndex] = (byte)(
                        _buffer[destinationIndex] * (1 - t) + framePixels[sourceIndex] * t + 0.5);
                }
                _buffer[bufferOffset + x * 4 + 3] = 255;
            }
        }
    }

    /// <summary>
    /// Grows (by doubling) and/or recentres the buffer so the used range plus
    /// <paramref name="additionalRows"/> fits on both sides. The stitcher caps
    /// the used height at the configured maximum, so a centred range always
    /// fits afterwards.
    /// </summary>
    private void EnsureSpace(int additionalRows, bool growingDown = true)
    {
        var used = UsedHeight;
        var required = used + additionalRows;
        if (_usedTop >= 0)
        {
            if (growingDown && _usedBottom + additionalRows <= _bufferRows) return;
            if (!growingDown && _usedTop - additionalRows >= 0) return;
        }

        var targetRows = _bufferRows;
        while (targetRows < required)
            targetRows = Math.Min(_maximumHeight, Math.Max(targetRows * 2, required));
        targetRows = Math.Max(targetRows, Math.Min(_maximumHeight, required));
        if (used <= 0)
        {
            if (targetRows != _bufferRows)
            {
                _buffer = new byte[(long)targetRows * _width * 4];
                _bufferRows = targetRows;
            }
            return;
        }

        var rowBytes = _width * 4;
        var newBuffer = new byte[(long)targetRows * _width * 4];
        var centeredTop = Math.Max(0, (targetRows - used) / 2);
        var newTop = growingDown
            ? Math.Max(0, Math.Min(centeredTop, targetRows - used - additionalRows))
            : Math.Min(Math.Max(centeredTop, additionalRows), targetRows - used);
        Buffer.BlockCopy(_buffer, _usedTop * rowBytes, newBuffer, newTop * rowBytes, used * rowBytes);
        var delta = newTop - _usedTop;
        _buffer = newBuffer;
        _bufferRows = targetRows;
        _origin += delta;
        _usedTop += delta;
        _usedBottom += delta;
    }

    private void InitializeThumbnail(byte[] framePixels, int seedHeight)
    {
        _thumbnailScale = Math.Min(1d, ThumbnailTargetWidth / (double)_width);
        _thumbnailWidth = Math.Max(1, (int)Math.Round(_width * _thumbnailScale));
        var wantedRows = (long)Math.Ceiling(_maximumHeight * _thumbnailScale) + 8;
        _thumbnailRows = (int)Math.Min(wantedRows, ThumbnailBudgetRows);
        _thumbnail = new byte[(long)_thumbnailRows * _thumbnailWidth * 4];
        _thumbnailOrigin =
            (_thumbnailRows - Math.Max(1, (int)Math.Round(seedHeight * _thumbnailScale))) / 2;
        ExtendThumbnail(framePixels, 0, _origin, seedHeight);
    }

    private int ThumbnailRow(int bufferRow) =>
        _thumbnailOrigin + (int)Math.Round((bufferRow - _origin) * _thumbnailScale);

    /// <summary>
    /// Extends the incremental thumbnail with the buffer rows that a strip
    /// append just wrote. Positions are derived from the canvas anchor rather
    /// than accumulated, so thumbnail extension never drifts.
    /// </summary>
    private void ExtendThumbnail(byte[] framePixels, int frameRowStart, int bufferRowStart, int rowCount)
    {
        if (_thumbnail is null || _thumbnailOverflow || rowCount <= 0) return;
        var thumbLo = ThumbnailRow(bufferRowStart);
        var thumbHi = ThumbnailRow(bufferRowStart + rowCount);
        if (thumbLo < 0 || thumbHi > _thumbnailRows)
        {
            _thumbnailOverflow = true;
            return;
        }
        if (thumbHi <= thumbLo) return;
        for (var row = thumbLo; row < thumbHi; row++)
        {
            var sourceRow = frameRowStart +
                Math.Min(rowCount - 1, (int)((row - thumbLo + 0.5) * rowCount / (thumbHi - thumbLo)));
            var sourceOffset = sourceRow * _width * 4;
            var destOffset = row * _thumbnailWidth * 4;
            for (var x = 0; x < _thumbnailWidth; x++)
            {
                var sourceX = Math.Min(_width - 1, (int)((x + 0.5) * _width / (double)_thumbnailWidth));
                Array.Copy(
                    framePixels,
                    sourceOffset + sourceX * 4,
                    _thumbnail,
                    destOffset + x * 4,
                    4);
            }
        }
    }

    private Drawing.Bitmap CropThumbnail(int thumbTop, int thumbBottom)
    {
        var height = thumbBottom - thumbTop;
        var result = new Drawing.Bitmap(_thumbnailWidth, height, PixelFormat.Format32bppArgb);
        var data = result.LockBits(
            new Drawing.Rectangle(0, 0, _thumbnailWidth, height),
            ImageLockMode.WriteOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            var rowBytes = _thumbnailWidth * 4;
            if (data.Stride == rowBytes)
            {
                Marshal.Copy(_thumbnail!, thumbTop * rowBytes, data.Scan0, height * rowBytes);
            }
            else
            {
                for (var row = 0; row < height; row++)
                    Marshal.Copy(
                        _thumbnail!,
                        (thumbTop + row) * rowBytes,
                        data.Scan0 + row * data.Stride,
                        rowBytes);
            }
        }
        finally
        {
            result.UnlockBits(data);
        }
        return result;
    }

    private Drawing.Bitmap CropBufferRows(int sourceTop, int height)
    {
        var result = new Drawing.Bitmap(_width, height, PixelFormat.Format32bppArgb);
        var data = result.LockBits(
            new Drawing.Rectangle(0, 0, _width, height),
            ImageLockMode.WriteOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            var rowBytes = _width * 4;
            if (data.Stride == rowBytes)
            {
                Marshal.Copy(_buffer, sourceTop * rowBytes, data.Scan0, height * rowBytes);
            }
            else
            {
                for (var row = 0; row < height; row++)
                    Marshal.Copy(
                        _buffer,
                        (sourceTop + row) * rowBytes,
                        data.Scan0 + row * data.Stride,
                        rowBytes);
            }
        }
        finally
        {
            result.UnlockBits(data);
        }
        return result;
    }

    private void UpdateHorizontalOffset(int deltaX)
    {
        _horizontalOffsetPixels = Math.Clamp(_horizontalOffsetPixels + deltaX, -32, 32);
    }

    private void CopyRowsWithOffset(byte[] source, int sourceRow, int destinationRow, int rows)
    {
        var shift = Math.Clamp(_horizontalOffsetPixels, -(_width - 1), _width - 1);
        if (shift == 0)
        {
            CopyRows(source, sourceRow, _buffer, destinationRow, rows);
            return;
        }

        var rowBytes = _width * 4;
        var copyWidth = _width - Math.Abs(shift);
        for (var row = 0; row < rows; row++)
        {
            var sourceOffset = (sourceRow + row) * rowBytes;
            var destinationOffset = (destinationRow + row) * rowBytes;
            if (shift > 0)
            {
                Buffer.BlockCopy(source, sourceOffset, _buffer, destinationOffset + shift * 4, copyWidth * 4);
                for (var x = 0; x < shift; x++)
                    Buffer.BlockCopy(source, sourceOffset, _buffer, destinationOffset + x * 4, 4);
            }
            else
            {
                var sourceShift = -shift;
                Buffer.BlockCopy(source, sourceOffset + sourceShift * 4, _buffer, destinationOffset, copyWidth * 4);
                for (var x = copyWidth; x < _width; x++)
                    Buffer.BlockCopy(source, sourceOffset + (_width - 1) * 4, _buffer, destinationOffset + x * 4, 4);
            }
        }
    }

    private void CopyRows(byte[] source, int sourceRow, byte[] destination, int destinationRow, int rows)
    {
        if (rows <= 0) return;
        var rowBytes = _width * 4;
        Buffer.BlockCopy(
            source,
            sourceRow * rowBytes,
            destination,
            destinationRow * rowBytes,
            rows * rowBytes);
    }
}
