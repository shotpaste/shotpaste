using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace ShotPaste.Windows.Services;

internal sealed class ShotPasteMcpServer(ShotPasteMcpProtocol protocol) : IDisposable
{
    private const int MaximumHeaderBytes = 16 * 1024;
    private const int MaximumBodyBytes = 1024 * 1024;
    private TcpListener? _listener;
    private CancellationTokenSource? _cancellation;
    private Task? _acceptLoop;
    private int _port;
    private string _token = string.Empty;

    public bool IsRunning => _listener is not null;
    public string? LastError { get; private set; }
    public string Endpoint => $"http://127.0.0.1:{_port}/mcp";

    public void Apply(bool enabled, int port, string token)
    {
        port = Math.Clamp(port, 1024, 65535);
        token = token.Trim();
        if (!enabled)
        {
            Stop();
            return;
        }
        if (IsRunning && _port == port && FixedEquals(_token, token)) return;
        Stop();
        if (string.IsNullOrWhiteSpace(token))
        {
            LastError = "MCP authentication token is missing.";
            return;
        }
        try
        {
            _port = port;
            _token = token;
            _cancellation = new CancellationTokenSource();
            _listener = new TcpListener(IPAddress.Loopback, port);
            _listener.Start(16);
            LastError = null;
            _acceptLoop = AcceptLoopAsync(_listener, _cancellation.Token);
        }
        catch (SocketException exception)
        {
            LastError = exception.Message;
            Stop();
        }
    }

