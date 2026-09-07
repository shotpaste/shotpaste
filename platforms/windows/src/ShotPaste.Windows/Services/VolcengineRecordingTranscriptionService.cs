using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using NAudio.Wave;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public sealed record RecordingTranscriptionConfiguration(
    string ApiKey, string AccessKey, string SecretKey, string Bucket, string InstallationId,
    string SourceLanguage, bool UseAI = false, string AgentEndpoint = "", string AgentModel = "", string AgentApiKey = "", string AgentApiProtocol = "openAICompatible", string OrganizationTemplate = "generalNotes")
{
    public string Prefix => $"transcription/v1/{InstallationId}/";
    public override string ToString() => "RecordingTranscriptionConfiguration { credentials redacted }";

    public static RecordingTranscriptionConfiguration? FromSettings(AppSettings settings, bool requireInitialized = true)
    {
        if ((requireInitialized && !settings.RecordingTranscriptionStorageInitialized) ||
            !VolcengineTosSigner.ValidCredential(settings.RecordingTranscriptionApiKey) ||
            !VolcengineTosSigner.ValidCredential(settings.RecordingTranscriptionAccessKey) ||
            !VolcengineTosSigner.ValidCredential(settings.RecordingTranscriptionSecretKey) ||
            !VolcengineTosSigner.ValidBucket(settings.RecordingTranscriptionBucket) ||
            !Guid.TryParse(settings.RecordingTranscriptionInstallationId, out _)) return null;
        return new(settings.RecordingTranscriptionApiKey, settings.RecordingTranscriptionAccessKey,
            settings.RecordingTranscriptionSecretKey, settings.RecordingTranscriptionBucket,
            settings.RecordingTranscriptionInstallationId, VolcengineTranscriptionProtocol.NormalizeLanguage(settings.RecordingTranscriptionSourceLanguage),
            settings.RecordingTranscriptionUseAI, settings.AgentEndpoint, settings.AgentModel, settings.AgentApiKey, settings.AgentApiProtocol, settings.RecordingTranscriptionTemplate);
    }
}

public enum RecordingTranscriptionFailure
{
    InvalidRecording, NoAudio, AudioTooLong, AudioDecode, Connection, InvalidResponse,
    ResponseTooLarge, EmptyTranscript, Timeout, Service, InvalidConfiguration
}
public sealed class RecordingTranscriptionException : Exception
{
    public RecordingTranscriptionFailure Failure { get; }
    public string? ServiceCode { get; }
    public RecordingTranscriptionException(RecordingTranscriptionFailure failure, string? serviceCode = null)
        : base($"Recording transcription failed: {failure} ({serviceCode})")
    { Failure = failure; ServiceCode = serviceCode; }
}

public sealed record RecordingUtterance(string Text, int StartMilliseconds, int EndMilliseconds, string? Speaker);
public sealed record RecordingTranscript(string Text, int DurationMilliseconds, IReadOnlyList<RecordingUtterance> Utterances);

public static class VolcengineTranscriptionProtocol
{
    public const string ResourceId = "volc.seedasr.auc";
    public const string BaseUrl = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/";
    public const int MaximumResponseBytes = 16 * 1024 * 1024;
    public static readonly string[] Languages = ["auto", "zh-CN", "en-US", "ja-JP", "id-ID", "es-MX", "pt-BR", "de-DE", "fr-FR", "ko-KR", "fil-PH", "ms-MY", "th-TH", "ar-SA", "it-IT", "bn-BD", "el-GR", "nl-NL", "ru-RU", "tr-TR", "vi-VN", "pl-PL", "ne-NP", "uk-UA", "yue-CN"];
    public static string NormalizeLanguage(string? language) => language switch
    {
        "zh" or "zh-Hans" or "zh-Hant" or "zh-TW" => "zh-CN", "en" => "en-US", "ja" => "ja-JP", "ko" => "ko-KR",
        "de" => "de-DE", "es" or "es-ES" => "es-MX", "fr" => "fr-FR", "ru" => "ru-RU", "vi" => "vi-VN",
        _ => Languages.Contains(language) ? language! : "auto"
    };

