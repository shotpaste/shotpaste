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
        if (e.Args.Any(argument => argument.Equals("--verify-build-identity", StringComparison.OrdinalIgnoreCase)))
        {
            base.OnStartup(e);
            var errors = AppBuildIdentity.ValidateCurrentBuild(Environment.ProcessPath);
            foreach (var error in errors) Console.Error.WriteLine(error);
            Shutdown(errors.Count == 0 ? 0 : 2);
            return;
        }

        UiTestMode = e.Args.Any(argument => argument.Equals("--ui-test", StringComparison.OrdinalIgnoreCase));
        if (UiTestMode)
        {
            try
            {
                _instanceScope = UiTestIsolationPolicy.PrepareDataRoot(e.Args, AppBuildIdentity.Current);
                AppPaths.ConfigureTestRoot(_instanceScope);
            }
            catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
            {
                Console.Error.WriteLine(exception.Message);
                base.OnStartup(e);
                Shutdown(2);
                return;
            }
        }
        DispatcherUnhandledException += (_, args) => WriteCrashLog(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception exception) WriteCrashLog(exception);
        };
        base.OnStartup(e);
        var mutexName = UiTestMode
            ? $"{AppBuildIdentity.Current.SingleInstanceMutexName}.UiTest.{ScopeToken(_instanceScope!)}"
            : AppBuildIdentity.Current.SingleInstanceMutexName;
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

        App.WriteQuickAccessLog($"{AppBuildIdentity.Current.DisplayName} startup begin version={typeof(App).Assembly.GetName().Version} path={Environment.ProcessPath}");
        _controller = new AppController();
        _commandService = new AppCommandService(_instanceScope);
        _commandService.Start(arguments => Dispatcher.BeginInvoke(() => _controller?.HandleExternalCommand(arguments)));
        _controller.Start();
        _controller.HandleExternalCommand(e.Args);
        if (UiTestMode && e.Args.Any(argument => argument.Equals("--ui-test-toast", StringComparison.OrdinalIgnoreCase)))
        {
            _ = Dispatcher.BeginInvoke(() => ToastService.Show(
                "UI redesign preview",
                "Toast, material, icon, and motion system ready.",
                ToastKind.Success,
                TimeSpan.FromSeconds(30)));
        }
    }

    private static string ScopeToken(string scope)
    {
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(scope)))[..16];
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
        ThemeService.Shutdown();
        _controller?.Dispose();
        _commandService?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
