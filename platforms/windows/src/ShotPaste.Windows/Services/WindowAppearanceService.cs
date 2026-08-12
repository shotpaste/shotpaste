using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using ShotPaste.Windows.Interop;

namespace ShotPaste.Windows.Services;

public enum WindowBackdropKind
{
    None,
    Mica,
    Acrylic
}

/// <summary>
/// Centralizes non-client chrome, Windows 11 rounded corners and system backdrops.
/// Windows 10 and transparent capture overlays safely retain the tokenized solid-color fallback.
/// </summary>
public static class WindowAppearanceService
{
    private const int DwmaUseImmersiveDarkMode = 20;
    private const int DwmaWindowCornerPreference = 33;
    private const int DwmaSystemBackdropType = 38;
    private const int DwmaMicaEffect = 1029;
    private const int DwmWindowCornerRound = 2;
    private const int DwmSystemBackdropAuto = 0;
    private const int DwmSystemBackdropMica = 2;
    private const int DwmSystemBackdropAcrylic = 3;

    private static readonly DependencyProperty BackdropProperty = DependencyProperty.RegisterAttached(
        "Backdrop", typeof(WindowBackdropKind), typeof(WindowAppearanceService),
        new PropertyMetadata(WindowBackdropKind.None));

    private static readonly DependencyProperty IsAttachedProperty = DependencyProperty.RegisterAttached(
        "IsAttached", typeof(bool), typeof(WindowAppearanceService), new PropertyMetadata(false));

    public static void Attach(Window window, WindowBackdropKind backdrop = WindowBackdropKind.Mica)
    {
        window.SetValue(BackdropProperty, backdrop);
        if (!(bool)window.GetValue(IsAttachedProperty))
        {
            window.SetValue(IsAttachedProperty, true);
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) && backdrop == WindowBackdropKind.Acrylic)
            {
                // Preserve per-pixel rounded HUDs on Windows 10, where the system backdrop API is unavailable.
                window.AllowsTransparency = true;
                window.WindowStyle = WindowStyle.None;
                window.Background = System.Windows.Media.Brushes.Transparent;
            }
            if (!window.AllowsTransparency)
            {
                window.WindowStyle = WindowStyle.None;
                WindowChrome.SetWindowChrome(window, new WindowChrome
                {
                    CaptionHeight = 0,
                    CornerRadius = new CornerRadius(0),
                    GlassFrameThickness = backdrop == WindowBackdropKind.None
                        ? new Thickness(0)
                        : WindowChrome.GlassFrameCompleteThickness,
                    ResizeBorderThickness = window.ResizeMode is ResizeMode.CanResize or ResizeMode.CanResizeWithGrip
                        ? new Thickness(6)
                        : new Thickness(0),
                    UseAeroCaptionButtons = false
                });
            }
            window.SourceInitialized += OnSourceInitialized;
            window.Activated += OnWindowActivated;
        }

        if (new WindowInteropHelper(window).Handle != IntPtr.Zero) Apply(window);
    }

    public static void RefreshOpenWindows()
    {
        var application = System.Windows.Application.Current;
        if (application is null) return;
        if (!application.Dispatcher.CheckAccess())
        {
            _ = application.Dispatcher.BeginInvoke(RefreshOpenWindows);
            return;
        }

        foreach (Window window in application.Windows)
            if ((bool)window.GetValue(IsAttachedProperty)) Apply(window);
    }

    private static void OnSourceInitialized(object? sender, EventArgs e)
    {
        if (sender is Window window) Apply(window);
    }

    private static void OnWindowActivated(object? sender, EventArgs e)
    {
        if (sender is Window window) Apply(window);
    }

    private static void Apply(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;

        var dark = ThemeService.IsDark ? 1 : 0;
        _ = NativeMethods.DwmSetWindowAttribute(handle, DwmaUseImmersiveDarkMode, ref dark, sizeof(int));

        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            var corner = DwmWindowCornerRound;
            _ = NativeMethods.DwmSetWindowAttribute(handle, DwmaWindowCornerPreference, ref corner, sizeof(int));
        }

        var backdrop = (WindowBackdropKind)window.GetValue(BackdropProperty);
        if (window.AllowsTransparency || backdrop == WindowBackdropKind.None) return;

        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
            window.Background = System.Windows.Media.Brushes.Transparent;
        else
            window.SetResourceReference(Window.BackgroundProperty,
                backdrop == WindowBackdropKind.Acrylic ? "HudBrush" : "WindowBrush");

        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
        {
            var backdropValue = backdrop == WindowBackdropKind.Acrylic
                ? DwmSystemBackdropAcrylic
                : DwmSystemBackdropMica;
            _ = NativeMethods.DwmSetWindowAttribute(handle, DwmaSystemBackdropType, ref backdropValue, sizeof(int));
            var margins = new NativeMethods.Margins(-1);
            _ = NativeMethods.DwmExtendFrameIntoClientArea(handle, ref margins);
        }
        else if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) && backdrop == WindowBackdropKind.Mica)
        {
            var enabled = 1;
            _ = NativeMethods.DwmSetWindowAttribute(handle, DwmaMicaEffect, ref enabled, sizeof(int));
            var margins = new NativeMethods.Margins(-1);
            _ = NativeMethods.DwmExtendFrameIntoClientArea(handle, ref margins);
        }
        else
        {
            var disabled = DwmSystemBackdropAuto;
            _ = NativeMethods.DwmSetWindowAttribute(handle, DwmaSystemBackdropType, ref disabled, sizeof(int));
        }

        if (PresentationSource.FromVisual(window) is HwndSource { CompositionTarget: not null } source)
            source.CompositionTarget.BackgroundColor = Colors.Transparent;
    }
}
