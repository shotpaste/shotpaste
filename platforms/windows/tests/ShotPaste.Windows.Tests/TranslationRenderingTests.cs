using System.Windows.Media;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class TranslationRenderingTests
{
    [Fact]
    [Trait("Category", "NativeDesktop")]
    public void RenderKeepsDimensionsSourcePixelsAndUntranslatedRegions()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                var pixels = Enumerable.Repeat(new byte[] { 30, 50, 70, 255 }, 200 * 100).SelectMany(pixel => pixel).ToArray();
                var source = BitmapSource.Create(200, 100, 144, 144, PixelFormats.Bgra32, null, pixels, 800);
                source.Freeze();
                var image = TranslationResultRenderer.Render(source, [new("b0", "source", new(20, 20, 80, 30))], [new("b0", "Translated text")]);
                Assert.True(image.IsFrozen);
                Assert.Equal(200, image.PixelWidth);
                Assert.Equal(100, image.PixelHeight);
                var result = new byte[pixels.Length];
                image.CopyPixels(result, 800, 0);
                Assert.Equal(pixels[..4], result[..4]);
                Assert.Equal(pixels[^4..], result[^4..]);
                Assert.NotEqual(pixels[(20 * 800 + 20 * 4)..(20 * 800 + 21 * 4)], result[(20 * 800 + 20 * 4)..(20 * 800 + 21 * 4)]);
                var original = new byte[pixels.Length];
                source.CopyPixels(original, 800, 0);
                Assert.Equal(pixels, original);
            }
            catch (Exception exception) { failure = exception; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
