using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace ShotPaste.Windows.Services;

internal readonly record struct AppReleaseVersion(int Major, int Minor, int Patch) : IComparable<AppReleaseVersion>
{
    internal static bool TryParse(string? rawValue, out AppReleaseVersion version)
    {
        version = default;
        var value = rawValue?.Trim();
        if (string.IsNullOrWhiteSpace(value)) return false;
        if (value[0] is 'v' or 'V') value = value[1..];

        var components = value.Split('.', StringSplitOptions.None);
        if (components.Length != 3) return false;
        var numbers = new int[3];
        for (var index = 0; index < components.Length; index++)
        {
            var component = components[index];
            if (component.Length == 0 || component.Any(character => !char.IsAsciiDigit(character)) ||
                (component.Length > 1 && component[0] == '0') ||
                !int.TryParse(component, out numbers[index]))
                return false;
        }

        version = new AppReleaseVersion(numbers[0], numbers[1], numbers[2]);
        return true;
    }

    public int CompareTo(AppReleaseVersion other)
    {
        var majorComparison = Major.CompareTo(other.Major);
        if (majorComparison != 0) return majorComparison;
        var minorComparison = Minor.CompareTo(other.Minor);
        return minorComparison != 0 ? minorComparison : Patch.CompareTo(other.Patch);
    }

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}

internal sealed record AppRelease(AppReleaseVersion Version, Uri PageUri);

internal enum AppUpdateAvailability
{
    UpToDate,
    UpdateAvailable
}

internal sealed record AppUpdateCheckResult(
    AppUpdateAvailability Availability,
    AppReleaseVersion CurrentVersion,
    AppRelease LatestRelease);

internal sealed class AppUpdateService
{
    internal static readonly Uri LatestReleaseApiUri = new(
        "https://api.github.com/repos/shotpaste/shotpaste/releases/latest");

    private static readonly HttpClient SharedClient = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly HttpClient _client;
    private readonly Func<string?> _currentVersionProvider;

    internal AppUpdateService() : this(SharedClient, InstalledVersion) { }

    internal AppUpdateService(HttpClient client, Func<string?> currentVersionProvider)
    {
        _client = client;
        _currentVersionProvider = currentVersionProvider;
    }

    internal string CurrentVersionString => _currentVersionProvider() ?? "—";

    internal async Task<AppUpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        if (!AppReleaseVersion.TryParse(CurrentVersionString, out var currentVersion))
            throw new InvalidDataException("The installed application version is not stable SemVer.");

        using var request = new HttpRequestMessage(HttpMethod.Get, LatestReleaseApiUri);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Headers.UserAgent.ParseAdd($"ShotPaste/{currentVersion}");

        using var response = await _client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException(
                $"GitHub returned HTTP {(int)response.StatusCode}.",
                null,
                response.StatusCode);

        await using var responseStream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var document = await JsonDocument.ParseAsync(
            responseStream,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var root = document.RootElement;

        if (!root.TryGetProperty("tag_name", out var tagElement) ||
            tagElement.ValueKind != JsonValueKind.String ||
            !AppReleaseVersion.TryParse(tagElement.GetString(), out var latestVersion) ||
            !root.TryGetProperty("html_url", out var htmlUrlElement) ||
            htmlUrlElement.ValueKind != JsonValueKind.String ||
            !Uri.TryCreate(htmlUrlElement.GetString(), UriKind.Absolute, out var htmlUrl) ||
            !root.TryGetProperty("draft", out var draftElement) ||
            draftElement.ValueKind != JsonValueKind.False ||
            !root.TryGetProperty("prerelease", out var prereleaseElement) ||
            prereleaseElement.ValueKind != JsonValueKind.False ||
            !IsTrustedReleasePageUri(htmlUrl))
            throw new InvalidDataException("GitHub returned an invalid stable Release.");

        var release = new AppRelease(latestVersion, htmlUrl);
        return new AppUpdateCheckResult(
            latestVersion.CompareTo(currentVersion) > 0
                ? AppUpdateAvailability.UpdateAvailable
                : AppUpdateAvailability.UpToDate,
            currentVersion,
            release);
    }

    private static string? InstalledVersion()
    {
        var version = typeof(AppUpdateService).Assembly.GetName().Version;
        return version is null ? null : $"{version.Major}.{version.Minor}.{Math.Max(0, version.Build)}";
    }

    private static bool IsTrustedReleasePageUri(Uri? uri) =>
        uri is { IsAbsoluteUri: true } &&
        uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
        uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) &&
        uri.AbsolutePath.StartsWith("/shotpaste/shotpaste/releases/", StringComparison.OrdinalIgnoreCase);

}
