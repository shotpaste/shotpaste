using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class ShotPasteDialogWindow : Window
{
    private readonly MessageBoxButton _buttons;
    private bool _completing;

    public MessageBoxResult Result { get; private set; } = MessageBoxResult.None;

    public ShotPasteDialogWindow(
        string message,
        string caption,
        MessageBoxButton buttons,
        MessageBoxImage image,
        IReadOnlyList<string>? customButtonText = null)
    {
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        Title = caption;
        MessageText.Text = message;
        _buttons = buttons;
        ConfigureIcon(image);
        ConfigureButtons(buttons, customButtonText);
        FitLocalizedChrome(caption);
        Closing += OnClosing;
    }

    private void FitLocalizedChrome(string caption)
    {
        var requiredButtonWidth = 36d;
        foreach (var button in new[] { TertiaryButton, SecondaryButton, PrimaryButton }
                     .Where(button => button.Visibility == Visibility.Visible))
        {
            button.Measure(new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity));
            requiredButtonWidth += button.DesiredSize.Width + button.Margin.Left + button.Margin.Right;
        }

        var displayedTitle = AppBuildIdentity.Current.FormatWindowTitle(caption);
        var titleTypeface = new Typeface(
            System.Windows.SystemFonts.MessageFontFamily,
            FontStyles.Normal,
            FontWeights.SemiBold,
            FontStretches.Normal);
        var titleMeasurement = new FormattedText(
            displayedTitle,
            CultureInfo.CurrentUICulture,
            System.Windows.FlowDirection.LeftToRight,
            titleTypeface,
            System.Windows.SystemFonts.MessageFontSize,
            System.Windows.Media.Brushes.Black,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
        const double titleIconAndCloseAllowance = 112d;
        var requiredTitleWidth = titleMeasurement.WidthIncludingTrailingWhitespace + titleIconAndCloseAllowance;
        Width = Math.Clamp(Math.Ceiling(Math.Max(requiredButtonWidth, requiredTitleWidth)), MinWidth, MaxWidth);
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

    private void ConfigureButtons(MessageBoxButton buttons, IReadOnlyList<string>? customButtonText)
    {
        string Label(int index, string fallback) => customButtonText is not null && customButtonText.Count > index
            ? customButtonText[index]
            : fallback;
        switch (buttons)
        {
            case MessageBoxButton.OKCancel:
                Configure(PrimaryButton, Label(0, "确定"), MessageBoxResult.OK, true, false);
                Configure(SecondaryButton, Label(1, "取消"), MessageBoxResult.Cancel, false, true);
                break;
            case MessageBoxButton.YesNo:
                Configure(PrimaryButton, Label(0, "是"), MessageBoxResult.Yes, true, false);
                Configure(SecondaryButton, Label(1, "否"), MessageBoxResult.No, false, true);
                break;
            case MessageBoxButton.YesNoCancel:
                Configure(PrimaryButton, Label(0, "是"), MessageBoxResult.Yes, true, false);
                Configure(SecondaryButton, Label(1, "否"), MessageBoxResult.No, false, false);
                Configure(TertiaryButton, Label(2, "取消"), MessageBoxResult.Cancel, false, true);
                break;
            default:
                Configure(PrimaryButton, Label(0, "确定"), MessageBoxResult.OK, true, true);
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
