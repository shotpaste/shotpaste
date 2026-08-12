using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Views;

public partial class ToastWindow : Window
{
    private readonly DispatcherTimer _dismissTimer = new();
    private bool _dismissing;

    public ToastWindow()
    {
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Acrylic);
        _dismissTimer.Tick += (_, _) => Dismiss();
        SourceInitialized += (_, _) =>
        {
            var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | NativeMethods.WsExNoActivate | NativeMethods.WsExToolWindow));
        };
        Closed += (_, _) => _dismissTimer.Stop();
    }

    public void Present(string title, string message, ToastKind kind, TimeSpan duration)
    {
        _dismissing = false;
        TitleText.Text = title;
        MessageText.Text = message;
        MessageText.Visibility = string.IsNullOrWhiteSpace(message) || string.Equals(title, message, StringComparison.Ordinal)
            ? Visibility.Collapsed
            : Visibility.Visible;
        var (iconKey, gradientKey) = kind switch
        {
            ToastKind.Success => ("Icon.Check", "Toast.SuccessGradient"),
            ToastKind.Warning => ("Icon.Warning", "Toast.WarningGradient"),
            ToastKind.Error => ("Icon.Error", "Toast.ErrorGradient"),
            _ => ("Icon.Info", "Toast.InfoGradient")
        };
        IconPath.Data = (Geometry)FindResource(iconKey);
        IconBackground.Background = (System.Windows.Media.Brush)FindResource(gradientKey);

        if (!IsVisible) Show();
        UpdateLayout();
        PositionOnPointerScreen();
        Opacity = 0;
        ToastScale.ScaleX = ToastScale.ScaleY = 0.95;
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));
        var easing = new CubicEase { EasingMode = EasingMode.EaseOut };
        ToastScale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.95, 1, TimeSpan.FromMilliseconds(280)) { EasingFunction = easing });
        ToastScale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.95, 1, TimeSpan.FromMilliseconds(280)) { EasingFunction = easing });

        _dismissTimer.Stop();
        _dismissTimer.Interval = duration < TimeSpan.FromMilliseconds(800) ? TimeSpan.FromMilliseconds(800) : duration;
        _dismissTimer.Start();
    }

    public void Dismiss()
    {
        if (_dismissing || !IsVisible) return;
        _dismissing = true;
        _dismissTimer.Stop();
        var fade = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(160));
        fade.Completed += (_, _) => Close();
        BeginAnimation(OpacityProperty, fade);
    }

    private void PositionOnPointerScreen()
    {
        var workArea = Forms.Screen.FromPoint(Forms.Cursor.Position).WorkingArea;
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        var scale = handle == IntPtr.Zero ? 1d : Math.Max(1d, NativeMethods.GetDpiForWindow(handle) / 96d);
        Left = (workArea.Left + (workArea.Width - ActualWidth * scale) / 2d) / scale;
        Top = (workArea.Top + 36d) / scale;
    }
}
