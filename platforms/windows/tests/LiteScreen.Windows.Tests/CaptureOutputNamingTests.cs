using LiteScreen.Windows.Models;
using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class CaptureOutputNamingTests
{
    [Fact]
    public void NewPath_UsesKindSpecificPrefix()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            var path = CaptureOutputNaming.NewPath(directory, CaptureKind.ScrollingScreenshot, ".png");
            Assert.StartsWith("LiteScreen-Scrolling-", Path.GetFileName(path));
            Assert.EndsWith(".png", path);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory); }
    }

    [Fact]
    public void NewPath_ExpandsTemplateAndBlocksTraversal()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            var path = CaptureOutputNaming.NewPath(directory, CaptureKind.Screenshot, ".png", "../shots/{year}/{type}_{ms}");
            Assert.StartsWith(Path.GetFullPath(directory), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase);
            Assert.Contains(Path.Combine("shots", DateTime.Now.Year.ToString()), path);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
