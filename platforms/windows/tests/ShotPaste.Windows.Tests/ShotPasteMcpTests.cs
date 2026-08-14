using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class ShotPasteMcpTests
{
    private static readonly IReadOnlyDictionary<string, string> IdleState = new Dictionary<string, string>
    {
        ["oneShot"] = "idle", ["recording"] = "idle", ["history"] = "hidden"
    };

    [Fact]
    public async Task InitializeNegotiatesSupportedProtocolAndWindowsIdentity()
    {
        var protocol = CreateProtocol();
        var response = JsonNode.Parse((await protocol.HandleAsync("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
            """))!)!.AsObject();

        Assert.Equal("2025-06-18", response["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Equal("shotpaste-windows", response["result"]!["serverInfo"]!["name"]!.GetValue<string>());
    }

    [Fact]
    public async Task ToolsListContainsTheSixAllowListedTools()
    {
        var response = JsonNode.Parse((await CreateProtocol().HandleAsync(
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"))!)!.AsObject();
        var tools = response["result"]!["tools"]!.AsArray();

        Assert.Equal(6, tools.Count);
        Assert.Contains(tools, tool => tool!["name"]!.GetValue<string>() == "shotpaste.start_capture");
        Assert.Contains(tools, tool => tool!["name"]!.GetValue<string>() == "shotpaste.control_recording");
    }

    [Fact]
    public async Task ToolCallValidatesArgumentsAndReturnsStructuredContent()
    {
        var executed = string.Empty;
        var protocol = CreateProtocol((name, _, _) =>
        {
            executed = name;
            return Task.FromResult(new McpAutomationResult(true, "opened", IdleState));
        });
        var invalid = JsonNode.Parse((await protocol.HandleAsync("""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"shotpaste.start_capture","arguments":{"mode":"window"}}}
            """))!)!.AsObject();
        var valid = JsonNode.Parse((await protocol.HandleAsync("""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"shotpaste.open_history","arguments":{"filter":"clipboard"}}}
            """))!)!.AsObject();

        Assert.True(invalid["result"]!["isError"]!.GetValue<bool>());
        Assert.Equal("shotpaste.open_history", executed);
        Assert.True(valid["result"]!["structuredContent"]!["ok"]!.GetValue<bool>());
    }

    [Fact]
    public async Task NotificationIsAcceptedWithoutResponse()
    {
        Assert.Null(await CreateProtocol().HandleAsync(
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"));
    }

    [Fact]
    public async Task LoopbackServerRequiresBearerTokenAndRejectsForeignOrigin()
    {
        var port = ReserveLoopbackPort();
        const string token = "unit-test-token";
        using var server = new ShotPasteMcpServer(CreateProtocol());
        server.Apply(true, port, token);
        Assert.True(server.IsRunning, server.LastError);
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false })
        {
            BaseAddress = new Uri($"http://127.0.0.1:{port}")
        };
        const string body = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}";

        using var unauthorized = await client.PostAsync("/mcp", new StringContent(body, Encoding.UTF8, "application/json"));
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        using var foreignOrigin = new HttpRequestMessage(HttpMethod.Post, "/mcp")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        foreignOrigin.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        foreignOrigin.Headers.TryAddWithoutValidation("Origin", "https://example.com");
        using var forbidden = await client.SendAsync(foreignOrigin);
        Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);

        using var authorized = new HttpRequestMessage(HttpMethod.Post, "/mcp")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        authorized.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var ok = await client.SendAsync(authorized);
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
    }

    private static ShotPasteMcpProtocol CreateProtocol(
        Func<string, JsonObject, CancellationToken, Task<McpAutomationResult>>? executor = null) =>
        new(executor ?? ((_, _, _) => Task.FromResult(new McpAutomationResult(true, "ok", IdleState))),
            () => new McpAutomationResult(true, "status", IdleState),
            "1.2.3");

    private static int ReserveLoopbackPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
