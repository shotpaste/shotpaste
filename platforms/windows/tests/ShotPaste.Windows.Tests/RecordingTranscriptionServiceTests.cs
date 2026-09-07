using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingTranscriptionServiceTests
{
    private static readonly DateTimeOffset Date = DateTimeOffset.Parse("2026-09-06T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture);
    private const string Bucket = "shotpaste-tmp-fixture-debug";
    private const string Key = "transcription/v1/test/part.m4a";

    [Fact]
    public void TosHeaderSignature_MatchesOfficialSdk292Fixture()
    {
        var signer = new VolcengineTosSigner("fixture-ak", "fixture-sk");
        using var request = signer.Request(HttpMethod.Put, Bucket, Key,
            headers: new() { ["content-type"] = "audio/mp4" }, body: Encoding.UTF8.GetBytes("hello"), date: Date);
        Assert.Equal("TOS4-HMAC-SHA256 Credential=fixture-ak/20260906/cn-beijing/tos/request, SignedHeaders=content-type;host;x-tos-content-sha256;x-tos-date, Signature=1954d66ac2961a650d13906cd5cc45f53b8a3591dcabed6b4ddbebc6984f7a14", request.Headers.GetValues("Authorization").Single());
    }
    [Fact]
    public void TosPresignedGet_MatchesOfficialSdk292Fixture()
    {
        var signed = new VolcengineTosSigner("fixture-ak", "fixture-sk").SignedGet(Bucket, Key, Date);
        Assert.Contains("X-Tos-Signature=1d7f41ad365d20f99329cab5de0d385cb6f2f47ad644a0354639c914a100ad20", signed.Query, StringComparison.Ordinal);
        Assert.Contains("X-Tos-Expires=86400", signed.Query, StringComparison.Ordinal);
        Assert.Contains("X-Tos-SignedHeaders=host", signed.Query, StringComparison.Ordinal);
    }
    [Theory]
    [InlineData("other-business-bucket", "transcription/v1/test/file.m4a")]
    [InlineData(Bucket, "transcription/v1/../file.m4a")]
    [InlineData(Bucket, "transcription/v1/test\\file.m4a")]
    [InlineData(Bucket, "secret/file.m4a")]
    public void Signer_RejectsUnownedResources(string bucket, string key) =>
        Assert.Throws<RecordingTranscriptionException>(() => VolcengineTosSigner.Endpoint(bucket, key));

    [Fact]
    public async Task Asr2Submit_UsesFixedResourceAndUrlShape()
    {
        var signed = new VolcengineTosSigner("fixture-ak", "fixture-sk").SignedGet(Bucket, Key, Date);
        var id = Guid.NewGuid();
        using var request = VolcengineTranscriptionProtocol.Request("fixture-key", id, signed);
        Assert.Equal("https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit", request.RequestUri!.AbsoluteUri);
        Assert.Equal("volc.seedasr.auc", request.Headers.GetValues("X-Api-Resource-Id").Single());
        Assert.Equal(id.ToString("D"), request.Headers.GetValues("X-Api-Request-Id").Single());
        using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
        Assert.Equal(signed.AbsoluteUri, body.RootElement.GetProperty("audio").GetProperty("url").GetString());
        Assert.Equal("m4a", body.RootElement.GetProperty("audio").GetProperty("format").GetString());
        Assert.False(body.RootElement.GetProperty("audio").TryGetProperty("language", out _));
        Assert.True(body.RootElement.GetProperty("request").GetProperty("enable_auto_lang").GetBoolean());
        using var query = VolcengineTranscriptionProtocol.Request("fixture-key", id);
        Assert.EndsWith("/query", query.RequestUri!.AbsolutePath, StringComparison.Ordinal);
        Assert.Equal("{}", await query.Content!.ReadAsStringAsync());
    }
    [Theory]
    [InlineData("https://example.com/transcription/v1/test.m4a")]
    [InlineData("http://shotpaste-tmp-fixture-debug.tos-cn-beijing.volces.com/transcription/v1/test.m4a")]
    [InlineData("https://user:pass@shotpaste-tmp-fixture-debug.tos-cn-beijing.volces.com/transcription/v1/test.m4a")]
    public void Asr2Submit_RejectsArbitraryAudioHost(string url) =>
        Assert.Throws<RecordingTranscriptionException>(() => VolcengineTranscriptionProtocol.Request("key", Guid.NewGuid(), new Uri(url)));

    [Theory]
    [InlineData(-1, 100)] [InlineData(100, 50)] [InlineData(0, 2000)]
    public void Transcript_RejectsInvalidTimeline(int start, int end)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { audio_info = new { duration = 1000 }, result = new { text = "test", utterances = new[] { new { text = "test", start_time = start, end_time = end } } } });
        Assert.Throws<RecordingTranscriptionException>(() => VolcengineTranscriptionProtocol.ParseTranscript(bytes));
    }
    [Fact]
    public void Transcript_PreservesTimedSpeakerAttribution()
    {
        var bytes = Encoding.UTF8.GetBytes("""{"audio_info":{"duration":1000},"result":{"text":"hello","utterances":[{"text":"hello","start_time":100,"end_time":900,"additions":{"speaker":"1"}}]}}""");
        var result = VolcengineTranscriptionProtocol.ParseTranscript(bytes);
        Assert.Equal("hello", result.Text); Assert.Equal("1", result.Utterances.Single().Speaker);
        Assert.Equal(100, result.Utterances.Single().StartMilliseconds);
    }
    [Fact]
    public void ProviderError_DoesNotExposeResponseBody()
    {
        using var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("secret-server-message") };
        response.Headers.Add("X-Api-Status-Code", "45000030");
        var error = Assert.Throws<RecordingTranscriptionException>(() => VolcengineTranscriptionProtocol.Status(response));
        Assert.DoesNotContain("secret-server-message", error.Message, StringComparison.Ordinal);
        Assert.Equal("45000030", error.ServiceCode);
    }
    [Fact]
    public void CleanupPolicy_RequiresBothPoliciesAndExactPrefix()
    {
        using var rule = JsonDocument.Parse("""{"Prefix":"transcription/v1/a/","Status":"Enabled","Expiration":{"Days":2},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":2}}""");
        Assert.True(VolcengineRecordingTranscriptionService.RequiredCleanupRule(rule.RootElement, "transcription/v1/a/"));
        Assert.False(VolcengineRecordingTranscriptionService.RequiredCleanupRule(rule.RootElement, "transcription/v1/b/"));
    }
    [Fact]
    public void Credentials_RoundTripUnderCurrentWindowsUserWithoutPlaintextSettings()
    {
        var settings = new AppSettings { RecordingTranscriptionApiKey = "fixture-speech-secret", RecordingTranscriptionAccessKey = "fixture-access-secret", RecordingTranscriptionSecretKey = "fixture-storage-secret", AgentApiKey = "fixture-agent-secret" };
        var json = JsonSerializer.Serialize(settings);
        foreach (var secret in new[] { "fixture-speech-secret", "fixture-access-secret", "fixture-storage-secret", "fixture-agent-secret" }) Assert.DoesNotContain(secret, json, StringComparison.Ordinal);
        var restored = JsonSerializer.Deserialize<AppSettings>(json)!;
        Assert.Equal(settings.RecordingTranscriptionApiKey, restored.RecordingTranscriptionApiKey);
        Assert.Equal(settings.RecordingTranscriptionSecretKey, restored.RecordingTranscriptionSecretKey);
        Assert.False(restored.RecordingTranscriptionEnabled);
        Assert.False(restored.RecordingTranscriptionCloudVerified);
        Assert.Null(RecordingTranscriptionConfiguration.FromSettings(restored));
    }
}
