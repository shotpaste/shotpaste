using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class ShotPasteDialogWindow : Window
{
    private readonly MessageBoxButton _buttons;
    private bool _completing;

    public MessageBoxResult Result { get; private set; } = MessageBoxResult.None;

    public ShotPasteDialogWindow(string message, string caption, MessageBoxButton buttons, MessageBoxImage image)
    {
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        Title = caption;
        MessageText.Text = message;
        _buttons = buttons;
        ConfigureIcon(image);
        ConfigureButtons(buttons);
        Closing += OnClosing;
    }

    private void ConfigureIcon(MessageBoxImage image)
    {
        var (iconKey, gradientKey) = image switch
        {
            MessageBoxImage.Warning => ("Icon.Warning", "Toast.WarningGradient"),
            MessageBoxImage.Error => ("Icon.Error", "Toast.ErrorGradient"),
            MessageBoxImage.Question => ("Icon.Info", "Toast.InfoGradient"),
            _ => ("Icon.Info", "Toast.InfoGradient")
        };
        IconPath.Data = (Geometry)FindResource(iconKey);
        IconBackground.Background = (System.Windows.Media.Brush)FindResource(gradientKey);
    }

    private void ConfigureButtons(MessageBoxButton buttons)
    {
        switch (buttons)
        {
            case MessageBoxButton.OKCancel:
                Configure(PrimaryButton, "确定", MessageBoxResult.OK, true, false);
                Configure(SecondaryButton, "取消", MessageBoxResult.Cancel, false, true);
                break;
            case MessageBoxButton.YesNo:
                Configure(PrimaryButton, "是", MessageBoxResult.Yes, true, false);
                Configure(SecondaryButton, "否", MessageBoxResult.No, false, true);
                break;
            case MessageBoxButton.YesNoCancel:
                Configure(PrimaryButton, "是", MessageBoxResult.Yes, true, false);
                Configure(SecondaryButton, "否", MessageBoxResult.No, false, false);
                Configure(TertiaryButton, "取消", MessageBoxResult.Cancel, false, true);
                break;
            default:
                Configure(PrimaryButton, "确定", MessageBoxResult.OK, true, true);
                break;
        }
    }

    private static void Configure(System.Windows.Controls.Button button, string text, MessageBoxResult result, bool isDefault, bool isCancel)
    {
        button.Content = LocalizedDialogService.Text(text);
        button.Tag = result;
        button.IsDefault = isDefault;
        button.IsCancel = isCancel;
        button.Visibility = Visibility.Visible;
    }

    private void OnPrimary(object sender, RoutedEventArgs e) => Complete((MessageBoxResult)PrimaryButton.Tag);
    private void OnSecondary(object sender, RoutedEventArgs e) => Complete((MessageBoxResult)SecondaryButton.Tag);
    private void OnTertiary(object sender, RoutedEventArgs e) => Complete((MessageBoxResult)TertiaryButton.Tag);

    private void Complete(MessageBoxResult result)
    {
        Result = result;
        _completing = true;
        DialogResult = true;
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_completing) return;
        Result = _buttons switch
        {
            MessageBoxButton.OKCancel or MessageBoxButton.YesNoCancel => MessageBoxResult.Cancel,
            MessageBoxButton.YesNo => MessageBoxResult.No,
            _ => MessageBoxResult.OK
        };
    }
}
