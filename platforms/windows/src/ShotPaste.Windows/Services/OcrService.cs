using Drawing = System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using ShotPaste.Windows.Models;
using Windows.Graphics.Imaging;
using Windows.Globalization;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using ZXing.Windows.Compatibility;

namespace ShotPaste.Windows.Services;

public sealed record OcrRecognitionResult(
    string Text,
    IReadOnlyList<string> QrPayloads,
    IReadOnlyList<string> Links,
    IReadOnlyList<SensitiveRegion> SensitiveRegions)
{
    public string? QrPayload => QrPayloads.FirstOrDefault();
}

public sealed record OcrWordRegion(string Text, Drawing.Rectangle Bounds);

public sealed class OcrService
{
    private readonly Func<string>? _languageProvider;
    private readonly Func<bool>? _linkDetectionProvider;
    private readonly Func<Drawing.Bitmap, Task<string?>>? _ocrTextRecognizer;
    private readonly Func<Drawing.Bitmap, IReadOnlyList<string>> _qrReader;

    public OcrService(Func<string>? languageProvider = null, Func<bool>? linkDetectionProvider = null)
        : this(languageProvider, null, TryReadQrs, linkDetectionProvider)
    {
    }

    internal OcrService(
        Func<string>? languageProvider,
        Func<Drawing.Bitmap, Task<string?>>? ocrTextRecognizer,
        Func<Drawing.Bitmap, IReadOnlyList<string>> qrReader,
        Func<bool>? linkDetectionProvider = null)
    {
        _languageProvider = languageProvider;
        _ocrTextRecognizer = ocrTextRecognizer;
        _qrReader = qrReader;
        _linkDetectionProvider = linkDetectionProvider;
    }

    public async Task<string> RecognizeAsync(Drawing.Bitmap bitmap)
    {
        var result = await RecognizeDetailedAsync(bitmap);
        return result.Text;
    }

    public async Task<OcrRecognitionResult> RecognizeDetailedAsync(Drawing.Bitmap bitmap)
    {
        using var qrBitmap = (Drawing.Bitmap)bitmap.Clone();
        using var ocrBitmap = (Drawing.Bitmap)bitmap.Clone();
        var qrTask = Task.Run(() => _qrReader(qrBitmap));
        var ocrTask = RecognizeTextPassAsync(ocrBitmap);
        var qrPayloads = await qrTask;
        OcrTextPass? recognized;
        try { recognized = await ocrTask; }
        catch (Exception exception) when (
            qrPayloads.Count > 0 && exception is NotSupportedException or InvalidOperationException)
        {
            recognized = null;
        }

        var uniqueQrPayloads = qrPayloads
            .Select(payload => payload?.Trim())
            .Where(payload => !string.IsNullOrWhiteSpace(payload))
            .Cast<string>()
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var text = ComposeOcrAndQrPayload(recognized?.Text, uniqueQrPayloads, LocalizationService.TranslatePhrase("二维码"))
            ?? string.Empty;
        var links = (_linkDetectionProvider?.Invoke() ?? true) ? DetectLinks(text) : [];
        var sensitive = recognized?.SensitiveRegions ?? [];
        return new OcrRecognitionResult(text, uniqueQrPayloads, links, sensitive);
    }

    internal static string? ComposeOcrAndQrPayload(
        string? recognizedText,
        IEnumerable<string> qrPayloads,
        string qrSectionTitle)
    {
        var text = recognizedText?.Trim() ?? string.Empty;
        var unique = qrPayloads
            .Select(payload => payload?.Trim())
            .Where(payload => !string.IsNullOrWhiteSpace(payload))
            .Cast<string>()
            .Distinct(StringComparer.Ordinal)
            .Where(payload => text.Length == 0 || !text.Contains(payload, StringComparison.Ordinal))
            .ToArray();
        if (text.Length == 0)
        {
            if (unique.Length == 0) return null;
            return unique.Length == 1
                ? unique[0]
                : $"{qrSectionTitle}:{Environment.NewLine}{string.Join(Environment.NewLine, unique)}";
        }
        if (unique.Length == 0) return text;
        return $"{text}{Environment.NewLine}{Environment.NewLine}{qrSectionTitle}:{Environment.NewLine}{string.Join(Environment.NewLine, unique)}";
    }

