using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class AppLaunchArgumentsTests
{
    [Fact]
    public void DirectExecutableLaunchOpensSettings()
    {
        var arguments = AppLaunchArguments.ResolveInitialCommandArguments([]);

        Assert.Equal([AppLaunchArguments.OpenSettings], arguments);
        Assert.Equal(AppCommand.Settings, UrlSchemeService.Parse(arguments).Command);
    }

    [Theory]
    [InlineData("--background")]
    [InlineData("--history")]
    [InlineData("--settings=capture-recording")]
    public void ExplicitLaunchIntentIsPreserved(string argument)
    {
        var arguments = AppLaunchArguments.ResolveInitialCommandArguments([argument]);

        Assert.Equal([argument], arguments);
    }

    [Fact]
    public void LoginStartupUsesAnExplicitSilentBackgroundIntent()
    {
        const string executable = @"C:\Program Files\ShotPaste\ShotPaste.exe";

        Assert.Equal(
            @"""C:\Program Files\ShotPaste\ShotPaste.exe"" --background",
            StartupService.BuildRunCommand(executable));
        Assert.Equal(AppCommand.None, UrlSchemeService.Parse([AppLaunchArguments.Background]).Command);
    }

    [Fact]
    public void UiTestCanExerciseTheSameDirectLaunchRouteWithAnIsolatedDataRoot()
    {
        var arguments = AppLaunchArguments.ResolveInitialCommandArguments(
            ["--ui-test", "--data-root", @"C:\isolated", AppLaunchArguments.UiTestDirectLaunch]);

        Assert.Equal(AppLaunchArguments.OpenSettings, arguments[^1]);
        Assert.Equal(AppCommand.Settings, UrlSchemeService.Parse(arguments).Command);
    }
}