    public void Stop()
    {
        var cancellation = _cancellation;
        var listener = _listener;
        _cancellation = null;
        _listener = null;
        _acceptLoop = null;
        try { cancellation?.Cancel(); } catch (ObjectDisposedException) { }
        try { listener?.Stop(); } catch (SocketException) { }
        cancellation?.Dispose();
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(cancellationToken); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) when (cancellationToken.IsCancellationRequested) { return; }
            _ = HandleClientSafelyAsync(client, cancellationToken);
        }
    }

    private async Task HandleClientSafelyAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
            client.NoDelay = true;
            try { await HandleClientAsync(client.GetStream(), cancellationToken); }
            catch (Exception exception) when (exception is IOException or SocketException or OperationCanceledException) { }
        }
    }

    private async Task HandleClientAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var request = await ReadRequestAsync(stream, cancellationToken);
        if (request.Error is { } error)
        {
            await WriteJsonErrorAsync(stream, error.Status, error.Message, cancellationToken);
            return;
        }

        if (!request.Method.Equals("POST", StringComparison.OrdinalIgnoreCase))
        {
            await WriteJsonErrorAsync(stream, 405, "This MCP server accepts POST requests only.", cancellationToken,
                ("Allow", "POST"));
            return;
        }
        if (!request.Path.Equals("/mcp", StringComparison.Ordinal))
        {
            await WriteJsonErrorAsync(stream, 404, "MCP endpoint not found.", cancellationToken);
            return;
        }
        if (!ValidHost(request.Headers.GetValueOrDefault("Host")))
        {
            await WriteJsonErrorAsync(stream, 421, "Invalid Host header.", cancellationToken);
            return;
        }
        if (!ValidOrigin(request.Headers.GetValueOrDefault("Origin")))
        {
            await WriteJsonErrorAsync(stream, 403, "Browser origins are not allowed for this local endpoint.", cancellationToken);
            return;
        }
        var authorization = request.Headers.GetValueOrDefault("Authorization") ?? string.Empty;
        if (!authorization.StartsWith("Bearer ", StringComparison.Ordinal) ||
            !FixedEquals(authorization[7..], _token))
        {
            await WriteJsonErrorAsync(stream, 401, "Authentication required.", cancellationToken,
                ("WWW-Authenticate", "Bearer realm=\"ShotPaste MCP\""));
            return;
        }
        if (request.Headers.TryGetValue("MCP-Protocol-Version", out var protocolVersion) &&
            protocolVersion is not (ShotPasteMcpProtocol.LatestProtocolVersion or "2025-06-18" or "2025-03-26"))
        {
            await WriteJsonErrorAsync(stream, 400, "Unsupported MCP-Protocol-Version.", cancellationToken);
            return;
        }

        var response = await protocol.HandleAsync(Encoding.UTF8.GetString(request.Body), cancellationToken);
        if (response is null)
        {
            await WriteResponseAsync(stream, 202, "Accepted", null, cancellationToken);
            return;
        }
        await WriteResponseAsync(stream, 200, "OK", response, cancellationToken,
            ("MCP-Protocol-Version", ShotPasteMcpProtocol.LatestProtocolVersion));
    }

    private bool ValidHost(string? host) => host is not null &&
        (host.Equals($"127.0.0.1:{_port}", StringComparison.OrdinalIgnoreCase) ||
         host.Equals($"localhost:{_port}", StringComparison.OrdinalIgnoreCase));

    private bool ValidOrigin(string? origin) => string.IsNullOrWhiteSpace(origin) ||
        origin.Equals($"http://127.0.0.1:{_port}", StringComparison.OrdinalIgnoreCase) ||
        origin.Equals($"http://localhost:{_port}", StringComparison.OrdinalIgnoreCase);

    private static async Task<HttpRequestData> ReadRequestAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[4096];
        var headerEnd = -1;
        while (headerEnd < 0)
        {
            var read = await stream.ReadAsync(chunk, cancellationToken);
            if (read == 0) return HttpRequestData.Failed(400, "Incomplete HTTP request.");
            buffer.Write(chunk, 0, read);
            if (buffer.Length > MaximumHeaderBytes) return HttpRequestData.Failed(431, "Request headers are too large.");
            headerEnd = FindHeaderEnd(buffer.GetBuffer(), (int)buffer.Length);
        }

        var received = buffer.ToArray();
        var headerText = Encoding.ASCII.GetString(received, 0, headerEnd);
        var lines = headerText.Split("\r\n", StringSplitOptions.None);
        var requestLine = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (requestLine.Length != 3 || !requestLine[2].Equals("HTTP/1.1", StringComparison.OrdinalIgnoreCase))
            return HttpRequestData.Failed(400, "Invalid HTTP request line.");

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var separator = line.IndexOf(':');
            if (separator <= 0) return HttpRequestData.Failed(400, "Invalid HTTP header.");
            var name = line[..separator].Trim();
            if (headers.ContainsKey(name)) return HttpRequestData.Failed(400, "Duplicate HTTP header.");
            headers[name] = line[(separator + 1)..].Trim();
        }
        if (!headers.TryGetValue("Content-Length", out var rawLength) || !int.TryParse(rawLength, out var contentLength) || contentLength < 0)
            return HttpRequestData.Failed(411, "Content-Length is required.");
        if (contentLength > MaximumBodyBytes) return HttpRequestData.Failed(413, "MCP request body is too large.");

        var bodyOffset = headerEnd + 4;
        var body = new byte[contentLength];
        var alreadyRead = Math.Min(contentLength, received.Length - bodyOffset);
        if (alreadyRead > 0) Array.Copy(received, bodyOffset, body, 0, alreadyRead);
        var offset = alreadyRead;
        while (offset < contentLength)
        {
            var read = await stream.ReadAsync(body.AsMemory(offset, contentLength - offset), cancellationToken);
            if (read == 0) return HttpRequestData.Failed(400, "Incomplete HTTP request body.");
            offset += read;
        }
        return new HttpRequestData(requestLine[0], requestLine[1], headers, body, null);
    }

    private static int FindHeaderEnd(byte[] bytes, int count)
    {
        for (var index = 3; index < count; index++)
            if (bytes[index - 3] == '\r' && bytes[index - 2] == '\n' && bytes[index - 1] == '\r' && bytes[index] == '\n')
                return index - 3;
        return -1;
    }

    private static Task WriteJsonErrorAsync(
        NetworkStream stream,
        int status,
        string message,
        CancellationToken cancellationToken,
        params (string Name, string Value)[] headers) =>
        WriteResponseAsync(stream, status, Reason(status),
            System.Text.Json.JsonSerializer.Serialize(new { error = message }), cancellationToken, headers);

    private static async Task WriteResponseAsync(
        NetworkStream stream,
        int status,
        string reason,
        string? json,
        CancellationToken cancellationToken,
        params (string Name, string Value)[] extraHeaders)
    {
        var body = json is null ? [] : Encoding.UTF8.GetBytes(json);
        var header = new StringBuilder()
            .Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n")
            .Append("Connection: close\r\n")
            .Append("Cache-Control: no-store\r\n")
            .Append("X-Content-Type-Options: nosniff\r\n")
            .Append("Content-Length: ").Append(body.Length).Append("\r\n");
        if (body.Length > 0) header.Append("Content-Type: application/json; charset=utf-8\r\n");
        foreach (var (name, value) in extraHeaders) header.Append(name).Append(": ").Append(value).Append("\r\n");
        header.Append("\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(header.ToString()), cancellationToken);
        if (body.Length > 0) await stream.WriteAsync(body, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private static string Reason(int status) => status switch
    {
        400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        405 => "Method Not Allowed", 411 => "Length Required", 413 => "Payload Too Large",
        421 => "Misdirected Request", 431 => "Request Header Fields Too Large", _ => "Error"
    };

    private static bool FixedEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        return leftBytes.Length == rightBytes.Length && CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    public void Dispose() => Stop();

    private sealed record HttpRequestData(
        string Method,
        string Path,
        Dictionary<string, string> Headers,
        byte[] Body,
        HttpRequestError? Error)
    {
        public static HttpRequestData Failed(int status, string message) =>
            new(string.Empty, string.Empty, new Dictionary<string, string>(), [], new HttpRequestError(status, message));
    }

    private sealed record HttpRequestError(int Status, string Message);
}