    private async Task<OcrTextPass?> RecognizeTextPassAsync(Drawing.Bitmap bitmap)
    {
        if (_ocrTextRecognizer is not null)
        {
            var text = await _ocrTextRecognizer(bitmap);
            return string.IsNullOrWhiteSpace(text) ? null : new OcrTextPass(text, []);
        }

        var recovered = await RecognizeWithRecoveryAsync(bitmap);
        return recovered is null
            ? null
            : new OcrTextPass(
                recovered.Result.Text,
                ClassifySensitiveRegions(recovered.Result, recovered.Scale));
    }

    public async Task<IReadOnlyList<OcrWordRegion>> RecognizeRegionsAsync(Drawing.Bitmap bitmap)
    {
        var recovered = await RecognizeWithRecoveryAsync(bitmap);
        if (recovered is null) return [];
        return recovered.Result.Lines
            .SelectMany(line => line.Words)
            .Select(word => new OcrWordRegion(
                word.Text,
                new Drawing.Rectangle(
                    Math.Max(0, (int)Math.Round(word.BoundingRect.X / recovered.Scale)),
                    Math.Max(0, (int)Math.Round(word.BoundingRect.Y / recovered.Scale)),
                    Math.Max(1, (int)Math.Round(word.BoundingRect.Width / recovered.Scale)),
                    Math.Max(1, (int)Math.Round(word.BoundingRect.Height / recovered.Scale)))))
            .ToArray();
    }

    public async Task<IReadOnlyList<SensitiveRegion>> FindSensitiveRegionsAsync(Drawing.Bitmap bitmap)
    {
        RecoveredOcr? recovered;
        try { recovered = await RecognizeWithRecoveryAsync(bitmap); }
        catch (NotSupportedException) { return []; }
        catch (InvalidOperationException) { return []; }
        return recovered is null ? [] : ClassifySensitiveRegions(recovered.Result, recovered.Scale);
    }

    private static IReadOnlyList<SensitiveRegion> ClassifySensitiveRegions(OcrResult result, double scale)
    {
        var regions = new List<SensitiveRegion>();
        foreach (var line in result.Lines)
        {
            var lineText = line.Text.Trim();
            if (TryClassifySensitive(lineText, out var lineKind))
            {
                var bounds = Bounds(line.Words.Select(word => word.BoundingRect), scale);
                if (!bounds.IsEmpty) regions.Add(new SensitiveRegion(lineText, bounds, lineKind));
                continue;
            }
            foreach (var word in line.Words)
            {
                if (!TryClassifySensitive(word.Text, out var kind)) continue;
                var rect = new Drawing.Rectangle(
                    Math.Max(0, (int)Math.Round(word.BoundingRect.X / scale)),
                    Math.Max(0, (int)Math.Round(word.BoundingRect.Y / scale)),
                    Math.Max(1, (int)Math.Round(word.BoundingRect.Width / scale)),
                    Math.Max(1, (int)Math.Round(word.BoundingRect.Height / scale)));
                regions.Add(new SensitiveRegion(word.Text, rect, kind));
            }
        }
        return regions;
    }

