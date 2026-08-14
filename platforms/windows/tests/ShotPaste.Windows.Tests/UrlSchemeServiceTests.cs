using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class UrlSchemeServiceTests
{
    [Theory]
    [InlineData("shotpaste://one-shot", AppCommand.OneShot)]
    [InlineData("shotpaste://capture/one-shot", AppCommand.OneShot)]
    [InlineData("SHOTPASTE://CAPTURE-ONE-SHOT", AppCommand.OneShot)]
    [InlineData("--one-shot", AppCommand.OneShot)]
    [InlineData("shotpaste://open/history", AppCommand.History)]
    [InlineData("shotpaste://capture-history", AppCommand.History)]
    [InlineData("--history", AppCommand.History)]
    public void Parse_MapsSupportedRoutes(string argument, AppCommand expected)
    {
        Assert.Equal(expected, UrlSchemeService.Parse([ForCurrentScheme(argument)]).Command);
    }

    [Theory]
    [InlineData("shotpaste://settings/quick-access", "quick-access")]
    [InlineData("shotpaste://settings/CAPTURE", "capture-recording")]
    [InlineData("shotpaste://preferences?tab=keyboard-shortcuts", "shortcuts-appearance")]
    [InlineData("--settings=advanced", "advanced")]
    public void Parse_SettingsDeepLinkNormalizesTab(string argument, string expected)
    {
        var result = UrlSchemeService.Parse([ForCurrentScheme(argument)]);

        Assert.Equal(AppCommand.Settings, result.Command);
        Assert.Equal(expected, result.SettingsTab);
    }

    [Theory]
    [InlineData("shotpaste://settings?tab=unknown")]
    [InlineData("shotpaste://settings?tab=annotate")]
    [InlineData("shotpaste://settings?tab=recording")]
    [InlineData("shotpaste://capture/area")]
    [InlineData("shotpaste://area")]
    [InlineData("shotpaste://annotate")]
    [InlineData("shotpaste://open-annotate")]
    [InlineData("shotpaste://capture/fullscreen")]
    [InlineData("shotpaste://capture/area-annotate")]
    [InlineData("shotpaste://capture/scrolling")]
    [InlineData("shotpaste://ocr")]
    [InlineData("shotpaste://record/screen")]
    [InlineData("shotpaste://not-a-command")]
    [InlineData("shotpaste://%")]
    public void Parse_InvalidUrlReturnsSafeFeedbackCommand(string argument)
    {
        var result = UrlSchemeService.Parse([ForCurrentScheme(argument)]);

        Assert.Equal(AppCommand.Invalid, result.Command);
        Assert.True(result.IsUrl);
        Assert.False(string.IsNullOrWhiteSpace(result.Error));
    }

    [Fact]
    public async Task CommandPipeForwardsArgumentsWithinAnIsolatedInstanceScope()
    {
        var scope = Path.Combine(Path.GetTempPath(), $"shotpaste-url-tests-{Guid.NewGuid():N}");
        try
        {
            var received = new TaskCompletionSource<IReadOnlyList<string>>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var service = new AppCommandService(scope);
            service.Start(arguments => received.TrySetResult(arguments));

            Assert.True(await AppCommandService.SendAsync(
                [$"{UrlSchemeService.Scheme}://settings/history"], timeoutMilliseconds: 3000, instanceScope: scope));
            var arguments = await received.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Assert.Equal($"{UrlSchemeService.Scheme}://settings/history", Assert.Single(arguments));
        }
        finally
        {
            if (Directory.Exists(scope)) Directory.Delete(scope, true);
        }
    }

    private static string ForCurrentScheme(string argument) => argument.Replace(
        "shotpaste:",
        UrlSchemeService.Scheme + ":",
        StringComparison.OrdinalIgnoreCase);
}
