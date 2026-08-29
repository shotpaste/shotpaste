using System.Text.Json;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingTranscriptionServiceTests
{
    [Fact]
    public void SessionUpdate_UsesOfficialClasiShapeAndOppositeTargetLanguage()
    {
        var configuration = new RecordingTranscriptionConfiguration("test-key", "test-model", "zh");
        using var document = JsonDocument.Parse(VolcengineTranscriptionProtocol.SessionUpdate(configuration));
        var root = document.RootElement;
        Assert.Equal("session.update", root.GetProperty("type").GetString());
        var session = root.GetProperty("session");
        Assert.Equal("pcm16", session.GetProperty("input_audio_format").GetString());
        var translation = session.GetProperty("input_audio_translation");
        Assert.Equal("zh", translation.GetProperty("source_language").GetString());
        Assert.Equal("en", translation.GetProperty("target_language").GetString());
    }

    [Fact]
    public void AudioCommit_UsesBoundedBase64Payload()
    {
        var pcm = Enumerable.Repeat((byte)0x2A, VolcengineTranscriptionProtocol.PcmBytesPerCommit).ToArray();
        using var document = JsonDocument.Parse(VolcengineTranscriptionProtocol.AudioCommit(pcm));
        Assert.Equal("input_audio.commit", document.RootElement.GetProperty("type").GetString());
        Assert.Equal(pcm, Convert.FromBase64String(document.RootElement.GetProperty("audio").GetString()!));
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            VolcengineTranscriptionProtocol.AudioCommit(new byte[VolcengineTranscriptionProtocol.PcmBytesPerCommit + 1]));
    }

    [Fact]
    public void Endpoint_EncodesModelAndUsesOfficialService()
    {
        var endpoint = VolcengineTranscriptionProtocol.Endpoint("model/with space");
        Assert.Equal("wss", endpoint.Scheme);
        Assert.Equal("ark-beta.cn-beijing.volces.com", endpoint.Host);
        Assert.Contains("service=clasi", endpoint.Query, StringComparison.Ordinal);
        Assert.Contains("model=model%2Fwith%20space", endpoint.Query, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Credential_IsProtectedInSerializedSettingsAndRoundTripsForCurrentUser()
    {
        var settings = new AppSettings
        {
            RecordingTranscriptionModelId = "model-id",
            RecordingTranscriptionSourceLanguage = "en"
        };
        settings.RecordingTranscriptionApiKey = "unit-test-secret";

        var json = JsonSerializer.Serialize(settings);
        Assert.DoesNotContain("unit-test-secret", json, StringComparison.Ordinal);
        var restored = Assert.IsType<AppSettings>(JsonSerializer.Deserialize<AppSettings>(json));
        Assert.Equal("unit-test-secret", restored.RecordingTranscriptionApiKey);
        Assert.Equal("model-id", restored.RecordingTranscriptionModelId);
        Assert.Equal("en", restored.RecordingTranscriptionSourceLanguage);
    }

    [Fact]
    public void Configuration_RequiresBothCredentialAndModel()
    {
        var settings = new AppSettings();
        Assert.Null(RecordingTranscriptionConfiguration.FromSettings(settings));
        settings.RecordingTranscriptionApiKey = "key";
        Assert.Null(RecordingTranscriptionConfiguration.FromSettings(settings));
        settings.RecordingTranscriptionModelId = "model";
        var configuration = Assert.IsType<RecordingTranscriptionConfiguration>(
            RecordingTranscriptionConfiguration.FromSettings(settings));
        Assert.Equal("zh", configuration.SourceLanguage);
        Assert.Equal("en", configuration.TargetLanguage);
    }
}
