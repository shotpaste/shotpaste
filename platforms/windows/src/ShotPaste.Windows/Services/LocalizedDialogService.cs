using System.Windows;

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
        System.Windows.MessageBox.Show(Text(message), Text(caption), buttons, image);

    public static MessageBoxResult Show(
        Window? owner,
        string message,
        string caption = "ShotPaste",
        MessageBoxButton buttons = MessageBoxButton.OK,
        MessageBoxImage image = MessageBoxImage.None) => owner is null
        ? System.Windows.MessageBox.Show(Text(message), Text(caption), buttons, image)
        : System.Windows.MessageBox.Show(owner, Text(message), Text(caption), buttons, image);
}
