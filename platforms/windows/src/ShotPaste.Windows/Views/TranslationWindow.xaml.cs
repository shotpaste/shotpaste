using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Utilities;

namespace ShotPaste.Windows.Views;

public partial class TranslationWindow : Window
{
    private readonly BitmapSource _selection;
    private readonly BitmapSource _screen;
    private readonly Func<AppSettings> _settingsProvider;
    private readonly Action<Window>? _openSettings;
    private CancellationTokenSource? _request;
    private bool _closed;
    private BitmapSource? _rendered;
    private BitmapSource? _recognizedSource;
    private string? _recognizedLanguage;
    private IReadOnlyList<TranslationSourceRegion>? _regions;

    public TranslationWindow(BitmapSource selection, BitmapSource screen, Func<AppSettings> settingsProvider, Action<Window>? openSettings = null)
    {
        _selection = selection;
        _screen = screen;
        _settingsProvider = settingsProvider;
        _openSettings = openSettings;
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        SourceLanguage.ItemsSource = new[] { new LocalizationService.LanguageOption("auto", L("one-shot.translation-automatic-language")) }
            .Concat(LocalizationService.SupportedLanguages).ToArray();
        TargetLanguage.ItemsSource = LocalizationService.SupportedLanguages;
        SourceLanguage.SelectedValue = "auto";
        TargetLanguage.SelectedValue = LocalizationService.CurrentLanguage;
        Preview.Source = _selection;
        OpenSettings.IsEnabled = openSettings is not null;
        if (!settingsProvider().TranslationSendRecognizedText)
            Status.Text = L("agent.translation-send-recognized-text-disabled");
        Loaded += (_, _) => WindowAppearanceService.ConstrainToWorkingArea(this);
        Closed += (_, _) => { _closed = true; _request?.Cancel(); };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            if (_request is not null) _request.Cancel(); else Close();
            e.Handled = true;
        };
    }

    private static string L(string key) => LocalizationService.Text(LocalizationService.CurrentLanguage, key);
    private async void OnTranslateSelection(object sender, RoutedEventArgs e) => await TranslateAsync(_selection);
    private async void OnTranslateScreen(object sender, RoutedEventArgs e) => await TranslateAsync(_screen);
    private void OnCancel(object sender, RoutedEventArgs e) => _request?.Cancel();
    private void OnClose(object sender, RoutedEventArgs e) => Close();
    private void OnOpenSettings(object sender, RoutedEventArgs e) => _openSettings?.Invoke(this);

    private async Task TranslateAsync(BitmapSource source)
    {
        if (_request is not null || _closed) return;
        var settings = _settingsProvider();
        if (!settings.TranslationSendRecognizedText)
        { Status.Text = L("agent.translation-send-recognized-text-disabled"); return; }
        using var request = new CancellationTokenSource();
        _request = request;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(request.Token);
        deadline.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(settings.TranslationTimeoutSeconds, 5, 120)));
        SetBusy(true);
        // Never label an earlier language or scope's result as the new result.
        _rendered = null;
        CopyImage.IsEnabled = CopyText.IsEnabled = false;
        TranslatedText.Clear();
        Preview.Source = source;
        try
        {
            var sourceLanguage = SourceLanguage.SelectedValue as string ?? "auto";
            var targetLanguage = TargetLanguage.SelectedValue as string ?? "en-US";
            if (!ReferenceEquals(source, _recognizedSource) || sourceLanguage != _recognizedLanguage || _regions is null)
            {
                OriginalText.Clear();
                Status.Text = L("one-shot.translation-recognizing-text");
                using var bitmap = BitmapSourceFactory.ToBitmap(source);
                var regions = await TranslationOcrService.RecognizeAsync(bitmap, sourceLanguage, deadline.Token);
                deadline.Token.ThrowIfCancellationRequested();
                _regions = regions;
                _recognizedSource = source;
                _recognizedLanguage = sourceLanguage;
            }
            OriginalText.Text = string.Join(Environment.NewLine, _regions.Select(region => region.Text));
            Status.Text = L("one-shot.translation-translating-text");
            var result = await new TextTranslationService().TranslateAsync(
                _regions.Select(region => new TranslationTextBlock(region.Id, region.Text)).ToArray(),
                sourceLanguage, targetLanguage, settings, deadline.Token);
            deadline.Token.ThrowIfCancellationRequested();
            if (_closed) return;
            Status.Text = L("one-shot.translation-laying-out");
            var rendered = TranslationResultRenderer.Render(source, _regions, result);
            deadline.Token.ThrowIfCancellationRequested();
            _rendered = rendered;
            Preview.Source = rendered;
            TranslatedText.Text = string.Join(Environment.NewLine, result.Select(block => block.Text));
            CopyImage.IsEnabled = CopyText.IsEnabled = true;
            Status.Text = L("one-shot.translation-translated");
        }
        catch (OperationCanceledException)
        { if (!_closed) Status.Text = L(request.IsCancellationRequested ? "one-shot.translation-cancelled" : "one-shot.translation-timed-out"); }
        catch (RecordingTranscriptionException exception)
        {
            if (!_closed) Status.Text = L(exception.Failure switch
            {
                RecordingTranscriptionFailure.InvalidConfiguration => "one-shot.translation-invalid-configuration",
                RecordingTranscriptionFailure.InvalidResponse or RecordingTranscriptionFailure.ResponseTooLarge => "one-shot.translation-invalid-response",
                RecordingTranscriptionFailure.Timeout => "one-shot.translation-timed-out",
                _ => "one-shot.translation-unavailable"
            });
        }
        catch (NotSupportedException)
        { if (!_closed) Status.Text = LocalizationService.TranslatePhrase("请在 Windows 设置中安装对应的 OCR 语言包。"); }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (!_closed) Status.Text = L(exception is InvalidOperationException && exception.Message.StartsWith("one-shot.translation-", StringComparison.Ordinal)
                ? exception.Message : "one-shot.translation-unavailable");
        }
        finally
        { _request = null; if (!_closed) SetBusy(false); }
    }

    private void SetBusy(bool busy)
    {
        TranslateSelection.IsEnabled = TranslateScreen.IsEnabled = SourceLanguage.IsEnabled = TargetLanguage.IsEnabled = !busy;
        CancelRequest.IsEnabled = busy;
        OpenSettings.IsEnabled = !busy && _openSettings is not null;
    }

    private void OnCopyImage(object sender, RoutedEventArgs e)
    {
        try { if (_rendered is not null) ClipboardWriter.SetImage(_rendered); }
        catch (System.Runtime.InteropServices.COMException) { Status.Text = L("one-shot.translation-unavailable"); }
    }
    private void OnCopyText(object sender, RoutedEventArgs e)
    {
        try { if (!string.IsNullOrEmpty(TranslatedText.Text)) ClipboardWriter.SetText(TranslatedText.Text); }
        catch (System.Runtime.InteropServices.COMException) { Status.Text = L("one-shot.translation-unavailable"); }
    }
}
