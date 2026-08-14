using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;
using WpfButton = System.Windows.Controls.Button;

namespace ShotPaste.Windows.Views;

public partial class PinnedImageWindow : Window
{
    private readonly BitmapSource _source;
    private readonly string? _sourcePath;
    private readonly Action? _onClosed;
    private HwndSource? _windowSource;
    private bool _locked;
    private bool _ready;
    private const int WmNcHitTest = 0x0084;
    private const int HtTransparent = -1;

    public PinnedImageWindow(BitmapSource source, string? sourcePath = null, Action? onClosed = null)
    {
        InitializeComponent();
        _source = source;
        _sourcePath = sourcePath;
        _onClosed = onClosed;
        PinnedImage.Source = source;
        var scale = Math.Min(1d, Math.Min(720d / source.PixelWidth, 520d / source.PixelHeight));
        SetScale(scale, animate: false);
        // The initial fit-to-screen scale is usually not one of the fixed presets.
        // Keep its real percentage visible without selecting a different value;
        // otherwise selecting that highlighted preset would not raise SelectionChanged.
        ZoomPicker.SelectedIndex = -1;
        ZoomPicker.Text = $"{scale * 100:0}%";
        _ready = true;
        ShowInTaskbar = App.UiTestMode;
        SourceInitialized += (_, _) =>
        {
            _windowSource = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
            _windowSource?.AddHook(WindowProcedure);
        };
        Closed += (_, _) =>
        {
            _windowSource?.RemoveHook(WindowProcedure);
            _windowSource = null;
            _onClosed?.Invoke();
        };
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_locked) return;
        var factor = e.Delta > 0 ? 1.12 : 1 / 1.12;
        SetWindowSize(Width * factor, Height * factor, animate: true);
        e.Handled = true;
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (_locked || e.ChangedButton != MouseButton.Left || IsButton(e.OriginalSource as DependencyObject)) return;
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
        else if (e.Key == Key.L) ToggleLock();
    }

    private void OnToggleLock(object sender, RoutedEventArgs e) => ToggleLock();

    private void ToggleLock()
    {
        _locked = !_locked;
        ResizeMode = _locked ? ResizeMode.NoResize : ResizeMode.CanResizeWithGrip;
        LockButton.Content = LocalizationService.TranslatePhrase(_locked ? "解锁" : "锁定");
        UnlockedControls.Visibility = _locked ? Visibility.Collapsed : Visibility.Visible;
        LockButton.ToolTip = LocalizationService.TranslatePhrase(_locked
            ? "解锁并恢复图片区域交互"
            : "锁定后图片区域自动穿透；锁按钮保持可操作");
    }

    public void RestoreInteraction()
    {
        if (_locked) ToggleLock();
        Activate();
    }

    private void OnZoomPresetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || _locked ||
            !double.TryParse(ZoomPicker.SelectedValue?.ToString(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var scale)) return;
        SetScale(scale, animate: true);
    }

    private IntPtr WindowProcedure(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmNcHitTest || !_locked) return IntPtr.Zero;
        NativeMethods.GetCursorPos(out var cursor);
        var point = LockButton.PointFromScreen(new System.Windows.Point(cursor.X, cursor.Y));
        if (point.X >= 0 && point.Y >= 0 && point.X <= LockButton.ActualWidth && point.Y <= LockButton.ActualHeight)
            return IntPtr.Zero;
        handled = true;
        return new IntPtr(HtTransparent);
    }

    private void SetScale(double scale, bool animate)
    {
        // A percentage preset describes source pixels, not WPF device-independent
        // units. Compensate for the target monitor DPI so 100% remains 1 image
        // pixel to 1 physical screen pixel on 125%/150% displays as well.
        var (dpiX, dpiY) = ResolveDpiScale();
        SetWindowSize(
            _source.PixelWidth * scale / dpiX,
            _source.PixelHeight * scale / dpiY,
            animate);
    }

    private void SetWindowSize(double width, double height, bool animate)
    {
        var workArea = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
        var (dpiX, dpiY) = ResolveDpiScale();
        var maximumWidth = Math.Max(180, workArea.Width * 0.95 / dpiX);
        var maximumHeight = Math.Max(120, workArea.Height * 0.95 / dpiY);
        var aspect = _source.PixelWidth / (double)Math.Max(1, _source.PixelHeight);
        width = Math.Clamp(width, 180, maximumWidth);
        height = width / aspect;
        if (height > maximumHeight)
        {
            height = maximumHeight;
            width = Math.Max(180, height * aspect);
        }
        if (!animate)
        {
            Width = width;
            Height = height;
            return;
        }
        BeginAnimation(WidthProperty, new DoubleAnimation(width, TimeSpan.FromMilliseconds(120)) { EasingFunction = new QuadraticEase() });
        BeginAnimation(HeightProperty, new DoubleAnimation(height, TimeSpan.FromMilliseconds(120)) { EasingFunction = new QuadraticEase() });
    }

    private (double X, double Y) ResolveDpiScale()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero)
        {
            var windowDpi = NativeMethods.GetDpiForWindow(handle);
            if (windowDpi > 0) return (windowDpi / 96d, windowDpi / 96d);
        }

        var cursor = System.Windows.Forms.Cursor.Position;
        var monitor = NativeMethods.MonitorFromPoint(
            new NativeMethods.PointStruct(cursor.X, cursor.Y),
            NativeMethods.MonitorDefaultToNearest);
        if (monitor != IntPtr.Zero &&
            NativeMethods.GetDpiForMonitor(monitor, NativeMethods.DpiTypeEffective, out var dpiX, out var dpiY) == 0 &&
            dpiX > 0 && dpiY > 0)
            return (dpiX / 96d, dpiY / 96d);

        var visualDpi = System.Windows.Media.VisualTreeHelper.GetDpi(this);
        return (Math.Max(1d, visualDpi.DpiScaleX), Math.Max(1d, visualDpi.DpiScaleY));
    }

    private void OnDragOut(object sender, MouseButtonEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_sourcePath) || !File.Exists(_sourcePath)) return;
        var data = new System.Windows.DataObject(System.Windows.DataFormats.FileDrop, new[] { Path.GetFullPath(_sourcePath) });
        System.Windows.DragDrop.DoDragDrop(this, data, System.Windows.DragDropEffects.Copy);
        e.Handled = true;
    }

    private void OnCopy(object sender, RoutedEventArgs e) => ClipboardWriter.SetImage(_source);

    private void OnSave(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = LocalizedDialogService.Text("保存贴图"),
            FileName = $"ShotPaste-Pinned-{DateTime.Now:yyyyMMdd-HHmmss}.png",
            DefaultExt = ".png",
            Filter = LocalizedDialogService.Text("PNG 图片|*.png")
        };
        if (dialog.ShowDialog() != true) return;
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(_source));
        using var stream = File.Create(dialog.FileName);
        encoder.Save(stream);
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    private static bool IsButton(DependencyObject? source)
    {
        var current = source;
        while (current is not null)
        {
            if (current is WpfButton) return true;
            current = System.Windows.Media.VisualTreeHelper.GetParent(current);
        }
        return false;
    }
}
