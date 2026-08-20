using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Views;
using Windows.Media.Ocr;
using ZXing;
using ZXing.Common;
using ZXing.Windows.Compatibility;
using Drawing = System.Drawing;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfButton = System.Windows.Controls.Button;
using WpfColor = System.Windows.Media.Color;
using WpfControl = System.Windows.Controls.Control;

namespace ShotPaste.Windows.OcrE2E;

internal static class Program
{
    private const string LeftPayload = "https://shotpaste.local/ocr-left";
    private const string RightPayload = "https://shotpaste.local/ocr-right";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            var outputRoot = Path.GetFullPath(args.FirstOrDefault() ?? Path.Combine("build", "e2e", "ocr-p2"));
            Directory.CreateDirectory(outputRoot);
            var fixturePath = Path.Combine(outputRoot, "mixed-chinese-english-two-qr.png");
            using var fixture = CreateFixture();
            fixture.Save(fixturePath, ImageFormat.Png);

            var availableLanguages = OcrEngine.AvailableRecognizerLanguages
                .Select(language => language.LanguageTag)
                .ToArray();
            var stopwatch = Stopwatch.StartNew();
            var result = new OcrService(() => "zh-CN").RecognizeDetailedAsync(fixture)
                .GetAwaiter().GetResult();
            stopwatch.Stop();

            var expectedPayloads = new[] { LeftPayload, RightPayload };
            if (!result.QrPayloads.SequenceEqual(expectedPayloads, StringComparer.Ordinal))
                throw new InvalidOperationException(
                    $"QR reading order changed: {string.Join(" | ", result.QrPayloads)}.");
            if (!result.Links.SequenceEqual(expectedPayloads, StringComparer.Ordinal))
                throw new InvalidOperationException(
                    $"Link order changed: {string.Join(" | ", result.Links)}.");
            if (!result.Text.Contains("2026", StringComparison.Ordinal))
                throw new InvalidOperationException($"Real OCR did not recognize the stable English marker: {result.Text}");
            if (result.Text.IndexOf(LeftPayload, StringComparison.Ordinal) >=
                result.Text.IndexOf(RightPayload, StringComparison.Ordinal))
                throw new InvalidOperationException("Merged OCR/QR text did not preserve left-to-right QR order.");

            var copiedText = VerifyClipboardRoundTrip(result.Text);
            var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            LoadProductResources(app);
            var window = new OcrResultWindow(result);
            window.Show();
            window.Dispatcher.Invoke(window.UpdateLayout, DispatcherPriority.ContextIdle);
            var linkButtons = VisualDescendants<WpfButton>(window)
                .Where(button => button.Tag is string)
                .Select(button => (string)button.Tag)
                .ToArray();
            var expectedLinkActions = expectedPayloads
                .SelectMany(payload => new[] { payload, payload })
                .ToArray();
            if (!linkButtons.SequenceEqual(expectedLinkActions, StringComparer.Ordinal))
                throw new InvalidOperationException(
                    $"OCR result window link order changed: {string.Join(" | ", linkButtons)}.");
            if (VisualDescendants<WpfButton>(window).Single(button => button.Name == "OpenAllButton").Visibility !=
                Visibility.Visible)
                throw new InvalidOperationException("OCR result window did not expose Open All for multiple links.");
            var resultWindowPath = Path.Combine(outputRoot, "ocr-result-window.png");
            SaveVisual(window, resultWindowPath);
            window.Close();

            using var blank = new Drawing.Bitmap(900, 320, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var graphics = Drawing.Graphics.FromImage(blank)) graphics.Clear(Drawing.Color.White);
            var blankStopwatch = Stopwatch.StartNew();
            var blankResult = new OcrService(() => "zh-CN").RecognizeDetailedAsync(blank)
                .GetAwaiter().GetResult();
            blankStopwatch.Stop();
            if (!string.IsNullOrWhiteSpace(blankResult.Text) || blankResult.QrPayloads.Count > 0)
                throw new InvalidOperationException($"Blank OCR fixture returned content: {blankResult.Text}");

