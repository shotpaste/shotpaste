using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class UiTestIsolationPolicyTests
{
    [Fact]
    public void UiTestRequiresAnExplicitAbsoluteDataRoot()
    {
        Assert.Throws<InvalidOperationException>(() =>
            UiTestIsolationPolicy.PrepareDataRoot(["--ui-test"], AppBuildIdentity.Debug));
        Assert.Throws<InvalidOperationException>(() =>
            UiTestIsolationPolicy.PrepareDataRoot(["--ui-test", "--data-root", "relative-root"], AppBuildIdentity.Debug));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void UiTestRejectsEveryProductionDataTree(bool debug)
    {
        var identity = AppBuildIdentity.ForBuild(debug);
        var productionRoot = AppPaths.DefaultRootFor(identity);

        Assert.Throws<InvalidOperationException>(() => UiTestIsolationPolicy.PrepareDataRoot(
            ["--data-root", productionRoot], identity));
        Assert.Throws<InvalidOperationException>(() => UiTestIsolationPolicy.PrepareDataRoot(
            ["--data-root", Path.Combine(productionRoot, "nested-test")], identity));
        Assert.Throws<InvalidOperationException>(() => UiTestIsolationPolicy.PrepareDataRoot(
            ["--data-root", Path.GetDirectoryName(productionRoot)!], identity));
    }

    [Fact]
    public void UiTestRootIsPermanentlyOwnedByOneAppVariant()
    {
        var root = Path.Combine(Path.GetTempPath(), "ShotPasteUiTestIsolation", Guid.NewGuid().ToString("N"));
        try
        {
            var prepared = UiTestIsolationPolicy.PrepareDataRoot(["--data-root", root], AppBuildIdentity.Debug);

            Assert.Equal(Path.GetFullPath(root), prepared);
            Assert.Equal("debug", File.ReadAllText(Path.Combine(root, UiTestIsolationPolicy.VariantMarkerFileName)));
            Assert.Equal(prepared,
                UiTestIsolationPolicy.PrepareDataRoot([$"--data-root={root}"], AppBuildIdentity.Debug));
            Assert.Throws<InvalidOperationException>(() =>
                UiTestIsolationPolicy.PrepareDataRoot(["--data-root", root], AppBuildIdentity.Release));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }
}
