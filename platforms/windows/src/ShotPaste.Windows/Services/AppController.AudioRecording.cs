using System.Windows;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Services;

public sealed partial class AppController
{
    private readonly AudioRecordingService _audioRecording = new();
    private AudioRecordingControlWindow? _audioControl;
    private TaskCompletionSource<bool>? _audioWorkflow;
    private Task<bool>? _audioSaveTask;
    private bool _audioCompletionInProgress;
    private AudioRecordingOptions? _audioOptions;
    private RecordingTranscriptionConfiguration? _audioCloudConfiguration;
    private (bool Enabled, bool UseAI, string Language) _audioTranscription;

    private void WireAudioRecordingEvents()
    {
        if (_tray is not null)
        {
            _tray.AudioRecordingRequested += (_, _) => StartAudioRecording();
            _tray.TranscriptionResultsRequested += (_, _) => ShowTranscriptionResults();
        }
        _audioRecording.StateChanged += (_, _) => System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
            _tray?.UpdateRecordingState(_audioRecording.IsRecording || _recording.IsRecording,
                _audioRecording.IsRecording ? _audioRecording.IsPaused : _recording.IsPaused));
        _audioRecording.CaptureStopped += (_, args) => System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
        {
            if (args.Generation == _audioRecording.CaptureGeneration && _audioWorkflow is not null && !_audioCompletionInProgress)
                _ = StopAudioRecordingAsync();
        });
    }

    public void StartAudioRecording() => RunExclusive(async () =>
    {
        if (_exitInProgress) return;
        var preparation = new AudioRecordingPreparationWindow(_settings.Current);
        if (preparation.ShowDialog() != true) return;
        var settings = _settings.Current;
        settings.AudioRecordSystemAudio = preparation.SystemAudio;
        settings.AudioRecordMicrophone = preparation.Microphone;
        settings.AudioTranscriptionEnabled = preparation.Transcribe;
        settings.AudioTranscriptionUseAI = preparation.UseAI;
        settings.AudioTranscriptionLanguage = preparation.SpeechLanguage;
        settings.RecordingTranscriptionTemplate = preparation.OrganizationTemplate;
        _settings.Save();
        _audioTranscription = (preparation.Transcribe, preparation.UseAI, preparation.SpeechLanguage);
        _audioCloudConfiguration = preparation.Transcribe ? RecordingTranscriptionConfiguration.FromSettings(settings) : null;
        if (_audioCloudConfiguration is not null)
            _audioCloudConfiguration = _audioCloudConfiguration with { UseAI = preparation.UseAI, SourceLanguage = preparation.SpeechLanguage,
                OrganizationTemplate = preparation.OrganizationTemplate };
        _audioOptions = new AudioRecordingOptions(preparation.SystemAudio, preparation.Microphone,
            settings.RecordingMicrophoneDeviceId, settings.RecordingSystemAudioVolume, settings.RecordingMicrophoneVolume,
            settings.SaveRecordings ? settings.SaveDirectory : AppPaths.Captures, _audioCloudConfiguration);
        var workflow = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _audioWorkflow = workflow;
        _audioSaveTask = null;
        try
        {
            _audioRecording.Start(_audioOptions);
            _audioControl = new AudioRecordingControlWindow(_audioRecording);
            _audioControl.StopRequested += (_, _) => _ = StopAudioRecordingAsync();
            _audioControl.DiscardRequested += (_, _) => RequestAudioDiscard();
            _audioControl.RestartRequested += (_, _) => RequestAudioRestart();
            _audioControl.Show();
            await workflow.Task;
        }
        finally
        {
            _audioControl?.CloseAfterCompletion(); _audioControl = null;
            if (ReferenceEquals(_audioWorkflow, workflow)) _audioWorkflow = null;
        }
    });

    private Task<bool> StopAudioRecordingAsync()
    {
        if (_audioSaveTask is null || _audioSaveTask.IsCompleted) _audioSaveTask = SaveAudioCoreAsync();
        return _audioSaveTask;
    }

    private async Task<bool> SaveAudioCoreAsync()
    {
        if (_audioWorkflow is null || _audioCompletionInProgress) return false;
        _audioCompletionInProgress = true;
        _audioControl?.SetSaving(true);
        try
        {
            var saved = await _audioRecording.StopAsync();
            CaptureHistoryItem item;
            if (_settings.Current.ClipboardHistoryEnabled)
                item = await _history.AddFileAsync(saved.Path, CaptureKind.Audio, saved.Duration);
            else item = new CaptureHistoryItem { Kind = CaptureKind.Audio, FilePath = saved.Path,
                Duration = saved.Duration, SizeBytes = new FileInfo(saved.Path).Length };
            if (_settings.Current.CopyRecordings) CopyHistoryItem(item);
            if (_settings.Current.ShowQuickAccess && _settings.Current.ShowQuickAccessForRecordings) ShowQuickAccess(item);
            PresentRecordingTranscriptIfConfigured(saved.Path, _audioTranscription.Enabled, _audioTranscription.UseAI, _audioTranscription.Language, _audioCloudConfiguration);
            if (_audioRecording.CaptureError is not null)
                _tray?.ShowMessage(AudioRecordingPreparationWindow.L("audio-recording.recording", "Audio recording"),
                    AudioRecordingPreparationWindow.L("audio-recording.ended-early-saved", "The audio device stopped. Available audio has been saved."));
            _audioWorkflow.TrySetResult(true);
            return true;
        }
        catch (Exception)
        {
            _tray?.ShowMessage(AudioRecordingPreparationWindow.L("audio-recording.recording", "Audio recording"),
                AudioRecordingPreparationWindow.L("audio-recording.extraction-recoverable", "Audio saving failed. Recovery files are retained; stop again to retry."),
                System.Windows.Forms.ToolTipIcon.Error);
            return false;
        }
        finally { _audioCompletionInProgress = false; _audioControl?.SetSaving(false); }
    }

    private async void RequestAudioDiscard() => await DiscardOrRestartAudioAsync(false);
    private async void RequestAudioRestart() => await DiscardOrRestartAudioAsync(true);

    private async Task DiscardOrRestartAudioAsync(bool restart)
    {
        if (_audioWorkflow is null || _audioCompletionInProgress) return;
        if (LocalizedDialogService.Show(_audioControl,
            AudioRecordingPreparationWindow.L("audio-recording.discard-confirm", "Discard the current audio recording?"),
            AudioRecordingPreparationWindow.L("audio-recording.recording", "Audio recording"),
            MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        _audioCompletionInProgress = true;
        _audioControl?.SetSaving(true);
        try
        {
            await _audioRecording.DiscardAsync();
            _audioSaveTask = null;
            if (restart && _audioOptions is not null) _audioRecording.Start(_audioOptions);
            else _audioWorkflow.TrySetResult(true);
        }
        catch (Exception) { _tray?.ShowMessage("操作失败", AudioRecordingPreparationWindow.L("audio-recording.extraction-recoverable", "Recovery files are retained; retry when ready.")); }
        finally { _audioCompletionInProgress = false; _audioControl?.SetSaving(false); }
    }

    private async Task<bool> StopAudioForExitAsync()
    {
        if (_audioSaveTask is { IsCompleted: false }) return await _audioSaveTask;
        var choice = LocalizedDialogService.ShowCustom(_audioControl,
            AudioRecordingPreparationWindow.L("audio-recording.quit-message", "Stop and save audio before quitting?"),
            LocalizationService.TranslatePhrase("退出 ShotPaste？"), "停止并保存", "丢弃并退出", "取消", MessageBoxImage.Warning);
        if (choice == MessageBoxResult.Cancel) return false;
        if (choice == MessageBoxResult.Yes) return await StopAudioRecordingAsync();
        _audioCompletionInProgress = true;
        try { await _audioRecording.DiscardAsync(); _audioWorkflow?.TrySetResult(true); return true; }
        catch (Exception) { return false; }
        finally { _audioCompletionInProgress = false; }
    }
}
