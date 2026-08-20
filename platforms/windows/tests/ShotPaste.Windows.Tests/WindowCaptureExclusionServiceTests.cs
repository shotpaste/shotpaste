using System.Windows.Interop;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class WindowCaptureExclusionServiceTests
{
    [Fact]
    public void EnabledService_ExcludesWindowsOpenedLaterAndRestoresTheirAffinity()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                using var service = new WindowCaptureExclusionService();
                service.SetEnabled(true);
                using var first = CreateTestWindow("ShotPasteCaptureExclusionTest.First");
                using var later = CreateTestWindow("ShotPasteCaptureExclusionTest.Later");
                // Force the same refresh that the production timer performs;
                // this test thread intentionally has no WPF Application loop.
                service.SetEnabled(true);

                AssertAffinity(first.Handle, NativeMethods.WdaExcludeFromCapture);
                AssertAffinity(later.Handle, NativeMethods.WdaExcludeFromCapture);

                service.SetEnabled(false);
                AssertAffinity(first.Handle, NativeMethods.WdaNone);
                AssertAffinity(later.Handle, NativeMethods.WdaNone);
            }
            catch (Exception exception) { failure = exception; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(10)), "Capture exclusion STA test timed out.");
        if (failure is not null) throw failure;
    }

    private static HwndSource CreateTestWindow(string name) => new(new HwndSourceParameters(name)
    {
        Width = 2,
        Height = 2,
        PositionX = 0,
        PositionY = 0,
        WindowStyle = 0x10000000
    });

    private static void AssertAffinity(IntPtr handle, uint expected)
    {
        Assert.NotEqual(IntPtr.Zero, handle);
        Assert.True(NativeMethods.GetWindowDisplayAffinity(handle, out var actual));
        Assert.Equal(expected, actual);
    }

}
