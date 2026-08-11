using System.Threading;
using System.Reflection;
using System.Windows;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows;

public partial class App : System.Windows.Application
{
    internal static bool UiTestMode { get; private set; }
    internal static bool DiagnosticsLoggingEnabled { get; private set; } = true;
    private Mutex? _singleInstance;
    private AppController? _controller;
    private AppCommandService? _commandService;
    private string? _instanceScope;

    protected override void OnStartup(StartupEventArgs e)
    {
        UiTestMode = e.Args.Any(argument => argument.Equals("--ui-test", StringComparison.OrdinalIgnoreCase));
        if (UiTestMode && TryGetArgumentValue(e.Args, "--data-root", out var testRoot))
        {
            _instanceScope = Path.GetFullPath(testRoot);
            AppPaths.ConfigureTestRoot(_instanceScope);
        }
        DispatcherUnhandledException += (_, args) => WriteCrashLog(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception exception) WriteCrashLog(exception);
        };
        base.OnStartup(e);
        var mutexName = UiTestMode
            ? $"ShotPaste.Windows.SingleInstance.UiTest.{ScopeToken(_instanceScope)}"
            : "ShotPaste.Windows.SingleInstance";
        _singleInstance = new Mutex(true, mutexName, out var createdNew);
        if (!createdNew)
        {
            var forwarded = e.Args.Length > 0 ? e.Args : ["--history"];
            App.WriteQuickAccessLog("Secondary instance forwarding command.");
            var sent = AppCommandService.SendAsync(forwarded, instanceScope: _instanceScope).GetAwaiter().GetResult();
            App.WriteQuickAccessLog($"Secondary instance forwarding completed sent={sent}; shutting down.");
            Shutdown();
            return;
        }

        App.WriteQuickAccessLog($"ShotPaste startup begin version={typeof(App).Assembly.GetName().Version} path={Environment.ProcessPath}");
        _controller = new AppController();
        _commandService = new AppCommandService(_instanceScope);
        _commandService.Start(arguments => Dispatcher.BeginInvoke(() => _controller?.HandleExternalCommand(arguments)));
        _controller.Start();
        _controller.HandleExternalCommand(e.Args);
    }

    private static bool TryGetArgumentValue(IReadOnlyList<string> arguments, string name, out string value)
    {
        value = string.Empty;
        for (var index = 0; index < arguments.Count; index++)
        {
            var argument = arguments[index];
            if (argument.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
            {
                value = argument[(name.Length + 1)..];
                return !string.IsNullOrWhiteSpace(value);
            }

            if (!argument.Equals(name, StringComparison.OrdinalIgnoreCase) || index + 1 >= arguments.Count) continue;
            value = arguments[index + 1];
            return !string.IsNullOrWhiteSpace(value);
        }

        return false;
    }

    private static string ScopeToken(string? scope)
    {
        var value = string.IsNullOrWhiteSpace(scope) ? Environment.ProcessId.ToString() : scope;
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..16];
    }

    internal static void WriteCrashLog(Exception exception)
    {
        try
        {
            AppPaths.EnsureCreated();
            File.WriteAllText(Path.Combine(AppPaths.Root, "crash.log"), $"{DateTimeOffset.Now:O}{Environment.NewLine}{exception}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    internal static void WriteQuickAccessLog(string message)
    {
        if (!DiagnosticsLoggingEnabled) return;
        try
        {
            AppPaths.EnsureCreated();
            File.AppendAllText(Path.Combine(AppPaths.Root, "quickaccess.log"), $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    internal static void ConfigureDiagnostics(bool enabled) => DiagnosticsLoggingEnabled = enabled;

    protected override void OnExit(ExitEventArgs e)
    {
        _controller?.Dispose();
        _commandService?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
