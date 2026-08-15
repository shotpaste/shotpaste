namespace ShotPaste.Windows.Services;

internal static class AppLaunchArguments
{
    internal const string Background = "--background";
    internal const string OpenSettings = "--settings";
    internal const string UiTestDirectLaunch = "--ui-test-direct-launch";

    internal static string[] ResolveInitialCommandArguments(IReadOnlyList<string> arguments)
    {
        var simulatesDirectLaunch = arguments.Any(argument =>
                                        argument.Equals("--ui-test", StringComparison.OrdinalIgnoreCase)) &&
                                    arguments.Any(argument =>
                                        argument.Equals(UiTestDirectLaunch, StringComparison.OrdinalIgnoreCase));
        return arguments.Count == 0 || simulatesDirectLaunch
            ? [.. arguments, OpenSettings]
            : [.. arguments];
    }
}
