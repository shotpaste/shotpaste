using System.Text.Json;
using System.Text.Json.Nodes;

namespace ShotPaste.Windows.Services;

internal sealed record McpAutomationResult(
    bool Ok,
    string Message,
    IReadOnlyDictionary<string, string> State)
{
    public static McpAutomationResult Failure(string message, IReadOnlyDictionary<string, string>? state = null) =>
        new(false, message, state ?? new Dictionary<string, string>());
}

internal sealed class ShotPasteMcpProtocol(
    Func<string, JsonObject, CancellationToken, Task<McpAutomationResult>> execute,
    Func<McpAutomationResult> status,
    string serverVersion)
{
    internal const string LatestProtocolVersion = "2025-11-25";
    private static readonly HashSet<string> SupportedProtocolVersions =
        [LatestProtocolVersion, "2025-06-18", "2025-03-26"];

    public async Task<string?> HandleAsync(string json, CancellationToken cancellationToken = default)
    {
        JsonObject request;
        try
        {
            request = JsonNode.Parse(json) as JsonObject
                ?? throw new JsonException("Request must be an object.");
        }
        catch (JsonException)
        {
            return Serialize(Error(null, -32700, "Parse error"));
        }

        var id = request["id"]?.DeepClone();
        if (request["jsonrpc"]?.GetValue<string>() != "2.0")
            return Serialize(Error(id, -32600, "Invalid Request"));
        if (request["method"] is not JsonValue methodValue || !methodValue.TryGetValue<string>(out var method))
            return Serialize(Error(id, -32600, "Invalid Request"));
        if (request["id"] is null) return null;

        return method switch
        {
            "initialize" => Serialize(Initialize(id, request["params"] as JsonObject)),
            "ping" => Serialize(Success(id, new JsonObject())),
            "tools/list" => Serialize(Success(id, new JsonObject { ["tools"] = ToolDefinitions().DeepClone() })),
            "tools/call" => Serialize(await CallToolAsync(id, request["params"] as JsonObject, cancellationToken)),
            _ => Serialize(Error(id, -32601, "Method not found"))
        };
    }

    private JsonObject Initialize(JsonNode? id, JsonObject? parameters)
    {
        if (parameters?["protocolVersion"] is not JsonValue versionNode ||
            !versionNode.TryGetValue<string>(out var requestedVersion) ||
            parameters["capabilities"] is not JsonObject ||
            parameters["clientInfo"] is not JsonObject)
            return Error(id, -32602, "Invalid initialize parameters");

        var negotiated = SupportedProtocolVersions.Contains(requestedVersion)
            ? requestedVersion
            : LatestProtocolVersion;
        return Success(id, new JsonObject
        {
            ["protocolVersion"] = negotiated,
            ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
            ["serverInfo"] = new JsonObject
            {
                ["name"] = "shotpaste-windows",
                ["title"] = "ShotPaste for Windows",
                ["version"] = serverVersion,
                ["description"] = "Local automation tools for the running ShotPaste application."
            },
            ["instructions"] = "Use these tools to operate the visible local ShotPaste UI. Capture remains user-controlled."
        });
    }

    private async Task<JsonObject> CallToolAsync(JsonNode? id, JsonObject? parameters, CancellationToken cancellationToken)
    {
        if (parameters?["name"] is not JsonValue nameNode || !nameNode.TryGetValue<string>(out var name))
            return Error(id, -32602, "Invalid tools/call parameters");
        if (parameters["arguments"] is not null && parameters["arguments"] is not JsonObject)
            return Error(id, -32602, "Tool arguments must be an object");
        var arguments = parameters["arguments"] as JsonObject ?? new JsonObject();

        McpAutomationResult result;
        switch (name)
        {
            case "shotpaste.get_status" when arguments.Count == 0:
                result = status();
                break;
            case "shotpaste.get_status":
            case "shotpaste.cancel_capture" when arguments.Count > 0:
                result = McpAutomationResult.Failure($"{name} does not accept arguments.", status().State);
                break;
            case "shotpaste.start_capture" when !HasOnly(arguments, "mode") ||
                                                     ReadString(arguments, "mode") is not ("screenshot" or "scrolling" or "recording"):
                result = McpAutomationResult.Failure("mode must be screenshot, scrolling, or recording.", status().State);
                break;
            case "shotpaste.open_history" when !HasOnly(arguments, "filter") ||
                                                   ReadString(arguments, "filter") is { } filter &&
                                                   filter is not ("all" or "screenshot" or "scrolling" or "recording" or "clipboard"):
                result = McpAutomationResult.Failure("filter must be all, screenshot, scrolling, recording, or clipboard.", status().State);
                break;
            case "shotpaste.open_settings" when !HasOnly(arguments, "tab"):
                result = McpAutomationResult.Failure("shotpaste.open_settings only accepts tab.", status().State);
                break;
            case "shotpaste.control_recording" when !HasOnly(arguments, "action") ||
                                                        ReadString(arguments, "action") is not ("pause" or "resume" or "stop"):
                result = McpAutomationResult.Failure("action must be pause, resume, or stop.", status().State);
                break;
            case "shotpaste.cancel_capture":
            case "shotpaste.start_capture":
            case "shotpaste.open_history":
            case "shotpaste.open_settings":
            case "shotpaste.control_recording":
                result = await execute(name, arguments, cancellationToken);
                break;
            default:
                return Error(id, -32602, $"Unknown tool: {name}");
        }
        return ToolResult(id, result);
    }

    private static bool HasOnly(JsonObject arguments, params string[] names) =>
        arguments.All(pair => names.Contains(pair.Key, StringComparer.Ordinal));

    internal static string? ReadString(JsonObject arguments, string name)
    {
        if (arguments[name] is not JsonValue value || !value.TryGetValue<string>(out var result)) return null;
        return result.Trim().ToLowerInvariant();
    }

    private static JsonObject ToolResult(JsonNode? id, McpAutomationResult result)
    {
        var state = new JsonObject(result.State.Select(pair =>
            new KeyValuePair<string, JsonNode?>(pair.Key, JsonValue.Create(pair.Value))));
        var structured = new JsonObject
        {
            ["ok"] = result.Ok,
            ["message"] = result.Message,
            ["state"] = state
        };
        return Success(id, new JsonObject
        {
            ["content"] = new JsonArray(new JsonObject
            {
                ["type"] = "text",
                ["text"] = structured.ToJsonString(new JsonSerializerOptions { WriteIndented = false })
            }),
            ["structuredContent"] = structured.DeepClone(),
            ["isError"] = !result.Ok
        });
    }

    private static JsonArray ToolDefinitions()
    {
        static JsonObject Schema(params (string Name, JsonArray Enum, bool Required)[] properties)
        {
            var props = new JsonObject();
            var required = new JsonArray();
            foreach (var property in properties)
            {
                props[property.Name] = new JsonObject { ["type"] = "string", ["enum"] = property.Enum };
                if (property.Required) required.Add(property.Name);
            }
            var schema = new JsonObject { ["type"] = "object", ["properties"] = props, ["additionalProperties"] = false };
            if (required.Count > 0) schema["required"] = required;
            return schema;
        }

        static JsonObject Tool(string name, string title, string description, JsonObject schema) => new()
        {
            ["name"] = name, ["title"] = title, ["description"] = description, ["inputSchema"] = schema
        };

        return new JsonArray
        {
            Tool("shotpaste.get_status", "Get ShotPaste status", "Read visible capture, recording, and history state.", Schema()),
            Tool("shotpaste.start_capture", "Start capture", "Open visible One Shot UI in a capture mode.",
                Schema(("mode", new JsonArray("screenshot", "scrolling", "recording"), true))),
            Tool("shotpaste.cancel_capture", "Cancel capture", "Cancel the active One Shot UI.", Schema()),
            Tool("shotpaste.open_history", "Open history", "Open history with an optional filter.",
                Schema(("filter", new JsonArray("all", "screenshot", "scrolling", "recording", "clipboard"), false))),
            Tool("shotpaste.open_settings", "Open settings", "Open an optional settings page.",
                Schema(("tab", new JsonArray("general", "capture", "quick-access", "history", "shortcuts", "appearance", "advanced"), false))),
            Tool("shotpaste.control_recording", "Control recording", "Pause, resume, or stop an active recording.",
                Schema(("action", new JsonArray("pause", "resume", "stop"), true)))
        };
    }

    private static JsonObject Success(JsonNode? id, JsonNode result) => new()
    {
        ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["result"] = result
    };

    private static JsonObject Error(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id?.DeepClone(),
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message }
    };

    private static string Serialize(JsonObject value) => value.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
}
