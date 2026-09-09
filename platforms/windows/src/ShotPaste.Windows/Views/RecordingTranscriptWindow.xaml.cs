using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class RecordingTranscriptWindow : Window
{
    private readonly RecordingTranscriptionJob _job;
    private readonly RecordingTranscriptionJobs _jobs = RecordingTranscriptionJobs.Shared;
    public RecordingTranscriptWindow(RecordingTranscriptionJob job)
    {
        _job = job;
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        _jobs.Changed += OnChanged;
        Loaded += (_, _) => Refresh();
        Closed += (_, _) => _jobs.Changed -= OnChanged;
    }
    private void OnChanged(object? sender, EventArgs e)
    {
        if (!Dispatcher.HasShutdownStarted) _ = Dispatcher.BeginInvoke(Refresh);
    }
    internal static string StateText(string state) => LocalizationService.TranslatePhrase(state switch
    {
        "queued" => "等待转写", "preparing" => "准备音频", "uploading" => "上传音频", "submitting" => "提交识别",
        "recognizing" => "识别中", "saving" => "保存文字稿", "organizing" => "AI 整理中",
        "completed" => "文字稿已生成", "cancelled" => "已取消", "interrupted" => "等待恢复", _ => "文字稿生成失败"
    });
    private void Refresh()
    {
        HeadingText.Text = StateText(_job.State);
        DescriptionText.Text = _job.DisplayName;
        var finished = _job.State is "completed" or "failed" or "cancelled" or "interrupted";
        Progress.Visibility = finished ? Visibility.Collapsed : Visibility.Visible;
        Progress.IsIndeterminate = _job.State != "uploading" || _job.UploadTotalBytes <= 0;
        Progress.Maximum = 1;
        if (!Progress.IsIndeterminate) Progress.Value = Math.Clamp(_job.UploadedBytes / (double)_job.UploadTotalBytes, 0, 1);
        ResultTabs.Visibility = _job.HasTranscript ? Visibility.Visible : Visibility.Collapsed;
        TranscriptText.Text = _job.RawText;
        TimedText.Text = _job.TimedText();
        PolishedText.Text = _job.AiPolishedText ?? "";
        AiText.Text = _job.AiText ?? LocalizationService.TranslatePhrase("AI 整理结果将在这里显示，原始文字稿会保留。");
        ErrorPanel.Visibility = _job.State == "failed" && !_job.HasTranscript ? Visibility.Visible : Visibility.Collapsed;
        ErrorText.Text = LocalizationService.TranslatePhrase("转写失败，请检查网络、凭证和服务权限。原始录制文件已保留。") + "\n" + _job.Error;
        StatusText.Text = (_job.State == "uploading" && _job.UploadTotalBytes > 0
            ? StateText("uploading") + $" · {_job.UploadedBytes / 1024:N0} / {_job.UploadTotalBytes / 1024:N0} KB" : "") +
            (finished && _job.CleanupPending ? LocalizationService.TranslatePhrase("云端音频待清理，将在下次启动时重试。") : "") +
            (_job.State == "failed" && _job.HasTranscript ? "\n" + LocalizationService.TranslatePhrase("部分处理失败，已生成的原始文字稿仍可查看和导出。") + " " + _job.Error : "");
        CopyButton.IsEnabled = SaveButton.IsEnabled = _job.HasTranscript;
        RetryButton.IsEnabled = _job.State is "failed" or "interrupted" or "cancelled";
        CancelButton.IsEnabled = !finished;
    }
    private string SelectedText => ResultTabs.SelectedIndex switch { 1 => _job.TimedText(), 2 => _job.AiPolishedText ?? "", 3 => _job.AiText ?? "", _ => _job.RawText };
    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(SelectedText)) return;
        try { ClipboardWriter.SetText(SelectedText); StatusText.Text = LocalizationService.TranslatePhrase("文字稿已复制"); }
        catch (ExternalException) { StatusText.Text = LocalizationService.TranslatePhrase("剪贴板正被其他应用占用，请稍后重试。"); }
    }
    private async void OnSave(object sender, RoutedEventArgs e)
    {
        if (!_job.HasTranscript) return;
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = LocalizationService.TranslatePhrase("保存录屏文字稿"), FileName = Path.GetFileNameWithoutExtension(_job.RecordingPath) + "-transcript.txt",
            DefaultExt = ".txt", AddExtension = true, Filter = "Text (*.txt)|*.txt|Markdown (*.md)|*.md|Transcript JSON (*.json)|*.json"
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            // Export deliberately excludes local paths, cloud objects and encrypted credentials.
            var content = dialog.FilterIndex == 3
                ? JsonSerializer.Serialize(new { _job.Id, _job.CreatedAt, Sources = _job.Parts.Select(part => new { part.Role, part.StartMilliseconds, part.Transcript, SegmentIds = part.Transcript?.Utterances.Select((_, index) => RecordingTranscriptAiProcessor.SegmentId(part, index)) }), _job.AiPolishedText, _job.AiArtifact, _job.AiText }, new JsonSerializerOptions { WriteIndented = true })
                : SelectedText;
            await File.WriteAllTextAsync(dialog.FileName, content, new UTF8Encoding(false));
            StatusText.Text = LocalizationService.TranslatePhrase("保存文字稿") + "：" + Path.GetFileName(dialog.FileName);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        { StatusText.Text = LocalizationService.TranslatePhrase("无法保存文字稿，请选择其他位置后重试。"); }
    }
    private void OnRetry(object sender, RoutedEventArgs e)
    {
        var resubmit = _job.RequiresResubmission;
        if (resubmit && LocalizedDialogService.Show(this,
            "原云端任务已失效，重试需要重新上传并提交识别，可能产生费用。是否继续？",
            "重新提交转写", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        _jobs.Retry(_job, allowResubmission: resubmit); Refresh();
    }
    private void OnCancel(object sender, RoutedEventArgs e) { _jobs.Cancel(_job); Refresh(); }
    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
