using System.Collections.Specialized;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Utilities;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.Services;

public sealed class AppController : IDisposable
{
    private readonly SettingsStore _settings = new();
    private readonly CaptureHistoryStore _history = new();
    private readonly ScreenCaptureService _capture = new();
    private readonly ScreenRecordingService _recording = new();
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly ImageFileService _images;
    private readonly OcrService _ocr;
    private RegionSelectionService? _selection;
    private ScrollingCaptureService? _scrolling;
    private GlobalHotkeyService? _hotkeys;
    private ClipboardMonitorService? _clipboard;
    private TrayIconService? _tray;
    private MainWindow? _mainWindow;
    private RecordingToolbarWindow? _recordingToolbar;
    private RecordingRegionOverlayWindow? _recordingRegionOverlay;
    private bool _restoreMainAfterCapture;
    private bool _resumeQuickAccessAfterCapture;
    private QuickAccessService? _quickAccess;
    private bool _discardRecording;
    private bool _restartRecording;
    private RecordingInkWindow? _recordingInk;
    private RecordingInkToolbarWindow? _recordingInkToolbar;
    private KeystrokeOverlayService? _keystrokeOverlay;
    private MouseClickOverlayService? _mouseClickOverlay;
    private System.Windows.Threading.DispatcherTimer? _historyMaintenanceTimer;
    private readonly Dictionary<Guid, PinnedImageWindow> _activePins = [];
    private Rectangle? _currentRecordingRectangle;
    private readonly Queue<IReadOnlyList<string>> _pendingCommands = new();
    private bool _ready;

    public AppController()
    {
        _images = new ImageFileService(_settings);
        _ocr = new OcrService(() => _settings.Current.OcrRecognitionLanguage.Equals("Auto", StringComparison.OrdinalIgnoreCase)
            ? _settings.Current.Language
            : _settings.Current.OcrRecognitionLanguage);
    }

    public async void Start()
    {
        try
        {
            await StartCoreAsync();
        }
        catch (Exception exception)
        {
            App.WriteCrashLog(exception);
            LocalizedDialogService.Show(
                "ShotPaste 启动失败。错误详情已写入本地 crash.log。",
                "ShotPaste",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            System.Windows.Application.Current.Shutdown(1);
        }
    }

    private async Task StartCoreAsync()
    {
        AppPaths.EnsureCreated();
        _settings.Load();
        App.ConfigureDiagnostics(_settings.Current.DiagnosticsEnabled);
        if (_settings.Current.DiagnosticsEnabled)
            DiagnosticsService.RunStartupMaintenance(_settings.Current.DiagnosticsRetentionDays);
        LocalizationService.Apply(_settings.Current);
        LocalizationService.EnableAutomaticWpfLocalization();
        ThemeService.Apply(_settings.Current.Theme);
        StartupService.Apply(_settings.Current.LaunchAtStartup);
        UrlSchemeService.Apply(_settings.Current.UrlSchemeEnabled);
        await _history.LoadAsync();
        var recoveryScan = await RecordingRecoveryService.ScanAsync();
        if (recoveryScan.Recording is { } recovered &&
            !_history.Items.Any(item => string.Equals(item.FilePath, recovered.Path, StringComparison.OrdinalIgnoreCase)))
            await _history.AddFileAsync(recovered.Path, CaptureKind.Recording, recovered.Duration);
        await _history.ClearSessionPinnedStateAsync();
        await _history.PruneAsync(_settings.Current.HistoryRetentionDays, _settings.Current.HistoryMaxCount);
        _selection = new RegionSelectionService(
            _capture,
            () => ScreenshotCaptureOptions);
        _scrolling = CreateScrollingCaptureService();
        _hotkeys = new GlobalHotkeyService();
        _clipboard = new ClipboardMonitorService(_history, _settings);
        _tray = new TrayIconService(_settings.Current, () => _recording.Elapsed);
        _quickAccess = new QuickAccessService(this, _settings);
        WireEvents();
        if (!string.IsNullOrWhiteSpace(_settings.LastConfigurationWarning))
            _tray.ShowMessage("设置已恢复", _settings.LastConfigurationWarning, Forms.ToolTipIcon.Warning);
        _hotkeys.RegisterConfigured(_settings.Current);
        if (recoveryScan.Recording is not null)
            _tray.ShowMessage("已恢复上次录屏", Path.GetFileName(recoveryScan.Recording.Path));
        else if (!string.IsNullOrWhiteSpace(recoveryScan.Warning))
            _tray.ShowMessage("录屏恢复", recoveryScan.Warning, Forms.ToolTipIcon.Warning);
        _mainWindow = new MainWindow(this, _history, _settings);
        if (App.UiTestMode) ShowHistory();
        _historyMaintenanceTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromHours(24) };
        _historyMaintenanceTimer.Tick += async (_, _) => await _history.PruneAsync(_settings.Current.HistoryRetentionDays, _settings.Current.HistoryMaxCount);
        _historyMaintenanceTimer.Start();
        if (_hotkeys.FailedActions.Count > 0)
            _tray.ShowMessage("部分快捷键不可用", "快捷键已被其他程序占用，可继续使用托盘菜单。", Forms.ToolTipIcon.Warning);
        _ready = true;
        while (_pendingCommands.Count > 0) ExecuteExternalCommand(UrlSchemeService.Parse(_pendingCommands.Dequeue()));
    }

