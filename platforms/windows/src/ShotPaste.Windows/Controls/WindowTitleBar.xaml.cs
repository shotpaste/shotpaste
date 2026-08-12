using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Controls;

public partial class WindowTitleBar : System.Windows.Controls.UserControl
{
    public static readonly DependencyProperty ShowMinimizeProperty = DependencyProperty.Register(
        nameof(ShowMinimize), typeof(bool), typeof(WindowTitleBar), new PropertyMetadata(true));
    public static readonly DependencyProperty ShowMaximizeProperty = DependencyProperty.Register(
        nameof(ShowMaximize), typeof(bool), typeof(WindowTitleBar), new PropertyMetadata(true));
    public static readonly DependencyProperty ShowCloseProperty = DependencyProperty.Register(
        nameof(ShowClose), typeof(bool), typeof(WindowTitleBar), new PropertyMetadata(true));

    public bool ShowMinimize { get => (bool)GetValue(ShowMinimizeProperty); set => SetValue(ShowMinimizeProperty, value); }
    public bool ShowMaximize { get => (bool)GetValue(ShowMaximizeProperty); set => SetValue(ShowMaximizeProperty, value); }
    public bool ShowClose { get => (bool)GetValue(ShowCloseProperty); set => SetValue(ShowCloseProperty, value); }

    public WindowTitleBar()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (Window.GetWindow(this) is not { } window) return;
            window.StateChanged -= OnWindowStateChanged;
            window.StateChanged += OnWindowStateChanged;
            UpdateMaximizeIcon(window);
        };
        Unloaded += (_, _) =>
        {
            if (Window.GetWindow(this) is { } window) window.StateChanged -= OnWindowStateChanged;
        };
    }

    private void OnTitleBarMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (FindAncestor<System.Windows.Controls.Primitives.ButtonBase>(e.OriginalSource as DependencyObject) is not null) return;
        var window = Window.GetWindow(this);
        if (window is null) return;
        if (e.ClickCount == 2 && ShowMaximize && window.ResizeMode is ResizeMode.CanResize or ResizeMode.CanResizeWithGrip)
        {
            ToggleMaximize(window);
            e.Handled = true;
            return;
        }
        if (e.LeftButton != MouseButtonState.Pressed) return;
        try { window.DragMove(); } catch (InvalidOperationException) { }
    }

    private void OnMinimize(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } window) window.WindowState = WindowState.Minimized;
    }

    private void OnMaximize(object sender, RoutedEventArgs e)
    {
        if (Window.GetWindow(this) is { } window) ToggleMaximize(window);
    }

    private void OnClose(object sender, RoutedEventArgs e) => Window.GetWindow(this)?.Close();

    private void OnWindowStateChanged(object? sender, EventArgs e)
    {
        if (sender is Window window) UpdateMaximizeIcon(window);
    }

    private void UpdateMaximizeIcon(Window window)
    {
        MaximizeButton.Content = FindResource(window.WindowState == WindowState.Maximized ? "Icon.Restore" : "Icon.Maximize");
        MaximizeButton.ToolTip = LocalizedDialogService.Text(window.WindowState == WindowState.Maximized ? "还原" : "最大化");
    }

    private static void ToggleMaximize(Window window) =>
        window.WindowState = window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private static T? FindAncestor<T>(DependencyObject? source) where T : DependencyObject
    {
        while (source is not null)
        {
            if (source is T match) return match;
            source = VisualTreeHelper.GetParent(source);
        }
        return null;
    }
}
