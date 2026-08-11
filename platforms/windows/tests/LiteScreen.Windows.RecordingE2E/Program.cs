using System.IO;
using System.Text.Json;
using System.Windows;

namespace LiteScreen.Windows.RecordingE2E;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var outputRoot = Path.GetFullPath(args.FirstOrDefault() ?? Path.Combine("build", "e2e", "recording"));
        Directory.CreateDirectory(outputRoot);
        var exitCode = 1;
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Startup += async (_, _) =>
        {
            try
            {
                var productExecutable = args.Skip(1).FirstOrDefault();
                var result = args.Any(argument => argument.Equals("--performance-only", StringComparison.OrdinalIgnoreCase))
                    ? await RecordingPerformanceE2E.RunAsync(outputRoot, ParsePerformanceSeconds(args))
                    : args.Any(argument => argument.Equals("--effects-only", StringComparison.OrdinalIgnoreCase))
                        ? await RecordingEffectsE2E.RunAsync(outputRoot)
                        : args.Any(argument => argument.Equals("--formats-only", StringComparison.OrdinalIgnoreCase))
                            ? await RecordingFormatE2E.RunAsync(outputRoot)
                            : args.Any(argument => argument.Equals("--settings-only", StringComparison.OrdinalIgnoreCase))
                                ? await RecordingSettingsE2E.RunAsync(Path.GetFullPath(productExecutable ??
                                    throw new ArgumentException("Product executable is required for --settings-only.")), outputRoot)
                                : await RunAsync(outputRoot, productExecutable);
                Console.WriteLine(JsonSerializer.Serialize(result));
                exitCode = 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception);
            }
            finally
            {
                application.Shutdown(exitCode);
            }
        };
        application.Run();
        return exitCode;
    }

    private static int ParsePerformanceSeconds(IReadOnlyList<string> args)
    {
        var argument = args.FirstOrDefault(value =>
            value.StartsWith("--performance-seconds=", StringComparison.OrdinalIgnoreCase));
        return argument is not null && int.TryParse(argument.Split('=', 2)[1], out var seconds)
            ? Math.Clamp(seconds, 10, 300)
            : 20;
    }

    private static async Task<object> RunAsync(string outputRoot, string? productExecutable)
    {
        var effects = await RecordingEffectsE2E.RunAsync(outputRoot);
        var formats = await RecordingFormatE2E.RunAsync(outputRoot);
        var settings = string.IsNullOrWhiteSpace(productExecutable)
            ? null
            : await RecordingSettingsE2E.RunAsync(Path.GetFullPath(productExecutable), outputRoot);
        return new { Effects = effects, Formats = formats, Settings = settings };
    }
}