    public void HandleExternalCommand(IReadOnlyList<string> arguments)
    {
        var parsed = UrlSchemeService.Parse(arguments);
        if (parsed.Command == AppCommand.None) return;
        if (!_ready)
        {
            _pendingCommands.Enqueue(arguments.ToArray());
            return;
        }
        ExecuteExternalCommand(parsed);
    }

    private void ExecuteExternalCommand(ParsedAppCommand command)
    {
        if (command.IsUrl && !_settings.Current.UrlSchemeEnabled)
        {
            App.WriteQuickAccessLog("External URL command ignored because URL Scheme is disabled.");
            _tray?.ShowMessage(
                LocalizationService.TranslatePhrase("自动化链接已停用"),
                LocalizationService.TranslatePhrase("可在设置中重新启用 shotpaste:// 链接。"),
                Forms.ToolTipIcon.Warning);
            return;
        }
        switch (command.Command)
        {
            case AppCommand.Invalid:
                App.WriteQuickAccessLog($"External command rejected: {command.Error ?? "invalid URL"}");
                _tray?.ShowMessage(
                    LocalizationService.TranslatePhrase("无法打开链接"),
                    LocalizationService.TranslatePhrase(command.Error ?? "ShotPaste 链接格式无效"),
                    Forms.ToolTipIcon.Warning);
                break;
            case AppCommand.OneShot: StartOneShot(); break;
            case AppCommand.History: ShowHistory(); break;
            case AppCommand.Settings: ShowSettings(command.SettingsTab); break;
        }
    }

