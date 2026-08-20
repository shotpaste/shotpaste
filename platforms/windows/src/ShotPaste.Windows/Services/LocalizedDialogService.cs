using System.Windows;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Services;

/// <summary>
/// Single localization boundary for native WPF dialogs and file-picker text.
/// Dynamic and formatted messages are translated at display time so callers
/// cannot accidentally bypass the active language by constructing a string in
/// code-behind.
/// </summary>
public static class LocalizedDialogService
{
    public static string Text(string? source) => LocalizationService.TranslatePhrase(source);

    public static MessageBoxResult Show(
        string message,
        string caption = "ShotPaste",
        MessageBoxButton buttons = MessageBoxButton.OK,
        MessageBoxImage image = MessageBoxImage.None) =>
        ShowCore(null, Text(message), Text(caption), buttons, image);

    public static MessageBoxResult Show(
        Window? owner,
        string message,
        string caption = "ShotPaste",
        MessageBoxButton buttons = MessageBoxButton.OK,
        MessageBoxImage image = MessageBoxImage.None) =>
        ShowCore(owner, Text(message), Text(caption), buttons, image);

    public static MessageBoxResult ShowCustom(
        Window? owner,
        string message,
        string caption,
        string primaryText,
        string secondaryText,
        string tertiaryText,
        MessageBoxImage image = MessageBoxImage.None) =>
        ShowCore(
            owner,
            Text(message),
            Text(caption),
            MessageBoxButton.YesNoCancel,
            image,
            [Text(primaryText), Text(secondaryText), Text(tertiaryText)]);

    public static MessageBoxResult ShowCustom(
        Window? owner,
        string message,
        string caption,
        string primaryText,
        string secondaryText,
        MessageBoxImage image = MessageBoxImage.None) =>
        ShowCore(
            owner,
            Text(message),
            Text(caption),
            MessageBoxButton.YesNo,
            image,
            [Text(primaryText), Text(secondaryText)]);

    private static MessageBoxResult ShowCore(
        Window? owner,
        string message,
        string caption,
        MessageBoxButton buttons,
        MessageBoxImage image,
        IReadOnlyList<string>? customButtonText = null)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess())
            return dispatcher.Invoke(() => ShowCore(owner, message, caption, buttons, image, customButtonText));

        var dialog = new ShotPasteDialogWindow(message, caption, buttons, image, customButtonText);
        if (owner?.IsVisible == true) dialog.Owner = owner;
        else dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        _ = dialog.ShowDialog();
        return dialog.Result;
    }
}
