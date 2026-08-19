using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class ScrollingMotionTrackerTests
{
    [Theory]
    [InlineData(24)]
    [InlineData(-24)]
    public void Estimate_DetectsSignedVerticalMotion(int delta)
    {
        const int width = 240;
        const int height = 180;
        var previousOffset = delta < 0 ? 80 : 0;
        var previous = GrayFrame.FromPixels(
            MakePixels(width, height, previousOffset), width, height);
        var current = GrayFrame.FromPixels(
            MakePixels(width, height, previousOffset + delta), width, height);
        var tracker = new ScrollingMotionTracker();

        var estimate = tracker.Estimate(
            previous,
            current,
            new MotionGuidance(0, 0, 0, 0, MotionSearchDirection.Both, 0, true));

        Assert.NotNull(estimate);
        Assert.InRange(estimate.Value.DeltaY, delta - 0.75, delta + 0.75);
        Assert.InRange(Math.Abs(estimate.Value.DeltaX), 0, 1);
        Assert.True(estimate.Value.ConfidentBandCount >= 2);
    }

    private static byte[] MakePixels(int width, int height, int logicalYOffset)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        {
            var logicalY = (ulong)(logicalYOffset + y);
            for (var x = 0; x < width; x++)
            {
                var value = logicalY * 1_103_515_245UL +
                            (ulong)x * 2_654_435_761UL +
                            0x9E37_79B9_7F4A_7C15UL;
                var mixed = value ^ (value >> 29) ^ (value >> 47);
                var index = (y * width + x) * 4;
                pixels[index] = (byte)(mixed >> 23);
                pixels[index + 1] = (byte)(mixed >> 11);
                pixels[index + 2] = (byte)mixed;
                pixels[index + 3] = 255;
            }
        }
        return pixels;
    }
}
