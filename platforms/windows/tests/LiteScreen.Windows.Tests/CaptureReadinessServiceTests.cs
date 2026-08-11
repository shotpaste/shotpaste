using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class CaptureReadinessServiceTests
{
    [Fact]
    public void CountVisible_IgnoresZeroHandlesAndUsesEveryRealHandle()
    {
        var visible = new HashSet<IntPtr> { new(2), new(4) };

        var count = CaptureReadinessService.CountVisible(
            [IntPtr.Zero, new IntPtr(1), new IntPtr(2), new IntPtr(3), new IntPtr(4)],
            visible.Contains);

        Assert.Equal(2, count);
    }
}
