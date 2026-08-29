using System.Net.Http;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using NAudio.Wave;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public sealed record RecordingTranscriptionConfiguration(
    string ApiKey,
    string ModelId,
    string SourceLanguage)
{
    public string TargetLanguage => SourceLanguage == "en" ? "zh" : "en";

    public static RecordingTranscriptionConfiguration? FromSettings(AppSettings settings)
    {
        var apiKey = settings.RecordingTranscriptionApiKey.Trim();
        var modelId = (settings.RecordingTranscriptionModelId ?? string.Empty).Trim();
        var sourceLanguage = settings.RecordingTranscriptionSourceLanguage is "en" ? "en" : "zh";
        if (string.IsNullOrEmpty(apiKey) || string.IsNullOrEmpty(modelId) ||
            apiKey.Length > 4_096 || modelId.Length > 512 ||
            apiKey.Contains('\r') || apiKey.Contains('\n') ||
            modelId.Contains('\r') || modelId.Contains('\n'))
            return null;
        return new RecordingTranscriptionConfiguration(apiKey, modelId, sourceLanguage);
    }
}

public enum RecordingTranscriptionFailure
{
    InvalidRecording,
    NoAudio,
    AudioTooLong,
    AudioDecode,
    Connection,
    InvalidResponse,
    ResponseTooLarge,
    EmptyTranscript,
    Timeout,
    Service
}

public sealed class RecordingTranscriptionException : Exception
{
    public RecordingTranscriptionFailure Failure { get; }
    public string? ServiceCode { get; }

    public RecordingTranscriptionException(
        RecordingTranscriptionFailure failure,
        string message,
        string? serviceCode = null,
        Exception? innerException = null) : base(message, innerException)
    {
        Failure = failure;
        ServiceCode = serviceCode;
    }
}

public static class VolcengineTranscriptionProtocol
{
    public const string BaseUrl = "wss://ark-beta.cn-beijing.volces.com/api/v3/realtime";
    public const int PcmBytesPerCommit = 3_200;
    public const int MaximumMessageBytes = 1_048_576;
    public const int MaximumTranscriptCharacters = 16_000_000;
    public static readonly TimeSpan CommitInterval = TimeSpan.FromMilliseconds(100);

    public static Uri Endpoint(string modelId) => new(
        $"{BaseUrl}?service=clasi&model={Uri.EscapeDataString(modelId)}");

    public static string SessionUpdate(RecordingTranscriptionConfiguration configuration) =>
        JsonSerializer.Serialize(new
        {
            event_id = EventId(),
            type = "session.update",
            session = new
            {
                input_audio_format = "pcm16",
                modalities = new[] { "text" },
                speaker_detection = new { enable_speaker_change_detection = true },
                input_audio_translation = new
                {
                    source_language = configuration.SourceLanguage,
                    target_language = configuration.TargetLanguage
                }
            }
        });

    public static string AudioCommit(ReadOnlySpan<byte> pcm)
    {
        if (pcm.IsEmpty || pcm.Length > PcmBytesPerCommit)
            throw new ArgumentOutOfRangeException(nameof(pcm));
        return JsonSerializer.Serialize(new
        {
            event_id = EventId(),
            type = "input_audio.commit",
            audio = Convert.ToBase64String(pcm)
        });
    }

    public static string AudioDone() => JsonSerializer.Serialize(new
    {
        event_id = EventId(),
        type = "input_audio.done"
    });

    private static string EventId() => "event_" + Guid.NewGuid().ToString("N");
}

