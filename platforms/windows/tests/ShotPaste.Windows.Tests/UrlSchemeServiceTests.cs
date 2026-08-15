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
    [InlineData("shotpaste://capture/cancel", AppCommand.CancelCapture)]
    [InlineData("--cancel", AppCommand.CancelCapture)]
    public void Parse_MapsSupportedRoutes(string argument, AppCommand expected)
    {
        Assert.Equal(expected, UrlSchemeService.Parse([ForCurrentScheme(argument)]).Command);
    }

    [Theory]
    [InlineData("shotpaste://settings/quick-access", "quick-access")]
    [InlineData("shotpaste://settings/CAPTURE", "capture-recording")]
    [InlineData("shotpaste://preferences?tab=keyboard-shortcuts", "shortcuts-appearance")]
    [InlineData("--settings=advanced", "advanced")]
    [InlineData("--settings=shortcuts-appearance", "shortcuts-appearance")]
    [InlineData("--settings=capture-recording", "capture-recording")]
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
    [InlineData("shotpaste://not-a-command")]
    [InlineData("shotpaste://%")]
    public void Parse_InvalidUrlReturnsSafeFeedbackCommand(string argument)
    {
        var result = UrlSchemeService.Parse([ForCurrentScheme(argument)]);

        Assert.Equal(AppCommand.Invalid, result.Command);
        Assert.True(result.IsUrl);
        Assert.False(string.IsNullOrWhiteSpace(result.Error));
    }

    [Theory]
    [InlineData("shotpaste://screenshot", "screenshot")]
    [InlineData("shotpaste://capture/scrolling", "scrolling")]
    [InlineData("shotpaste://ocr", "ocr")]
    [InlineData("shotpaste://record/screen", "recording")]
    [InlineData("shotpaste://one-shot?mode=recording", "recording")]
    [InlineData("--capture=ocr", "ocr")]
    [InlineData("--scrolling", "scrolling")]
    [InlineData("--record", "recording")]
    public void Parse_CaptureRoutesPreserveRequestedMode(string argument, string expectedMode)
    {
        var result = UrlSchemeService.Parse([ForCurrentScheme(argument)]);

        Assert.Equal(AppCommand.OneShot, result.Command);
        Assert.Equal(expectedMode, result.CaptureMode);
    }

    [Theory]
    [InlineData("shotpaste://history?filter=clipboard", "clipboard")]
    [InlineData("shotpaste://open/clipboard", "clipboard")]
    [InlineData("--history=recording", "recording")]
    [InlineData("--history=all", "all")]
    public void Parse_HistoryRoutesPreserveFilter(string argument, string expectedFilter)
    {
        var result = UrlSchemeService.Parse([ForCurrentScheme(argument)]);

        Assert.Equal(AppCommand.History, result.Command);
        Assert.Equal(expectedFilter, result.HistoryFilter);
    }

    [Theory]
    [InlineData("shotpaste://recording/pause", "pause")]
    [InlineData("shotpaste://recording/resume", "resume")]
    [InlineData("shotpaste://record/stop", "stop")]
    [InlineData("--recording=stop", "stop")]
    public void Parse_RecordingControlRoutesPreserveAction(string argument, string expectedAction)
    {
        var result = UrlSchemeService.Parse([ForCurrentScheme(argument)]);

        Assert.Equal(AppCommand.ControlRecording, result.Command);
        Assert.Equal(expectedAction, result.RecordingAction);
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