    public static IReadOnlyList<string> DetectLinks(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        var matches = System.Text.RegularExpressions.Regex.Matches(
            text,
            @"(?:(?:https?://|www\.)[^\s<>]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return matches.Select(match => match.Value.TrimEnd('.', ',', ';', ')', ']', '}')).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private async Task<RecoveredOcr?> RecognizeWithRecoveryAsync(Drawing.Bitmap bitmap)
    {
        try
        {
            var original = await RecognizeWindowsAsync(bitmap);
            if (!string.IsNullOrWhiteSpace(original.Text)) return new RecoveredOcr(original, 1d);
        }
        catch (NotSupportedException) { throw; }
        catch (InvalidOperationException) { }

        foreach (var invert in new[] { false, true })
        {
            var (preprocessed, scale) = Preprocess(bitmap, invert);
            using (preprocessed)
            {
                try
                {
                    var recovered = await RecognizeWindowsAsync(preprocessed);
                    if (!string.IsNullOrWhiteSpace(recovered.Text)) return new RecoveredOcr(recovered, scale);
                }
                catch (NotSupportedException) { throw; }
                catch (InvalidOperationException) { }
            }
        }
        return null;
    }

    private async Task<OcrResult> RecognizeWindowsAsync(Drawing.Bitmap bitmap)
    {
        using var png = new MemoryStream();
        bitmap.Save(png, ImageFormat.Png);
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(png.ToArray());
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var softwareBitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        OcrResult? best = null;
        foreach (var engine in CreatePreferredEngines(_languageProvider?.Invoke()))
        {
            var result = await engine.RecognizeAsync(softwareBitmap);
            if (best is null || result.Text.Length > best.Text.Length) best = result;
            if (!string.IsNullOrWhiteSpace(result.Text)) return result;
        }
        return best ?? throw new NotSupportedException("当前 Windows 语言没有可用的 OCR 组件。请在 Windows 设置中安装对应的 OCR 语言包。");
    }

    private static IReadOnlyList<OcrEngine> CreatePreferredEngines(string? requestedLanguage)
    {
        var available = OcrEngine.AvailableRecognizerLanguages;
        var orderedTags = BuildLanguageCandidates(requestedLanguage, available.Select(language => language.LanguageTag));
        var engines = new List<OcrEngine>();
        foreach (var tag in orderedTags)
        {
            var language = available.FirstOrDefault(candidate => candidate.LanguageTag.Equals(tag, StringComparison.OrdinalIgnoreCase));
            if (language is null) continue;
            var engine = OcrEngine.TryCreateFromLanguage(language);
            if (engine is not null) engines.Add(engine);
        }
        var profileEngine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (profileEngine is not null && engines.All(engine => !engine.RecognizerLanguage.LanguageTag.Equals(profileEngine.RecognizerLanguage.LanguageTag, StringComparison.OrdinalIgnoreCase)))
            engines.Add(profileEngine);
        return engines;
    }

    internal static IReadOnlyList<string> BuildLanguageCandidates(string? requestedLanguage, IEnumerable<string> availableLanguages)
    {
        var available = availableLanguages.Where(tag => !string.IsNullOrWhiteSpace(tag)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var requested = string.IsNullOrWhiteSpace(requestedLanguage) || requestedLanguage.Equals("Auto", StringComparison.OrdinalIgnoreCase)
            ? string.Empty
            : requestedLanguage;
        var result = new List<string>();
        void AddMatches(string? preference)
        {
            if (string.IsNullOrWhiteSpace(preference)) return;
            var normalized = preference.Replace('_', '-');
            var primary = normalized.Split('-')[0];
            foreach (var tag in available.Where(tag => tag.Equals(normalized, StringComparison.OrdinalIgnoreCase)))
                if (!result.Contains(tag, StringComparer.OrdinalIgnoreCase)) result.Add(tag);
            foreach (var tag in available.Where(tag => tag.StartsWith(primary + "-", StringComparison.OrdinalIgnoreCase) || tag.Equals(primary, StringComparison.OrdinalIgnoreCase)))
                if (!result.Contains(tag, StringComparer.OrdinalIgnoreCase)) result.Add(tag);
        }

        AddMatches(requested);
        if (requested.StartsWith("zh", StringComparison.OrdinalIgnoreCase))
        {
            AddMatches(requested.Contains("TW", StringComparison.OrdinalIgnoreCase) || requested.Contains("Hant", StringComparison.OrdinalIgnoreCase) ? "zh-Hant" : "zh-Hans");
            AddMatches("ja");
            AddMatches("ko");
        }
        AddMatches("en-US");
        foreach (var tag in available)
            if (!result.Contains(tag, StringComparer.OrdinalIgnoreCase)) result.Add(tag);
        return result;
    }

    private static (Drawing.Bitmap Bitmap, double Scale) Preprocess(Drawing.Bitmap source, bool invert)
    {
        var scale = source.Width < 900 ? Math.Min(2d, 900d / Math.Max(1, source.Width)) : 1d;
        var width = Math.Max(1, (int)Math.Round(source.Width * scale));
        var height = Math.Max(1, (int)Math.Round(source.Height * scale));
        var result = new Drawing.Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Drawing.Graphics.FromImage(result);
        using var attributes = new ImageAttributes();
        var matrix = invert
            ? new ColorMatrix(new[]
            {
                new[] { -1f, 0f, 0f, 0f, 0f },
                new[] { 0f, -1f, 0f, 0f, 0f },
                new[] { 0f, 0f, -1f, 0f, 0f },
                new[] { 0f, 0f, 0f, 1f, 0f },
                new[] { 1f, 1f, 1f, 0f, 1f }
            })
            : new ColorMatrix(new[]
            {
                new[] { 1.35f, 0f, 0f, 0f, 0f },
                new[] { 0f, 1.35f, 0f, 0f, 0f },
                new[] { 0f, 0f, 1.35f, 0f, 0f },
                new[] { 0f, 0f, 0f, 1f, 0f },
                new[] { -0.12f, -0.12f, -0.12f, 0f, 1f }
            });
        attributes.SetColorMatrix(matrix);
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.DrawImage(source, new Drawing.Rectangle(0, 0, width, height), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel, attributes);
        return (result, scale);
    }

    private static Drawing.Rectangle Bounds(IEnumerable<global::Windows.Foundation.Rect> rects, double scale = 1d)
    {
        var values = rects.ToArray();
        if (values.Length == 0) return Drawing.Rectangle.Empty;
        var left = values.Min(rect => rect.X);
        var top = values.Min(rect => rect.Y);
        var right = values.Max(rect => rect.X + rect.Width);
        var bottom = values.Max(rect => rect.Y + rect.Height);
        return new Drawing.Rectangle(
            Math.Max(0, (int)Math.Floor(left / scale)),
            Math.Max(0, (int)Math.Floor(top / scale)),
            Math.Max(1, (int)Math.Ceiling((right - left) / scale)),
            Math.Max(1, (int)Math.Ceiling((bottom - top) / scale)));
    }

    private static bool TryClassifySensitive(string? value, out SensitiveRegionKind kind)
    {
        kind = SensitiveRegionKind.Unknown;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var text = value.Trim();
        if (System.Text.RegularExpressions.Regex.IsMatch(text, @"https?://|www\.", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            kind = SensitiveRegionKind.Url;
        else if (System.Text.RegularExpressions.Regex.IsMatch(text, @"^[^\s@]+@[^\s@]+\.[^\s@]+$"))
            kind = SensitiveRegionKind.Email;
        else if (System.Text.RegularExpressions.Regex.IsMatch(text, @"(?<!\d)(?:\+?\d[\d ()-]{7,}\d)(?!\d)"))
            kind = SensitiveRegionKind.Phone;
        else if (System.Text.RegularExpressions.Regex.IsMatch(text, @"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"))
            kind = SensitiveRegionKind.CreditCard;
        else if (System.Text.RegularExpressions.Regex.IsMatch(text, @"^[A-Z0-9_-]{20,}$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            kind = SensitiveRegionKind.ApiKey;
        else if (System.Text.RegularExpressions.Regex.IsMatch(text, @"^[0-9Xx-]{15,20}$"))
            kind = SensitiveRegionKind.IdentityNumber;
        else return false;
        return true;
    }

    private static IReadOnlyList<string> TryReadQrs(Drawing.Bitmap bitmap)
    {
        var reader = new BarcodeReader { AutoRotate = true, Options = { TryHarder = true } };
        var results = reader.DecodeMultiple(bitmap);
        if (results is null || results.Length == 0)
        {
            var single = reader.Decode(bitmap)?.Text;
            return string.IsNullOrWhiteSpace(single) ? [] : [single];
        }
        var placements = results.Select(result =>
        {
            var points = result.ResultPoints ?? [];
            var left = points.Length > 0 ? points.Min(point => point.X) : float.MaxValue;
            var top = points.Length > 0 ? points.Min(point => point.Y) : float.MaxValue;
            var right = points.Length > 0 ? points.Max(point => point.X) : float.MaxValue;
            var bottom = points.Length > 0 ? points.Max(point => point.Y) : float.MaxValue;
            return new QrPlacement(result, left, top, right, bottom);
        }).OrderBy(placement => placement.CenterY).ToList();
        var visualOrder = new List<QrPlacement>(placements.Count);
        while (placements.Count > 0)
        {
            var anchor = placements[0];
            var line = placements.Where(candidate =>
                    Math.Abs(candidate.CenterY - anchor.CenterY) <=
                    Math.Max(8, Math.Min(anchor.Height, candidate.Height) * 0.35f))
                .OrderBy(candidate => candidate.Left)
                .ToArray();
            visualOrder.AddRange(line);
            foreach (var placement in line) placements.Remove(placement);
        }
        return visualOrder
            .Select(placement => placement.Result.Text?.Trim())
            .Where(payload => !string.IsNullOrWhiteSpace(payload))
            .Cast<string>()
            .Distinct(StringComparer.Ordinal)
            .ToArray();
    }

    private sealed record QrPlacement(ZXing.Result Result, float Left, float Top, float Right, float Bottom)
    {
        public float CenterY => (Top + Bottom) / 2;
        public float Height => float.IsFinite(Bottom - Top) ? Math.Max(1, Bottom - Top) : 1;
    }

    private sealed record OcrTextPass(string Text, IReadOnlyList<SensitiveRegion> SensitiveRegions);
    private sealed record RecoveredOcr(OcrResult Result, double Scale);
}
