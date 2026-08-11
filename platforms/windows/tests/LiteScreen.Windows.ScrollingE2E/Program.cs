using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Text.Json;
using LiteScreen.Windows.Services;

if (args.Length > 0 && args[0].Equals("--live", StringComparison.OrdinalIgnoreCase))
    return await LiveScrollingCapture.RunAsync(args.Skip(1).ToArray(), fastManualScroll: false);

if (args.Length > 0 && args[0].Equals("--live-fast", StringComparison.OrdinalIgnoreCase))
    return await LiveScrollingCapture.RunAsync(args.Skip(1).ToArray(), fastManualScroll: true);

if (args.Length > 0 && args[0].Equals("--edge", StringComparison.OrdinalIgnoreCase))
    return await EdgeScrollingCapture.RunAsync(args.Skip(1).ToArray(), fastManualScroll: false);

if (args.Length > 0 && args[0].Equals("--edge-fast", StringComparison.OrdinalIgnoreCase))
    return await EdgeScrollingCapture.RunAsync(args.Skip(1).ToArray(), fastManualScroll: true);

if (args.Length != 4 ||
    !int.TryParse(args[2], out var expectedWidth) ||
    !int.TryParse(args[3], out var expectedHeight))
{
    Console.Error.WriteLine(
        "Usage: LiteScreen.Windows.ScrollingE2E <frames-directory> <output.png> <expected-width> <expected-height>");
    return 2;
}

var framesDirectory = Path.GetFullPath(args[0]);
var outputPath = Path.GetFullPath(args[1]);
var framePaths = Directory.GetFiles(framesDirectory, "frame-*.png")
    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
    .ToArray();
if (framePaths.Length < 2)
    throw new InvalidOperationException($"Expected at least two browser frames in {framesDirectory}.");

using var stitcher = new ScrollingStitcher(detectFixedBars: true);
var observations = new List<object>(framePaths.Length);
foreach (var (framePath, index) in framePaths.Select((path, index) => (path, index)))
{
    using var frame = new Bitmap(framePath);
    var result = stitcher.Append(frame, expectedWheelDirection: index == 0 ? 0 : -1);
    observations.Add(new
    {
        index,
        file = Path.GetFileName(framePath),
        result = result.ToString(),
        height = stitcher.OutputHeight,
        match = stitcher.LastMatchDiagnostics
    });
    if (result is StitchResult.NoMatch or StitchResult.HeightLimit)
        throw new InvalidOperationException(
            $"Frame {index} failed to stitch: {result} ({framePath}); " +
            $"fixed horizontal={stitcher.FixedHorizontalBars}, sides={stitcher.FixedSideBars}.");
}

using var stitched = stitcher.Result ?? throw new InvalidOperationException("Stitcher returned no output.");
if (stitched.Width != expectedWidth || stitched.Height != expectedHeight)
    throw new InvalidOperationException(
        $"Unexpected output size {stitched.Width}x{stitched.Height}; expected {expectedWidth}x{expectedHeight}.");

var fixedHorizontal = stitcher.FixedHorizontalBars;
var fixedSides = stitcher.FixedSideBars;
if (fixedHorizontal.Top < 40 || fixedHorizontal.Top > 80)
    throw new InvalidOperationException($"Fixed header detection is implausible: {fixedHorizontal.Top}px.");
if (fixedSides.Left < stitched.Width * 0.05 || fixedSides.Left > stitched.Width * 0.20)
    throw new InvalidOperationException($"Fixed left rail detection is implausible: {fixedSides.Left}px.");

using var firstFrame = new Bitmap(framePaths[0]);
using var lastFrame = new Bitmap(framePaths[^1]);
if (!BandsEqual(firstFrame, 0, stitched, 0, fixedHorizontal.Top))
    throw new InvalidOperationException("The fixed header changed while composing the final image.");
var tailProofHeight = Math.Min(120, Math.Min(lastFrame.Height, stitched.Height));
if (!BandsEqual(
        lastFrame,
        lastFrame.Height - tailProofHeight,
        stitched,
        stitched.Height - tailProofHeight,
        tailProofHeight))
    throw new InvalidOperationException("The final browser viewport was not preserved at the bottom of the long image.");

Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
stitched.Save(outputPath, ImageFormat.Png);
Console.WriteLine(JsonSerializer.Serialize(new
{
    passed = true,
    frames = framePaths.Length,
    output = outputPath,
    width = stitched.Width,
    height = stitched.Height,
    fixedTop = fixedHorizontal.Top,
    fixedBottom = fixedHorizontal.Bottom,
    fixedLeft = fixedSides.Left,
    fixedRight = fixedSides.Right,
    headerProof = true,
    tailProof = true,
    observations
}, new JsonSerializerOptions { WriteIndented = true }));
return 0;

static bool BandsEqual(Bitmap expected, int expectedY, Bitmap actual, int actualY, int height)
{
    if (expected.Width != actual.Width || height < 0) return false;
    for (var y = 0; y < height; y++)
    {
        for (var x = 0; x < expected.Width; x++)
        {
            if (expected.GetPixel(x, expectedY + y).ToArgb() != actual.GetPixel(x, actualY + y).ToArgb())
                return false;
        }
    }
    return true;
}
