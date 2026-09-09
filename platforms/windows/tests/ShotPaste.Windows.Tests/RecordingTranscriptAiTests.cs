using System.Text;
using System.Text.Json;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class RecordingTranscriptAiTests
{
    [Theory]
    [InlineData("http://localhost:11434/v1/chat/completions", true)]
    [InlineData("https://api.example.com/v1/messages", true)]
    [InlineData("http://public.example.com/v1/chat/completions", false)]
    [InlineData("https://key:secret@api.example.com/v1/messages", false)]
    [InlineData("https://api.example.com/v1/messages?key=secret", false)]
    public void Endpoint_RequiresSecureOrLoopbackExplicitConfiguration(string uri, bool accepted) =>
        Assert.Equal(accepted, RecordingTranscriptAiProcessor.ValidEndpoint(uri));
    [Fact]
    public void StructuredOutput_RejectsInventedOrMissingSourceReferences()
    {
        Assert.Throws<RecordingTranscriptionException>(() => RecordingTranscriptAiProcessor.ParseStructured("""{"qa":[],"notes":[{"text":"a","segmentIDs":["invented"]}]}""", ["source-1"], "generalNotes"));
        Assert.Throws<RecordingTranscriptionException>(() => RecordingTranscriptAiProcessor.ParseStructured("""{"qa":[],"notes":[{"text":"a","segmentIDs":[]}]}""", ["source-1"], "generalNotes"));
        var result = RecordingTranscriptAiProcessor.ParseStructured("""{"qa":[],"notes":[{"text":"a","segmentIDs":["source-1"]}]}""", ["source-1"], "generalNotes");
        Assert.Equal("source-1", result.Notes.Single().SegmentIds.Single());
    }
    [Fact]
    public void TranscriptBatches_AreBoundedAndDoNotContainMediaReferences()
    {
        var part = new RecordingTranscriptionPart
        {
            RequestId = Guid.NewGuid(), SourcePath = "C:\\private\\meeting.m4a", Role = "microphone", StartMilliseconds = 5000,
            Transcript = new RecordingTranscript("long", 1000, Enumerable.Range(0, 95).Select(index => new RecordingUtterance(new string('a', 150), index * 10, index * 10 + 5, null)).ToArray())
        };
        var batches = RecordingTranscriptAiProcessor.MakeBatches(new() { Parts = [part] });
        Assert.True(batches.Count > 1);
        Assert.All(batches, batch => Assert.InRange(batch.Length, 1, 80));
        var payload = JsonSerializer.Serialize(batches);
        Assert.DoesNotContain(part.SourcePath, payload, StringComparison.Ordinal);
        Assert.DoesNotContain("meeting.m4a", payload, StringComparison.Ordinal);
        Assert.Equal(95, batches.Sum(batch => batch.Length));
        Assert.All(batches.SelectMany(batch => batch), segment => Assert.Equal("microphone", segment.Speaker));
    }
    [Theory]
    [InlineData("openAICompatible", "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial\"}}]}")]
    [InlineData("anthropicMessages", "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}")]
    [InlineData("responses", "{\"status\":\"incomplete\",\"output\":[]}")]
    public void ProviderOutput_RejectsTruncatedResponses(string protocol, string body) =>
        Assert.Throws<RecordingTranscriptionException>(() => RecordingTranscriptAiProcessor.ParseResponse(Encoding.UTF8.GetBytes(body), protocol));
    [Theory]
    [InlineData("openAICompatible", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"ok\"}}]}")]
    [InlineData("anthropicMessages", "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}")]
    [InlineData("responses", "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}")]
    public void ProviderOutput_AcceptsCompletedText(string protocol, string body) =>
        Assert.Equal("ok", RecordingTranscriptAiProcessor.ParseResponse(Encoding.UTF8.GetBytes(body), protocol));
    [Fact]
    public async Task AnthropicRequest_UsesProtocolSpecificCredentialHeaders()
    {
        var config = new RecordingTranscriptionConfiguration("speech", "ak", "sk", "shotpaste-tmp-fixture-debug", Guid.NewGuid().ToString("N"), "auto",
            AgentEndpoint: "https://api.example.com/v1/messages", AgentModel: "fixture-model", AgentApiKey: "agent-secret", AgentApiProtocol: "anthropicMessages");
        using var request = RecordingTranscriptAiProcessor.Request("text-only", config, "instruction");
        Assert.False(request.Headers.Contains("Authorization"));
        Assert.Equal("agent-secret", request.Headers.GetValues("x-api-key").Single());
        Assert.Equal("2023-06-01", request.Headers.GetValues("anthropic-version").Single());
        Assert.DoesNotContain("speech", await request.Content!.ReadAsStringAsync(), StringComparison.Ordinal);
        Assert.DoesNotContain("agent-secret", await request.Content.ReadAsStringAsync(), StringComparison.Ordinal);
    }
}
