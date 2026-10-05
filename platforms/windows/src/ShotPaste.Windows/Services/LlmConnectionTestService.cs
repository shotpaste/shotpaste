using System.Net;
using System.Net.Http;
using System.Text.Json;

namespace ShotPaste.Windows.Services;

/// <summary>Tests model inference with fixed text only; credentials remain in request headers.</summary>
public sealed class LlmConnectionTestService
{
    internal const string TestText = "Reply with OK only.";
    internal const string TestInstruction = "This is a connection test. Return a short text response.";
    internal const int MaximumResponseBytes = 65_536;
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
    {
        Timeout = Timeout.InfiniteTimeSpan
    };
    private readonly HttpClient _http;
    private readonly TimeSpan _timeout;

    public LlmConnectionTestService() : this(Http, TimeSpan.FromSeconds(15)) { }
    internal LlmConnectionTestService(HttpClient http, TimeSpan timeout) { _http = http; _timeout = timeout; }

    // Return known localization keys only. Provider bodies, output, URLs and exceptions are never shown or logged.
    public async Task<string> TestAsync(RecordingTranscriptionConfiguration configuration, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        if (!LlmEndpointResolver.IsValid(configuration.AgentEndpoint) ||
            configuration.AgentApiProtocol is not ("openAICompatible" or "anthropicMessages" or "responses") ||
            string.IsNullOrWhiteSpace(configuration.AgentModel) || configuration.AgentModel.Length > 512 ||
            configuration.AgentModel.Any(char.IsControl)) return "agent.connection-test-invalid-configuration";
        if (!new Uri(configuration.AgentEndpoint).IsLoopback && string.IsNullOrWhiteSpace(configuration.AgentApiKey))
            return "agent.connection-test-missing-key";
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(_timeout);
        try
        {
            // Chat-compatible reasoning models may reject max_tokens; keep this fixed-text probe compatible.
            using var request = RecordingTranscriptAiProcessor.Request(TestText, configuration, TestInstruction,
                maximumOutputTokens: configuration.AgentApiProtocol == "openAICompatible" ? null : 512);
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            deadline.Token.ThrowIfCancellationRequested();
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                return "agent.connection-test-authentication-failed";
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
                return "agent.connection-test-rate-limited";
            if (response.StatusCode is HttpStatusCode.RequestTimeout or HttpStatusCode.GatewayTimeout)
                return "agent.connection-test-timeout";
            if (!response.IsSuccessStatusCode) return "agent.connection-test-provider-failed";
            await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
            using var body = new MemoryStream();
            var buffer = new byte[8192];
            while (true)
            {
                var count = await stream.ReadAsync(buffer, deadline.Token);
                if (count == 0) break;
                if (body.Length + count > MaximumResponseBytes) return "agent.connection-test-invalid-response";
                body.Write(buffer, 0, count);
            }
            var bytes = body.ToArray();
            ValidateTextOnlyResponse(bytes, configuration.AgentApiProtocol);
            _ = RecordingTranscriptAiProcessor.ParseResponse(bytes, configuration.AgentApiProtocol);
            deadline.Token.ThrowIfCancellationRequested();
            return "agent.connection-test-success";
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { return "agent.connection-test-timeout"; }
        catch (RecordingTranscriptionException exception)
        {
            return exception.Failure == RecordingTranscriptionFailure.InvalidConfiguration
                ? "agent.connection-test-invalid-configuration" : "agent.connection-test-invalid-response";
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException)
        { return "agent.connection-test-network-failed"; }
    }

    private static void ValidateTextOnlyResponse(ReadOnlyMemory<byte> bytes, string protocol)
    {
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            if (root.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null) throw new JsonException();
            switch (protocol)
            {
                case "openAICompatible":
                    var message = root.GetProperty("choices")[0].GetProperty("message");
                    foreach (var name in new[] { "tool_calls", "function_call" })
                    {
                        if (message.TryGetProperty(name, out var call) && call.ValueKind != JsonValueKind.Null &&
                            (call.ValueKind != JsonValueKind.Array || call.GetArrayLength() > 0)) throw new JsonException();
                    }
                    break;
                case "anthropicMessages":
                    if (root.GetProperty("content").EnumerateArray().Any(block =>
                        block.GetProperty("type").GetString() is not ("text" or "thinking" or "redacted_thinking"))) throw new JsonException();
                    break;
                case "responses":
                    foreach (var item in root.GetProperty("output").EnumerateArray())
                    {
                        var type = item.GetProperty("type").GetString();
                        if (type is not ("message" or "reasoning")) throw new JsonException();
                        if (type == "message" && item.GetProperty("content").EnumerateArray().Any(block =>
                            block.GetProperty("type").GetString() != "output_text")) throw new JsonException();
                    }
                    break;
            }
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or KeyNotFoundException or IndexOutOfRangeException)
        { throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidResponse); }
    }
}
