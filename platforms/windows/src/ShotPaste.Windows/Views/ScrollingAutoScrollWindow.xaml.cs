using System.ComponentModel;
using System.Windows;
using System.Windows.Interop;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Views;

public partial class ScrollingAutoScrollWindow : Window
{
    public event EventHandler? ToggleRequested;

    public bool IsAutoScrollEnabled { get; private set; }

    private Drawing.Rectangle? _captureRegion;
    private bool _capturing;
    private bool _allowClose;

    public ScrollingAutoScrollWindow()
    {
        InitializeComponent();
        ShowInTaskbar = App.UiTestMode;
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
            NativeMethods.SetWindowLongPtr(
                handle,
                NativeMethods.GwlExStyle,
                new IntPtr(style | toolWindowStyle | NativeMethods.WsExNoActivate));
            if (!App.UiTestMode) WindowCaptureExclusionService.ExcludeCaptureControl(handle);
            ApplyPhysicalPlacement();
        };
        SizeChanged += (_, _) => ApplyPhysicalPlacement();
        Closing += OnClosing;
    }

    public void ShowForCapture(Drawing.Rectangle region)
    {
        _captureRegion = region;
        _capturing = true;
        IsAutoScrollEnabled = false;
        ToggleIcon.Content = FindResource("Icon.Resume");
        ToggleLabel.Text = LocalizationService.TranslatePhrase("自动滚动");
        ToggleButton.IsEnabled = false;
        if (!IsVisible) Show();
        ApplyPhysicalPlacement();
    }

    public void PositionInside(Drawing.Rectangle region)
    {
        _captureRegion = region;
        ApplyPhysicalPlacement();
    }

    public void UpdateProgress(ScrollingCaptureProgress progress)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => UpdateProgress(progress));
            return;
        }
        if (!_capturing) return;
        ToggleButton.IsEnabled = progress.Frames > 0 &&
                                 progress.PreviewTruth is not (ScrollingPreviewTruth.Finalizing or ScrollingPreviewTruth.Saving);
    }

    public void StopAndHide()
    {
        _capturing = false;
        IsAutoScrollEnabled = false;
        ToggleIcon.Content = FindResource("Icon.Resume");
        ToggleLabel.Text = LocalizationService.TranslatePhrase("自动滚动");
        ToggleButton.IsEnabled = false;
        if (IsVisible) Hide();
    }

    internal void CloseAfterWorkflow()
    {
        _allowClose = true;
        Close();
    }

    private void OnToggle(object sender, RoutedEventArgs e)
    {
        if (!_capturing || !ToggleButton.IsEnabled) return;
        IsAutoScrollEnabled = !IsAutoScrollEnabled;
        ToggleIcon.Content = FindResource(IsAutoScrollEnabled ? "Icon.Stop" : "Icon.Resume");
        ToggleLabel.Text = LocalizationService.TranslatePhrase(IsAutoScrollEnabled ? "停止" : "自动滚动");
        ToggleRequested?.Invoke(this, EventArgs.Empty);
        ApplyPhysicalPlacement();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        StopAndHide();
    }

    private void ApplyPhysicalPlacement()
    {
        if (_captureRegion is not { } region || ActualWidth <= 0 || ActualHeight <= 0 ||
            PresentationSource.FromVisual(this) is not HwndSource source) return;
        var handle = source.Handle;
        if (handle == IntPtr.Zero) return;
        var dpi = Math.Max(96u, NativeMethods.GetDpiForWindow(handle));
        var size = new Drawing.Size(
            Math.Max(1, (int)Math.Ceiling(ActualWidth * dpi / 96d)),
            Math.Max(1, (int)Math.Ceiling(ActualHeight * dpi / 96d)));
        var placement = ResolvePhysicalPlacement(
            region,
            Forms.Screen.FromRectangle(region).WorkingArea,
            size);
        NativeMethods.SetWindowPos(
            handle,
            NativeMethods.HwndTopmost,
            placement.X,
            placement.Y,
            placement.Width,
            placement.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpNoOwnerZOrder);
    }

    internal static Drawing.Rectangle ResolvePhysicalPlacement(
        Drawing.Rectangle capture,
        Drawing.Rectangle workingArea,
        Drawing.Size windowSize,
        int horizontalInset = 12,
        int bottomInset = 14)
    {
        var preferredX = capture.Left + (capture.Width - windowSize.Width) / 2;
        var x = Math.Clamp(
            preferredX,
            workingArea.Left + horizontalInset,
            Math.Max(workingArea.Left + horizontalInset, workingArea.Right - windowSize.Width - horizontalInset));
        var preferredY = capture.Bottom - windowSize.Height - bottomInset;
        var y = Math.Clamp(
            preferredY,
            Math.Max(workingArea.Top + bottomInset, capture.Top + bottomInset),
            Math.Max(workingArea.Top + bottomInset, workingArea.Bottom - windowSize.Height - bottomInset));
        return new Drawing.Rectangle(x, y, windowSize.Width, windowSize.Height);
    }
}
