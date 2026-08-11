using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Services;

internal sealed class SelectionPerformanceTrace : IDisposable
{
    private static readonly object WriteGate = new();
    private static readonly ConcurrentDictionary<string, int> StartsByMode = new(StringComparer.OrdinalIgnoreCase);
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly DispatcherTimer _heartbeat;
    private readonly string _operation;
    private readonly string _mode;
    private readonly string _startup;
    private readonly Drawing.Rectangle _virtualBounds;
    private readonly int _uiThreadId = Environment.CurrentManagedThreadId;
    private readonly long _managedBaseline = GC.GetTotalMemory(false);
    private readonly long _workingSetBaseline;
    private readonly string[] _displays;
    private TimeSpan _lastHeartbeat;
    private double _maximumHeartbeatGapMs;
    private long _managedPeak;
    private long _workingSetPeak;
    private double? _captureMs;
    private int? _captureThreadId;
    private double? _overlayInitializedMs;
    private double? _firstFrameMs;
    private bool _completed;

    private SelectionPerformanceTrace(
        string operation,
        Drawing.Rectangle virtualBounds)
    {
        _operation = operation;
        _mode = "Frozen";
        _startup = StartsByMode.AddOrUpdate(_mode, 1, (_, value) => value + 1) == 1 ? "Cold" : "Hot";
        _virtualBounds = virtualBounds;
        using var process = Process.GetCurrentProcess();
        _workingSetBaseline = process.WorkingSet64;
        _workingSetPeak = _workingSetBaseline;
        _managedPeak = _managedBaseline;
        _displays = Forms.Screen.AllScreens.Select(DescribeDisplay).ToArray();
        _lastHeartbeat = _clock.Elapsed;
        _heartbeat = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(16)
        };
        _heartbeat.Tick += OnHeartbeat;
        _heartbeat.Start();
    }

    public static SelectionPerformanceTrace Start(
        string operation,
        Drawing.Rectangle virtualBounds)
        => new(operation, virtualBounds);

    public void MarkCaptureCompleted(double milliseconds, int threadId)
    {
        _captureMs = milliseconds;
        _captureThreadId = threadId;
        SampleMemory();
    }

    public void MarkOverlayInitialized()
    {
        _overlayInitializedMs ??= _clock.Elapsed.TotalMilliseconds;
        SampleMemory();
    }

    public void MarkFirstFrame()
    {
        _firstFrameMs ??= _clock.Elapsed.TotalMilliseconds;
        SampleMemory();
    }

    public void Complete(string outcome)
    {
        if (_completed) return;
        _completed = true;
        _heartbeat.Stop();
        SampleMemory();
        var payload = new
        {
            Timestamp = DateTimeOffset.Now,
            Operation = _operation,
            Mode = _mode,
            Startup = _startup,
            Outcome = outcome,
            VirtualBounds = new { _virtualBounds.X, _virtualBounds.Y, _virtualBounds.Width, _virtualBounds.Height },
            VirtualPixelCount = (long)_virtualBounds.Width * _virtualBounds.Height,
            DisplayCount = _displays.Length,
            Displays = _displays,
            UiThreadId = _uiThreadId,
            CaptureThreadId = _captureThreadId,
            CaptureOffUiThread = _captureThreadId is null || _captureThreadId != _uiThreadId,
            CaptureMs = Round(_captureMs),
            OverlayInitializedMs = Round(_overlayInitializedMs),
            FirstFrameMs = Round(_firstFrameMs),
            UiHeartbeatMaxGapMs = Math.Round(_maximumHeartbeatGapMs, 2),
            ManagedPeakDeltaBytes = Math.Max(0, _managedPeak - _managedBaseline),
            WorkingSetPeakDeltaBytes = Math.Max(0, _workingSetPeak - _workingSetBaseline)
        };

        try
        {
            AppPaths.EnsureCreated();
            var line = JsonSerializer.Serialize(payload) + Environment.NewLine;
            lock (WriteGate)
                File.AppendAllText(Path.Combine(AppPaths.Root, "selection-performance.jsonl"), line);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void OnHeartbeat(object? sender, EventArgs e)
    {
        var now = _clock.Elapsed;
        _maximumHeartbeatGapMs = Math.Max(_maximumHeartbeatGapMs, (now - _lastHeartbeat).TotalMilliseconds);
        _lastHeartbeat = now;
        SampleMemory();
    }

    private void SampleMemory()
    {
        _managedPeak = Math.Max(_managedPeak, GC.GetTotalMemory(false));
        using var process = Process.GetCurrentProcess();
        _workingSetPeak = Math.Max(_workingSetPeak, process.WorkingSet64);
    }

    private static string DescribeDisplay(Forms.Screen screen)
    {
        var center = new NativeMethods.PointStruct(
            screen.Bounds.Left + screen.Bounds.Width / 2,
            screen.Bounds.Top + screen.Bounds.Height / 2);
        var monitor = NativeMethods.MonitorFromPoint(center, NativeMethods.MonitorDefaultToNearest);
        var dpi = 96u;
        try
        {
            if (monitor != IntPtr.Zero && NativeMethods.GetDpiForMonitor(
                    monitor, NativeMethods.DpiTypeEffective, out var dpiX, out _) == 0)
                dpi = dpiX;
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        return $"{screen.DeviceName}:{screen.Bounds.X},{screen.Bounds.Y},{screen.Bounds.Width}x{screen.Bounds.Height}@{dpi / 96d:0.##}x";
    }

    private static double? Round(double? value) => value is null ? null : Math.Round(value.Value, 2);

    public void Dispose()
    {
        if (!_completed) Complete("Disposed");
    }
}