    private void WireEvents()
    {
        if (_tray is null || _hotkeys is null) return;
        _tray.RecordingRequested += (_, _) => { if (_recording.IsRecording) _recording.Stop(); };
        _tray.PauseRecordingRequested += (_, _) => _recording.TogglePause();
        _tray.OneShotRequested += (_, _) => StartOneShot();
        _tray.HistoryRequested += (_, _) => ShowHistory();
        _tray.SettingsRequested += (_, _) => ShowSettings();
        _tray.ExitRequested += (_, _) => Exit();
        _history.Items.CollectionChanged += (_, change) =>
        {
            if (change.Action != NotifyCollectionChangedAction.Add || !_settings.Current.PlaySounds) return;
            try { System.Media.SystemSounds.Asterisk.Play(); } catch (InvalidOperationException) { }
        };
        _recording.StateChanged += (_, _) => System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
        {
            _tray?.UpdateRecordingState(_recording.IsRecording, _recording.IsPaused);
            _mouseClickOverlay?.SetPaused(!_recording.IsRecording || _recording.IsPaused);
            _keystrokeOverlay?.SetPaused(!_recording.IsRecording || _recording.IsPaused);
            _recordingInk?.SetPaused(!_recording.IsRecording || _recording.IsPaused);
        });
        _hotkeys.Triggered += (_, action) => System.Windows.Application.Current.Dispatcher.Invoke(() =>
        {
            switch (action)
            {
                case HotkeyAction.OneShot: StartOneShot(); break;
                case HotkeyAction.History: ShowHistory(); break;
                case HotkeyAction.HistoryMode:
                    ShowHistory();
                    _mainWindow?.ToggleHistoryMode();
                    break;
                case HotkeyAction.RecordingPause:
                    if (_recording.IsRecording) _recording.TogglePause();
                    break;
                case HotkeyAction.RecordingAnnotation:
                    if (_recording.IsRecording && _currentRecordingRectangle is { } recordingRectangle)
                        ToggleRecordingInk(recordingRectangle);
                    break;
                case HotkeyAction.RecordingRestart:
                    if (_recording.IsRecording) { _restartRecording = true; _recording.Stop(); }
                    break;
                case HotkeyAction.RecordingDelete:
                    if (_recording.IsRecording) { _discardRecording = true; _recording.Stop(); }
                    break;
            }
        });
    }

    private async Task CaptureScrollingCoreAsync(Rectangle initialRegion)
    {
        if (_scrolling is null) return;
        _scrolling = CreateScrollingCaptureService();
        HideApplicationWindows();
        var region = initialRegion;
        using var cancellation = new CancellationTokenSource();
        var outline = new RecordingRegionOverlayWindow(
            region,
            _capture.VirtualBounds,
            constrainToRegionScreen: true);
        var window = new ScrollingProgressWindow(_settings.Current.ScrollingShowHints);
        var startCompletion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var discard = false;
        var autoScrollState = 0;
        var finishState = 0;
        window.StartRequested += (_, _) => startCompletion.TrySetResult(true);
        window.DoneRequested += (_, _) =>
        {
            if (Interlocked.Exchange(ref finishState, 1) != 0) return;
            window.BeginFinalizing();
        };
        window.CancelRequested += (_, _) =>
        {
            discard = true;
            startCompletion.TrySetResult(false);
            cancellation.Cancel();
        };
        window.AutoScrollRequested += (_, _) =>
            Volatile.Write(ref autoScrollState, window.IsAutoScrollEnabled ? 1 : 0);
        window.Closed += (_, _) => startCompletion.TrySetResult(false);
        outline.RegionChanged += updatedRegion =>
        {
            region = updatedRegion;
            window.UpdateReadyRegion(updatedRegion);
        };
        outline.SetScrollingAppearance(capturing: false);
        window.ShowReady(region);
        window.PositionNear(region);
        outline.Show();
        window.Show();
        Bitmap? captured = null;
        try
        {
            try
            {
                var shouldStart = await startCompletion.Task;
                if (!shouldStart || discard) return;

                outline.SetScrollingAppearance(capturing: true);
                window.BeginCapture(_settings.Current.ScrollingAutoScrollEnabled);
                window.PositionNear(region);
                await window.Dispatcher.InvokeAsync(
                    window.UpdateLayout,
                    System.Windows.Threading.DispatcherPriority.Render);
                await Task.Delay(16);

                var center = new NativeMethods.PointStruct(
                    region.Left + region.Width / 2,
                    region.Top + region.Height / 2);
                var scrollTarget = NativeMethods.GetAncestor(NativeMethods.WindowFromPoint(center), NativeMethods.GaRoot);
                using var wheelMonitor = new MouseWheelMonitor();
                wheelMonitor.Start(region);
                var progress = new Progress<ScrollingCaptureProgress>(window.UpdateProgress);
                captured = await _scrolling.CaptureAsync(
                    region,
                    scrollTarget,
                    wheelMonitor,
                    progress,
                    cancellation.Token,
                    () => Volatile.Read(ref autoScrollState) == 1 &&
                          _settings.Current.ScrollingAutoScrollEnabled,
                    () => discard,
                    () => Volatile.Read(ref finishState) == 1);
            }
            catch (OperationCanceledException)
            {
                captured = null;
            }

            using var capturedResult = captured;
            using var result = capturedResult is null ? null : PrepareScreenshot(capturedResult);
            if (discard || result is null) return;

            // Match macOS: keep the HUD visible, lock every action, and expose a
            // distinct saving state until the long screenshot has been written.
            window.BeginSaving();
            await window.Dispatcher.InvokeAsync(
                window.UpdateLayout,
                System.Windows.Threading.DispatcherPriority.Render);
            await Task.Delay(16);
            var path = _images.Save(result, ScreenshotOutputDirectory, CaptureKind.ScrollingScreenshot);
            await FinishImageCaptureAsync(path, CaptureKind.ScrollingScreenshot, result);
        }
        finally
        {
            window.Close();
            outline.Close();
            RestoreMainWindowIfNeeded();
        }
    }

    private async Task ProcessOcrImageAsync(Bitmap image)
    {
        var result = await _ocr.RecognizeDetailedAsync(image);
        if (string.IsNullOrWhiteSpace(result.Text))
        {
            _tray?.ShowMessage("未识别到文字", "请选择包含清晰文字或二维码的区域。", Forms.ToolTipIcon.Warning);
            return;
        }
        _clipboard?.SuppressNextChange();
        System.Windows.Clipboard.SetText(result.Text);
        if (_settings.Current.ShowOcrLinkNotifications && result.Links.Count > 0)
        {
            var resultWindow = new OcrResultWindow(result)
            {
                Owner = _mainWindow?.IsVisible == true ? _mainWindow : null
            };
            resultWindow.Show();
            resultWindow.Activate();
        }
        else if (_settings.Current.ShowOcrSuccessNotifications)
            _tray?.ShowMessage("文字已复制", result.Text.Length > 90 ? result.Text[..90] + "…" : result.Text);
    }

    public void StartOneShot() => RunExclusive(async () =>
    {
        if (_selection is null) return;
        var recordingOptions = new OneShotRecordingOptions(
            _settings.Current.RecordingOutputMode,
            _settings.Current.IncludeCursorInRecording,
            _settings.Current.RecordSystemAudio,
            _settings.Current.RecordMicrophone);
        using var result = await _selection.SelectOneShotAsync(recordingOptions);
        if (result is null) return;

        switch (result.Mode)
        {
            case OneShotMode.Screenshot when result.Image is not null:
                using (var image = PrepareScreenshot(result.Image))
                {
                    var path = _images.Save(image, ScreenshotOutputDirectory, CaptureKind.Screenshot);
                    var item = await FinishImageCaptureAsync(path, CaptureKind.Screenshot, image);
                    if (result.PinRequested) PinHistoryItem(item);
                }
                break;
            case OneShotMode.Scrolling:
                await CaptureScrollingCoreAsync(result.Rectangle);
                break;
            case OneShotMode.Recording when result.RecordingOptions is not null:
                await StartOneShotRecordingAsync(result.Rectangle, result.RecordingOptions);
                break;
            case OneShotMode.Ocr when result.Image is not null:
                await ProcessOcrImageAsync(result.Image);
                break;
            case OneShotMode.Clipboard:
                ShowAllHistoryExpanded();
                break;
        }
    });

    private async Task StartOneShotRecordingAsync(Rectangle rectangle, OneShotRecordingOptions options)
    {
        await RecordingFormatCapabilityService.ProbeAsync();
        _recordingRegionOverlay?.Close();
        _recordingRegionOverlay = new RecordingRegionOverlayWindow(rectangle, _capture.VirtualBounds);
        _recordingRegionOverlay.Show();
        var request = new RecordingRequest(
            RecordingTarget.Region(rectangle),
            options.OutputMode,
            options.SystemAudio,
            options.Microphone,
            _settings.Current.RecordingQualityPreset,
            options.IncludeCursor,
            _settings.Current.HighlightMouseClicks,
            _settings.Current.ShowKeystrokes,
            _settings.Current.DimNonSelectedRecordingArea,
            _settings.Current.RecordingMicrophoneDeviceId,
            _settings.Current.RecordingMicrophoneDeviceName,
            _settings.Current.RecordingSystemAudioVolume,
            _settings.Current.RecordingMicrophoneVolume,
            _settings.Current.IncludeShotPasteInRecording);
        await ExecuteRecordingRequestAsync(request);
    }

    private async Task ExecuteRecordingRequestAsync(RecordingRequest request)
    {
        ApplyRecordingRequestSettings(request);
        var target = request.Target;
        var rectangle = target.Bounds;

        _recordingRegionOverlay ??= new RecordingRegionOverlayWindow(rectangle, _capture.VirtualBounds);
        if (!_recordingRegionOverlay.IsVisible) _recordingRegionOverlay.Show();
        _recordingRegionOverlay.SetRecordingAppearance(request.DimNonSelectedArea);
        HideApplicationWindows(forRecording: true);
        try
        {
            _currentRecordingRectangle = rectangle;
            do
            {
                _discardRecording = false;
                _restartRecording = false;
                if (_settings.Current.HighlightMouseClicks)
                {
                    try { _mouseClickOverlay = new MouseClickOverlayService(rectangle, _settings.Current); }
                    catch (System.ComponentModel.Win32Exception exception) { ShowError("鼠标点击效果不可用", exception); }
                }
                if (_settings.Current.ShowKeystrokes)
                {
                    try { _keystrokeOverlay = new KeystrokeOverlayService(rectangle, _settings.Current); }
                    catch (System.ComponentModel.Win32Exception exception) { ShowError("按键显示不可用", exception); }
                }
                PrepareRecordingInk(rectangle);
                var completion = _recording.StartAsync(target, _settings.Current, request.Gif);
                if (_recording.LastFormatDecision is { UsedFallback: true } formatDecision)
                {
                    var reason = formatDecision.FallbackReason?.Contains(RecordingFormatCapabilityService.HevcUnavailable, StringComparison.Ordinal) == true
                        ? "当前 Windows 未提供 HEVC 编码器，已安全改用 H.264 / MP4。"
                        : formatDecision.FallbackReason?.Contains(RecordingFormatCapabilityService.GifIntermediate, StringComparison.Ordinal) == true
                            ? "GIF 转换的中间视频固定使用 H.264 / MP4，以保证后处理兼容性。"
                            : "Windows 录制组件不输出 MOV，已安全改用 MP4 容器。";
                    _tray?.ShowMessage("录制格式已调整", reason, Forms.ToolTipIcon.Info);
                }
                if (_settings.Current.ShowRecordingToolbar)
                {
                    _recordingToolbar = new RecordingToolbarWindow(_recording, _settings.Current);
                    _recordingToolbar.StopRequested += (_, _) => _recording.Stop();
                    _recordingToolbar.DeleteRequested += (_, _) => { _discardRecording = true; _recording.Stop(); };
                    _recordingToolbar.RestartRequested += (_, _) => { _restartRecording = true; _recording.Stop(); };
                    _recordingToolbar.PenRequested += (_, _) => ToggleRecordingInk(rectangle);
                    _recordingToolbar.Show();
                }
                var path = await completion;
                var duration = _recording.Elapsed;
                _recordingToolbar?.Close(); _recordingToolbar = null;
                CloseRecordingInk();
                _keystrokeOverlay?.Dispose(); _keystrokeOverlay = null;
                _mouseClickOverlay?.Dispose(); _mouseClickOverlay = null;
                if (_discardRecording || _restartRecording)
                {
                    try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { }
                    continue;
                }
                var kind = request.Gif ? CaptureKind.Gif : CaptureKind.Recording;
                var item = await _history.AddFileAsync(path, kind, duration);
                if (_settings.Current.CopyRecordings) CopyHistoryItem(item);
                if (_settings.Current.ShowQuickAccess && _settings.Current.ShowQuickAccessForRecordings) ShowQuickAccess(item);
                if (_settings.Current.ShowCaptureNotifications)
                    _tray?.ShowMessage("录屏已保存", Path.GetFileName(path));
            }
            while (_restartRecording);
            _currentRecordingRectangle = null;
            _recordingRegionOverlay?.Close(); _recordingRegionOverlay = null;
            RestoreMainWindowIfNeeded();
        }
        catch (Exception exception)
        {
            _currentRecordingRectangle = null;
            _recordingToolbar?.Close(); _recordingToolbar = null;
            CloseRecordingInk();
            _keystrokeOverlay?.Dispose(); _keystrokeOverlay = null;
            _mouseClickOverlay?.Dispose(); _mouseClickOverlay = null;
            _recordingRegionOverlay?.Close(); _recordingRegionOverlay = null;
            ShowError("录屏失败", exception); RestoreMainWindowIfNeeded();
        }
    }

    private void ApplyRecordingRequestSettings(RecordingRequest request)
    {
        _settings.Current.RecordSystemAudio = request.SystemAudio;
        _settings.Current.RecordMicrophone = request.Microphone;
        _settings.Current.RecordingQualityPreset = request.Quality;
        _settings.Current.RecordingOutputMode = request.OutputMode;
        _settings.Current.IncludeCursorInRecording = request.IncludeCursor;
        _settings.Current.HighlightMouseClicks = request.HighlightMouseClicks;
        _settings.Current.ShowKeystrokes = request.ShowKeystrokes;
        _settings.Current.IncludeShotPasteInRecording = request.IncludeShotPaste;
        _settings.Current.DimNonSelectedRecordingArea = request.DimNonSelectedArea;
        _settings.Current.RecordingMicrophoneDeviceId = request.MicrophoneDeviceId;
        _settings.Current.RecordingMicrophoneDeviceName = request.MicrophoneDeviceName;
        _settings.Current.RecordingSystemAudioVolume = request.SystemAudioVolume;
        _settings.Current.RecordingMicrophoneVolume = request.MicrophoneVolume;
        _settings.Save();
    }

    private void ToggleRecordingInk(Rectangle rectangle)
    {
        PrepareRecordingInk(rectangle);
        if (_recordingInk is null) return;
        if (_recordingInkToolbar is null)
        {
            _recordingInk.SetInteractionEnabled(true);
            _recordingInkToolbar = new RecordingInkToolbarWindow(_recordingInk);
            _recordingInkToolbar.CloseRequested += (_, _) => DeactivateRecordingInk();
            _recordingInkToolbar.Show();
            _recordingToolbar?.SetPenActive(true);
        }
        else
        {
            DeactivateRecordingInk();
        }
    }

    private void PrepareRecordingInk(Rectangle rectangle)
    {
        if (_recordingInk is not null) return;
        _recordingInk = new RecordingInkWindow(rectangle, _settings.Current, _settings.Save);
        _recordingInk.SetInteractionEnabled(false);
        _recordingInk.Show();
    }

    private void DeactivateRecordingInk()
    {
        var toolbar = _recordingInkToolbar;
        _recordingInkToolbar = null;
        if (toolbar is not null) toolbar.Close();
        _recordingInk?.SetInteractionEnabled(false);
        _recordingToolbar?.SetPenActive(false);
    }

    private void CloseRecordingInk()
    {
        DeactivateRecordingInk();
        var ink = _recordingInk;
        _recordingInk = null;
        if (ink is not null) ink.Close();
        _recordingToolbar?.SetPenActive(false);
    }

    private async Task<CaptureHistoryItem> FinishImageCaptureAsync(string path, CaptureKind kind, Bitmap image)
    {
        if (_settings.Current.CopyScreenshots)
        {
            _clipboard?.SuppressNextChange();
            System.Windows.Clipboard.SetImage(BitmapSourceFactory.FromBitmap(image));
        }
        var item = await _history.AddFileAsync(path, kind);
        if (_settings.Current.ShowQuickAccess && _settings.Current.ShowQuickAccessForScreenshots) ShowQuickAccess(item);
        if (_settings.Current.ShowCaptureNotifications)
            _tray?.ShowMessage(kind == CaptureKind.ScrollingScreenshot ? "滚动截屏已保存" : "截图已保存", Path.GetFileName(path));
        return item;
    }

    public async void CopyHistoryItem(CaptureHistoryItem item)
    {
        try
        {
            _clipboard?.SuppressNextChange();
            if (item.Kind == CaptureKind.ClipboardText)
            {
                var loaded = await item.LoadFullTextAsync();
                if (loaded.Text is null)
                {
                    ShowError("复制失败", new IOException(loaded.Error ?? "完整文本不可用。"));
                    return;
                }
                System.Windows.Clipboard.SetText(loaded.Text);
                if (loaded.IsLimited && !string.IsNullOrWhiteSpace(loaded.Error))
                    _tray?.ShowMessage("文本已受限", loaded.Error, Forms.ToolTipIcon.Warning);
            }
            else if (item.FilePaths.Count > 0 && item.ExistingFilePaths.Count > 0)
            {
                var files = new StringCollection();
                files.AddRange(item.ExistingFilePaths.ToArray());
                System.Windows.Clipboard.SetFileDropList(files);
            }
            else if (!string.IsNullOrWhiteSpace(item.FilePath) && File.Exists(item.FilePath))
            {
                if (item.Kind is CaptureKind.Screenshot or CaptureKind.ScrollingScreenshot or CaptureKind.ClipboardImage)
                {
                    var image = BitmapSourceFactory.FromPath(item.FilePath);
                    if (image is not null) System.Windows.Clipboard.SetImage(image);
                }
                else
                {
                    var files = new StringCollection { item.FilePath };
                    System.Windows.Clipboard.SetFileDropList(files);
                }
            }
        }
        catch (Exception exception) when (exception is ExternalException or IOException) { ShowError("复制失败", exception); }
    }

    public async void CopyHistoryItems(IEnumerable<CaptureHistoryItem> items)
    {
        var selected = items.ToArray();
        if (selected.Length == 1) { CopyHistoryItem(selected[0]); return; }
        var paths = selected
            .SelectMany(item => item.FilePaths.Count > 0
                ? item.ExistingFilePaths
                : !string.IsNullOrWhiteSpace(item.FilePath) && File.Exists(item.FilePath) ? [item.FilePath] : [])
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (paths.Length > 0)
        {
            _clipboard?.SuppressNextChange();
            var files = new StringCollection();
            files.AddRange(paths);
            System.Windows.Clipboard.SetFileDropList(files);
        }
        else
        {
            var loaded = await Task.WhenAll(selected
                .Where(item => item.Kind == CaptureKind.ClipboardText)
                .Select(item => item.LoadFullTextAsync()));
            var text = string.Join(Environment.NewLine + Environment.NewLine,
                loaded.Select(result => result.Text).Where(value => !string.IsNullOrWhiteSpace(value)));
            if (text.Length > 0) System.Windows.Clipboard.SetText(text);
        }
    }

    public void ShowHistory()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        if (!_mainWindow.IsCompactMode) _mainWindow.Activate();
    }

    private void ShowAllHistoryExpanded()
    {
        if (_mainWindow is null) return;
        _mainWindow.ShowAllExpanded();
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    public void ShowSettings(string? tab = null)
    {
        var window = new SettingsWindow(_settings, tab) { Owner = _mainWindow?.IsVisible == true ? _mainWindow : null };
        _hotkeys?.Suspend();
        var saved = false;
        try
        {
            saved = window.ShowDialog() == true;
            if (saved) ApplyLiveSettings();
        }
        finally
        {
            _hotkeys?.RegisterConfigured(_settings.Current);
        }

        if (saved && _hotkeys?.FailedActions.Count > 0)
            _tray?.ShowMessage("部分快捷键不可用", "请检查快捷键格式，或确认组合键未被其他程序占用。", Forms.ToolTipIcon.Warning);
    }

    private void ApplyLiveSettings()
    {
        ThemeService.Apply(_settings.Current.Theme);
        LocalizationService.Apply(_settings.Current);
        foreach (Window openWindow in System.Windows.Application.Current.Windows)
            LocalizationService.LocalizeWindow(openWindow);
        _mainWindow?.RefreshLocalization();
        _mainWindow?.ApplyHistoryMode("Compact");
        _mainWindow?.ApplyHistoryBackgroundStyle();
        _quickAccess?.RefreshSettings();
        StartupService.Apply(_settings.Current.LaunchAtStartup);
        UrlSchemeService.Apply(_settings.Current.UrlSchemeEnabled);
        App.ConfigureDiagnostics(_settings.Current.DiagnosticsEnabled);
        _hotkeys?.RegisterConfigured(_settings.Current);
        _tray?.UpdateShortcuts(_settings.Current);
    }

    private void ShowQuickAccess(CaptureHistoryItem item)
    {
        if (System.Windows.Application.Current is null) return;
        var dispatcher = System.Windows.Application.Current.Dispatcher;
        if (dispatcher.HasShutdownStarted || dispatcher.HasShutdownFinished) return;
        App.WriteQuickAccessLog($"ShowQuickAccess kind={item.Kind} file={(string.IsNullOrWhiteSpace(item.FilePath) ? "(null)" : item.FilePath)}");
        if (_quickAccess is null)
        {
            _quickAccess = new QuickAccessService(this, _settings);
            App.WriteQuickAccessLog("ShowQuickAccess re-created quick access service");
        }

        void TryShow(string tag)
        {
            if (System.Windows.Application.Current is null || _quickAccess is null) return;
            App.WriteQuickAccessLog($"ShowQuickAccess execute tag={tag} kind={item.Kind} file={(string.IsNullOrWhiteSpace(item.FilePath) ? "(null)" : item.FilePath)}");
            try
            {
                _quickAccess.Show(item);
            }
            catch (Exception exception)
            {
                App.WriteQuickAccessLog($"ShowQuickAccess failed: {exception.Message}");
                try { App.WriteCrashLog(exception); } catch { }
            }
        }

        dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Send, () => TryShow("initial"));
        if (item.Kind is CaptureKind.Screenshot or CaptureKind.ScrollingScreenshot or CaptureKind.ClipboardImage or
            CaptureKind.Recording or CaptureKind.Gif or CaptureKind.ClipboardGif or CaptureKind.ClipboardVideo)
        {
            RetryShowQuickAccess(item, 12, TimeSpan.FromMilliseconds(250));
        }
    }

    private void RetryShowQuickAccess(CaptureHistoryItem item, int attempts, TimeSpan interval)
    {
        if (attempts <= 0)
        {
            App.WriteQuickAccessLog($"RetryShowQuickAccess skipped attempts<=0 kind={item.Kind} file={(string.IsNullOrWhiteSpace(item.FilePath) ? "(null)" : item.FilePath)}");
            return;
        }

        var timer = new System.Windows.Threading.DispatcherTimer { Interval = interval };
        var remaining = attempts;
        timer.Tick += (_, _) =>
        {
            if (remaining <= 0)
            {
                timer.Stop();
                return;
            }

            remaining--;
            if (System.Windows.Application.Current is null || _quickAccess is null) return;
            try { _quickAccess.Show(item); }
            catch (Exception exception)
            {
                App.WriteQuickAccessLog($"RetryShowQuickAccess failed: {exception.Message}");
                try { App.WriteCrashLog(exception); } catch { }
            }
            if (remaining == 0) timer.Stop();
        };
        timer.Start();
    }

    public void RestoreHistoryItem(CaptureHistoryItem item)
    {
        ShowQuickAccess(item);
        if (!string.IsNullOrWhiteSpace(item.FilePath) && File.Exists(item.FilePath))
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(item.FilePath) { UseShellExecute = true });
        else if (item.Kind == CaptureKind.ClipboardText) CopyHistoryItem(item);
    }

    public void PinHistoryItem(CaptureHistoryItem item)
    {
        if (item.Kind is not (CaptureKind.Screenshot or CaptureKind.ScrollingScreenshot or CaptureKind.ClipboardImage) ||
            item.FilePaths.Count > 0 ||
            string.IsNullOrWhiteSpace(item.FilePath) || !File.Exists(item.FilePath)) return;
        if (_activePins.TryGetValue(item.Id, out var existing))
        {
            _quickAccess?.SetItemWindowOpen(item.Id, true);
            existing.RestoreInteraction();
            if (!existing.IsVisible) existing.Show();
            existing.Activate();
            return;
        }
        _ = _history.UpdatePinnedAsync(item, true);
        var pinned = new PinnedImageWindow(_images.Load(item.FilePath), item.FilePath, () =>
        {
            _activePins.Remove(item.Id);
            _ = _history.UpdatePinnedAsync(item, false);
            _quickAccess?.SetItemWindowOpen(item.Id, false);
        });
        _activePins[item.Id] = pinned;
        _quickAccess?.SetItemWindowOpen(item.Id, true);
        pinned.Show();
    }

    public Task DeleteHistoryItemAsync(CaptureHistoryItem item) => _history.RemoveAsync(item, true);

    public async Task SaveHistoryItemAsync(CaptureHistoryItem item)
    {
        var path = item.FilePath;
        if ((string.IsNullOrWhiteSpace(path) || !File.Exists(path)) && item.Kind == CaptureKind.ClipboardText)
        {
            var textDialog = new Microsoft.Win32.SaveFileDialog
            {
                Title = LocalizedDialogService.Text("保存文本"),
                InitialDirectory = _settings.Current.SaveDirectory,
                FileName = $"ShotPaste-Clipboard-{DateTime.Now:yyyyMMdd-HHmmss}.txt",
                DefaultExt = ".txt",
                Filter = LocalizedDialogService.Text("文本文件|*.txt|所有文件|*.*")
            };
            if (textDialog.ShowDialog() == true)
            {
                var loaded = await item.LoadFullTextAsync();
                if (loaded.Text is null)
                {
                    ShowError("保存文本失败", new IOException(loaded.Error ?? "完整文本不可用。"));
                    return;
                }
                await File.WriteAllTextAsync(textDialog.FileName, loaded.Text);
            }
            return;
        }
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = LocalizedDialogService.Text("另存为"),
            InitialDirectory = _settings.Current.SaveDirectory,
            FileName = Path.GetFileName(path),
            DefaultExt = Path.GetExtension(path),
            Filter = LocalizedDialogService.Text("原始格式|*") + Path.GetExtension(path) +
                     LocalizedDialogService.Text("|所有文件|*.*"),
            AddExtension = true,
            OverwritePrompt = true
        };
        if (dialog.ShowDialog() != true) return;
        var destination = Path.GetFullPath(dialog.FileName);
        if (destination.Equals(Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var captureRoot = Path.GetFullPath(AppPaths.Captures).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (Path.GetFullPath(path).StartsWith(captureRoot, StringComparison.OrdinalIgnoreCase))
        {
            File.Move(path, destination, true);
            await _history.RemoveAsync(item, false);
            var updated = await _history.AddFileAsync(destination, item.Kind, item.Duration);
            if (_settings.Current.ShowQuickAccess) ShowQuickAccess(updated);
        }
        else File.Copy(path, destination, true);
    }

    public Task OpenHistoryItemAsync(CaptureHistoryItem item)
    {
        if (item.FilePaths.Count > 0 && item.ExistingFilePaths.Count > 0)
        {
            foreach (var persistedPath in item.ExistingFilePaths)
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(persistedPath) { UseShellExecute = true });
            return Task.CompletedTask;
        }
        var path = item.FilePath;
        if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        else if (item.Kind == CaptureKind.ClipboardText) ShowClipboardText(item);
        return Task.CompletedTask;
    }

    private void ShowClipboardText(CaptureHistoryItem item)
    {
        var window = new ClipboardTextViewerWindow(item)
        {
            Owner = _mainWindow?.IsVisible == true ? _mainWindow : null
        };
        window.Show();
        window.Activate();
    }

    private string ScreenshotOutputDirectory => _settings.Current.SaveScreenshots ? _settings.Current.SaveDirectory : AppPaths.Captures;

    private ScreenCaptureOptions ScreenshotCaptureOptions => new(
        _settings.Current.ShowCursorInScreenshots,
        _settings.Current.HideDesktopIconsInScreenshots,
        _settings.Current.HideDesktopWidgetsInScreenshots,
        _settings.Current.ExcludeOwnApplicationFromScreenshots);

    private ScrollingCaptureService CreateScrollingCaptureService() => new(
        _capture,
        _settings.Current.ScrollingMaxHeight,
        _settings.Current.ScrollingPreviewMaxHeight,
        _settings.Current.ScrollingAutoScrollIntervalMs,
        _settings.Current.ScrollingDetectFixedBars,
        _settings.Current.ScrollingSafetyGuardEnabled,
        () => new ScreenCaptureOptions(
            IncludeCursor: false,
            HideDesktopIcons: false,
            HideDesktopWidgets: false,
            ExcludeOwnApplication: _settings.Current.ExcludeOwnApplicationFromScreenshots));

    private Drawing.Bitmap PrepareScreenshot(Drawing.Bitmap source)
    {
        var scale = _settings.Current.ScreenshotScale switch { 1 => 1d, 2 => 2d, _ => 1d };
        if (Math.Abs(scale - 1d) < 0.001) return new Drawing.Bitmap(source);
        var result = new Drawing.Bitmap(
            Math.Max(1, (int)Math.Round(source.Width * scale)),
            Math.Max(1, (int)Math.Round(source.Height * scale)),
            System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using var graphics = Drawing.Graphics.FromImage(result);
        graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        graphics.DrawImage(source, new Drawing.Rectangle(0, 0, result.Width, result.Height));
        return result;
    }

    private void RunExclusive(Func<Task> operation)
    {
        _ = RunExclusiveCore(operation);
    }

    private async Task RunExclusiveCore(Func<Task> operation)
    {
        if (!await _operationGate.WaitAsync(0)) return;
        try { await operation(); }
        catch (Exception exception) { ShowError("操作失败", exception); RestoreMainWindowIfNeeded(); }
        finally { _operationGate.Release(); }
    }

    private CaptureHideState HideApplicationWindows(bool forRecording = false)
    {
        var shouldHide = ShouldHideOwnApplication(_settings.Current, forRecording);
        if (!shouldHide)
        {
            _restoreMainAfterCapture = false;
            return CaptureHideState.Empty;
        }
        var hiddenWindows = new List<CaptureHideProbe>();
        _restoreMainAfterCapture = _mainWindow?.IsVisible == true;
        _resumeQuickAccessAfterCapture = _quickAccess?.IsSuspended == false;
        if (_resumeQuickAccessAfterCapture) _quickAccess?.SuspendAll();
        _tray?.DismissMessage();
        var app = System.Windows.Application.Current;
        if (app is null) return new CaptureHideState(hiddenWindows);
        foreach (Window window in app.Windows.Cast<Window>().ToArray())
        {
            if (!window.IsVisible
                || window is ScrollingProgressWindow
                || window is RecordingToolbarWindow
                || window is RecordingRegionOverlayWindow)
            {
                continue;
            }

            try
            {
                var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle;
                CaptureHideProbe? probe = null;
                if (handle != IntPtr.Zero && NativeMethods.GetWindowRect(handle, out var nativeBounds))
                {
                    var bounds = Rectangle.FromLTRB(nativeBounds.Left, nativeBounds.Top, nativeBounds.Right, nativeBounds.Bottom);
                    if (bounds.Width > 0 && bounds.Height > 0)
                        probe = CaptureReadinessService.CreateProbe(handle, bounds);
                }
                window.Hide();
                if (probe is not null) hiddenWindows.Add(probe);
                App.WriteQuickAccessLog($"HideApplicationWindows hidden {window.GetType().Name}");
            }
            catch (Exception exception)
            {
                App.WriteQuickAccessLog($"HideApplicationWindows failed for {window.GetType().Name}: {exception.Message}");
            }
        }
        return new CaptureHideState(hiddenWindows);
    }

    private void RecordCaptureReadiness(CaptureReadinessResult result)
    {
        App.WriteQuickAccessLog(
            $"CaptureReadiness scenario={result.Scenario} totalMs={result.TotalMilliseconds:0.###} hidden={result.HiddenWindowCount} remaining={result.RemainingVisibleWindows} stale={result.RemainingStaleProbes} transitions={result.PixelTransitionsObserved} dwm={result.DwmResult} remote={result.RemoteSession}");
        if (App.UiTestMode || _settings.Current.DiagnosticsEnabled) CaptureReadinessService.AppendEvidence(result);
    }

    internal static bool ShouldHideOwnApplication(AppSettings settings, bool forRecording) =>
        forRecording ? !settings.IncludeShotPasteInRecording : settings.ExcludeOwnApplicationFromScreenshots;

    private void RestoreMainWindowIfNeeded()
    {
        // Capture commands launched from the history window restore it; tray-launched commands leave it hidden.
        if (_restoreMainAfterCapture && _mainWindow is not null) _mainWindow.Show();
        _restoreMainAfterCapture = false;
        if (_resumeQuickAccessAfterCapture) _quickAccess?.ResumeAll();
        _resumeQuickAccessAfterCapture = false;
    }

    private void ShowError(string title, Exception exception) => _tray?.ShowMessage(title, exception.Message, Forms.ToolTipIcon.Error);

    private void Exit()
    {
        _mainWindow?.CloseForExit();
        System.Windows.Application.Current.Shutdown();
    }

    public void Dispose()
    {
        _historyMaintenanceTimer?.Stop();
        _recording.Dispose();
        _keystrokeOverlay?.Dispose();
        _mouseClickOverlay?.Dispose();
        CloseRecordingInk();
        _recordingRegionOverlay?.Close();
        foreach (var pinned in _activePins.Values.ToArray()) pinned.Close();
        _activePins.Clear();
        _quickAccess?.Dispose();
        _clipboard?.Dispose();
        _hotkeys?.Dispose();
        _tray?.Dispose();
        _operationGate.Dispose();
    }
}
