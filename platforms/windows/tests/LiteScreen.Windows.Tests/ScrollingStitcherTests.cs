using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using LiteScreen.Windows.Models;
using LiteScreen.Windows.Services;
using LiteScreen.Windows.Utilities;

namespace LiteScreen.Windows.Tests;

public sealed class ScrollingStitcherTests
{
    [Fact]
    public void Append_OverlappingFrames_ProducesExpectedHeight()
    {
        using var source = MakePattern(160, 240);
        using var first = source.Clone(new Rectangle(0, 0, 160, 160), source.PixelFormat);
        using var second = source.Clone(new Rectangle(0, 80, 160, 160), source.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.Equal(160, result.Width);
        Assert.InRange(result.Height, 236, 244);
    }

    [Fact]
    public void Append_LongSequence_ContinuesUntilHeightLimitThenStopsAtLimit()
    {
        const int width = 96;
        const int frameHeight = 1_000;
        const int scrollDelta = 500;
        const int maximumHeight = 60_000;
        const int sourceHeight = 61_000;

        using var source = MakeFastPattern(width, sourceHeight);
        using var stitcher = new ScrollingStitcher(maximumHeight);
        using var first = source.Clone(new Rectangle(0, 0, width, frameHeight), source.PixelFormat);

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        var expectedHeight = frameHeight;

        // Every frame through this offset should be accepted. The result reaches
        // exactly the configured limit only after the last accepted frame.
        for (var offset = scrollDelta; offset <= 59_000; offset += scrollDelta)
        {
            using var frame = source.Clone(
                new Rectangle(0, offset, width, frameHeight), source.PixelFormat);

            Assert.Equal(StitchResult.Added, stitcher.Append(frame));
            expectedHeight += scrollDelta;
        }

        Assert.Equal(maximumHeight, expectedHeight);
        using var atLimit = stitcher.Result;
        Assert.NotNull(atLimit);
        Assert.Equal(maximumHeight, atLimit.Height);

        // The next frame would add another 500 px. It must be rejected by the
        // height guard, and the already stitched result must remain intact.
        using var overflow = source.Clone(
            new Rectangle(0, 59_500, width, frameHeight), source.PixelFormat);
        Assert.Equal(StitchResult.HeightLimit, stitcher.Append(overflow));

        using var afterLimit = stitcher.Result;
        Assert.NotNull(afterLimit);
        Assert.Equal(maximumHeight, afterLimit.Height);

        // Exercise the same final-output paths used by the controller: PNG save
        // and full-image conversion for the clipboard. A failure here would mean
        // the height guard is not the only blocker.
        var outputDirectory = Path.Combine(
            Path.GetTempPath(), $"LiteScreen-ScrollingTest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(outputDirectory);
        try
        {
            var images = new ImageFileService(new SettingsStore());
            var path = images.Save(afterLimit, outputDirectory, CaptureKind.ScrollingScreenshot);
            Assert.True(File.Exists(path));

            var clipboardSource = BitmapSourceFactory.FromBitmap(afterLimit);
            Assert.Equal(width, clipboardSource.PixelWidth);
            Assert.Equal(maximumHeight, clipboardSource.PixelHeight);
        }
        finally
        {
            if (Directory.Exists(outputDirectory)) Directory.Delete(outputDirectory, recursive: true);
        }
    }

    [Fact]
    public void Append_SameFrame_IsDuplicate()
    {
        using var frame = MakePattern(160, 160);
        using var stitcher = new ScrollingStitcher();
        Assert.Equal(StitchResult.Added, stitcher.Append(frame));
        Assert.Equal(StitchResult.Duplicate, stitcher.Append(frame));
    }

    [Fact]
    public void Append_RepetitiveRowsAndShortFinalScroll_DoesNotDuplicateTail()
    {
        const int rowHeight = 8;
        using var source = MakeRepetitiveRows(160, 40, rowHeight);
        using var first = source.Clone(new Rectangle(0, 0, 160, 20 * rowHeight), source.PixelFormat);
        using var second = source.Clone(new Rectangle(0, 8 * rowHeight, 160, 20 * rowHeight), source.PixelFormat);
        using var third = source.Clone(new Rectangle(0, 16 * rowHeight, 160, 20 * rowHeight), source.PixelFormat);
        using var final = source.Clone(new Rectangle(0, 20 * rowHeight, 160, 20 * rowHeight), source.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        Assert.Equal(StitchResult.Added, stitcher.Append(third));
        Assert.Equal(StitchResult.Added, stitcher.Append(final));
        Assert.Equal(StitchResult.Duplicate, stitcher.Append(final));
        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.InRange(result.Height, 39 * rowHeight, 41 * rowHeight);
    }

    [Fact]
    public void Append_FixedHeaderAndFooter_KeepsChromeOnlyOnce()
    {
        using var content = MakePattern(160, 200);
        using var first = MakeViewport(content, 0, 10, 30);
        using var second = MakeViewport(content, 80, 10, 30);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));

        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.InRange(result.Height, 236, 244);
        Assert.Equal(Color.FromArgb(255, 20, 80, 160), result.GetPixel(80, 2));
        Assert.Equal(Color.FromArgb(255, 70, 70, 70), result.GetPixel(80, result.Height - 2));
        Assert.NotEqual(Color.FromArgb(255, 70, 70, 70), result.GetPixel(80, 145));
    }

    [Fact]
    public void Append_FixedSideRail_IsExcludedFromAlignmentButPreservedInOutput()
    {
        using var content = MakePattern(172, 260);
        using var first = MakeSideRailViewport(content, 0);
        using var second = MakeSideRailViewport(content, 60);
        using var stitcher = new ScrollingStitcher();
        var selectedWidth = first.Width;
        var railWidth = selectedWidth - content.Width;

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));

        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.InRange(stitcher.FixedSideBars.Left, 24, 32);
        Assert.Equal(selectedWidth, result.Width);
        Assert.InRange(result.Height, 176, 184);
        Assert.Equal(Color.FromArgb(255, 44, 44, 54).ToArgb(), result.GetPixel(2, 130).ToArgb());
        Assert.Equal(content.GetPixel(22, 130).ToArgb(), result.GetPixel(railWidth + 22, 130).ToArgb());

