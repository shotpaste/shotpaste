using System.Windows;
using System.Windows.Interop;
using ShotPaste.Windows.Interop;

namespace ShotPaste.Windows.Services;

/// <summary>
/// Continuously applies WDA_EXCLUDEFROMCAPTURE to every ShotPaste window while
/// privacy exclusion is active. A class-level Loaded hook covers windows opened
/// after recording starts; a lightweight timer covers late/recreated HWNDs.
/// Previous affinity values are restored exactly when exclusion is disabled.
/// </summary>
public sealed class WindowCaptureExclusionService : IDisposable
{
    private static WindowCaptureExclusionService? _activeInstance;
    private readonly Dictionary<IntPtr, uint> _previousAffinities = [];
    private readonly System.Windows.Threading.DispatcherTimer _refreshTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(100)
    };
    private bool _enabled;

    static WindowCaptureExclusionService()
    {
        EventManager.RegisterClassHandler(
            typeof(Window),
            FrameworkElement.LoadedEvent,
            new RoutedEventHandler((sender, _) => _activeInstance?.ApplyToWindow(sender as Window)));
    }

    public WindowCaptureExclusionService()
    {
        _refreshTimer.Tick += (_, _) => ApplyToOpenWindows();
    }

    public bool IsEnabled => _enabled;

    public void SetEnabled(bool enabled)
    {
        if (_enabled == enabled)
        {
            if (enabled) ApplyToOpenWindows();
            return;
        }

        _enabled = enabled;
        if (enabled)
        {
            _activeInstance = this;
            ApplyToOpenWindows();
            _refreshTimer.Start();
        }
        else
        {
            _refreshTimer.Stop();
            if (ReferenceEquals(_activeInstance, this)) _activeInstance = null;
            RestoreAll();
        }
    }

    private void ApplyToOpenWindows()
    {
        var application = System.Windows.Application.Current;
        if (!_enabled) return;
        if (application?.Dispatcher.CheckAccess() == true)
            foreach (Window window in application.Windows.Cast<Window>().ToArray()) ApplyToWindow(window);

        var currentProcessId = (uint)Environment.ProcessId;
        _ = NativeMethods.EnumWindows((handle, parameter) =>
        {
            _ = NativeMethods.GetWindowThreadProcessId(handle, out var processId);
            if (processId == currentProcessId) ApplyToHandle(handle);
            return true;
        }, IntPtr.Zero);

        foreach (var handle in _previousAffinities.Keys.ToArray())
        {
            if (!NativeMethods.IsWindow(handle))
            {
                _previousAffinities.Remove(handle);
                continue;
            }
            _ = NativeMethods.GetWindowThreadProcessId(handle, out var processId);
            if (processId != currentProcessId) _previousAffinities.Remove(handle);
        }
    }

    private void ApplyToWindow(Window? window)
    {
        if (!_enabled || window is null) return;
        var handle = new WindowInteropHelper(window).Handle;
        ApplyToHandle(handle);
    }

    private void ApplyToHandle(IntPtr handle)
    {
        if (!_enabled || handle == IntPtr.Zero || _previousAffinities.ContainsKey(handle)) return;
        var previous = NativeMethods.GetWindowDisplayAffinity(handle, out var affinity)
            ? affinity
            : NativeMethods.WdaNone;
        if (!NativeMethods.SetWindowDisplayAffinity(handle, NativeMethods.WdaExcludeFromCapture)) return;
        _previousAffinities[handle] = previous;
    }

    private void RestoreAll()
    {
        var currentProcessId = (uint)Environment.ProcessId;
        foreach (var pair in _previousAffinities.ToArray())
        {
            if (!NativeMethods.IsWindow(pair.Key)) continue;
            _ = NativeMethods.GetWindowThreadProcessId(pair.Key, out var processId);
            if (processId == currentProcessId)
                _ = NativeMethods.SetWindowDisplayAffinity(pair.Key, pair.Value);
        }
        _previousAffinities.Clear();
    }

    public void Dispose()
    {
        SetEnabled(false);
        _refreshTimer.Stop();
    }
}
