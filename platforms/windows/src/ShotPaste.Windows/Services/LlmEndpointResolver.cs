namespace ShotPaste.Windows.Services;

public static class LlmEndpointResolver
{
    public static bool IsValid(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        string.IsNullOrEmpty(uri.UserInfo) && string.IsNullOrEmpty(uri.Query) && string.IsNullOrEmpty(uri.Fragment) &&
        (uri.Scheme == "https" || (uri.Scheme == "http" && (uri.IsLoopback || IsPrivateIPv4(uri.Host))));

    private static bool IsPrivateIPv4(string host)
    {
        if (!System.Net.IPAddress.TryParse(host, out var address) ||
            address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
        var bytes = address.GetAddressBytes();
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
               (bytes[0] == 192 && bytes[1] == 168);
    }

    // Preserve the base URL and explicit compatible routes accepted by 0.3.0.
    // Only protocol suffixes change; the configured host and port stay intact.
    public static string Resolve(string endpoint, string protocol)
    {
        if (!IsValid(endpoint)) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration);
        var uri = new Uri(endpoint);
        var path = uri.AbsolutePath.TrimEnd('/');
        if (protocol == "openAICompatible" && path.EndsWith("/completions", StringComparison.OrdinalIgnoreCase))
            return uri.AbsoluteUri;
        var suffix = protocol switch
        {
            "openAICompatible" => "/chat/completions",
            "anthropicMessages" => "/messages",
            "responses" => "/responses",
            _ => throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration)
        };
        foreach (var known in new[] { "/chat/completions", "/messages", "/responses" })
        {
            if (!path.EndsWith(known, StringComparison.OrdinalIgnoreCase)) continue;
            path = path[..^known.Length];
            break;
        }
        if (path.Length == 0) path = "/v1";
        return new UriBuilder(uri) { Path = path + suffix }.Uri.AbsoluteUri;
    }
}