        using var preview = stitcher.CreatePreviewBitmap(1000, 1000);
        Assert.NotNull(preview);
        Assert.Equal(selectedWidth, preview.Width);
    }

    [Fact]
    public void Append_WideFixedRailAndChangingHeaderLabel_StillAlignsBrowserContent()
    {
        using var content = MakePattern(400, 900);
        using var first = MakeBrowserChromeViewport(content, 0, Color.Gold);
        using var second = MakeBrowserChromeViewport(content, 200, Color.LimeGreen);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second, expectedWheelDirection: -1));

        Assert.InRange(stitcher.FixedHorizontalBars.Top, 54, 56);
        Assert.InRange(stitcher.FixedSideBars.Left, 126, 130);
        Assert.Equal(700, stitcher.OutputHeight);
    }

    [Fact]
    public void Append_NarrowChangingHeaderCounter_DoesNotCutFixedHeaderAtFirstGlyphRow()
    {
        using var content = MakePattern(400, 900);
        using var first = MakeBrowserChromeViewport(content, 0, Color.Gold, liveLabelWidth: 96);
        using var second = MakeBrowserChromeViewport(content, 200, Color.LimeGreen, liveLabelWidth: 96);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second, expectedWheelDirection: -1));

        Assert.InRange(stitcher.FixedHorizontalBars.Top, 54, 56);
        Assert.Equal(700, stitcher.OutputHeight);
    }

    [Fact]
    public void Append_SparseCompositorPixelChanges_DoNotInvalidateAlignedRows()
    {
        const int width = 200;
        const int viewportHeight = 500;
        using var content = MakePattern(width, 800);
        using var first = content.Clone(
            new Rectangle(0, 0, width, viewportHeight), content.PixelFormat);
        using var second = content.Clone(
            new Rectangle(0, 300, width, viewportHeight), content.PixelFormat);
        for (var y = 0; y < second.Height; y++)
        {
            var original = second.GetPixel(100, y);
            second.SetPixel(100, y, Color.FromArgb(
                255,
                (byte)(255 - original.R),
                (byte)(255 - original.G),
                (byte)(255 - original.B)));
        }

        using var stitcher = new ScrollingStitcher();
        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second, expectedWheelDirection: -1));
        Assert.Equal(800, stitcher.OutputHeight);
    }

    [Fact]
    public void Append_WideStationaryPageGutters_AreNotMistakenForFixedSideRails()
    {
        using var content = MakePattern(180, 260);
        using var first = MakeWideGutterViewport(content, 0);
        using var second = MakeWideGutterViewport(content, 60);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second, expectedWheelDirection: -1));
        Assert.Equal((0, 0), stitcher.FixedSideBars);
        Assert.Equal(180, stitcher.OutputHeight);
    }

    [Fact]
    public void Append_InitialFrameHigherThanLimit_IsCroppedToLimit()
    {
        using var frame = MakePattern(80, 1200);
        using var stitcher = new ScrollingStitcher(1024);

        Assert.Equal(StitchResult.Added, stitcher.Append(frame));
        using var result = stitcher.Result;

        Assert.NotNull(result);
        Assert.Equal(1024, result.Height);
    }

    [Fact]
    public void Append_UpwardFrames_PrependsContentAndRecoversTop()
    {
        using var content = MakePattern(160, 200);
        using var lower = MakeViewport(content, 80, 10, 30);
        using var upper = MakeViewport(content, 0, 10, 30);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(lower));
        Assert.Equal(StitchResult.Added, stitcher.Append(upper));

        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.InRange(result.Height, 236, 244);
        Assert.Equal(content.GetPixel(80, 0), result.GetPixel(80, 10));
        Assert.Equal(content.GetPixel(80, 199), result.GetPixel(80, result.Height - 31));
    }

    [Fact]
    public void Append_AfterDownwardLock_RejectsUpwardFramesWithoutGrowing()
    {
        using var content = MakePattern(160, 300);
        using var first = MakeViewport(content, 80, 10, 30);
        using var second = MakeViewport(content, 120, 10, 30);
        using var reverse = MakeViewport(content, 100, 10, 30);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        Assert.Equal(ScrollingStitcher.ScrollDirection.Down, stitcher.LockedDirection);
        using var before = stitcher.Result;
        Assert.NotNull(before);
        var heightBefore = before.Height;

        Assert.Equal(StitchResult.NoMatch, stitcher.Append(reverse));
        using var after = stitcher.Result;
        Assert.NotNull(after);
        Assert.Equal(heightBefore, after.Height);
        Assert.Equal(ScrollingStitcher.ScrollDirection.Down, stitcher.LockedDirection);

        // Continuing in the locked direction still appends after the rejection.
        using var further = MakeViewport(content, 160, 10, 30);
        Assert.Equal(StitchResult.Added, stitcher.Append(further));
        using var grown = stitcher.Result;
        Assert.NotNull(grown);
        Assert.True(grown.Height > heightBefore);
    }

    [Fact]
    public void Append_FirstMovementHonorsWheelDirectionHint()
    {
        using var content = MakePattern(160, 240);
        using var first = content.Clone(new Rectangle(0, 0, 160, 160), content.PixelFormat);
        using var second = content.Clone(new Rectangle(0, 40, 160, 160), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.NoMatch, stitcher.Append(second, expectedWheelDirection: 1));
        Assert.Equal(StitchResult.Added, stitcher.Append(second, expectedWheelDirection: -1));
        Assert.Equal(ScrollingStitcher.ScrollDirection.Down, stitcher.LockedDirection);
    }

    [Fact]
    public void Append_AfterUpwardLock_RejectsDownwardFramesWithoutGrowing()
    {
        using var content = MakePattern(160, 300);
        using var first = MakeViewport(content, 120, 10, 30);
        using var second = MakeViewport(content, 80, 10, 30);
        using var reverse = MakeViewport(content, 100, 10, 30);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        Assert.Equal(ScrollingStitcher.ScrollDirection.Up, stitcher.LockedDirection);
        using var before = stitcher.Result;
        Assert.NotNull(before);
        var heightBefore = before.Height;

        Assert.Equal(StitchResult.NoMatch, stitcher.Append(reverse));
        using var after = stitcher.Result;
        Assert.NotNull(after);
        Assert.Equal(heightBefore, after.Height);
        Assert.Equal(ScrollingStitcher.ScrollDirection.Up, stitcher.LockedDirection);
    }

    [Fact]
    public void Append_SeamRowsMatchSourceExactlyAndStayOpaque()
    {
        using var content = MakePattern(127, 320);
        using var first = content.Clone(new Rectangle(0, 0, 127, 160), content.PixelFormat);
        using var second = content.Clone(new Rectangle(0, 80, 127, 160), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.Equal(240, result.Height);

        for (var y = 0; y < result.Height; y++)
        {
            var expected = content.GetPixel(63, y);
            var actual = result.GetPixel(63, y);
            Assert.True(actual.A == 255, $"row {y} has non-opaque pixel {actual}");
            Assert.Equal(expected, actual);
        }
    }

    [Fact]
    public void Append_SparseContent_AlignsExactlyOnDistinctiveRows()
    {
        using var content = MakeSparseRows(160, 240);
        using var first = content.Clone(new Rectangle(0, 0, 160, 160), content.PixelFormat);
        using var second = content.Clone(new Rectangle(0, 40, 160, 160), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.Equal(200, result.Height);

        // Mostly-white content must still align on the sparse distinctive rows;
        // each marker survives at its original content position without a seam.
        Assert.Equal(Color.White.ToArgb(), result.GetPixel(80, 5).ToArgb());
        Assert.Equal(SparseMarkerColors[0].ToArgb(), result.GetPixel(42, 25).ToArgb());
        Assert.Equal(SparseMarkerColors[1].ToArgb(), result.GetPixel(42, 61).ToArgb());
        Assert.Equal(SparseMarkerColors[2].ToArgb(), result.GetPixel(42, 103).ToArgb());
        Assert.Equal(SparseMarkerColors[3].ToArgb(), result.GetPixel(42, 139).ToArgb());
        Assert.Equal(SparseMarkerColors[4].ToArgb(), result.GetPixel(42, 172).ToArgb());
    }

    [Fact]
    public void Append_SparseContent_AfterLock_RejectsReverseFrames()
    {
        using var content = MakeSparseRows(160, 240);
        using var first = content.Clone(new Rectangle(0, 0, 160, 160), content.PixelFormat);
        using var second = content.Clone(new Rectangle(0, 40, 160, 160), content.PixelFormat);
        using var reverse = content.Clone(new Rectangle(0, 20, 160, 160), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        Assert.Equal(ScrollingStitcher.ScrollDirection.Down, stitcher.LockedDirection);
        using var before = stitcher.Result;
        Assert.NotNull(before);
        var heightBefore = before.Height;

        Assert.Equal(StitchResult.NoMatch, stitcher.Append(reverse));
        using var after = stitcher.Result;
        Assert.NotNull(after);
        Assert.Equal(heightBefore, after.Height);
    }

    [Fact]
    public void Append_LargeScrollGap_UsesRecoveryOverlap()
    {
        const int width = 180;
        const int viewportHeight = 600;
        const int scrollDelta = 530;
        using var content = MakePattern(width, viewportHeight + scrollDelta);
        using var first = content.Clone(
            new Rectangle(0, 0, width, viewportHeight), content.PixelFormat);
        using var second = content.Clone(
            new Rectangle(0, scrollDelta, width, viewportHeight), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        Assert.Equal(viewportHeight + scrollDelta, stitcher.OutputHeight);

        using var result = stitcher.Result;
        Assert.NotNull(result);
        Assert.Equal(viewportHeight + scrollDelta, result.Height);
    }

    [Fact]
    public void Append_RepeatedCardsWithLargeJump_DoesNotAcceptShortFalseOverlap()
    {
        const int width = 1_200;
        const int viewportHeight = 916;
        const int scrollDelta = 600;
        using var content = MakeCardPage(width, 2_000);
        using var first = content.Clone(
            new Rectangle(0, 0, width, viewportHeight), content.PixelFormat);
        using var second = content.Clone(
            new Rectangle(0, scrollDelta, width, viewportHeight), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second, expectedWheelDirection: -1));
        Assert.Equal(viewportHeight + scrollDelta, stitcher.OutputHeight);
    }

    [Fact]
    public void Append_RepeatedCardsWithStableSmallSteps_DoesNotJumpToDistantOverlap()
    {
        const int viewportHeight = 930;
        const int scrollStep = 72;
        using var content = MakeDenseCardPage(900, 3_200);
        using var stitcher = new ScrollingStitcher();
        for (var index = 0; index <= 23; index++)
        {
            var offset = index * scrollStep;
            using var frame = MakeWpfLikeViewport(content, offset, index);
            Assert.Equal(
                StitchResult.Added,
                stitcher.Append(frame, expectedWheelDirection: index == 0 ? 0 : -1));
            Assert.Equal(viewportHeight + offset, stitcher.OutputHeight);
        }
    }

    [Fact]
    public void Append_TinyCompositorStepOnRepeatedCards_DefersUntilEdgesLockThenCommits()
    {
        using var content = MakeDenseCardPage(900, 2_000);
        using var first = MakeWpfLikeViewport(content, 0, 0);
        using var tinyStep = MakeWpfLikeViewport(content, 2, 1);
        using var settledStep = MakeWpfLikeViewport(content, 150, 2);
        using var laterTinyStep = MakeWpfLikeViewport(content, 152, 3);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(
            StitchResult.Duplicate,
            stitcher.Append(tinyStep, expectedWheelDirection: -1));
        Assert.Equal(first.Height, stitcher.OutputHeight);
        Assert.Equal(
            StitchResult.Added,
            stitcher.Append(settledStep, expectedWheelDirection: -1));
        Assert.Equal(first.Height + 150, stitcher.OutputHeight);
        Assert.Equal(
            StitchResult.Added,
            stitcher.Append(laterTinyStep, expectedWheelDirection: -1));
        Assert.Equal(first.Height + 152, stitcher.OutputHeight);
    }

    [Fact]
    public void Append_RepeatedCardsWithChromiumCompositorSteps_RemainsContinuous()
    {
        const int viewportHeight = 930;
        using var content = MakeDenseCardPage(900, 5_000);
        using var stitcher = new ScrollingStitcher();
        using (var first = MakeWpfLikeViewport(content, 0, 0))
            Assert.Equal(StitchResult.Added, stitcher.Append(first));

        var label = 1;
        for (var wheel = 0; wheel < 20; wheel++)
        {
            var settledOffset = wheel * 150;
            foreach (var phase in new[] { 2, 81, 145, 150 })
            {
                var offset = settledOffset + phase;
                using var frame = MakeWpfLikeViewport(content, offset, label++);
                var result = stitcher.Append(frame, expectedWheelDirection: -1);
                Assert.True(
                    result is StitchResult.Added or StitchResult.Duplicate,
                    $"offset={offset} result={result} failure={stitcher.LastFailureDiagnostics} " +
                    $"match={stitcher.LastMatchDiagnostics}");
                var expectedHeight = wheel == 0 && phase == 2
                    ? viewportHeight
                    : viewportHeight + offset;
                Assert.Equal(expectedHeight, stitcher.OutputHeight);
            }
        }
    }

    [Fact]
    public void CreatePreviewBitmap_ComposesSlicesWithoutMaterializingFullResult()
    {
        using var content = MakePattern(320, 1_000);
        using var first = content.Clone(new Rectangle(0, 0, 320, 500), content.PixelFormat);
        using var second = content.Clone(new Rectangle(0, 300, 320, 500), content.PixelFormat);
        using var third = content.Clone(new Rectangle(0, 500, 320, 500), content.PixelFormat);
        using var stitcher = new ScrollingStitcher();

        Assert.Equal(StitchResult.Added, stitcher.Append(first));
        Assert.Equal(StitchResult.Added, stitcher.Append(second));
        Assert.Equal(StitchResult.Added, stitcher.Append(third));

        using var preview = stitcher.CreatePreviewBitmap(220, 420);
        Assert.NotNull(preview);
        Assert.True(preview.Width <= 220);
        Assert.True(preview.Height <= 420);
        Assert.Equal(1_000, stitcher.OutputHeight);
    }

    private static Bitmap MakePattern(int width, int height)
    {
        var bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var hash = unchecked((uint)(x * 73856093) ^ (uint)(y * 19349663));
                bitmap.SetPixel(x, y, Color.FromArgb(255, (byte)hash, (byte)(hash >> 8), (byte)(hash >> 16)));
            }
        }
        return bitmap;
    }

    private static Bitmap MakeFastPattern(int width, int height)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        var data = bitmap.LockBits(
            new Rectangle(0, 0, width, height),
            ImageLockMode.WriteOnly,
            PixelFormat.Format32bppArgb);
        try
        {
            var stride = Math.Abs(data.Stride);
            var pixels = new byte[stride * height];
            for (var y = 0; y < height; y++)
            {
                for (var x = 0; x < width; x++)
                {
                    var hash = unchecked((uint)(x * 73856093) ^ (uint)(y * 19349663));
                    var index = y * stride + x * 4;
                    pixels[index] = (byte)(hash >> 16);
                    pixels[index + 1] = (byte)(hash >> 8);
                    pixels[index + 2] = (byte)hash;
                    pixels[index + 3] = 255;
                }
            }

            Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }

        return bitmap;
    }

    private static Bitmap MakeRepetitiveRows(int width, int rowCount, int rowHeight)
    {
        var bitmap = new Bitmap(width, rowCount * rowHeight, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 32, 32, 32));
        using var line = new Pen(Color.FromArgb(255, 205, 205, 205));
        using var marker = new SolidBrush(Color.FromArgb(255, 110, 170, 255));
        for (var row = 0; row < rowCount; row++)
        {
            var top = row * rowHeight;
            graphics.DrawLine(line, 54, top + 2, 106, top + 2);
            for (var bit = 0; bit < 6; bit++)
                if ((row & (1 << bit)) != 0) graphics.FillRectangle(marker, 62 + bit * 7, top + 4, 3, 3);
        }
        return bitmap;
    }

    private static Bitmap MakeViewport(Bitmap content, int contentOffset, int headerHeight, int footerHeight)
    {
        var bodyHeight = 120;
        var bitmap = new Bitmap(content.Width, headerHeight + bodyHeight + footerHeight,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 20, 80, 160));
        graphics.DrawImage(content,
            new Rectangle(0, headerHeight, content.Width, bodyHeight),
            new Rectangle(0, contentOffset, content.Width, bodyHeight),
            GraphicsUnit.Pixel);
        using var footer = new SolidBrush(Color.FromArgb(255, 70, 70, 70));
        graphics.FillRectangle(footer, 0, headerHeight + bodyHeight, content.Width, footerHeight);
        return bitmap;
    }

    private static Bitmap MakeSideRailViewport(Bitmap content, int contentOffset)
    {
        const int railWidth = 28;
        const int bodyHeight = 120;
        var bitmap = new Bitmap(railWidth + content.Width, bodyHeight,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 44, 44, 54));
        graphics.DrawImage(content,
            new Rectangle(railWidth, 0, content.Width, bodyHeight),
            new Rectangle(0, contentOffset, content.Width, bodyHeight),
            GraphicsUnit.Pixel);
        return bitmap;
    }

    private static Bitmap MakeWideGutterViewport(Bitmap content, int contentOffset)
    {
        const int gutterWidth = 140;
        const int bodyHeight = 120;
        var bitmap = new Bitmap(gutterWidth * 2 + content.Width, bodyHeight,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.White);
        graphics.DrawImage(content,
            new Rectangle(gutterWidth, 0, content.Width, bodyHeight),
            new Rectangle(0, contentOffset, content.Width, bodyHeight),
            GraphicsUnit.Pixel);
        return bitmap;
    }

    private static Bitmap MakeBrowserChromeViewport(
        Bitmap content,
        int contentOffset,
        Color labelColor,
        int liveLabelWidth = 40)
    {
        const int railWidth = 128;
        const int headerHeight = 55;
        const int viewportHeight = 500;
        var bitmap = new Bitmap(
            railWidth + content.Width,
            viewportHeight,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 238, 241, 247));
        graphics.DrawImage(
            content,
            new Rectangle(railWidth, headerHeight, content.Width, viewportHeight - headerHeight),
            new Rectangle(0, contentOffset, content.Width, viewportHeight - headerHeight),
            GraphicsUnit.Pixel);

        using var rail = new SolidBrush(Color.FromArgb(255, 32, 41, 66));
        using var railItem = new SolidBrush(Color.FromArgb(255, 51, 64, 95));
        graphics.FillRectangle(rail, 0, headerHeight, railWidth, viewportHeight - headerHeight);
        for (var y = headerHeight + 24; y < viewportHeight; y += 64)
            graphics.FillRectangle(railItem, 14, y, 82, 42);

        using var header = new SolidBrush(Color.FromArgb(255, 86, 55, 199));
        using var liveLabel = new SolidBrush(labelColor);
        graphics.FillRectangle(header, 0, 0, bitmap.Width, headerHeight);
        graphics.FillRectangle(liveLabel, bitmap.Width - liveLabelWidth - 30, 20, liveLabelWidth, 12);
        return bitmap;
    }

    private static Bitmap MakeWpfLikeViewport(Bitmap content, int contentOffset, int labelValue)
    {
        const int railWidth = 204;
        const int rightPadding = 36;
        const int headerHeight = 84;
        const int viewportHeight = 930;
        var bitmap = new Bitmap(
            railWidth + content.Width + rightPadding,
            viewportHeight,
            PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 238, 241, 247));
        graphics.DrawImage(
            content,
            new Rectangle(railWidth, headerHeight, content.Width, viewportHeight - headerHeight),
            new Rectangle(0, contentOffset, content.Width, viewportHeight - headerHeight),
            GraphicsUnit.Pixel);

        using var rail = new SolidBrush(Color.FromArgb(255, 32, 41, 66));
        using var railItem = new SolidBrush(Color.FromArgb(255, 51, 64, 95));
        graphics.FillRectangle(rail, 0, headerHeight, railWidth, viewportHeight - headerHeight);
        for (var y = headerHeight + 36; y < headerHeight + 360; y += 96)
            graphics.FillRectangle(railItem, 21, y, 123, 63);

        using var header = new SolidBrush(Color.FromArgb(255, 86, 55, 199));
        using var liveLabel = new SolidBrush(Color.FromArgb(
            255,
            180 + labelValue % 60,
            180,
            220));
        graphics.FillRectangle(header, 0, 0, bitmap.Width, headerHeight);
        graphics.FillRectangle(liveLabel, bitmap.Width - 120, 30, 72, 18);
        return bitmap;
    }

    private static Bitmap MakeDenseCardPage(int width, int height)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 238, 241, 247));
        using var border = new Pen(Color.FromArgb(255, 23, 32, 51), 4);
        using var fill = new SolidBrush(Color.White);
        for (var row = 0; row < 16; row++)
        {
            var top = 30 + row * 213;
            graphics.FillRectangle(fill, 0, top, width, 198);
            graphics.DrawRectangle(border, 0, top, width - 1, 198);
            using var accent = new SolidBrush(SparseMarkerColors[row % SparseMarkerColors.Length]);
            graphics.FillRectangle(accent, 4, top + 4, 27, 190);
            graphics.DrawLine(border, 70, top + 72, 560 + row * 9, top + 72);
            for (var bit = 0; bit < 8; bit++)
            {
                if ((row & (1 << bit)) == 0) continue;
                graphics.FillRectangle(accent, 90 + bit * 29, top + 105, 14, 21);
            }
        }
        return bitmap;
    }

    private static Bitmap MakeSparseRows(int width, int height)
    {
        var bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.White);
        var rows = new[] { 25, 61, 103, 139, 172 };
        for (var i = 0; i < rows.Length; i++)
        {
            using var marker = new SolidBrush(SparseMarkerColors[i]);
            graphics.FillRectangle(marker, 40, rows[i], 4, 4);
        }
        return bitmap;
    }

    private static Bitmap MakeCardPage(int width, int height)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.FromArgb(255, 245, 247, 252));
        using var border = new Pen(Color.FromArgb(255, 23, 35, 61), 4);
        using var fill = new SolidBrush(Color.White);
        for (var row = 0; row < 12; row++)
        {
            var top = 16 + row * 210;
            graphics.FillRectangle(fill, 140, top, width - 280, 190);
            graphics.DrawRectangle(border, 140, top, width - 280, 190);
            using var marker = new SolidBrush(SparseMarkerColors[row % SparseMarkerColors.Length]);
            graphics.FillRectangle(marker, 144, top + 4, 24, 182);
            for (var bit = 0; bit < 8; bit++)
            {
                if ((row & (1 << bit)) == 0) continue;
                graphics.FillRectangle(marker, 200 + bit * 23, top + 54, 12, 18);
            }
            graphics.DrawLine(border, 200, top + 112, 520 + row * 11, top + 112);
        }
        return bitmap;
    }

    private static readonly Color[] SparseMarkerColors =
    [
        Color.FromArgb(255, 200, 60, 60),
        Color.FromArgb(255, 30, 90, 200),
        Color.FromArgb(255, 40, 180, 90),
        Color.FromArgb(255, 220, 160, 40),
        Color.FromArgb(255, 140, 60, 200)
    ];
}
