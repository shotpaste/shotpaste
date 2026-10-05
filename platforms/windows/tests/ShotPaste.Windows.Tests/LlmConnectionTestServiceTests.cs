using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class LlmConnectionTestServiceTests
{
    [Theory]
    [InlineData("openAICompatible", "/chat/completions", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"Connected\"}}]}")]
    [InlineData("anthropicMessages", "/messages", "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"Connected\"}]}")]
    [InlineData("responses", "/responses", "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Connected\"}]}]}")]
    public async Task TestMakesOneBoundedInferenceRequestUsingOnlyFixedText(string protocol, string suffix, string response)
    {
        var calls = 0;
        using var http = Client(async (request, token) =>
        {
            calls++;
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal("https://example.org/gateway" + suffix, request.RequestUri!.AbsoluteUri);
            var payload = await request.Content!.ReadAsStringAsync(token);
            Assert.DoesNotContain("private-recording-content", payload, StringComparison.Ordinal);
            Assert.DoesNotContain("synthetic-test-key", payload, StringComparison.Ordinal);
            using var body = JsonDocument.Parse(payload);
            var root = body.RootElement;
            Assert.Equal("fixture-model", root.GetProperty("model").GetString());
            Assert.False(root.GetProperty("stream").GetBoolean());
            if (protocol == "openAICompatible") Assert.False(root.TryGetProperty("max_tokens", out _));
            else Assert.Equal(512, root.GetProperty(protocol == "responses" ? "max_output_tokens" : "max_tokens").GetInt32());
            if (protocol == "responses")
            {
                Assert.False(root.GetProperty("store").GetBoolean());
                Assert.Equal(LlmConnectionTestService.TestText, root.GetProperty("input").GetString());
                Assert.Equal(LlmConnectionTestService.TestInstruction, root.GetProperty("instructions").GetString());
            }
            else
                Assert.Equal(LlmConnectionTestService.TestText, root.GetProperty("messages").EnumerateArray().Last().GetProperty("content").GetString());
            if (protocol == "anthropicMessages")
            {
                Assert.Equal("synthetic-test-key", request.Headers.GetValues("x-api-key").Single());
                Assert.Equal("2023-06-01", request.Headers.GetValues("anthropic-version").Single());
                Assert.False(request.Headers.Contains("Authorization"));
            }
            else Assert.Equal("Bearer synthetic-test-key", request.Headers.Authorization!.ToString());
            return Response(response);
        });
        var result = await new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(
            Configuration(protocol) with { SourceLanguage = "private-recording-content", ApiKey = "private-recording-content" });
        Assert.Equal("agent.connection-test-success", result);
        Assert.Equal(1, calls);
    }

    [Theory]
    [InlineData("http://example.org/v1", "fixture-model", "responses", "synthetic-test-key", "agent.connection-test-invalid-configuration")]
    [InlineData("https://example.org/v1?key=secret", "fixture-model", "responses", "synthetic-test-key", "agent.connection-test-invalid-configuration")]
    [InlineData("https://example.org/v1", "", "responses", "synthetic-test-key", "agent.connection-test-invalid-configuration")]
    [InlineData("https://example.org/v1", "invalid\nmodel", "responses", "synthetic-test-key", "agent.connection-test-invalid-configuration")]
    [InlineData("https://example.org/v1", "fixture-model", "unknown", "synthetic-test-key", "agent.connection-test-invalid-configuration")]
    [InlineData("https://example.org/v1", "fixture-model", "responses", "invalid\nkey", "agent.connection-test-invalid-configuration")]
    [InlineData("https://example.org/v1", "fixture-model", "responses", "", "agent.connection-test-missing-key")]
    public async Task InvalidSettingsDoNotSendAnyRequest(string endpoint, string model, string protocol, string key, string expected)
    {
        using var http = Client((_, _) => throw new InvalidOperationException("Invalid configuration must not send."));
        Assert.Equal(expected, await new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(
            Configuration(protocol) with { AgentEndpoint = endpoint, AgentModel = model, AgentApiKey = key }));
    }

    [Fact]
    public async Task LoopbackTestPreservesSupportForAnUnauthenticatedLocalModel()
    {
        using var http = Client((request, _) =>
        {
            Assert.Equal("http://localhost:1234/v1/responses", request.RequestUri!.AbsoluteUri);
            Assert.False(request.Headers.Contains("Authorization"));
            return Task.FromResult(Response("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}"));
        });
        Assert.Equal("agent.connection-test-success", await new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(
            Configuration("responses") with { AgentEndpoint = "http://localhost:1234/v1", AgentApiKey = "" }));
    }

    [Theory]
    [InlineData(401, "agent.connection-test-authentication-failed")]
    [InlineData(403, "agent.connection-test-authentication-failed")]
    [InlineData(429, "agent.connection-test-rate-limited")]
    [InlineData(408, "agent.connection-test-timeout")]
    [InlineData(504, "agent.connection-test-timeout")]
    [InlineData(302, "agent.connection-test-provider-failed")]
    [InlineData(400, "agent.connection-test-provider-failed")]
    [InlineData(503, "agent.connection-test-provider-failed")]
    public async Task HttpFailureUsesSafeMessagesWithoutReadingProviderErrorsOrRetrying(int status, string expected)
    {
        var calls = 0;
        using var http = Client((_, _) =>
        {
            calls++;
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status) { Content = new UnreadableContent() });
        });
        var result = await new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(Configuration("responses"));
        Assert.Equal(expected, result);
        Assert.Equal(1, calls);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"status\":\"incomplete\",\"output\":[]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"status\":\"incomplete\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]}]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"secret error\"}]}]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"},{\"type\":\"refusal\",\"refusal\":\"secret error\"}]}]}")]
    [InlineData("{\"status\":\"completed\",\"error\":{\"message\":\"secret error\"},\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]}]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]},{\"type\":\"function_call\",\"name\":\"call_tool\"}]}")]
    [InlineData("{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]},{\"type\":\"unknown_output\"}]}")]
    public async Task IncompleteEmptyRefusedAndInvalidResponsesCannotSucceed(string response)
    {
        using var http = Client((_, _) => Task.FromResult(Response(response)));
        Assert.Equal("agent.connection-test-invalid-response", await new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(Configuration("responses")));
    }

    [Theory]
    [InlineData("openAICompatible", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"partial\",\"refusal\":\"secret error\"}}]}")]
    [InlineData("openAICompatible", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"partial\",\"tool_calls\":[{\"type\":\"function\"}]}}]}")]
    [InlineData("anthropicMessages", "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"},{\"type\":\"tool_use\",\"name\":\"call_tool\"}]}")]
    public async Task OtherProtocolsRejectMixedTextAndRefusalsOrToolCalls(string protocol, string response)
    {
        using var http = Client((_, _) => Task.FromResult(Response(response)));
        Assert.Equal("agent.connection-test-invalid-response", await new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(Configuration(protocol)));
    }

    [Fact]
    public async Task ResponseLimitAndNetworkErrorsUseSafeMessages()
    {
        using var oversized = Client((_, _) => Task.FromResult(Response(new string('x', LlmConnectionTestService.MaximumResponseBytes + 1))));
        Assert.Equal("agent.connection-test-invalid-response", await new LlmConnectionTestService(oversized, TimeSpan.FromSeconds(15)).TestAsync(Configuration("responses")));
        using var failed = Client((_, _) => throw new HttpRequestException("https://example.org/private?key=secret"));
        Assert.Equal("agent.connection-test-network-failed", await new LlmConnectionTestService(failed, TimeSpan.FromSeconds(15)).TestAsync(Configuration("responses")));
    }

    [Fact]
    public async Task DeadlineCancelsTheOnlyRequestAndCallerCancellationCannotPublishAResult()
    {
        var calls = 0;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var http = Client(async (_, token) =>
        {
            calls++;
            started.TrySetResult();
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException();
        });
        Assert.Equal("agent.connection-test-timeout", await new LlmConnectionTestService(http, TimeSpan.FromMilliseconds(50)).TestAsync(Configuration("responses")));
        Assert.Equal(1, calls);
        using var cancellation = new CancellationTokenSource();
        var test = new LlmConnectionTestService(http, TimeSpan.FromSeconds(15)).TestAsync(Configuration("responses"), cancellation.Token);
        await started.Task;
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => test);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task DeadlineAlsoBoundsReadingTheResponseBodyAfterHeadersArrive()
    {
        var body = new BlockingReadStream();
        using var http = Client((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(body) }));
        Assert.Equal("agent.connection-test-timeout", await new LlmConnectionTestService(http, TimeSpan.FromMilliseconds(50)).TestAsync(Configuration("responses")));
        Assert.True(body.ReadStarted);
        Assert.True(body.Cancelled);
    }

    private static RecordingTranscriptionConfiguration Configuration(string protocol) =>
        new("", "", "", "", "", "auto", AgentEndpoint: "https://example.org/gateway", AgentModel: "fixture-model",
            AgentApiKey: "synthetic-test-key", AgentApiProtocol: protocol);
    private static HttpResponseMessage Response(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private static HttpClient Client(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) => new(new Handler(send));
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
    }
    private sealed class UnreadableContent : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new InvalidOperationException("Provider error bodies must not be read.");
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
    }
    private sealed class BlockingReadStream : Stream
    {
        public bool ReadStarted { get; private set; }
        public bool Cancelled { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            ReadStarted = true;
            try { await Task.Delay(Timeout.Infinite, cancellationToken); }
            catch (OperationCanceledException) { Cancelled = true; throw; }
            throw new InvalidOperationException();
        }
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