public sealed class VolcengineRecordingTranscriptionService
{
    public async Task<string> TranscribeAsync(
        string recordingPath,
        RecordingTranscriptionConfiguration configuration,
        CancellationToken cancellationToken = default)
    {
        var duration = InspectAudio(recordingPath);
        using var socket = new ClientWebSocket();
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        socket.Options.SetRequestHeader("Authorization", "Bearer " + configuration.ApiKey);

        using (var connectionCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            connectionCts.CancelAfter(TimeSpan.FromSeconds(30));
            try
            {
                await socket.ConnectAsync(
                    VolcengineTranscriptionProtocol.Endpoint(configuration.ModelId),
                    connectionCts.Token);
                await SendTextAsync(
                    socket,
                    VolcengineTranscriptionProtocol.SessionUpdate(configuration),
                    connectionCts.Token);
                await WaitForSessionUpdateAsync(socket, connectionCts.Token);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw Failure(RecordingTranscriptionFailure.Timeout, "连接火山引擎同声传译超时。");
            }
            catch (RecordingTranscriptionException) { throw; }
            catch (Exception exception) when (exception is WebSocketException or HttpRequestException or IOException)
            {
                throw Failure(RecordingTranscriptionFailure.Connection, "无法连接火山引擎同声传译。", exception);
            }
        }

        using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        sessionCts.CancelAfter(TimeSpan.FromSeconds(Math.Max(90, duration.TotalSeconds + 90)));
        var sendTask = SendAudioAsync(recordingPath, socket, sessionCts.Token);
        var receiveTask = ReceiveTranscriptAsync(socket, sessionCts.Token);
        try
        {
            var first = await Task.WhenAny(sendTask, receiveTask);
            if (ReferenceEquals(first, sendTask) && sendTask.IsFaulted)
                await sendTask;
            var transcript = await receiveTask;
            await sendTask;
            if (socket.State == WebSocketState.Open)
                await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
            return transcript;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw Failure(RecordingTranscriptionFailure.Timeout, "文字稿生成超时。");
        }
        catch (RecordingTranscriptionException) { throw; }
        catch (Exception exception) when (exception is WebSocketException or HttpRequestException or IOException)
        {
            throw Failure(RecordingTranscriptionFailure.Connection, "火山引擎同声传译连接已中断。", exception);
        }
        finally
        {
            sessionCts.Cancel();
            if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                socket.Abort();
            await ObserveCompletionAsync(sendTask);
            await ObserveCompletionAsync(receiveTask);
        }
    }

    private static TimeSpan InspectAudio(string recordingPath)
    {
        if (string.IsNullOrWhiteSpace(recordingPath) || !File.Exists(recordingPath))
            throw Failure(RecordingTranscriptionFailure.InvalidRecording, "无法读取已完成的录屏文件。");
        try
        {
            using var reader = new MediaFoundationReader(recordingPath);
            var duration = reader.TotalTime;
            if (duration <= TimeSpan.Zero)
                throw Failure(RecordingTranscriptionFailure.NoAudio, "录屏中没有可读取的音轨。");
            if (duration > TimeSpan.FromHours(2))
                throw Failure(RecordingTranscriptionFailure.AudioTooLong, "火山引擎同声传译仅支持两小时以内的录音。");
            return duration;
        }
        catch (RecordingTranscriptionException) { throw; }
        catch (Exception exception) when (exception is InvalidOperationException or NotSupportedException or COMException)
        {
            throw Failure(RecordingTranscriptionFailure.NoAudio, "录屏中没有可读取的音轨。", exception);
        }
    }