    public static HttpRequestMessage Request(string apiKey, Guid requestId, Uri? audioUrl = null, string language = "auto")
    {
        if (!VolcengineTosSigner.ValidCredential(apiKey) || !Languages.Contains(language) || requestId == Guid.Empty)
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        if (audioUrl is not null && (audioUrl.Scheme != "https" || !audioUrl.IsDefaultPort ||
            !string.IsNullOrEmpty(audioUrl.UserInfo) || !string.IsNullOrEmpty(audioUrl.Fragment) ||
            !audioUrl.Host.EndsWith(".tos-cn-beijing.volces.com", StringComparison.Ordinal) ||
            !audioUrl.Host.StartsWith("shotpaste-tmp-", StringComparison.Ordinal) ||
            !audioUrl.AbsolutePath.StartsWith("/transcription/v1/", StringComparison.Ordinal)))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        object body = new { };
        if (audioUrl is not null)
        {
            var audio = new Dictionary<string, object> { ["url"] = audioUrl.AbsoluteUri, ["format"] = "m4a" };
            if (language != "auto") audio["language"] = language;
            body = new { audio, request = new { model_name = "bigmodel", show_utterances = true,
                enable_auto_lang = language == "auto", enable_itn = true, enable_punc = true,
                enable_speaker_info = language is "auto" or "zh-CN" } };
        }
        var message = new HttpRequestMessage(HttpMethod.Post, BaseUrl + (audioUrl is null ? "query" : "submit"));
        message.Headers.Add("X-Api-Key", apiKey);
        message.Headers.Add("X-Api-Resource-Id", ResourceId);
        message.Headers.Add("X-Api-Request-Id", requestId.ToString("D"));
        message.Headers.Add("X-Api-Sequence", "-1");
        message.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        return message;
    }
    public static string Status(HttpResponseMessage response)
    {
        var code = response.Headers.TryGetValues("X-Api-Status-Code", out var codes) ? codes.SingleOrDefault() : null;
        if (response.StatusCode != HttpStatusCode.OK)
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Service, ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture));
        if (code is null || !Regex.IsMatch(code, "^[0-9]{8}$"))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidResponse);
        if (code is not ("20000000" or "20000001" or "20000002"))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Service, code);
        return code;
    }
    public static RecordingTranscript ParseTranscript(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.Length > MaximumResponseBytes) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.ResponseTooLarge);
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            var duration = root.GetProperty("audio_info").GetProperty("duration").GetInt32();
            var result = root.GetProperty("result");
            var text = result.GetProperty("text").GetString();
            if (duration <= 0 || duration > 18_000_000 || string.IsNullOrWhiteSpace(text))
                throw new RecordingTranscriptionException(RecordingTranscriptionFailure.EmptyTranscript);
            var utterances = new List<RecordingUtterance>();
            var previous = -1;
            foreach (var item in result.GetProperty("utterances").EnumerateArray())
            {
                var start = item.GetProperty("start_time").GetInt32();
                var end = item.GetProperty("end_time").GetInt32();
                var utteranceText = item.GetProperty("text").GetString();
                string? speaker = null;
                if (item.TryGetProperty("additions", out var additions) && additions.ValueKind == JsonValueKind.Object && additions.TryGetProperty("speaker", out var speakerValue))
                    speaker = speakerValue.ValueKind == JsonValueKind.Null ? null : speakerValue.GetString();
                if (string.IsNullOrWhiteSpace(utteranceText) || start < 0 || start < previous || end <= start || end > duration ||
                    (speaker is not null && !Regex.IsMatch(speaker, "^[0-9]{1,8}$")))
                    throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidResponse);
                utterances.Add(new(utteranceText, start, end, speaker)); previous = start;
            }
            if (utterances.Count == 0) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.EmptyTranscript);
            return new(text!, duration, utterances);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException or FormatException)
        { throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidResponse); }
    }
}

