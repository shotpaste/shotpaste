using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Drawing = System.Drawing;
using LiteScreen.Windows.Interop;

namespace LiteScreen.Windows.Views;

public partial class ScrollingRegionOverlayWindow : Window
{
    private readonly Drawing.Rectangle _region;
    private readonly Drawing.Rectangle _virtualBounds;

    public ScrollingRegionOverlayWindow(Drawing.Rectangle region, Drawing.Rectangle virtualBounds)
    {
        InitializeComponent();
        ShowInTaskbar = App.UiTestMode;
        _region = region;
        _virtualBounds = virtualBounds;
        Left = virtualBounds.Left;
        Top = virtualBounds.Top;
        Width = virtualBounds.Width;
        Height = virtualBounds.Height;
        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var source = (HwndSource)PresentationSource.FromVisual(this);
        var toDip = source.CompositionTarget.TransformFromDevice;
        var origin = toDip.Transform(new System.Windows.Point(_virtualBounds.Left, _virtualBounds.Top));
        var size = toDip.Transform(new System.Windows.Point(_virtualBounds.Width, _virtualBounds.Height));
        Left = origin.X;
        Top = origin.Y;
        Width = size.X;
        Height = size.Y;

        var handle = new WindowInteropHelper(this).Handle;
        var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
        var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
        NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
            new IntPtr(style | NativeMethods.WsExTransparent | toolWindowStyle | NativeMethods.WsExNoActivate));
        NativeMethods.SetWindowDisplayAffinity(handle, NativeMethods.WdaExcludeFromCapture);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        OverlayCanvas.Width = ActualWidth;
        OverlayCanvas.Height = ActualHeight;
        var scaleX = ActualWidth / _virtualBounds.Width;
        var scaleY = ActualHeight / _virtualBounds.Height;
        var rect = new Rect(
            (_region.Left - _virtualBounds.Left) * scaleX,
            (_region.Top - _virtualBounds.Top) * scaleY,
            _region.Width * scaleX,
            _region.Height * scaleY);
        const double thickness = 4;
        SetRect(TopLine, new Rect(rect.Left - thickness, rect.Top - thickness, rect.Width + thickness * 2, thickness));
        SetRect(RightLine, new Rect(rect.Right, rect.Top, thickness, rect.Height));
        SetRect(BottomLine, new Rect(rect.Left - thickness, rect.Bottom, rect.Width + thickness * 2, thickness));
        SetRect(LeftLine, new Rect(rect.Left - thickness, rect.Top, thickness, rect.Height));

        StatusBadge.Measure(new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity));
        var badgeLeft = Math.Clamp(rect.Left, 8, Math.Max(8, ActualWidth - StatusBadge.DesiredSize.Width - 8));
        var above = rect.Top - StatusBadge.DesiredSize.Height - 8;
        var below = rect.Bottom + 8;
        if (above >= 8 || below + StatusBadge.DesiredSize.Height <= ActualHeight - 8)
        {
            Canvas.SetLeft(StatusBadge, badgeLeft);
            Canvas.SetTop(StatusBadge, above >= 8 ? above : below);
        }
        else StatusBadge.Visibility = Visibility.Collapsed;
    }

    private static void SetRect(FrameworkElement element, Rect rect)
    {
        Canvas.SetLeft(element, rect.Left);
        Canvas.SetTop(element, rect.Top);
        element.Width = Math.Max(0, rect.Width);
        element.Height = Math.Max(0, rect.Height);
    }
}
