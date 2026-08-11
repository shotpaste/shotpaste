using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Views;

public partial class KeystrokeOverlayWindow : Window
{
    private readonly DispatcherTimer _hideTimer = new();
    private System.Drawing.Rectangle _recordingRegion;
    private readonly string _position;

    internal string VisibilityRule { get; }

    public KeystrokeOverlayWindow(System.Drawing.Rectangle recordingRegion)
        : this(recordingRegion, new AppSettings())
    {
    }

    public KeystrokeOverlayWindow(System.Drawing.Rectangle recordingRegion, AppSettings settings)
    {
        InitializeComponent();
        _position = settings.RecordingKeystrokePosition;
        VisibilityRule = settings.RecordingKeystrokeVisibility;
        GestureText.FontSize = Math.Clamp(settings.RecordingKeystrokeFontSize, 10d, 48d);
        _hideTimer.Interval = TimeSpan.FromMilliseconds(Math.Clamp(settings.RecordingKeystrokeDurationMs, 250, 10000));
        UpdateRecordingRegion(recordingRegion);
        SourceInitialized += (_, _) => ApplyRecordingRegion();
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(ApplyRecordingRegion);
        _hideTimer.Tick += (_, _) => { GesturePanel.Opacity = 0; _hideTimer.Stop(); };
    }

    public void UpdateRecordingRegion(System.Drawing.Rectangle recordingRegion)
    {
        _recordingRegion = recordingRegion;
        ApplyRecordingRegion();
    }

    private void ApplyRecordingRegion()
    {
        var transform = (PresentationSource.FromVisual(this) as HwndSource)?
            .CompositionTarget?.TransformFromDevice ?? System.Windows.Media.Matrix.Identity;
        var topLeft = transform.Transform(new System.Windows.Point(_recordingRegion.Left, _recordingRegion.Top));
        var bottomRight = transform.Transform(new System.Windows.Point(_recordingRegion.Right, _recordingRegion.Bottom));
        var regionWidth = Math.Max(0, bottomRight.X - topLeft.X);
        var regionHeight = Math.Max(0, bottomRight.Y - topLeft.Y);
        var horizontal = _position.EndsWith("Left", StringComparison.OrdinalIgnoreCase)
            ? 28d
            : _position.EndsWith("Right", StringComparison.OrdinalIgnoreCase)
                ? Math.Max(0, regionWidth - Width - 28d)
                : Math.Max(0, (regionWidth - Width) / 2d);
        var vertical = _position.StartsWith("Top", StringComparison.OrdinalIgnoreCase)
            ? 28d
            : Math.Max(0, regionHeight - Height - 28d);
        Left = topLeft.X + horizontal;
        Top = topLeft.Y + vertical;
    }

    public void ShowGesture(string gesture)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero)
            NativeMethods.SetWindowPos(
                handle,
                NativeMethods.HwndTopmost,
                0, 0, 0, 0,
                NativeMethods.SwpNoMove |
                NativeMethods.SwpNoSize |
                NativeMethods.SwpNoActivate |
                NativeMethods.SwpShowWindow);
        GestureText.Text = gesture;
        GesturePanel.Opacity = 1;
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    public void ClearGesture()
    {
        _hideTimer.Stop();
        GesturePanel.Opacity = 0;
    }

    protected override void OnClosed(EventArgs e)
    {
        _hideTimer.Stop();
        base.OnClosed(e);
    }
}