            var summaryPath = Path.Combine(outputRoot, "summary.json");
            File.WriteAllText(summaryPath, JsonSerializer.Serialize(new
            {
                GeneratedAt = DateTimeOffset.Now,
                Fixture = fixturePath,
                ResultWindow = resultWindowPath,
                AvailableRecognizerLanguages = availableLanguages,
                HasChineseRecognizer = availableLanguages.Any(tag => tag.StartsWith("zh", StringComparison.OrdinalIgnoreCase)),
                RecognizedChineseGlyphs = result.Text.Any(character => character is >= '\u3400' and <= '\u9FFF'),
                RecognitionMilliseconds = Math.Round(stopwatch.Elapsed.TotalMilliseconds, 2),
                BlankRecognitionMilliseconds = Math.Round(blankStopwatch.Elapsed.TotalMilliseconds, 2),
                result.Text,
                result.QrPayloads,
                result.Links,
                ClipboardRoundTrip = copiedText == result.Text,
                ResultWindowLinkOrder = linkButtons,
                BlankResultIsEmpty = string.IsNullOrWhiteSpace(blankResult.Text)
            }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine(File.ReadAllText(summaryPath));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }

    private static Drawing.Bitmap CreateFixture()
    {
        var bitmap = new Drawing.Bitmap(1400, 760, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.Clear(Drawing.Color.White);
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using var englishFont = new Drawing.Font("Segoe UI", 58, Drawing.FontStyle.Bold, Drawing.GraphicsUnit.Pixel);
        using var chineseFont = new Drawing.Font("Microsoft YaHei UI", 54, Drawing.FontStyle.Regular, Drawing.GraphicsUnit.Pixel);
        using var hintFont = new Drawing.Font("Segoe UI", 28, Drawing.FontStyle.Regular, Drawing.GraphicsUnit.Pixel);
        graphics.DrawString("ShotPaste OCR 2026", englishFont, Drawing.Brushes.Black, 54, 48);
        graphics.DrawString("中文识别 · 对齐验证", chineseFont, Drawing.Brushes.Black, 54, 155);
        graphics.DrawString("Two QR links must remain in visual order", hintFont, Drawing.Brushes.DimGray, 58, 270);

        var writer = new BarcodeWriter
        {
            Format = BarcodeFormat.QR_CODE,
            Options = new EncodingOptions { Width = 260, Height = 260, Margin = 2 }
        };
        using var left = writer.Write(LeftPayload);
        using var right = writer.Write(RightPayload);
        graphics.DrawImageUnscaled(left, 70, 385);
        graphics.DrawImageUnscaled(right, 520, 385);
        graphics.DrawString("LEFT", hintFont, Drawing.Brushes.Black, 158, 665);
        graphics.DrawString("RIGHT", hintFont, Drawing.Brushes.Black, 598, 665);
        return bitmap;
    }

    private static string VerifyClipboardRoundTrip(string text)
    {
        var previous = TryGetClipboardData();
        try
        {
            var data = new System.Windows.DataObject();
            data.SetText(text);
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new byte[] { 1 });
            RetryClipboard(() => System.Windows.Clipboard.SetDataObject(data, true));
            return RetryClipboard(System.Windows.Clipboard.GetText);
        }
        finally
        {
            if (previous is not null)
                try { RetryClipboard(() => System.Windows.Clipboard.SetDataObject(previous, true)); }
                catch (ExternalException) { }
        }
    }

    private static System.Windows.IDataObject? TryGetClipboardData()
    {
        try { return RetryClipboard(System.Windows.Clipboard.GetDataObject); }
        catch (ExternalException) { return null; }
    }

    private static void RetryClipboard(Action action)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { action(); return; }
            catch (ExternalException) when (attempt < 5) { Thread.Sleep(60); }
        }
    }

    private static T RetryClipboard<T>(Func<T> action)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { return action(); }
            catch (ExternalException) when (attempt < 5) { Thread.Sleep(60); }
        }
    }

    private static void LoadProductResources(System.Windows.Application app)
    {
        var productAssembly = typeof(OcrResultWindow).Assembly.GetName().Name
            ?? throw new InvalidOperationException("ShotPaste product assembly name is unavailable.");
        foreach (var relative in new[]
                 {
                     "Resources/DesignTokens.xaml", "Resources/Themes/Colors.Light.xaml",
                     "Resources/AnnotationIcons.xaml", "Resources/Icons.xaml",
                     "Resources/Controls/Common.xaml", "Resources/Controls/Buttons.xaml",
                     "Resources/Controls/CheckBox.xaml", "Resources/Controls/RadioButton.xaml",
                     "Resources/Controls/TextBox.xaml", "Resources/Controls/ComboBox.xaml",
                     "Resources/Controls/Slider.xaml", "Resources/Controls/ScrollBar.xaml",
                     "Resources/Controls/Menu.xaml", "Resources/Controls/Tabs.xaml"
                 })
            app.Resources.MergedDictionaries.Add(new ResourceDictionary
            {
                Source = new Uri($"pack://application:,,,/{productAssembly};component/{relative}", UriKind.Absolute)
            });
    }

    private static IEnumerable<T> VisualDescendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T typed) yield return typed;
            foreach (var descendant in VisualDescendants<T>(child)) yield return descendant;
        }
    }

    private static void SaveVisual(FrameworkElement visual, string path)
    {
        var width = Math.Max(1, (int)Math.Ceiling(visual.ActualWidth));
        var height = Math.Max(1, (int)Math.Ceiling(visual.ActualHeight));
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