/// <summary>TOS V4 signing; endpoints and the application namespace are deliberately fixed.</summary>
public sealed class VolcengineTosSigner(string accessKey, string secretKey)
{
    private const string Region = "cn-beijing";
    public static bool ValidCredential(string? value) => !string.IsNullOrEmpty(value) && value.Length <= 4096 && value.All(c => c is >= (char)33 and <= (char)126);
    public static bool ValidBucket(string? bucket) => bucket is not null && Regex.IsMatch(bucket, "^shotpaste-tmp-[a-z0-9-]{3,48}$") && !bucket.EndsWith('-');
    public static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string Encode(string value, bool slash = false) => slash
        ? string.Join('/', value.Split('/').Select(Uri.EscapeDataString)) : Uri.EscapeDataString(value);
    private static string Query(IReadOnlyDictionary<string, string> query) => string.Join('&', query.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{Encode(pair.Key)}={Encode(pair.Value)}"));
    public static Uri Endpoint(string bucket, string? key = null)
    {
        if (!ValidBucket(bucket) || (key is not null && (!key.StartsWith("transcription/v1/", StringComparison.Ordinal) || key.Contains("..", StringComparison.Ordinal) || key.Contains('\\') || key.Any(char.IsControl))))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        return new Uri($"https://{bucket}.tos-{Region}.volces.com/{Encode(key ?? "", true)}");
    }
    private string Signature(string canonical, string timestamp)
    {
        if (!ValidCredential(accessKey) || !ValidCredential(secretKey)) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        static byte[] Hmac(byte[] key, string value) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(value));
        var key = Hmac(Encoding.UTF8.GetBytes(secretKey), timestamp[..8]);
        foreach (var part in new[] { Region, "tos", "request" }) key = Hmac(key, part);
        return Convert.ToHexString(Hmac(key, $"TOS4-HMAC-SHA256\n{timestamp}\n{Scope(timestamp)}\n{Hash(Encoding.UTF8.GetBytes(canonical))}")).ToLowerInvariant();
    }
    private static string Scope(string timestamp) => $"{timestamp[..8]}/{Region}/tos/request";
    private static string Timestamp(DateTimeOffset? date) => (date ?? DateTimeOffset.UtcNow).UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
    public HttpRequestMessage Request(HttpMethod method, string bucket, string? key = null,
        Dictionary<string, string>? query = null, Dictionary<string, string>? headers = null, byte[]? body = null, DateTimeOffset? date = null)
    {
        if (method != HttpMethod.Get && method != HttpMethod.Head && method != HttpMethod.Put && method != HttpMethod.Delete)
            throw new ArgumentOutOfRangeException(nameof(method));
        var uri = Endpoint(bucket, key); var timestamp = Timestamp(date); var hash = Hash(body ?? []);
        var signed = new SortedDictionary<string, string>(StringComparer.Ordinal) { ["host"] = uri.Host, ["x-tos-date"] = timestamp, ["x-tos-content-sha256"] = hash };
        foreach (var (name, value) in headers ?? [])
        {
            if ((!name.StartsWith("x-tos-", StringComparison.Ordinal) && name != "content-type") || name is "x-tos-date" or "x-tos-content-sha256" || value.Any(char.IsControl))
                throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
            signed[name] = value;
        }
        var queryString = Query(query ?? []); var signedNames = string.Join(';', signed.Keys);
        var canonical = $"{method.Method}\n{Encode('/' + (key ?? ""), true)}\n{queryString}\n{string.Concat(signed.Select(pair => $"{pair.Key}:{pair.Value}\n"))}\n{signedNames}\n{hash}";
        var message = new HttpRequestMessage(method, uri.AbsoluteUri + (queryString.Length == 0 ? "" : "?" + queryString));
        if (body is not null) message.Content = new ByteArrayContent(body);
        foreach (var (name, value) in signed)
        {
            if (name == "content-type") { message.Content ??= new ByteArrayContent([]); message.Content.Headers.TryAddWithoutValidation(name, value); }
            else message.Headers.TryAddWithoutValidation(name, value);
        }
        message.Headers.TryAddWithoutValidation("Authorization", $"TOS4-HMAC-SHA256 Credential={accessKey}/{Scope(timestamp)}, SignedHeaders={signedNames}, Signature={Signature(canonical, timestamp)}");
        return message;
    }
    public Uri SignedGet(string bucket, string key, DateTimeOffset? date = null)
    {
        var uri = Endpoint(bucket, key); var timestamp = Timestamp(date);
        var query = new Dictionary<string, string> { ["X-Tos-Algorithm"] = "TOS4-HMAC-SHA256", ["X-Tos-Credential"] = $"{accessKey}/{Scope(timestamp)}",
            ["X-Tos-Date"] = timestamp, ["X-Tos-Expires"] = "86400", ["X-Tos-SignedHeaders"] = "host" };
        var canonical = $"GET\n{Encode('/' + key, true)}\n{Query(query)}\nhost:{uri.Host}\n\nhost\nUNSIGNED-PAYLOAD";
        query["X-Tos-Signature"] = Signature(canonical, timestamp);
        return new Uri(uri.AbsoluteUri + "?" + Query(query));
    }
}

