using LiteScreen.Windows.Services;

namespace LiteScreen.Windows.Tests;

public sealed class UrlSchemeServiceTests
{
    [Theory]
    [InlineData("litescreen://one-shot", AppCommand.OneShot)]
    [InlineData("litescreen://capture/one-shot", AppCommand.OneShot)]
    [InlineData("LITESCREEN://CAPTURE-ONE-SHOT", AppCommand.OneShot)]
    [InlineData("--one-shot", AppCommand.OneShot)]
    [InlineData("litescreen://open/history", AppCommand.History)]
    [InlineData("litescreen://capture-history", AppCommand.History)]
    [InlineData("--history", AppCommand.History)]
    public void Parse_MapsSupportedRoutes(string argument, AppCommand expected)
    {
        Assert.Equal(expected, UrlSchemeService.Parse([argument]).Command);
    }

    [Theory]
    [InlineData("litescreen://settings/quick-access", "quick-access")]
    [InlineData("litescreen://settings/CAPTURE", "capture-recording")]
    [InlineData("litescreen://preferences?tab=keyboard-shortcuts", "shortcuts-appearance")]
    [InlineData("--settings=advanced", "advanced")]
    public void Parse_SettingsDeepLinkNormalizesTab(string argument, string expected)
    {
        var result = UrlSchemeService.Parse([argument]);

        Assert.Equal(AppCommand.Settings, result.Command);
        Assert.Equal(expected, result.SettingsTab);
    }

    [Theory]
    [InlineData("litescreen://settings?tab=unknown")]
    [InlineData("litescreen://settings?tab=annotate")]
    [InlineData("litescreen://settings?tab=recording")]
    [InlineData("litescreen://capture/area")]
    [InlineData("litescreen://area")]
    [InlineData("litescreen://annotate")]
    [InlineData("litescreen://open-annotate")]
    [InlineData("litescreen://capture/fullscreen")]
    [InlineData("litescreen://capture/area-annotate")]
    [InlineData("litescreen://capture/scrolling")]
    [InlineData("litescreen://ocr")]
    [InlineData("litescreen://record/screen")]
    [InlineData("litescreen://not-a-command")]
    [InlineData("litescreen://%")]
    public void Parse_InvalidUrlReturnsSafeFeedbackCommand(string argument)
    {
        var result = UrlSchemeService.Parse([argument]);

        Assert.Equal(AppCommand.Invalid, result.Command);
        Assert.True(result.IsUrl);
        Assert.False(string.IsNullOrWhiteSpace(result.Error));
    }

    [Fact]
    public async Task CommandPipeForwardsArgumentsWithinAnIsolatedInstanceScope()
    {
        var scope = Path.Combine(Path.GetTempPath(), $"litescreen-url-tests-{Guid.NewGuid():N}");
        try
        {
            var received = new TaskCompletionSource<IReadOnlyList<string>>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var service = new AppCommandService(scope);
            service.Start(arguments => received.TrySetResult(arguments));

            Assert.True(await AppCommandService.SendAsync(
                ["litescreen://settings/history"], timeoutMilliseconds: 3000, instanceScope: scope));
            var arguments = await received.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Assert.Equal("litescreen://settings/history", Assert.Single(arguments));
        }
        finally
        {
            if (Directory.Exists(scope)) Directory.Delete(scope, true);
        }
    }
}
