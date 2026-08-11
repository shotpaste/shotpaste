using System.Runtime.InteropServices;
using System.Windows;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class ClipboardTextViewerWindow : Window
{
    private readonly CaptureHistoryItem _item;
    private string? _loadedText;

    public ClipboardTextViewerWindow(CaptureHistoryItem item)
    {
        _item = item;
        InitializeComponent();
        Title = LocalizationService.TranslatePhrase("剪贴板文本");
        CopyButton.Content = LocalizationService.TranslatePhrase("复制全文");
        CloseButton.Content = LocalizationService.TranslatePhrase("关闭");
        LengthText.Text = string.Format(LocalizationService.TranslatePhrase("{0:N0} 个字符"),
            item.TextLength > 0 ? item.TextLength : item.Text?.Length ?? 0);
        StatusText.Text = LocalizationService.TranslatePhrase("正在按需加载完整文本…");
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var result = await _item.LoadFullTextAsync();
        _loadedText = result.Text ?? _item.Text;
        FullText.Text = _loadedText ?? string.Empty;
        CopyButton.IsEnabled = !string.IsNullOrEmpty(_loadedText);
        StatusText.Text = result.Error ?? (result.IsLimited
            ? LocalizationService.TranslatePhrase("已显示受控预览")
            : LocalizationService.TranslatePhrase("完整文本已加载；关闭窗口后不会常驻内存。"));
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_loadedText)) return;
        try
        {
            System.Windows.Clipboard.SetText(_loadedText);
            StatusText.Text = LocalizationService.TranslatePhrase("已复制当前显示文本");
        }
        catch (ExternalException exception)
        {
            StatusText.Text = LocalizationService.TranslatePhrase("剪贴板正被其他应用占用，请稍后重试。") + " " + exception.Message;
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
