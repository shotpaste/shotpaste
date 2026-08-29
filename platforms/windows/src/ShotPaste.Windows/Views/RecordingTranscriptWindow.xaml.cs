using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class RecordingTranscriptWindow : Window
{
    private readonly string _recordingPath;
    private readonly RecordingTranscriptionConfiguration _configuration;
    private readonly VolcengineRecordingTranscriptionService _service = new();
    private readonly CancellationTokenSource _cancellation = new();
    private string? _transcript;

    public RecordingTranscriptWindow(
        string recordingPath,
        RecordingTranscriptionConfiguration configuration)
    {
        _recordingPath = recordingPath;
        _configuration = configuration;
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        Loaded += OnLoaded;
        Closed += (_, _) =>
        {
            _cancellation.Cancel();
            _cancellation.Dispose();
        };
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        try
        {
            _transcript = await _service.TranscribeAsync(
                _recordingPath,
                _configuration,
                _cancellation.Token);
            if (_cancellation.IsCancellationRequested) return;
            Progress.Visibility = Visibility.Collapsed;
            PrivacyText.Visibility = Visibility.Collapsed;
            HeadingText.Text = LocalizationService.TranslatePhrase("文字稿已生成");
            DescriptionText.Text = LocalizationService.TranslatePhrase("检查文字后，可复制或单独保存为文本文件。");
            TranscriptText.Text = _transcript;
            TranscriptText.Visibility = Visibility.Visible;
            CopyButton.IsEnabled = true;
            SaveButton.IsEnabled = true;
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
        }
        catch (RecordingTranscriptionException exception)
        {
            ShowFailure(LocalizeFailure(exception));
        }
        catch (Exception)
        {
            ShowFailure(LocalizationService.TranslatePhrase("无法连接火山引擎同声传译。请检查网络、凭证、模型权限和邀测资格。"));
        }
    }

    private void ShowFailure(string message)
    {
        Progress.Visibility = Visibility.Collapsed;
        PrivacyText.Visibility = Visibility.Collapsed;
        HeadingText.Text = LocalizationService.TranslatePhrase("文字稿生成失败");
        DescriptionText.Text = LocalizationService.TranslatePhrase("视频录屏已安全保存且不会被修改。");
        ErrorText.Text = message;
        ErrorPanel.Visibility = Visibility.Visible;
    }

    private static string LocalizeFailure(RecordingTranscriptionException exception)
    {
        if (exception.Failure == RecordingTranscriptionFailure.Service)
        {
            var message = LocalizationService.TranslatePhrase(
                "无法连接火山引擎同声传译。请检查网络、凭证、模型权限和邀测资格。");
            return string.IsNullOrWhiteSpace(exception.ServiceCode)
                ? message
                : $"{message} ({exception.ServiceCode})";
        }
        var source = exception.Failure switch
        {
            RecordingTranscriptionFailure.InvalidRecording => "无法读取已完成的录屏文件。",
            RecordingTranscriptionFailure.NoAudio => "录屏中没有可读取的音轨。",
            RecordingTranscriptionFailure.AudioTooLong => "火山引擎同声传译仅支持两小时以内的录音。",
            RecordingTranscriptionFailure.AudioDecode => "无法解码录屏音轨。",
            RecordingTranscriptionFailure.InvalidResponse => "火山引擎返回了无效的文字稿响应。",
            RecordingTranscriptionFailure.ResponseTooLarge => "返回的文字稿超过安全大小限制。",
            RecordingTranscriptionFailure.EmptyTranscript => "录屏中没有识别到语音。",
            RecordingTranscriptionFailure.Timeout => "文字稿生成超时。",
            _ => "无法连接火山引擎同声传译。请检查网络、凭证、模型权限和邀测资格。"
        };
        return LocalizationService.TranslatePhrase(source);
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_transcript)) return;
        try
        {
            ClipboardWriter.SetText(_transcript);
            StatusText.Text = LocalizationService.TranslatePhrase("文字稿已复制");
        }
        catch (ExternalException)
        {
            StatusText.Text = LocalizationService.TranslatePhrase("剪贴板正被其他应用占用，请稍后重试。");
        }
    }

    private async void OnSave(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_transcript)) return;
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = LocalizationService.TranslatePhrase("保存录屏文字稿"),
            FileName = Path.GetFileNameWithoutExtension(_recordingPath) + "-transcript.txt",
            InitialDirectory = Path.GetDirectoryName(_recordingPath),
            DefaultExt = ".txt",
            AddExtension = true,
            Filter = "Text files (*.txt)|*.txt"
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            await File.WriteAllTextAsync(
                dialog.FileName,
                _transcript,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                _cancellation.Token);
            StatusText.Text = LocalizationService.TranslatePhrase("保存文字稿") + "：" +
                              Path.GetFileName(dialog.FileName);
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            StatusText.Text = LocalizationService.TranslatePhrase("无法保存文字稿，请选择其他位置后重试。");
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
