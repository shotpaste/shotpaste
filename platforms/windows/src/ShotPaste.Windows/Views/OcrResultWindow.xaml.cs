using System.Diagnostics;
using System.Windows;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class OcrResultWindow : Window
{
    private readonly OcrRecognitionResult _result;

    public OcrResultWindow(OcrRecognitionResult result)
    {
        _result = result;
        InitializeComponent();
        DataContext = result;
    }

    private void OnOpenLink(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button { Tag: string value } || string.IsNullOrWhiteSpace(value)) return;
        var target = value.Contains('@') && !value.Contains("://", StringComparison.Ordinal)
            ? "mailto:" + value
            : value.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + value : value;
        if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https" or "mailto")) return;
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }

    private void OnCopy(object sender, RoutedEventArgs e) => System.Windows.Clipboard.SetText(_result.Text);
    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
