using LiteScreen.Windows.Services;
using ZXing;
using ZXing.Common;
using ZXing.Windows.Compatibility;

namespace LiteScreen.Windows.Tests;

public sealed class OcrServiceTests
{
    [Fact]
    public async Task RecognizeAsync_ReadsHighContrastPrintedText()
    {
        using var bitmap = new System.Drawing.Bitmap(1200, 180);
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
        using (var font = new System.Drawing.Font("Arial", 48, System.Drawing.FontStyle.Bold))
        {
            graphics.Clear(System.Drawing.Color.White);
            graphics.DrawString("LITE SCREEN OCR 12345", font, System.Drawing.Brushes.Black, 20, 45);
        }

        var text = await new OcrService().RecognizeAsync(bitmap);

        // Installed Windows OCR languages may render the final digits differently.
        Assert.Contains("123", text);
    }

    [Fact]
    public async Task RecognizeAsync_IncludesQrPayload()
    {
        var writer = new BarcodeWriter
        {
            Format = BarcodeFormat.QR_CODE,
            Options = new EncodingOptions { Width = 240, Height = 240, Margin = 2 }
        };
        using var bitmap = writer.Write("https://litescreen.local/test");
        var text = await new OcrService().RecognizeAsync(bitmap);
        Assert.Contains("https://litescreen.local/test", text);
    }

    [Fact]
    public async Task RecognizeDetailedAsync_MergesOcrAndMultipleQrPayloads()
    {
        var writer = new BarcodeWriter
        {
            Format = BarcodeFormat.QR_CODE,
            Options = new EncodingOptions { Width = 240, Height = 240, Margin = 2 }
        };
        using var first = writer.Write("https://litescreen.local/one");
        using var second = writer.Write("https://litescreen.local/two");
        using var bitmap = new System.Drawing.Bitmap(900, 340);
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
        using (var font = new System.Drawing.Font("Arial", 34, System.Drawing.FontStyle.Bold))
        {
            graphics.Clear(System.Drawing.Color.White);
            graphics.DrawImageUnscaled(first, 10, 10);
            graphics.DrawImageUnscaled(second, 270, 10);
            graphics.DrawString("OCR 123", font, System.Drawing.Brushes.Black, 545, 120);
        }

        var result = await new OcrService().RecognizeDetailedAsync(bitmap);

        Assert.Contains("https://litescreen.local/one", result.QrPayloads);
        Assert.Contains("https://litescreen.local/two", result.QrPayloads);
        Assert.Equal(
            ["https://litescreen.local/one", "https://litescreen.local/two"],
            result.QrPayloads);
        Assert.Contains("123", result.Text);
        Assert.Contains("https://litescreen.local/one", result.Text);
        Assert.Contains("https://litescreen.local/two", result.Text);
        Assert.Equal(2, result.Links.Count(link => link.StartsWith("https://litescreen.local/", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task RecognizeDetailedAsync_RunsOcrAndQrConcurrentlyAndKeepsResultOrder()
    {
        var ocrStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var qrStarted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var service = new OcrService(
            null,
            async _ =>
            {
                ocrStarted.TrySetResult(true);
                await qrStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
                return "OCR FIRST https://litescreen.local/text";
            },
            _ =>
            {
                qrStarted.TrySetResult(true);
                ocrStarted.Task.WaitAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();
                return ["https://litescreen.local/left", "dd@example.com"];
            });
        using var bitmap = new System.Drawing.Bitmap(32, 32);

        var result = await service.RecognizeDetailedAsync(bitmap).WaitAsync(TimeSpan.FromSeconds(4));

        Assert.Equal(
            ["https://litescreen.local/left", "dd@example.com"],
            result.QrPayloads);
        Assert.True(result.Text.IndexOf("OCR FIRST", StringComparison.Ordinal) <
                    result.Text.IndexOf("https://litescreen.local/left", StringComparison.Ordinal));
        Assert.True(result.Text.IndexOf("https://litescreen.local/left", StringComparison.Ordinal) <
                    result.Text.IndexOf("dd@example.com", StringComparison.Ordinal));
        Assert.Equal(
            ["https://litescreen.local/text", "https://litescreen.local/left", "dd@example.com"],
            result.Links);
    }

    [Fact]
    public async Task RecognizeDetailedAsync_ReturnsEmptyResultWhenNeitherEngineFindsContent()
    {
        var service = new OcrService(
            null,
            _ => Task.FromResult<string?>(null),
            _ => []);
        using var bitmap = new System.Drawing.Bitmap(32, 32);

        var result = await service.RecognizeDetailedAsync(bitmap);

        Assert.Empty(result.Text);
        Assert.Empty(result.QrPayloads);
        Assert.Empty(result.Links);
        Assert.Empty(result.SensitiveRegions);
    }

    [Fact]
    public async Task RecognizeDetailedAsync_ReportsUnavailableOcrWhenQrAlsoFails()
    {
        var service = new OcrService(
            null,
            _ => Task.FromException<string?>(new NotSupportedException("OCR language pack unavailable")),
            _ => []);
        using var bitmap = new System.Drawing.Bitmap(32, 32);

        var error = await Assert.ThrowsAsync<NotSupportedException>(() => service.RecognizeDetailedAsync(bitmap));

        Assert.Contains("unavailable", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task RecognizeDetailedAsync_UsesQrWhenOcrEngineIsUnavailable()
    {
        var service = new OcrService(
            null,
            _ => Task.FromException<string?>(new NotSupportedException("OCR language pack unavailable")),
            _ => ["https://litescreen.local/qr-only"]);
        using var bitmap = new System.Drawing.Bitmap(32, 32);

        var result = await service.RecognizeDetailedAsync(bitmap);

        Assert.Equal("https://litescreen.local/qr-only", result.Text);
        Assert.Equal(["https://litescreen.local/qr-only"], result.Links);
    }

    [Fact]
    public void DetectLinks_FindsUrlsAndEmailsWithoutTrailingPunctuation()
    {
        var links = OcrService.DetectLinks("See https://example.com/a, then email dd@example.com.");

        Assert.Equal(2, links.Count);
        Assert.Contains("https://example.com/a", links);
        Assert.Contains("dd@example.com", links);
    }

    [Fact]
    public void BuildLanguageCandidates_PrioritizesConfiguredCjkAndKeepsFallbacks()
    {
        var candidates = OcrService.BuildLanguageCandidates(
            "zh-CN",
            ["en-US", "ja-JP", "zh-Hans-CN", "ko-KR", "fr-FR"]);

        Assert.Equal("zh-Hans-CN", candidates[0]);
        var ordered = candidates.ToArray();
        Assert.True(Array.IndexOf(ordered, "ja-JP") < Array.IndexOf(ordered, "en-US"));
        Assert.Equal(candidates.Count, candidates.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Fact]
    public void BuildLanguageCandidates_RecoversFromMissingConfiguredLanguage()
    {
        var candidates = OcrService.BuildLanguageCandidates(
            "de-DE",
            ["zh-Hans-CN", "en-US", "ja-JP"]);

        Assert.Equal("en-US", candidates[0]);
        Assert.Equal(3, candidates.Count);
    }
}