    private static async Task WaitForSessionUpdateAsync(
        ClientWebSocket socket,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            using var message = await ReceiveJsonAsync(socket, cancellationToken);
            var root = message.RootElement;
            var type = ReadRequiredString(root, "type");
            if (type == "session.updated") return;
            if (type == "error") throw ServiceFailure(root);
        }
    }

    private static async Task<string> ReceiveTranscriptAsync(
        ClientWebSocket socket,
        CancellationToken cancellationToken)
    {
        var transcript = new StringBuilder();
        while (true)
        {
            using var message = await ReceiveJsonAsync(socket, cancellationToken);
            var root = message.RootElement;
            var type = ReadRequiredString(root, "type");
            switch (type)
            {
                case "response.input_audio_transcription.delta":
                    if (!root.TryGetProperty("delta", out var deltaElement) ||
                        deltaElement.ValueKind != JsonValueKind.String) continue;
                    var delta = deltaElement.GetString();
                    if (string.IsNullOrEmpty(delta)) continue;
                    if (root.TryGetProperty("speaker_change", out var speakerElement) &&
                        speakerElement.ValueKind is JsonValueKind.True && transcript.Length > 0 &&
                        transcript[^1] != '\n')
                        transcript.AppendLine();
                    if (transcript.Length > VolcengineTranscriptionProtocol.MaximumTranscriptCharacters - delta.Length)
                        throw Failure(RecordingTranscriptionFailure.ResponseTooLarge, "返回的文字稿超过安全大小限制。");
                    transcript.Append(delta);
                    break;
                case "response.done":
                    var result = transcript.ToString().Trim();
                    if (string.IsNullOrEmpty(result))
                        throw Failure(RecordingTranscriptionFailure.EmptyTranscript, "录屏中没有识别到语音。");
                    return result;
                case "error":
                    throw ServiceFailure(root);
            }
        }
    }

    private static async Task SendAudioAsync(
        string recordingPath,
        ClientWebSocket socket,
        CancellationToken cancellationToken)
    {
        try
        {
            using var reader = new MediaFoundationReader(recordingPath);
            using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16_000, 16, 1))
            {
                ResamplerQuality = 60
            };
            var buffer = new byte[VolcengineTranscriptionProtocol.PcmBytesPerCommit];
            var sentAnyAudio = false;
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var count = FillBuffer(resampler, buffer);
                if (count == 0) break;
                await SendTextAsync(
                    socket,
                    VolcengineTranscriptionProtocol.AudioCommit(buffer.AsSpan(0, count)),
                    cancellationToken);
                sentAnyAudio = true;
                await Task.Delay(VolcengineTranscriptionProtocol.CommitInterval, cancellationToken);
            }
            if (!sentAnyAudio)
                throw Failure(RecordingTranscriptionFailure.NoAudio, "录屏中没有可读取的音轨。");
            await SendTextAsync(socket, VolcengineTranscriptionProtocol.AudioDone(), cancellationToken);
        }
        catch (RecordingTranscriptionException) { throw; }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is InvalidOperationException or NotSupportedException or COMException)
        {
            throw Failure(RecordingTranscriptionFailure.AudioDecode, "无法解码录屏音轨。", exception);
        }
    }

    private static int FillBuffer(IWaveProvider provider, byte[] buffer)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var read = provider.Read(buffer, total, buffer.Length - total);
            if (read == 0) break;
            total += read;
        }
        return total;
    }

    private static async Task SendTextAsync(
        ClientWebSocket socket,
        string text,
        CancellationToken cancellationToken)
    {
        var data = Encoding.UTF8.GetBytes(text);
        await socket.SendAsync(
            new ArraySegment<byte>(data),
            WebSocketMessageType.Text,
            true,
            cancellationToken);
    }

    private static async Task<JsonDocument> ReceiveJsonAsync(
        ClientWebSocket socket,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[8_192];
        using var stream = new MemoryStream();
        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close)
                throw Failure(RecordingTranscriptionFailure.Connection, "火山引擎同声传译连接已关闭。");
            if (result.MessageType != WebSocketMessageType.Text)
                throw Failure(RecordingTranscriptionFailure.InvalidResponse, "火山引擎返回了无效的文字稿响应。");
            if (stream.Length > VolcengineTranscriptionProtocol.MaximumMessageBytes - result.Count)
                throw Failure(RecordingTranscriptionFailure.ResponseTooLarge, "火山引擎返回的数据超过安全大小限制。");
            stream.Write(buffer, 0, result.Count);
            if (result.EndOfMessage) break;
        }
        try
        {
            return JsonDocument.Parse(stream.GetBuffer().AsMemory(0, checked((int)stream.Length)));
        }
        catch (JsonException exception)
        {
            throw Failure(RecordingTranscriptionFailure.InvalidResponse, "火山引擎返回了无效的文字稿响应。", exception);
        }
    }

    private static string ReadRequiredString(JsonElement root, string propertyName)
    {
        if (root.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String &&
            property.GetString() is { Length: > 0 } value)
            return value;
        throw Failure(RecordingTranscriptionFailure.InvalidResponse, "火山引擎返回了无效的文字稿响应。");
    }

    private static RecordingTranscriptionException ServiceFailure(JsonElement root)
    {
        var code = "UnknownError";
        var message = "服务返回错误。";
        if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
        {
            if (error.TryGetProperty("code", out var codeElement) && codeElement.ValueKind == JsonValueKind.String)
                code = Sanitize(codeElement.GetString(), 128, code);
            if (error.TryGetProperty("message", out var messageElement) && messageElement.ValueKind == JsonValueKind.String)
                message = Sanitize(messageElement.GetString(), 1_024, message);
        }
        return new RecordingTranscriptionException(
            RecordingTranscriptionFailure.Service,
            $"火山引擎错误 ({code})：{message}",
            code);
    }

    private static string Sanitize(string? value, int maximumLength, string fallback)
    {
        var normalized = (value ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ').Trim();
        if (string.IsNullOrEmpty(normalized)) return fallback;
        return normalized.Length <= maximumLength ? normalized : normalized[..maximumLength];
    }

    private static RecordingTranscriptionException Failure(
        RecordingTranscriptionFailure failure,
        string message,
        Exception? innerException = null) => new(failure, message, innerException: innerException);

    private static async Task ObserveCompletionAsync(Task task)
    {
        try { await task; }
        catch (Exception) { }
    }
}