public sealed class VolcengineRecordingTranscriptionService
{
    internal const long MaximumPartMilliseconds = 4L * 60 * 60 * 1000;
    internal sealed record PreparedAudio(byte[] Data, long DurationMilliseconds);
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromMinutes(10) };
    internal static async Task<(byte[] Body, HttpResponseMessage Response)> SendAsync(HttpRequestMessage request, CancellationToken token, int limit = VolcengineTranscriptionProtocol.MaximumResponseBytes)
    {
        using (request)
        {
            var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            try
            {
                if ((int)response.StatusCode is >= 300 and < 400) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Connection);
                await using var stream = await response.Content.ReadAsStreamAsync(token);
                using var output = new MemoryStream(); var buffer = new byte[8192];
                while (true)
                {
                    var count = await stream.ReadAsync(buffer, token); if (count == 0) break;
                    if (output.Length + count > limit) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.ResponseTooLarge);
                    output.Write(buffer, 0, count);
                }
                return (output.ToArray(), response);
            }
            catch { response.Dispose(); throw; }
        }
    }
    internal static void EnsureSuccess(HttpResponseMessage response)
    {
        if (!response.IsSuccessStatusCode) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Service, ((int)response.StatusCode).ToString(CultureInfo.InvariantCulture));
    }
    public async Task InitializeStorageAsync(RecordingTranscriptionConfiguration config, CancellationToken token = default)
    {
        var signer = new VolcengineTosSigner(config.AccessKey, config.SecretKey);
        var (_, head) = await SendAsync(signer.Request(HttpMethod.Head, config.Bucket), token);
        using (head)
        {
            if (head.StatusCode == HttpStatusCode.NotFound)
            {
                var (_, created) = await SendAsync(signer.Request(HttpMethod.Put, config.Bucket,
                    headers: new() { ["x-tos-acl"] = "private", ["x-tos-storage-class"] = "STANDARD", ["x-tos-az-redundancy"] = "single-az" }), token);
                using (created) EnsureSuccess(created);
            }
            else EnsureSuccess(head);
        }
        await CheckStorageAsync(config, token);
        var (existing, lifecycle) = await SendAsync(signer.Request(HttpMethod.Get, config.Bucket, query: new() { ["lifecycle"] = "" }), token);
        var rules = new List<JsonElement>();
        using (lifecycle)
        {
            if (lifecycle.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(existing);
                rules.AddRange(doc.RootElement.GetProperty("Rules").EnumerateArray().Select(rule => rule.Clone()));
            }
            else if (lifecycle.StatusCode != HttpStatusCode.NotFound) EnsureSuccess(lifecycle);
        }
        if (rules.Any(rule => RequiredCleanupRule(rule, config.Prefix))) return;
        var id = "shotpaste-" + config.InstallationId;
        // Preserve unrelated rules; never replace a rule with this ID that belongs to another prefix.
        foreach (var rule in rules.Where(rule => rule.TryGetProperty("ID", out var value) && value.GetString() == id))
            if (!rule.TryGetProperty("Prefix", out var prefix) || prefix.GetString() != config.Prefix)
                throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        rules.RemoveAll(rule => rule.TryGetProperty("ID", out var value) && value.GetString() == id);
        rules.Add(JsonSerializer.SerializeToElement(new { ID = id, Prefix = config.Prefix, Status = "Enabled", Expiration = new { Days = 2 }, AbortIncompleteMultipartUpload = new { DaysAfterInitiation = 2 } }));
        var (_, put) = await SendAsync(signer.Request(HttpMethod.Put, config.Bucket, query: new() { ["lifecycle"] = "" },
            headers: new() { ["content-type"] = "application/json" }, body: JsonSerializer.SerializeToUtf8Bytes(new { Rules = rules })), token);
        using (put) EnsureSuccess(put);
        var (verified, get) = await SendAsync(signer.Request(HttpMethod.Get, config.Bucket, query: new() { ["lifecycle"] = "" }), token);
        using (get) EnsureSuccess(get);
        using var verify = JsonDocument.Parse(verified);
        if (!verify.RootElement.GetProperty("Rules").EnumerateArray().Any(rule => RequiredCleanupRule(rule, config.Prefix)))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
    }
    internal static bool RequiredCleanupRule(JsonElement rule, string prefix) =>
        rule.TryGetProperty("Prefix", out var p) && p.GetString() == prefix &&
        rule.TryGetProperty("Status", out var s) && s.GetString() == "Enabled" &&
        rule.TryGetProperty("Expiration", out var expiration) && expiration.TryGetProperty("Days", out var days) && days.TryGetInt32(out var count) && count == 2 &&
        rule.TryGetProperty("AbortIncompleteMultipartUpload", out var abort) && abort.TryGetProperty("DaysAfterInitiation", out var after) && after.TryGetInt32(out var pending) && pending == 2;
    internal async Task CheckStorageAsync(RecordingTranscriptionConfiguration config, CancellationToken token)
    {
        var signer = new VolcengineTosSigner(config.AccessKey, config.SecretKey);
        var (_, head) = await SendAsync(signer.Request(HttpMethod.Head, config.Bucket), token);
        using (head)
        {
            EnsureSuccess(head);
            if (!head.Headers.TryGetValues("x-tos-bucket-region", out var regions) || regions.SingleOrDefault() != "cn-beijing" ||
                !head.Headers.TryGetValues("x-tos-storage-class", out var classes) || classes.SingleOrDefault() != "STANDARD")
                throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        }
        var (aclBytes, aclResponse) = await SendAsync(signer.Request(HttpMethod.Get, config.Bucket, query: new() { ["acl"] = "" }), token);
        using (aclResponse) EnsureSuccess(aclResponse);
        using var acl = JsonDocument.Parse(aclBytes);
        var owner = acl.RootElement.GetProperty("Owner").GetProperty("ID").GetString();
        var grants = acl.RootElement.GetProperty("Grants").EnumerateArray().ToArray();
        if (string.IsNullOrEmpty(owner) || grants.Length == 0 || grants.Any(grant =>
            grant.GetProperty("Grantee").GetProperty("Type").GetString() != "CanonicalUser" ||
            grant.GetProperty("Grantee").GetProperty("ID").GetString() != owner))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        var (versionBytes, versionResponse) = await SendAsync(signer.Request(HttpMethod.Get, config.Bucket, query: new() { ["versioning"] = "" }), token);
        using (versionResponse) EnsureSuccess(versionResponse);
        using var version = JsonDocument.Parse(versionBytes);
        if (version.RootElement.TryGetProperty("Status", out var status) && status.GetString() is not ("" or "Disabled"))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
    }
    internal static Task<PreparedAudio> PrepareAudioPartAsync(string source, string temporary,
        long startMilliseconds, long requestedMilliseconds, CancellationToken token)
    {
        if (!File.Exists(source)) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
        return Task.Run(() =>
        {
            try
            {
                token.ThrowIfCancellationRequested();
                using var reader = new MediaFoundationReader(source);
                if (reader.TotalTime <= TimeSpan.Zero) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.NoAudio);
                var available = (long)Math.Round(reader.TotalTime.TotalMilliseconds) - startMilliseconds;
                if (startMilliseconds < 0 || available <= 0 || requestedMilliseconds < 0)
                    throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
                var length = Math.Min(MaximumPartMilliseconds, requestedMilliseconds == 0 ? available : Math.Min(available, requestedMilliseconds));
                if (length < available && (requestedMilliseconds == 0 || requestedMilliseconds > MaximumPartMilliseconds))
                    length = QuietBoundary(reader, startMilliseconds, length, token);
                for (var attempt = 0; attempt < 12; attempt++)
                {
                    token.ThrowIfCancellationRequested();
                    reader.CurrentTime = TimeSpan.FromMilliseconds(startMilliseconds);
                    // Windows' built-in AAC MFT supports 44.1/48 kHz, regardless of the ASR input language.
                    using (var resampler = new MediaFoundationResampler(new BoundedWaveProvider(reader, length), new WaveFormat(48000, 16, 1)) { ResamplerQuality = 60 })
                        MediaFoundationEncoder.EncodeToAac(new CancellationWaveProvider(resampler, token), temporary, 96000);
                    token.ThrowIfCancellationRequested();
                    var info = new FileInfo(temporary);
                    if (info.Length > 0 && info.Length <= 256L * 1024 * 1024)
                        return new PreparedAudio(File.ReadAllBytes(temporary), length);
                    File.Delete(temporary);
                    length /= 2;
                    if (length < 100) break;
                }
                throw new RecordingTranscriptionException(RecordingTranscriptionFailure.AudioTooLong);
            }
            catch (Exception exception) when (exception is COMException or InvalidOperationException or NotSupportedException)
            { throw new RecordingTranscriptionException(RecordingTranscriptionFailure.AudioDecode); }
            finally { try { File.Delete(temporary); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }
        }, token);
    }

    internal static Task<long> DurationMillisecondsAsync(string source, CancellationToken token) => Task.Run(() =>
    {
        token.ThrowIfCancellationRequested();
        using var reader = new MediaFoundationReader(source);
        if (reader.TotalTime <= TimeSpan.Zero) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.NoAudio);
        return (long)Math.Round(reader.TotalTime.TotalMilliseconds);
    }, token);

    private static long QuietBoundary(MediaFoundationReader reader, long start, long length, CancellationToken token)
    {
        var window = Math.Min(30_000, length / 4);
        reader.CurrentTime = TimeSpan.FromMilliseconds(start + length - window);
        using var resampler = new MediaFoundationResampler(new BoundedWaveProvider(reader, window), new WaveFormat(8000, 16, 1)) { ResamplerQuality = 60 };
        var buffer = new byte[1600];
        long elapsed = 0, boundary = length;
        var minimum = double.PositiveInfinity;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var count = resampler.Read(buffer, 0, buffer.Length);
            if (count == 0) break;
            if (count != buffer.Length) break;
            var energy = 0.0;
            for (var offset = 0; offset < count; offset += 2)
            {
                var value = (short)(buffer[offset] | buffer[offset + 1] << 8);
                energy += (double)value * value;
            }
            if (energy < minimum) { minimum = energy; boundary = length - window + elapsed + 50; }
            elapsed += 100;
        }
        return boundary;
    }

    private sealed class BoundedWaveProvider(IWaveProvider inner, long milliseconds) : IWaveProvider
    {
        private long _remaining = milliseconds * inner.WaveFormat.AverageBytesPerSecond / 1000 / inner.WaveFormat.BlockAlign * inner.WaveFormat.BlockAlign;
        public WaveFormat WaveFormat => inner.WaveFormat;
        public int Read(byte[] buffer, int offset, int count)
        {
            var read = inner.Read(buffer, offset, (int)Math.Min(count, _remaining));
            _remaining -= read;
            return read;
        }
    }
    private sealed class CancellationWaveProvider(IWaveProvider inner, CancellationToken token) : IWaveProvider
    {
        public WaveFormat WaveFormat => inner.WaveFormat;
        public int Read(byte[] buffer, int offset, int count) { token.ThrowIfCancellationRequested(); return inner.Read(buffer, offset, count); }
    }
    internal async Task UploadAsync(byte[] audio, RecordingTranscriptionConfiguration config, string key, CancellationToken token,
        Action<long, long>? progress = null)
    {
        ValidateOwnedKey(config, key);
        var signer = new VolcengineTosSigner(config.AccessKey, config.SecretKey);
        var request = signer.Request(HttpMethod.Put, config.Bucket, key,
            headers: new() { ["content-type"] = "audio/mp4", ["x-tos-forbid-overwrite"] = "true", ["x-tos-meta-sha256"] = VolcengineTosSigner.Hash(audio) }, body: audio);
        var content = new UploadContent(audio, progress);
        if (request.Content is { } previous)
        {
            foreach (var header in previous.Headers) content.Headers.TryAddWithoutValidation(header.Key, header.Value);
            previous.Dispose();
        }
        request.Content = content;
        var (_, response) = await SendAsync(request, token);
        using (response) EnsureSuccess(response);
    }
    internal sealed class UploadContent(byte[] data, Action<long, long>? progress) : HttpContent
    {
        protected override bool TryComputeLength(out long length) { length = data.LongLength; return true; }
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => WriteAsync(stream, CancellationToken.None);
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken cancellationToken) => WriteAsync(stream, cancellationToken);
        private async Task WriteAsync(Stream stream, CancellationToken token)
        {
            Report(0);
            for (var offset = 0; offset < data.Length;)
            {
                token.ThrowIfCancellationRequested();
                var count = Math.Min(64 * 1024, data.Length - offset);
                await stream.WriteAsync(data.AsMemory(offset, count), token);
                offset += count;
                Report(offset);
            }
        }
        private void Report(long sent)
        {
            try { progress?.Invoke(sent, data.LongLength); }
            catch (Exception) { /* Display updates must never fail the upload. */ }
        }
    }
    internal async Task DeleteAsync(RecordingTranscriptionConfiguration config, string key, CancellationToken token)
    {
        ValidateOwnedKey(config, key);
        var signer = new VolcengineTosSigner(config.AccessKey, config.SecretKey);
        var (_, response) = await SendAsync(signer.Request(HttpMethod.Delete, config.Bucket, key), token);
        using (response) if (response.StatusCode != HttpStatusCode.NotFound) EnsureSuccess(response);
        var (_, head) = await SendAsync(signer.Request(HttpMethod.Head, config.Bucket, key), token);
        using (head) if (head.StatusCode != HttpStatusCode.NotFound) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidResponse);
        var (_, bucket) = await SendAsync(signer.Request(HttpMethod.Head, config.Bucket), token);
        using (bucket) EnsureSuccess(bucket);
    }
    internal static void ValidateOwnedKey(RecordingTranscriptionConfiguration config, string key)
    {
        if (!key.StartsWith(config.Prefix, StringComparison.Ordinal)) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        _ = VolcengineTosSigner.Endpoint(config.Bucket, key);
    }
}
