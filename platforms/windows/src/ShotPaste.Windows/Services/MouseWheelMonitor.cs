using System.Diagnostics;
using System.Runtime.InteropServices;
using Drawing = System.Drawing;
using ShotPaste.Windows.Interop;

namespace ShotPaste.Windows.Services;

/// <summary>
/// Tracks mouse-wheel activity over the scrolling capture region using a low-level
/// mouse hook. Mirrors the macOS scroll monitor: captures are triggered by wheel
/// input instead of a blind polling loop, so scrolling that no longer moves content
/// (for example at the end of a page) does not keep producing screenshots.
/// Must be started on a thread with a message pump (the WPF UI thread).
/// </summary>
public sealed class MouseWheelMonitor : IDisposable
{
    internal const int ScrollHitSlop = 32;

    private readonly NativeMethods.LowLevelMouseProc _callback;
    private readonly object _sync = new();
    private IntPtr _hook;
    private Drawing.Rectangle _region;
    private long _wheelSequence;
    private long _lastWheelTimestamp;
    private long _cumulativeWheelDelta;
    private long _positiveWheelEvents;
    private long _negativeWheelEvents;
    private int _lastWheelDirection;

    public MouseWheelMonitor()
    {
        _callback = OnLowLevelMouse;
    }

    public bool IsActive { get; private set; }
    public event Action? WheelObserved;

    public MouseWheelSnapshot Snapshot
    {
        get
        {
            lock (_sync)
            {
                return new MouseWheelSnapshot(
                    _wheelSequence,
                    _lastWheelTimestamp,
                    _cumulativeWheelDelta,
                    _positiveWheelEvents,
                    _negativeWheelEvents,
                    _lastWheelDirection);
            }
        }
    }

    public bool Start(Drawing.Rectangle region)
    {
        Stop();
        _region = region;
        lock (_sync)
        {
            _wheelSequence = 0;
            _lastWheelTimestamp = 0;
            _cumulativeWheelDelta = 0;
            _positiveWheelEvents = 0;
            _negativeWheelEvents = 0;
            _lastWheelDirection = 0;
        }
        _hook = NativeMethods.SetWindowsHookEx(
            NativeMethods.WhMouseLl, _callback, NativeMethods.GetModuleHandle(null), 0);
        IsActive = _hook != IntPtr.Zero;
        return IsActive;
    }

    public bool HasWheelSince(long sequenceNumber)
    {
        lock (_sync) return _wheelSequence > sequenceNumber;
    }

    private IntPtr OnLowLevelMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0)
            {
                var message = wParam.ToInt32();
                // Horizontal wheel input must not drive a vertical stitch session.
                // Precision touchpads commonly emit both messages during a diagonal
                // gesture; treating WM_MOUSEHWHEEL as vertical creates false boundary
                // detections while the selected content has not moved vertically.
                if (IsVerticalWheelMessage(message))
                {
                    var data = Marshal.PtrToStructure<NativeMethods.MouseHookData>(lParam);
                    if (IsInsideScrollRegion(data.Point, _region))
                    {
                        var delta = unchecked((short)((data.MouseData >> 16) & 0xFFFF));
                        if (delta != 0)
                        {
                            Action? wheelObserved;
                            lock (_sync)
                            {
                                _wheelSequence++;
                                _lastWheelTimestamp = Stopwatch.GetTimestamp();
                                _cumulativeWheelDelta += delta;
                                if (delta > 0) _positiveWheelEvents++;
                                else _negativeWheelEvents++;
                                _lastWheelDirection = Math.Sign(delta);
                                wheelObserved = WheelObserved;
                            }
                            wheelObserved?.Invoke();
                        }
                    }
                }
            }
        }
        catch
        {
            // A hook callback must never throw into the system.
        }
        return NativeMethods.CallNextHookEx(_hook, code, wParam, lParam);
    }

    internal static bool IsInsideScrollRegion(
        NativeMethods.PointStruct point,
        Drawing.Rectangle region,
        int slop = ScrollHitSlop)
    {
        return point.X >= region.Left - slop
            && point.X <= region.Right + slop
            && point.Y >= region.Top - slop
            && point.Y <= region.Bottom + slop;
    }

    internal static bool IsVerticalWheelMessage(int message) => message == NativeMethods.WmMouseWheel;

    public void Stop()
    {
        if (_hook != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        IsActive = false;
    }

    public void Dispose() => Stop();
}

public readonly record struct MouseWheelSnapshot(
    long SequenceNumber,
    long Timestamp,
    long CumulativeDelta,
    long PositiveEventCount,
    long NegativeEventCount,
    int Direction);
