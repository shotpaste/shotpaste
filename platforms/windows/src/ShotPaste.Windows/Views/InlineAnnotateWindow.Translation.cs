using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Utilities;

namespace ShotPaste.Windows.Views;

public partial class InlineAnnotateWindow
{
    private CancellationTokenSource? _translationCancellation;

    private void ResetTranslationResult()
    {
        CancelTranslation();
        TranslationResult.Clear();
        TranslationResult.Visibility = TranslationCopyButton.Visibility = Visibility.Collapsed;
    }

    private void InitializeTranslation()
    {
        TranslationSource.ItemsSource = new[] { new LocalizationService.LanguageOption("auto", LocalizationService.TranslatePhrase("自动检测")) }
            .Concat(LocalizationService.SupportedLanguages).ToArray();
        TranslationTarget.ItemsSource = new[] { new LocalizationService.LanguageOption("current", LocalizationService.TranslatePhrase("当前语言")) }
            .Concat(LocalizationService.SupportedLanguages).ToArray();
        TranslationSource.SelectedValue = _settings?.TranslationSourceLanguage ?? "auto";
        TranslationTarget.SelectedValue = _settings?.TranslationTargetLanguage ?? "current";
        if (TranslationSource.SelectedIndex < 0) TranslationSource.SelectedIndex = 0;
        if (TranslationTarget.SelectedIndex < 0) TranslationTarget.SelectedIndex = 0;
    }

    private async void OnTranslateFullScreen(object sender, RoutedEventArgs e) => await TranslateAsync(true);
    private async void OnTranslateSelection(object sender, RoutedEventArgs e) => await TranslateAsync(false);

    private async Task TranslateAsync(bool fullScreen)
    {
        if (_translationCancellation is not null || (!fullScreen && !_annotating)) return;
        using var cancellation = new CancellationTokenSource();
        _translationCancellation = cancellation;
        TranslationActions.IsEnabled = TranslationLanguages.IsEnabled = false;
        TranslationCancelButton.Visibility = Visibility.Visible;
        TranslationResult.Visibility = TranslationCopyButton.Visibility = Visibility.Collapsed;
        TranslationResult.Clear();
        try
        {
            var settings = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(_settings ?? new AppSettings()))!;
            TextTranslationService.Validate(settings);
            var source = TranslationSource.SelectedValue as string ?? "auto";
            var targetChoice = TranslationTarget.SelectedValue as string ?? "current";
            var target = targetChoice == "current" ? LocalizationService.CurrentLanguage : targetChoice;
            if (_settings is not null)
            {
                _settings.TranslationSourceLanguage = source;
                _settings.TranslationTargetLanguage = targetChoice;
                _saveSettings?.Invoke();
            }
            TranslationStatus.Text = LocalizationService.TranslatePhrase("正在识别文字…");
            BitmapSource image = _backdropSource;
            if (!fullScreen)
            {
                var rect = SelectionPixelRect();
                image = new CroppedBitmap(_backdropSource, new Int32Rect(rect.X, rect.Y, rect.Width, rect.Height));
            }
            using var bitmap = BitmapSourceFactory.ToBitmap(image);
            var text = await new OcrService(() => source).RecognizeTranslationTextAsync(bitmap);
            cancellation.Token.ThrowIfCancellationRequested();
            TranslationStatus.Text = LocalizationService.TranslatePhrase("正在翻译…");
            var translated = await new TextTranslationService().TranslateAsync(text, settings, source, target, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            TranslationResult.Text = translated;
            TranslationResult.Visibility = TranslationCopyButton.Visibility = Visibility.Visible;
            TranslationStatus.Text = LocalizationService.TranslatePhrase("翻译完成");
        }
        catch (OperationCanceledException)
        {
            TranslationStatus.Text = LocalizationService.TranslatePhrase(cancellation.IsCancellationRequested ? "翻译已取消。" : "翻译超时，请重试。");
        }
        catch (InvalidOperationException exception) when (exception.Message is
            "请先配置 LLM 供应商、模型和 API Key。" or "请在 AI 翻译设置中允许发送识别文字。" or
            "未识别到可翻译的文字。" or "识别文字过多，请缩小选区后重试。")
        {
            TranslationStatus.Text = LocalizationService.TranslatePhrase(exception.Message);
        }
        catch (Exception)
        {
            // Provider bodies may contain credentials or recognized content: never display/log them.
            TranslationStatus.Text = LocalizationService.TranslatePhrase("翻译失败，请检查供应商配置、网络或 OCR 语言包后重试。");
        }
        finally
        {
            if (ReferenceEquals(_translationCancellation, cancellation)) _translationCancellation = null;
            TranslationActions.IsEnabled = TranslationLanguages.IsEnabled = true;
            TranslationCancelButton.Visibility = Visibility.Collapsed;
            PositionOneShotModePanel();
        }
    }

    private void CancelTranslation() => _translationCancellation?.Cancel();
    private void OnCancelTranslation(object sender, RoutedEventArgs e) => CancelTranslation();
    private void OnTranslationLanguageChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e) => ResetTranslationResult();
    private void OnCopyTranslation(object sender, RoutedEventArgs e)
    {
        try { if (!string.IsNullOrWhiteSpace(TranslationResult.Text)) System.Windows.Clipboard.SetText(TranslationResult.Text); }
        catch (System.Runtime.InteropServices.COMException) { ShowStatus("剪贴板正忙，请重试"); }
    }
    private void OnTranslationSettings(object sender, RoutedEventArgs e)
    {
        CancelTranslation();
        TranslationSettingsRequested = true;
        RequestCancel();
    }
    public bool TranslationSettingsRequested { get; private set; }
}
