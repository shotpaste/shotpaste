using System.Windows;
using ShotPaste.Windows.Views;
using Forms = System.Windows.Forms;

namespace ShotPaste.Windows.Services;

public enum ToastKind
{
    Info,
    Success,
    Warning,
    Error
}

public static class ToastService
{
    private static ToastWindow? _current;

    public static void Show(string title, string message, ToastKind kind = ToastKind.Info, TimeSpan? duration = null)
    {
        var application = System.Windows.Application.Current;
        if (application is null) return;
        if (!application.Dispatcher.CheckAccess())
        {
            _ = application.Dispatcher.BeginInvoke(() => Show(title, message, kind, duration));
            return;
        }

        if (_current is null || !_current.IsLoaded)
        {
            _current = new ToastWindow();
            _current.Closed += (_, _) => _current = null;
        }
        _current.Present(title, message, kind, duration ?? TimeSpan.FromSeconds(2.5));
    }

    public static void Show(string title, string message, Forms.ToolTipIcon icon)
    {
        var kind = icon switch
        {
            Forms.ToolTipIcon.Warning => ToastKind.Warning,
            Forms.ToolTipIcon.Error => ToastKind.Error,
            Forms.ToolTipIcon.Info => ToastKind.Success,
            _ => ToastKind.Info
        };
        Show(title, message, kind);
    }

    public static void Dismiss()
    {
        var application = System.Windows.Application.Current;
        if (application is null) return;
        if (!application.Dispatcher.CheckAccess())
        {
            _ = application.Dispatcher.BeginInvoke(Dismiss);
            return;
        }
        _current?.Dismiss();
    }
}
