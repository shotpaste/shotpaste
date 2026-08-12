using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;
using WpfBrush = System.Windows.Media.Brush;
using WpfColor = System.Windows.Media.Color;
using WpfColorConverter = System.Windows.Media.ColorConverter;
using WpfPoint = System.Windows.Point;

namespace ShotPaste.Windows.Views;

public partial class MouseClickOverlayWindow : Window
{
    private System.Drawing.Rectangle _recordingRegion;
    private readonly double _radius;
    private readonly double _opacity;
    private readonly TimeSpan _duration;
    private readonly int _rippleCount;
    private readonly WpfBrush _leftBrush;
    private readonly WpfBrush _rightBrush;
    private bool _closed;

    public MouseClickOverlayWindow(System.Drawing.Rectangle recordingRegion, AppSettings settings)
    {
        InitializeComponent();
        _recordingRegion = recordingRegion;
        _radius = Math.Clamp(settings.RecordingClickRadius, 6d, 96d);
        _opacity = Math.Clamp(settings.RecordingClickOpacity, 0.1d, 1d);
        _duration = TimeSpan.FromMilliseconds(Math.Clamp(settings.RecordingClickDurationMs, 100, 3000));
        _rippleCount = Math.Clamp(settings.RecordingClickRippleCount, 1, 5);
        _leftBrush = CreateBrush(settings.RecordingClickLeftColor, "AccentBrush");
        _rightBrush = CreateBrush(settings.RecordingClickRightColor, "WarningBrush");
        SourceInitialized += (_, _) =>
        {
            ApplyCaptureBounds();
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | NativeMethods.WsExTransparent | NativeMethods.WsExNoActivate | NativeMethods.WsExToolWindow));
        };
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(ApplyCaptureBounds);
        Closed += (_, _) => _closed = true;
    }

    public void UpdateRecordingRegion(System.Drawing.Rectangle recordingRegion)
    {
        _recordingRegion = recordingRegion;
        ApplyCaptureBounds();
    }

    public void Clear() => RippleCanvas.Children.Clear();

    public void ShowClick(System.Drawing.Point screenPoint, bool rightButton)
    {
        if (_closed || !_recordingRegion.Contains(screenPoint)) return;
        if (PresentationSource.FromVisual(this) is not HwndSource source) return;
        ReinforceTopmost(source.Handle);
        var toDip = source.CompositionTarget.TransformFromDevice;
        var screenDip = toDip.Transform(new WpfPoint(screenPoint.X, screenPoint.Y));
        var originDip = toDip.Transform(new WpfPoint(_recordingRegion.Left, _recordingRegion.Top));
        var center = new WpfPoint(screenDip.X - originDip.X, screenDip.Y - originDip.Y);
        var radiusDip = Math.Max(3d, _radius * Math.Min(Math.Abs(toDip.M11), Math.Abs(toDip.M22)));
        for (var index = 0; index < _rippleCount; index++)
            AddRipple(center, radiusDip, rightButton ? _rightBrush : _leftBrush, index);
    }

    private static void ReinforceTopmost(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return;
        NativeMethods.SetWindowPos(
            handle,
            NativeMethods.HwndTopmost,
            0, 0, 0, 0,
            NativeMethods.SwpNoMove |
            NativeMethods.SwpNoSize |
            NativeMethods.SwpNoActivate |
            NativeMethods.SwpShowWindow);
    }

    private void AddRipple(WpfPoint center, double radius, WpfBrush brush, int index)
    {
        var diameter = radius * 2d;
        var ellipse = new Ellipse
        {
            Width = diameter,
            Height = diameter,
            Stroke = brush,
            StrokeThickness = Math.Clamp(radius / 7d, 2d, 7d),
            Fill = new SolidColorBrush(((SolidColorBrush)brush).Color) { Opacity = 0.12 },
            RenderTransformOrigin = new WpfPoint(0.5, 0.5),
            RenderTransform = new ScaleTransform(0.12, 0.12),
            Opacity = 0
        };
        Canvas.SetLeft(ellipse, center.X - radius);
        Canvas.SetTop(ellipse, center.Y - radius);
        RippleCanvas.Children.Add(ellipse);

        var delayFraction = _rippleCount == 1 ? 0d : index * 0.14d;
        var delay = TimeSpan.FromMilliseconds(_duration.TotalMilliseconds * delayFraction);
        var animationDuration = TimeSpan.FromMilliseconds(Math.Max(80d, _duration.TotalMilliseconds - delay.TotalMilliseconds));
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var scale = (ScaleTransform)ellipse.RenderTransform;
        var scaleAnimation = new DoubleAnimation(0.12, 1, animationDuration) { BeginTime = delay, EasingFunction = ease };
        var opacityAnimation = new DoubleAnimationUsingKeyFrames { BeginTime = delay, Duration = animationDuration };
        opacityAnimation.KeyFrames.Add(new LinearDoubleKeyFrame(_opacity, KeyTime.FromPercent(0)));
        opacityAnimation.KeyFrames.Add(new LinearDoubleKeyFrame(_opacity * 0.82, KeyTime.FromPercent(0.42)));
        opacityAnimation.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromPercent(1)));
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, scaleAnimation);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, scaleAnimation);
        opacityAnimation.Completed += (_, _) =>
        {
            if (!_closed) RippleCanvas.Children.Remove(ellipse);
        };
        ellipse.BeginAnimation(OpacityProperty, opacityAnimation);
    }

    private void ApplyCaptureBounds()
    {
        if (PresentationSource.FromVisual(this) is not HwndSource source) return;
        var toDip = source.CompositionTarget.TransformFromDevice;
        var origin = toDip.Transform(new WpfPoint(_recordingRegion.Left, _recordingRegion.Top));
        var corner = toDip.Transform(new WpfPoint(_recordingRegion.Right, _recordingRegion.Bottom));
        Left = origin.X;
        Top = origin.Y;
        Width = Math.Max(1, corner.X - origin.X);
        Height = Math.Max(1, corner.Y - origin.Y);
    }

    private SolidColorBrush CreateBrush(string value, string fallbackResourceKey)
    {
        try { return new SolidColorBrush((WpfColor)WpfColorConverter.ConvertFromString(value)); }
        catch (Exception exception) when (exception is FormatException or NotSupportedException)
        {
            return ((SolidColorBrush)FindResource(fallbackResourceKey)).CloneCurrentValue();
        }
    }
}
