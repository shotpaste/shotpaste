using System.Net;
using System.Net.Http;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class AppUpdateServiceTests
{
    [Theory]
    [InlineData("1.2.3", 1, 2, 3)]
    [InlineData("v12.0.9", 12, 0, 9)]
    public void ReleaseVersionParsesStableSemanticVersion(string value, int major, int minor, int patch)
    {
        Assert.True(AppReleaseVersion.TryParse(value, out var version));
        Assert.Equal(new AppReleaseVersion(major, minor, patch), version);
    }

    [Theory]
    [InlineData("1.2")]
    [InlineData("1.2.3-beta.1")]
    [InlineData("1.02.3")]
    [InlineData("1.2.3.0")]
    public void ReleaseVersionRejectsNonStableOrNonCanonicalValue(string value) =>
        Assert.False(AppReleaseVersion.TryParse(value, out _));

    [Fact]
    public async Task CheckForUpdatesReturnsAvailableReleaseAndUsesGitHubHeaders()
    {
        HttpRequestMessage? capturedRequest = null;
        using var client = new HttpClient(new StubHttpMessageHandler(request =>
        {
            capturedRequest = request;
            return JsonResponse(
                """
                [
                  {
                    "tag_name":"macos-v9.0.0",
                    "html_url":"https://github.com/shotpaste/shotpaste/releases/tag/macos-v9.0.0",
                    "draft":false,
                    "prerelease":false,
                    "assets":[{"name":"ShotPaste-v9.0.0-macOS-arm64.dmg"}]
                  },
                  {
                    "tag_name":"windows-v1.13.0",
                    "html_url":"https://github.com/shotpaste/shotpaste/releases/tag/windows-v1.13.0",
                    "draft":false,
                    "prerelease":false,
                    "assets":[{"name":"ShotPaste-v1.13.0-Windows-x64-portable.zip"}]
                  }
                ]
                """);
        }));
        var service = new AppUpdateService(client, () => "1.12.2");

        var result = await service.CheckForUpdatesAsync();

        Assert.Equal(AppUpdateAvailability.UpdateAvailable, result.Availability);
        Assert.Equal("1.12.2", result.CurrentVersion.ToString());
        Assert.Equal("1.13.0", result.LatestRelease.Version.ToString());
        var request = Assert.IsType<HttpRequestMessage>(capturedRequest);
        Assert.Equal(AppUpdateService.ReleasesApiUri, request.RequestUri);
        Assert.Equal("application/vnd.github+json", request.Headers.Accept.Single().MediaType);
        Assert.Equal("2022-11-28", request.Headers.GetValues("X-GitHub-Api-Version").Single());
        Assert.Equal("ShotPaste/1.12.2", request.Headers.UserAgent.ToString());
    }

    [Fact]
    public async Task CheckForUpdatesTreatsSameVersionAsUpToDate()
    {
        using var client = new HttpClient(new StubHttpMessageHandler(_ => JsonResponse(
            """
            [{
              "tag_name":"windows-v1.12.2",
              "html_url":"https://github.com/shotpaste/shotpaste/releases/tag/windows-v1.12.2",
              "draft":false,
              "prerelease":false,
              "assets":[{"name":"ShotPaste-v1.12.2-Windows-x64-portable.zip"}]
            }]
            """)));
        var service = new AppUpdateService(client, () => "1.12.2");

        var result = await service.CheckForUpdatesAsync();

        Assert.Equal(AppUpdateAvailability.UpToDate, result.Availability);
    }

    [Fact]
    public async Task CheckForUpdatesRejectsUntrustedReleasePage()
    {
        using var client = new HttpClient(new StubHttpMessageHandler(_ => JsonResponse(
            """
            [{
              "tag_name":"windows-v9.0.0",
              "html_url":"https://example.com/download",
              "draft":false,
              "prerelease":false,
              "assets":[{"name":"ShotPaste-v9.0.0-Windows-x64-portable.zip"}]
            }]
            """)));
        var service = new AppUpdateService(client, () => "1.12.2");

        await Assert.ThrowsAsync<InvalidDataException>(() => service.CheckForUpdatesAsync());
    }

    [Fact]
    public async Task CheckForUpdatesRejectsResponseWithoutWindowsPackage()
    {
        using var client = new HttpClient(new StubHttpMessageHandler(_ => JsonResponse(
            """
            [{
              "tag_name":"macos-v1.13.0",
              "html_url":"https://github.com/shotpaste/shotpaste/releases/tag/macos-v1.13.0",
              "draft":false,
              "prerelease":false,
              "assets":[{"name":"ShotPaste-v1.13.0-macOS-arm64.dmg"}]
            }]
            """)));
        var service = new AppUpdateService(client, () => "1.12.2");

        await Assert.ThrowsAsync<InvalidDataException>(() => service.CheckForUpdatesAsync());
    }

    [Fact]
    public async Task CheckForUpdatesSurfacesHttpStatus()
    {
        using var client = new HttpClient(new StubHttpMessageHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.Forbidden)));
        var service = new AppUpdateService(client, () => "1.12.2");

        var exception = await Assert.ThrowsAsync<HttpRequestException>(() => service.CheckForUpdatesAsync());
        Assert.Equal(HttpStatusCode.Forbidden, exception.StatusCode);
    }

    private static HttpResponseMessage JsonResponse(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json")
    };

    private sealed class StubHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(responder(request));
    }
}
