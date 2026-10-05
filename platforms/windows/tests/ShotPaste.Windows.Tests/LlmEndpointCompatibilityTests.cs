using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class LlmEndpointCompatibilityTests
{
    [Theory]
    [InlineData("https://example.org", "openAICompatible", "https://example.org/v1/chat/completions")]
    [InlineData("https://example.org/v1/", "anthropicMessages", "https://example.org/v1/messages")]
    [InlineData("https://example.org/v1", "responses", "https://example.org/v1/responses")]
    [InlineData("https://example.org/gateway", "openAICompatible", "https://example.org/gateway/chat/completions")]
    [InlineData("https://example.org/v1/messages", "responses", "https://example.org/v1/responses")]
    [InlineData("https://example.org/gateway/v1/chat/completions", "anthropicMessages", "https://example.org/gateway/v1/messages")]
    [InlineData("http://192.168.0.2:8080/chat/v1/completions", "openAICompatible", "http://192.168.0.2:8080/chat/v1/completions")]
    [InlineData("http://172.20.0.2:8080/chat/v1/completions/", "openAICompatible", "http://172.20.0.2:8080/chat/v1/completions/")]
    public void RequestRestoresPublishedBaseRoutesAndPreservesExplicitProxyRoutes(string endpoint, string protocol, string expected)
    {
        using var request = RecordingTranscriptAiProcessor.Request("text-only", Configuration(endpoint, protocol), "translate");
        Assert.Equal(expected, request.RequestUri!.AbsoluteUri);
        if (protocol == "anthropicMessages")
        {
            Assert.Equal("synthetic-test-key", request.Headers.GetValues("x-api-key").Single());
            Assert.False(request.Headers.Contains("Authorization"));
        }
        else
        {
            Assert.Equal("Bearer synthetic-test-key", request.Headers.Authorization!.ToString());
            Assert.False(request.Headers.Contains("x-api-key"));
        }
    }

    [Theory]
    [InlineData("http://10.0.0.1/v1", true)]
    [InlineData("http://11.0.0.1/v1", false)]
    [InlineData("http://172.16.0.1/v1", true)]
    [InlineData("http://172.31.255.254/v1", true)]
    [InlineData("http://172.15.0.1/v1", false)]
    [InlineData("http://172.32.0.1/v1", false)]
    [InlineData("http://192.168.0.1/v1", true)]
    [InlineData("http://192.169.0.1/v1", false)]
    [InlineData("http://127.0.0.1:1234/v1", true)]
    [InlineData("http://localhost:1234/v1", true)]
    [InlineData("http://[::1]:1234/v1", true)]
    [InlineData("http://[::ffff:10.0.0.1]/v1", false)]
    [InlineData("http://model.internal/v1", false)]
    [InlineData("http://169.254.169.254/v1", false)]
    [InlineData("http://8.8.8.8/v1", false)]
    [InlineData("https://example.org/v1", true)]
    [InlineData("http://user:password@10.0.0.1/v1", false)]
    [InlineData("http://10.0.0.1/v1?key=synthetic", false)]
    [InlineData("http://10.0.0.1/v1#synthetic", false)]
    [InlineData("file:///tmp/model", false)]
    public void PublishedEndpointBoundaryAcceptsOnlyExplicitPrivateHttpOrHttps(string endpoint, bool accepted)
    {
        Assert.Equal(accepted, RecordingTranscriptAiProcessor.ValidEndpoint(endpoint));
        if (!accepted)
            Assert.Throws<RecordingTranscriptionException>(() => LlmEndpointResolver.Resolve(endpoint, "openAICompatible"));
    }

    [Theory]
    [InlineData("http://10.0.0.1/v1", "")]
    [InlineData("http://10.0.0.1/v1", "invalid\nkey")]
    [InlineData("http://localhost:1234/v1", "invalid\nkey")]
    public void RestoredLanSupportDoesNotRelaxCredentialValidation(string endpoint, string key)
    {
        var configuration = Configuration(endpoint, "openAICompatible") with { AgentApiKey = key };
        var error = Assert.Throws<RecordingTranscriptionException>(() =>
            RecordingTranscriptAiProcessor.Request("text-only", configuration, "translate"));
        Assert.Equal(RecordingTranscriptionFailure.InvalidConfiguration, error.Failure);
    }

    [Fact]
    public void LoopbackStillPermitsAnUnauthenticatedLocalModel()
    {
        using var request = RecordingTranscriptAiProcessor.Request("text-only",
            Configuration("http://localhost:1234/v1", "openAICompatible") with { AgentApiKey = "" }, "translate");
        Assert.Equal("http://localhost:1234/v1/chat/completions", request.RequestUri!.AbsoluteUri);
        Assert.False(request.Headers.Contains("Authorization"));
    }

    [Fact]
    public void UnknownProtocolCannotChooseAnArbitraryRequestShape() =>
        Assert.Throws<RecordingTranscriptionException>(() =>
            RecordingTranscriptAiProcessor.Request("text-only", Configuration("https://example.org/v1", "unknown"), "translate"));

    private static RecordingTranscriptionConfiguration Configuration(string endpoint, string protocol) =>
        new("", "", "", "", "", "auto", AgentEndpoint: endpoint, AgentModel: "local-model",
            AgentApiKey: "synthetic-test-key", AgentApiProtocol: protocol);
}
