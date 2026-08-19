using System.Collections.Specialized;
using System.Drawing;
using System.Net.Http;
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
    private readonly AppUpdateService _updateService = new();
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly ImageFileService _images;
    private readonly OcrService _ocr;
    private readonly IRecoverableFileOperations _recoverableFiles = new ShellRecoverableFileOperations();
    private readonly WindowCaptureExclusionService _recordingCaptureExclusion = new();
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
    private ShotPasteMcpServer? _mcpServer;
    private readonly Dictionary<Guid, PinnedImageWindow> _activePins = [];
    private Rectangle? _currentRecordingRectangle;
    private TaskCompletionSource<bool>? _activeRecordingWorkflow;
    private TaskCompletionSource<bool>? _activeScrollingWorkflow;
    private ScrollingProgressWindow? _activeScrollingWindow;
    private bool _exitInProgress;
    private readonly Queue<IReadOnlyList<string>> _pendingCommands = new();
    private bool _ready;
    private bool _settingsWindowOpen;
    private SettingsWindow? _settingsWindow;
    private string? _databaseRecoveryArchivePath;

    public AppController()
    {
        _images = new ImageFileService(_settings);
        _ocr = new OcrService(() => _settings.Current.OcrRecognitionLanguage.Equals("Auto", StringComparison.OrdinalIgnoreCase)
            ? _settings.Current.Language
            : _settings.Current.OcrRecognitionLanguage,
            () => _settings.Current.ShowOcrLinkNotifications);
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
        ApplyOperatingSystemIntegrations();
        if (!await EnsureHistoryDatabaseReadyForLaunchAsync()) return;
        var recoveryScan = await RecordingRecoveryService.ScanAsync();
        if (recoveryScan.Recording is { } recovered &&
            !_history.Items.Any(item => string.Equals(item.FilePath, recovered.Path, StringComparison.OrdinalIgnoreCase)))
            await _history.AddFileAsync(recovered.Path, CaptureKind.Recording, recovered.Duration);
        await _history.ClearSessionPinnedStateAsync();
        await _history.PruneAsync(_settings.Current.HistoryRetentionDays, _settings.Current.HistoryMaxCount);
        _selection = new RegionSelectionService(
            _capture,
            () => ScreenshotCaptureOptions,
            () => _settings.Current,
            _settings.Save);
        _scrolling = CreateScrollingCaptureService();
        if (!App.UiTestMode)
        {
            _hotkeys = new GlobalHotkeyService();
            _tray = new TrayIconService(
                _settings.Current,
                () => _recording.Elapsed,
                () => _quickAccess?.HasVisibleItems == true,
                () => _settingsWindow?.IsVisible == true ? _settingsWindow : null);
        }
        if (!App.UiTestMode || App.UiTestClipboardMonitorEnabled)
            _clipboard = new ClipboardMonitorService(_history, _settings);
        _quickAccess = new QuickAccessService(this, _settings);
        WireEvents();
        if (!string.IsNullOrWhiteSpace(_settings.LastConfigurationWarning))
            _tray?.ShowMessage("设置已恢复", _settings.LastConfigurationWarning, Forms.ToolTipIcon.Warning);
        _hotkeys?.RegisterConfigured(_settings.Current);
        if (recoveryScan.Recording is not null)
            _tray?.ShowMessage("已恢复上次录屏", Path.GetFileName(recoveryScan.Recording.Path));
        else if (!string.IsNullOrWhiteSpace(recoveryScan.Warning))
            _tray?.ShowMessage("录屏恢复", recoveryScan.Warning, Forms.ToolTipIcon.Warning);
        _mainWindow = new MainWindow(this, _history, _settings);
        _mcpServer = new ShotPasteMcpServer(new ShotPasteMcpProtocol(
            ExecuteMcpToolAsync,
            GetMcpStatus,
            typeof(AppController).Assembly.GetName().Version?.ToString() ?? "1.0.0"));
        ApplyMcpSettings();
        if (!string.IsNullOrWhiteSpace(_databaseRecoveryArchivePath))
            _tray?.ShowMessage(
                LocalizationService.TranslatePhrase("数据库已重置"),
                LocalizationService.TranslatePhrase("旧数据库已保存在：") + _databaseRecoveryArchivePath,
                Forms.ToolTipIcon.Warning);
        if (App.UiTestMode)
        {
            _mainWindow.Show();
            _mainWindow.WindowState = WindowState.Normal;
        }
        _historyMaintenanceTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromHours(24) };
        _historyMaintenanceTimer.Tick += async (_, _) => await _history.PruneAsync(_settings.Current.HistoryRetentionDays, _settings.Current.HistoryMaxCount);
        _historyMaintenanceTimer.Start();
        if (_hotkeys?.FailedActions.Count > 0)
            _tray?.ShowMessage("部分快捷键不可用", "快捷键已被其他程序占用，可继续使用托盘菜单。", Forms.ToolTipIcon.Warning);
        _ready = true;
        while (_pendingCommands.Count > 0) HandleExternalCommand(_pendingCommands.Dequeue());
        if (!App.UiTestMode && AppBuildIdentity.Current.PerformsAutomaticUpdateChecks)
            _ = CheckForUpdatesAutomaticallyAsync();
    }

    private async Task<bool> EnsureHistoryDatabaseReadyForLaunchAsync()
    {
        Exception? currentError = null;
        string? note = null;
        while (true)
        {
            try
            {
                await _history.LoadAsync();
                return true;
            }
            catch (Exception exception) when (DatabaseRecoveryService.IsRecoverableLaunchFailure(exception))
            {
                currentError = exception;
            }

            var details = $"{LocalizationService.TranslatePhrase("ShotPaste 需要历史数据库才能运行。")}\n\n" +
                          $"{LocalizationService.TranslatePhrase("数据库：")}\n{_history.DatabasePath}\n\n" +
                          $"{LocalizationService.TranslatePhrase("错误：")}\n{currentError.Message}";
            if (!string.IsNullOrWhiteSpace(note)) details += $"\n\n{LocalizationService.TranslatePhrase(note)}";
            details += "\n\n" + LocalizationService.TranslatePhrase(
                "请先尝试修复。重置会把现有数据库移到恢复文件夹，再创建空数据库；磁盘上的截图、录屏和剪贴板文件不会被删除。");
            var action = LocalizedDialogService.ShowCustom(
                null,
                details,
                "ShotPaste 无法打开数据库",
                "尝试修复",
                "重置数据库…",
                "退出 ShotPaste",
                MessageBoxImage.Error);

            if (action == MessageBoxResult.Yes)
            {
                note = "修复未成功。你可以在备份现有数据库后重置，或退出 ShotPaste。";
                continue;
            }

            if (action == MessageBoxResult.No)
            {
                var confirm = LocalizedDialogService.ShowCustom(
                    null,
                    $"{LocalizationService.TranslatePhrase("ShotPaste 会把当前数据库文件移到恢复文件夹，然后创建新的空数据库。")}\n\n" +
                    $"{LocalizationService.TranslatePhrase("这会清空 ShotPaste 内的历史记录，但不会删除磁盘上的截图、录屏或剪贴板文件。")}\n\n" +
                    $"{LocalizationService.TranslatePhrase("数据库：")}\n{_history.DatabasePath}\n\n" +
                    $"{LocalizationService.TranslatePhrase("当前错误：")}\n{currentError.Message}",
                    "重置 ShotPaste 数据库？",
                    "重置数据库",
                    "取消",
                    MessageBoxImage.Warning);
                if (confirm != MessageBoxResult.Yes)
                {
                    note = null;
                    continue;
                }

                try
                {
                    var archive = DatabaseRecoveryService.ArchiveDatabaseFiles(_history.DatabasePath);
                    _databaseRecoveryArchivePath = archive.ArchiveDirectory;
                    note = "旧数据库已移到恢复文件夹，但 ShotPaste 仍无法创建新数据库。";
                    continue;
                }
                catch (Exception resetException) when (DatabaseRecoveryService.IsRecoverableLaunchFailure(resetException))
                {
                    currentError = resetException;
                    note = "重置在创建新数据库前失败。";
                    continue;
                }
            }

            System.Windows.Application.Current.Shutdown(1);
            return false;
        }
    }

    private async Task CheckForUpdatesAutomaticallyAsync()
    {
        if (!_settings.Current.CheckForUpdatesAutomatically) return;
        var checkedAt = DateTimeOffset.UtcNow;
        if (_settings.Current.LastUpdateCheckUtc is { } lastCheck &&
            checkedAt - lastCheck < TimeSpan.FromHours(24))
            return;

        try
        {
            var result = await _updateService.CheckForUpdatesAsync();
            _settings.Current.LastUpdateCheckUtc = checkedAt;
            if (result.Availability != AppUpdateAvailability.UpdateAvailable)
            {
                _settings.Save();
                return;
            }

            var version = result.LatestRelease.Version.ToString();
            if (string.Equals(
                    _settings.Current.LastPromptedUpdateVersion,
                    version,
                    StringComparison.OrdinalIgnoreCase))
            {
                _settings.Save();
                return;
            }

            _settings.Current.LastPromptedUpdateVersion = version;
            _settings.Save();
            if (LocalizedDialogService.Show(
                    $"{LocalizedDialogService.Text("当前版本")}: {result.CurrentVersion}\n" +
                    $"{LocalizedDialogService.Text("最新版本")}: {result.LatestRelease.Version}\n\n" +
                    LocalizedDialogService.Text("是否前往 GitHub Release 页面下载更新？"),
                    LocalizedDialogService.Text("软件更新"),
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information) == MessageBoxResult.Yes)
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                    result.LatestRelease.PageUri.AbsoluteUri) { UseShellExecute = true });
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or
                                                System.Text.Json.JsonException or InvalidDataException or
                                                IOException or UnauthorizedAccessException or
                                                System.ComponentModel.Win32Exception)
        {
            _settings.Current.LastUpdateCheckUtc = checkedAt;
            try { _settings.Save(); } catch (Exception saveException) when (saveException is IOException or UnauthorizedAccessException) { }
            App.WriteQuickAccessLog($"Automatic GitHub update check failed: {exception.GetType().Name}");
        }
    }

    public void HandleExternalCommand(IReadOnlyList<string> arguments)
    {
        if (!_ready)
        {
            _pendingCommands.Enqueue(arguments.ToArray());
            return;
        }
        if (App.UiTestMode && arguments.Any(argument =>
                argument.Equals("--ui-test-exit", StringComparison.OrdinalIgnoreCase)))
        {
            Exit();
            return;
        }
        var uiTestSurface = App.UiTestMode
            ? arguments.FirstOrDefault(argument => argument.StartsWith("--ui-test-surface=", StringComparison.OrdinalIgnoreCase))
            : null;
        if (uiTestSurface is not null)
        {
            ShowUiTestSurface(uiTestSurface.Split('=', 2)[1]);
            return;
        }
        var parsed = UrlSchemeService.Parse(arguments);
        if (parsed.Command == AppCommand.None) return;
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
            case AppCommand.OneShot:
                StartOneShot(command.CaptureMode switch
                {
                    "scrolling" => OneShotMode.Scrolling,
                    "recording" => OneShotMode.Recording,
                    "ocr" => OneShotMode.Ocr,
                    _ => OneShotMode.Screenshot
                });
                break;
            case AppCommand.CancelCapture:
            {
                var overlay = System.Windows.Application.Current.Windows.OfType<InlineAnnotateWindow>()
                    .FirstOrDefault(window => window.IsVisible);
                if (overlay is null)
                    _tray?.ShowMessage("无法取消捕获", "当前没有正在进行的 One Shot。", Forms.ToolTipIcon.Warning);
                else
                    overlay.RequestExternalCancel();
                break;
            }
            case AppCommand.History: ShowHistory(command.HistoryFilter); break;
            case AppCommand.Settings: ShowSettings(command.SettingsTab); break;
            case AppCommand.ControlRecording: ExecuteExternalRecordingAction(command.RecordingAction); break;
        }
    }

    private void ExecuteExternalRecordingAction(string? action)
    {
        if (!_recording.IsRecording)
        {
            _tray?.ShowMessage("无法控制录屏", "当前没有正在进行的录屏。", Forms.ToolTipIcon.Warning);
            return;
        }
        if (action == "pause" && !_recording.IsPaused) _recording.TogglePause();
        else if (action == "resume" && _recording.IsPaused) _recording.TogglePause();
        else if (action == "stop") _recording.Stop();
        else
            _tray?.ShowMessage("无法控制录屏", action == "pause" ? "录屏已经暂停。" : "录屏当前并未暂停。", Forms.ToolTipIcon.Warning);
    }

    private void WireEvents()
    {
        if (_tray is not null)
        {
            _tray.RecordingRequested += (_, _) => { if (_recording.IsRecording) _recording.Stop(); };
            _tray.PauseRecordingRequested += (_, _) => _recording.TogglePause();
            _tray.OneShotRequested += (_, _) => StartOneShot();
            _tray.HistoryRequested += (_, _) => ShowHistory();
            _tray.FocusQuickAccessRequested += (_, _) => _quickAccess?.FocusNewest();
            _tray.SettingsRequested += (_, _) => ShowSettings();
            _tray.ExitRequested += (_, _) => Exit();
        }
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
        if (_hotkeys is null) return;
        _hotkeys.Triggered += (_, action) => System.Windows.Application.Current.Dispatcher.Invoke(() =>
        {
            switch (action)
            {
                case HotkeyAction.OneShot: StartOneShot(); break;
                case HotkeyAction.History: ShowHistory(); break;
                case HotkeyAction.RecordingPause:
                    if (_recording.IsRecording) _recording.TogglePause();
                    break;
                case HotkeyAction.RecordingAnnotation:
                    if (_recording.IsRecording && _currentRecordingRectangle is { } recordingRectangle)
                        ToggleRecordingInk(recordingRectangle);
                    break;
                case HotkeyAction.RecordingRestart:
                    RequestRecordingRestart();
                    break;
                case HotkeyAction.RecordingDelete:
                    RequestRecordingDiscard();
                    break;
            }
        });
    }

    private async Task CaptureScrollingCoreAsync(Rectangle initialRegion)
    {
        if (_scrolling is null) return;
        var workflow = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _activeScrollingWorkflow = workflow;
        _scrolling = CreateScrollingCaptureService();
        HideApplicationWindows();
        var region = initialRegion;
        using var cancellation = new CancellationTokenSource();
        var outline = new RecordingRegionOverlayWindow(
            region,
            _capture.VirtualBounds,
            constrainToRegionScreen: true);
        var preview = new ScrollingPreviewWindow();
        var window = new ScrollingProgressWindow(_settings.Current.ScrollingShowHints, preview);
        _activeScrollingWindow = window;
        var startCompletion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var discard = false;
        var autoScrollState = 0;
        var finishState = 0;
        window.StartRequested += (_, _) => startCompletion.TrySetResult(true);
        window.DoneRequested += (_, _) =>
        {
            if (Interlocked.Exchange(ref finishState, 1) != 0) return;
            window.BeginFinalizing();
            // The incremental canvas is already the product. Exit capture UI
            // immediately while the tail fence, final crop, encoding, and
            // history insertion continue in the protected workflow.
            window.Hide();
            preview.Hide();
            outline.Hide();
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
        preview.Show();
        window.Show();
        Bitmap? captured = null;
        try
        {
            try
            {
                var shouldStart = await startCompletion.Task;
                if (!shouldStart || discard) return;

                outline.SetScrollingAppearance(capturing: true);
                window.BeginCapture(true);
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
                    () => Volatile.Read(ref autoScrollState) == 1,
                    () => discard,
                    () => Volatile.Read(ref finishState) == 1);
            }
            catch (OperationCanceledException)
            {
                captured = null;
            }

            using var capturedResult = captured;
            // The scrolling canvas already owns the final 32-bpp bitmap. Avoid
            // cloning the entire long image at the default 1x scale; only create
            // a second bitmap when the user explicitly requests 2x output.
            using var scaledResult = capturedResult is not null && _settings.Current.ScreenshotScale == 2
                ? PrepareScreenshot(capturedResult)
                : null;
            var result = scaledResult ?? capturedResult;
            if (discard || result is null) return;

            await SaveScrollingResultWithRecoveryAsync(window, result);
        }
        finally
        {
            window.CloseAfterWorkflow();
            preview.Close();
            outline.Close();
            RestoreMainWindowIfNeeded();
            workflow.TrySetResult(true);
            if (ReferenceEquals(_activeScrollingWorkflow, workflow)) _activeScrollingWorkflow = null;
            if (ReferenceEquals(_activeScrollingWindow, window)) _activeScrollingWindow = null;
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
        ClipboardWriter.SetText(result.Text);
        if (_settings.Current.ShowOcrLinkNotifications && result.Links.Count > 0)
        {
            var resultWindow = new OcrResultWindow(result)
            {
                Owner = _mainWindow?.IsVisible == true ? _mainWindow : null
            };
            resultWindow.Show();
        }
        else if (_settings.Current.ShowOcrSuccessNotifications)
            _tray?.ShowMessage("文字已复制", result.Text.Length > 90 ? result.Text[..90] + "…" : result.Text);
    }

    public void StartOneShot() => StartOneShot(OneShotMode.Screenshot);

    internal void StartOneShot(OneShotMode initialMode) => RunExclusive(async () =>
    {
        if (_selection is null) return;
        var recordingOptions = new OneShotRecordingOptions(
            _settings.Current.RecordingOutputMode,
            _settings.Current.IncludeCursorInRecording,
            _settings.Current.RecordSystemAudio,
            _settings.Current.RecordMicrophone);
        using var result = await _selection.SelectOneShotAsync(recordingOptions, CommitScreenshotFromOverlayAsync, initialMode);
        if (result is null) return;

        switch (result.Mode)
        {
            case OneShotMode.Screenshot when result.Image is not null:
                if (!result.ScreenshotCommitted)
                {
                    using var image = PrepareScreenshot(result.Image);
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
                ShowClipboardHistory();
                break;
        }
    });

    private async Task<bool> CommitScreenshotFromOverlayAsync(Window owner, Bitmap rendered, bool pin)
    {
        using var image = PrepareScreenshot(rendered);
        string? savedPath = null;
        while (savedPath is null)
        {
            try
            {
                savedPath = _images.Save(image, ScreenshotOutputDirectory, CaptureKind.Screenshot);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                               System.ComponentModel.Win32Exception or ExternalException)
            {
                var decision = LocalizedDialogService.ShowCustom(
                    owner,
                    $"截图尚未写入磁盘：{exception.Message}\n\n成果仍保留在标注窗口中。可以重试、选择其他位置，或返回后使用复制按钮。",
                    "截图保存失败",
                    "重试",
                    "选择其他位置",
                    "返回",
                    MessageBoxImage.Error);
                if (decision == MessageBoxResult.Yes) continue;
                if (decision != MessageBoxResult.No) return false;

                var dialog = new Microsoft.Win32.SaveFileDialog
                {
                    Title = LocalizedDialogService.Text("选择截图保存位置"),
                    InitialDirectory = _settings.Current.SaveDirectory,
                    FileName = Path.GetFileName(_images.NewPath(_settings.Current.SaveDirectory, CaptureKind.Screenshot)),
                    DefaultExt = ".png",
                    Filter = LocalizedDialogService.Text("图片文件|*.png;*.jpg;*.jpeg;*.webp|所有文件|*.*"),
                    AddExtension = true,
                    OverwritePrompt = true
                };
                if (dialog.ShowDialog(owner) != true) return false;
                try
                {
                    _images.SaveToPath(image, dialog.FileName);
                    savedPath = dialog.FileName;
                }
                catch (Exception saveAsException) when (saveAsException is IOException or UnauthorizedAccessException or
                                                        System.ComponentModel.Win32Exception or ExternalException)
                {
                    LocalizedDialogService.Show(owner, $"仍无法保存：{saveAsException.Message}", "截图保存失败",
                        MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
        }

        try
        {
            var item = await FinishImageCaptureAsync(savedPath, CaptureKind.Screenshot, image);
            if (pin) PinHistoryItem(item);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ExternalException or
                                           Microsoft.Data.Sqlite.SqliteException)
        {
            LocalizedDialogService.Show(
                owner,
                $"截图已保存到：\n{savedPath}\n\n但写入历史或剪贴板失败：{exception.Message}",
                "截图已保存",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
        return true;
    }

    private void ShowUiTestSurface(string surface)
    {
        switch (surface.ToLowerInvariant())
        {
            case "ocr":
                new OcrResultWindow(new OcrRecognitionResult(
                    "ShotPaste OCR localization preview\nhttps://shotpaste.local/help",
                    [],
                    ["https://shotpaste.local/help"],
                    [])).Show();
                break;
            case "scrolling-recovery":
            {
                var preview = new ScrollingPreviewWindow();
                var hud = new ScrollingProgressWindow(showHints: true, preview);
                hud.ShowReady(new Rectangle(120, 120, 760, 520));
                preview.Show();
                hud.Show();
                _ = hud.WaitForSaveRecoveryActionAsync("保存失败，成果仍保留；可重试、另存或复制");
                hud.Closed += (_, _) => preview.Close();
                break;
            }
            case "recording-toolbar":
                _recordingToolbar = new RecordingToolbarWindow(_recording, _settings.Current);
                _recordingToolbar.Show();
                break;
            case "quick-access":
                _settings.Current.QuickAccessAutoDismissEnabled = false;
                new QuickAccessWindow(new CaptureHistoryItem
                {
                    Kind = CaptureKind.ClipboardText,
                    Text = "ShotPaste localization preview"
                }, this, _settings).Show();
                break;
            case "dialog":
                LocalizedDialogService.ShowCustom(
                    _mainWindow,
                    "您有未保存的更改。您想在关闭前保存吗？",
                    "未保存的更改",
                    "保存",
                    "不要保存",
                    "取消",
                    MessageBoxImage.Warning);
                break;
        }
    }

    private async Task<bool> SaveScrollingResultWithRecoveryAsync(
        ScrollingProgressWindow window,
        Bitmap result)
    {
        Exception? lastFailure = null;
        while (true)
        {
            if (lastFailure is null)
            {
                window.BeginSaving();
                await window.Dispatcher.InvokeAsync(
                    window.UpdateLayout,
                    System.Windows.Threading.DispatcherPriority.Render);
                await Task.Delay(16);
            }

            try
            {
                var path = _images.Save(result, ScreenshotOutputDirectory, CaptureKind.ScrollingScreenshot);
                await FinishSavedScrollingResultAsync(window, path, result);
                return true;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                               System.ComponentModel.Win32Exception or ExternalException)
            {
                lastFailure = exception;
            }

            var action = await window.WaitForSaveRecoveryActionAsync(
                $"{lastFailure.Message}\n成果仍在内存中，可重试、选择其他位置或复制到剪贴板。");
            switch (action)
            {
                case ScrollingSaveRecoveryAction.Retry:
                    lastFailure = null;
                    continue;
                case ScrollingSaveRecoveryAction.Copy:
                    try
                    {
                        ClipboardWriter.SetImage(BitmapSourceFactory.FromBitmap(result));
                        lastFailure = new IOException("成果已复制到剪贴板，但尚未写入磁盘。");
                    }
                    catch (ExternalException exception)
                    {
                        lastFailure = exception;
                    }
                    continue;
                case ScrollingSaveRecoveryAction.SaveAs:
                {
                    var dialog = new Microsoft.Win32.SaveFileDialog
                    {
                        Title = LocalizedDialogService.Text("选择长图保存位置"),
                        InitialDirectory = _settings.Current.SaveDirectory,
                        FileName = Path.GetFileName(_images.NewPath(_settings.Current.SaveDirectory, CaptureKind.ScrollingScreenshot)),
                        DefaultExt = ".png",
                        Filter = LocalizedDialogService.Text("图片文件|*.png;*.jpg;*.jpeg;*.webp|所有文件|*.*"),
                        AddExtension = true,
                        OverwritePrompt = true
                    };
                    if (dialog.ShowDialog(window) != true) continue;
                    try
                    {
                        _images.SaveToPath(result, dialog.FileName);
                        await FinishSavedScrollingResultAsync(window, dialog.FileName, result);
                        return true;
                    }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
                                                       System.ComponentModel.Win32Exception or ExternalException)
                    {
                        lastFailure = exception;
                        continue;
                    }
                }
                case ScrollingSaveRecoveryAction.Discard:
                    var decision = LocalizedDialogService.ShowCustom(
                        window,
                        "长图尚未保存。确定丢弃当前合并成果吗？此操作无法恢复。",
                        "丢弃长图？",
                        "丢弃成果",
                        "返回",
                        MessageBoxImage.Warning);
                    if (decision == MessageBoxResult.Yes) return false;
                    continue;
                case ScrollingSaveRecoveryAction.DiscardConfirmed:
                    return false;
            }
        }
    }

    private async Task FinishSavedScrollingResultAsync(
        Window owner,
        string path,
        Bitmap result)
    {
        try
        {
            _ = await FinishImageCaptureAsync(path, CaptureKind.ScrollingScreenshot, result);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ExternalException or
                                           Microsoft.Data.Sqlite.SqliteException)
        {
            LocalizedDialogService.Show(
                owner,
                $"长图已保存到：\n{path}\n\n但写入历史或剪贴板失败：{exception.Message}",
                "长图已保存",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

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
        var workflow = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _activeRecordingWorkflow = workflow;
        var completedSafely = false;
        ApplyRecordingRequestSettings(request);
        var target = request.Target;
        var rectangle = target.Bounds;

        _recordingRegionOverlay ??= new RecordingRegionOverlayWindow(rectangle, _capture.VirtualBounds);
        if (!_recordingRegionOverlay.IsVisible) _recordingRegionOverlay.Show();
        _recordingRegionOverlay.SetRecordingAppearance(request.DimNonSelectedArea);
        _recordingCaptureExclusion.SetEnabled(!request.IncludeShotPaste);
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
                    ShowRecordingToolbar(rectangle);
                }
                var path = await completion;
                var duration = _recording.Elapsed;
                _recordingToolbar?.Close(); _recordingToolbar = null;
                CloseRecordingInk();
                _keystrokeOverlay?.Dispose(); _keystrokeOverlay = null;
                _mouseClickOverlay?.Dispose(); _mouseClickOverlay = null;
                if (_discardRecording || _restartRecording)
                {
                    var removal = _recoverableFiles.MoveToRecycleBin(path);
                    if (removal.Succeeded) continue;

                    _discardRecording = false;
                    _restartRecording = false;
                    LocalizedDialogService.Show(
                        $"录屏未能移入 Windows 回收站，因此文件已保留并会加入历史。\n\n{removal.Error}",
                        "无法丢弃录屏",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error);
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
            completedSafely = true;
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
        finally
        {
            _recordingCaptureExclusion.SetEnabled(false);
            workflow.TrySetResult(completedSafely);
            if (ReferenceEquals(_activeRecordingWorkflow, workflow)) _activeRecordingWorkflow = null;
        }
    }

    private void ShowRecordingToolbar(Rectangle rectangle)
    {
        if (_recordingToolbar is { IsVisible: true }) return;
        var toolbar = new RecordingToolbarWindow(_recording, () => _settings.Current, _settings.Save);
        _recordingToolbar = toolbar;
        toolbar.StopRequested += (_, _) => _recording.Stop();
        toolbar.DeleteRequested += (_, _) => RequestRecordingDiscard();
        toolbar.RestartRequested += (_, _) => RequestRecordingRestart();
        toolbar.PenRequested += (_, _) => ToggleRecordingInk(rectangle);
        toolbar.Closed += (_, _) =>
        {
            if (ReferenceEquals(_recordingToolbar, toolbar)) _recordingToolbar = null;
        };
        toolbar.Show();
    }

    private void RequestRecordingRestart()
    {
        if (!_recording.IsRecording || _restartRecording || _discardRecording) return;
        var decision = LocalizedDialogService.ShowCustom(
            _recordingToolbar,
            "重新录制会停止当前录屏，并把当前文件移入 Windows 回收站。确定继续吗？",
            "重新录制？",
            "移入回收站并重录",
            "继续当前录屏",
            MessageBoxImage.Warning);
        if (decision != MessageBoxResult.Yes) return;
        _restartRecording = true;
        _recording.Stop();
    }

    private void RequestRecordingDiscard()
    {
        if (!_recording.IsRecording || _restartRecording || _discardRecording) return;
        var decision = LocalizedDialogService.ShowCustom(
            _recordingToolbar,
            "删除会停止当前录屏，并把当前文件移入 Windows 回收站。确定继续吗？",
            "删除录屏？",
            "移入回收站",
            "继续录屏",
            MessageBoxImage.Warning);
        if (decision != MessageBoxResult.Yes) return;
        _discardRecording = true;
        _recording.Stop();
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
            _recordingInkToolbar = new RecordingInkToolbarWindow(_recordingInk, _recordingToolbar);
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
            ClipboardWriter.SetImage(BitmapSourceFactory.FromBitmap(image));
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
            if (item.Kind == CaptureKind.ClipboardText)
            {
                var loaded = await item.LoadFullTextAsync();
                if (loaded.Text is null)
                {
                    ShowError("复制失败", new IOException(loaded.Error ?? "完整文本不可用。"));
                    return;
                }
                ClipboardWriter.SetText(loaded.Text);
                if (loaded.IsLimited && !string.IsNullOrWhiteSpace(loaded.Error))
                    _tray?.ShowMessage("文本已受限", loaded.Error, Forms.ToolTipIcon.Warning);
            }
            else if (item.FilePaths.Count > 0 && item.ExistingFilePaths.Count > 0)
            {
                var files = new StringCollection();
                files.AddRange(item.ExistingFilePaths.ToArray());
                ClipboardWriter.SetFileDropList(files);
            }
            else if (!string.IsNullOrWhiteSpace(item.FilePath) && File.Exists(item.FilePath))
            {
                if (item.Kind is CaptureKind.Screenshot or CaptureKind.ScrollingScreenshot or CaptureKind.ClipboardImage)
                {
                    var image = BitmapSourceFactory.FromPath(item.FilePath);
                    if (image is not null) ClipboardWriter.SetImage(image);
                }
                else
                {
                    var files = new StringCollection { item.FilePath };
                    ClipboardWriter.SetFileDropList(files);
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
            var files = new StringCollection();
            files.AddRange(paths);
            ClipboardWriter.SetFileDropList(files);
        }
        else
        {
            var loaded = await Task.WhenAll(selected
                .Where(item => item.Kind == CaptureKind.ClipboardText)
                .Select(item => item.LoadFullTextAsync()));
            var text = string.Join(Environment.NewLine + Environment.NewLine,
                loaded.Select(result => result.Text).Where(value => !string.IsNullOrWhiteSpace(value)));
            if (text.Length > 0) ClipboardWriter.SetText(text);
        }
    }

    public void ShowHistory()
    {
        if (_mainWindow is null) return;
        _mainWindow.ShowDefaultHistory();
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    private void ShowClipboardHistory()
    {
        if (_mainWindow is null) return;
        _mainWindow.ShowClipboardHistory();
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    private void ShowHistory(string? filter)
    {
        if (_mainWindow is null) return;
        if (string.IsNullOrWhiteSpace(filter)) _mainWindow.ShowDefaultHistory();
        else _mainWindow.ShowHistoryFilter(filter);
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    public void ShowSettings(string? tab = null)
    {
        if (_settingsWindow is { } existing)
        {
            existing.NavigateToTab(tab);
            if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal;
            existing.Activate();
            existing.Focus();
            var handle = new System.Windows.Interop.WindowInteropHelper(existing).Handle;
            if (handle != IntPtr.Zero) NativeMethods.SetForegroundWindow(handle);
            return;
        }

        var window = new SettingsWindow(_settings, tab, ApplyLiveSettings)
        {
            Owner = _mainWindow?.IsVisible == true ? _mainWindow : null
        };
        _settingsWindow = window;
        _hotkeys?.Suspend();
        _settingsWindowOpen = true;
        var saved = false;
        try
        {
            saved = window.ShowDialog() == true;
            if (saved) ApplyLiveSettings();
        }
        finally
        {
            if (ReferenceEquals(_settingsWindow, window)) _settingsWindow = null;
            _settingsWindowOpen = false;
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
        _mainWindow?.ApplyHistoryPresentation();
        _quickAccess?.RefreshSettings();
        ApplyOperatingSystemIntegrations();
        App.ConfigureDiagnostics(_settings.Current.DiagnosticsEnabled);
        if (!_settingsWindowOpen) _hotkeys?.RegisterConfigured(_settings.Current);
        _tray?.UpdateShortcuts(_settings.Current);
        _recordingCaptureExclusion.SetEnabled(_recording.IsRecording && !_settings.Current.IncludeShotPasteInRecording);
        if (_recording.IsRecording && _currentRecordingRectangle is { } rectangle)
        {
            _recordingRegionOverlay?.SetRecordingAppearance(_settings.Current.DimNonSelectedRecordingArea);
            if (_settings.Current.ShowRecordingToolbar) ShowRecordingToolbar(rectangle);
            else
            {
                _recordingToolbar?.Close();
                _recordingToolbar = null;
            }
        }
        ApplyMcpSettings();
    }

    private void ApplyMcpSettings()
    {
        if (_mcpServer is null) return;
        if (_settings.Current.McpServerEnabled && string.IsNullOrWhiteSpace(_settings.Current.McpServerAuthToken))
        {
            _settings.Current.McpServerAuthToken = Convert.ToBase64String(
                    System.Security.Cryptography.RandomNumberGenerator.GetBytes(32))
                .TrimEnd('=').Replace('+', '-').Replace('/', '_');
            _settings.Save();
        }
        _mcpServer.Apply(
            _settings.Current.McpServerEnabled,
            _settings.Current.McpServerPort,
            _settings.Current.McpServerAuthToken);
        if (_settings.Current.McpServerEnabled && _mcpServer.LastError is { } error)
            _tray?.ShowMessage("MCP Server 启动失败", error, Forms.ToolTipIcon.Warning);
    }

    private Task<McpAutomationResult> ExecuteMcpToolAsync(
        string name,
        System.Text.Json.Nodes.JsonObject arguments,
        CancellationToken cancellationToken)
    {
        var dispatcher = System.Windows.Application.Current.Dispatcher;
        if (dispatcher.CheckAccess()) return Task.FromResult(ExecuteMcpTool(name, arguments));
        return dispatcher.InvokeAsync(() => ExecuteMcpTool(name, arguments),
            System.Windows.Threading.DispatcherPriority.Normal, cancellationToken).Task;
    }

    private McpAutomationResult ExecuteMcpTool(string name, System.Text.Json.Nodes.JsonObject arguments)
    {
        switch (name)
        {
            case "shotpaste.start_capture":
            {
                if (_operationGate.CurrentCount == 0 || System.Windows.Application.Current.Windows.OfType<InlineAnnotateWindow>().Any(window => window.IsVisible))
                    return McpAutomationResult.Failure("A capture or another exclusive operation is already active.", GetMcpStatus().State);
                var mode = ShotPasteMcpProtocol.ReadString(arguments, "mode") switch
                {
                    "scrolling" => OneShotMode.Scrolling,
                    "recording" => OneShotMode.Recording,
                    _ => OneShotMode.Screenshot
                };
                StartOneShot(mode);
                return new McpAutomationResult(true, $"Started One Shot in {mode.ToString().ToLowerInvariant()} mode.", GetMcpStatus().State);
            }
            case "shotpaste.cancel_capture":
            {
                var overlay = System.Windows.Application.Current.Windows.OfType<InlineAnnotateWindow>().FirstOrDefault(window => window.IsVisible);
                if (overlay is null) return McpAutomationResult.Failure("No One Shot capture is active.", GetMcpStatus().State);
                overlay.RequestExternalCancel();
                return new McpAutomationResult(true, "Requested cancellation of the active One Shot capture.", GetMcpStatus().State);
            }
            case "shotpaste.open_history":
            {
                var filter = ShotPasteMcpProtocol.ReadString(arguments, "filter");
                ShowHistory(filter);
                return new McpAutomationResult(true, $"Opened history{(filter is null ? string.Empty : $" with {filter} filter")}.", GetMcpStatus().State);
            }
            case "shotpaste.open_settings":
            {
                var rawTab = ShotPasteMcpProtocol.ReadString(arguments, "tab");
                var tab = rawTab == "appearance" ? "appearance" : UrlSchemeService.NormalizeSettingsTab(rawTab);
                if (rawTab is not null && tab is null)
                    return McpAutomationResult.Failure("Unknown settings tab.", GetMcpStatus().State);
                _ = System.Windows.Application.Current.Dispatcher.BeginInvoke(() => ShowSettings(tab));
                return new McpAutomationResult(true, "Opened settings.", GetMcpStatus().State);
            }
            case "shotpaste.control_recording":
            {
                var action = ShotPasteMcpProtocol.ReadString(arguments, "action");
                var transitionError = RecordingActionError(action, _recording.IsRecording, _recording.IsPaused);
                if (transitionError is not null)
                    return McpAutomationResult.Failure(transitionError, GetMcpStatus().State);
                if (action is "pause" or "resume") _recording.TogglePause();
                else if (action == "stop") _recording.Stop();
                return new McpAutomationResult(true, $"Recording {action} request accepted.", GetMcpStatus().State);
            }
            default:
                return McpAutomationResult.Failure("Unknown MCP tool.", GetMcpStatus().State);
        }
    }

    private McpAutomationResult GetMcpStatus()
    {
        var dispatcher = System.Windows.Application.Current.Dispatcher;
        if (!dispatcher.CheckAccess()) return dispatcher.Invoke(GetMcpStatus);
        var oneShot = System.Windows.Application.Current.Windows.OfType<InlineAnnotateWindow>()
            .FirstOrDefault(window => window.IsVisible);
        var state = BuildMcpStatusState(
            oneShot?.CurrentOneShotMode,
            _activeScrollingWorkflow is not null,
            _recording.IsRecording,
            _recording.IsPaused,
            _recording.IsPostProcessing,
            _recording.Elapsed,
            _mainWindow?.IsVisible == true);
        return new McpAutomationResult(true, "ShotPaste status read.", state);
    }

    internal static IReadOnlyDictionary<string, string> BuildMcpStatusState(
        OneShotMode? oneShotMode,
        bool scrollingActive,
        bool recordingActive,
        bool recordingPaused,
        bool recordingPostProcessing,
        TimeSpan recordingDuration,
        bool historyVisible) => new Dictionary<string, string>
        {
            ["platform"] = "Windows",
            ["oneShot"] = oneShotMode is null ? "idle" : "active",
            ["oneShotMode"] = oneShotMode?.ToString().ToLowerInvariant() ?? "none",
            ["scrollingCapture"] = scrollingActive ? "active" : "idle",
            ["recording"] = recordingPostProcessing ? "stopping" :
                !recordingActive ? "idle" : recordingPaused ? "paused" : "recording",
            ["recordingDuration"] = $"{(int)recordingDuration.TotalMinutes:00}:{recordingDuration.Seconds:00}",
            ["historyVisible"] = historyVisible ? "true" : "false"
        };

    internal static string? RecordingActionError(string? action, bool recordingActive, bool recordingPaused) => action switch
    {
        "pause" when recordingActive && !recordingPaused => null,
        "pause" => "No running recording can be paused.",
        "resume" when recordingActive && recordingPaused => null,
        "resume" => "No paused recording can be resumed.",
        "stop" when recordingActive => null,
        "stop" => "No active recording can be stopped.",
        _ => "Unknown recording action."
    };

    private void ApplyOperatingSystemIntegrations()
    {
        if (App.UiTestMode) return;
        StartupService.Apply(_settings.Current.LaunchAtStartup);
        UrlSchemeService.Apply(_settings.Current.UrlSchemeEnabled);
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

    public async Task<bool> DeleteHistoryItemAsync(CaptureHistoryItem item, Window? owner = null)
    {
        var decision = LocalizedDialogService.ShowCustom(
            owner,
            "确定删除这条历史记录吗？由 ShotPaste 保存的文件会移入 Windows 回收站，可以恢复。",
            "删除历史记录",
            "移入回收站",
            "取消",
            MessageBoxImage.Warning);
        if (decision != MessageBoxResult.Yes) return false;

        var result = await _history.RemoveAsync(item, true);
        if (result.RecordRemoved) return true;
        var detail = string.Join("\n", result.Failures.Take(3).Select(failure =>
            $"{Path.GetFileName(failure.Path)}：{failure.Message}"));
        LocalizedDialogService.Show(
            owner,
            $"未能完成安全文件处理或历史数据库更新，因此记录仍然保留，可重试。\n\n{detail}",
            "删除失败",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        return false;
    }

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
        captureOptionsProvider: () => new ScreenCaptureOptions(
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

    internal bool HasProtectedWork =>
        _recording.IsRecording ||
        _activeRecordingWorkflow is not null ||
        _activeScrollingWorkflow is not null ||
        System.Windows.Application.Current.Windows.OfType<InlineAnnotateWindow>()
            .Any(window => window.IsVisible && window.HasUnsavedAnnotations);

    internal void RequestSessionEnding() => _ = ExitAsync();

    private void Exit() => _ = ExitAsync();

    private async Task<bool> ExitAsync()
    {
        if (_exitInProgress) return false;
        _exitInProgress = true;
        try
        {
            var editor = System.Windows.Application.Current.Windows.OfType<InlineAnnotateWindow>()
                .FirstOrDefault(window => window.IsVisible);
            if (editor is not null && !await editor.RequestCloseForExitAsync())
            {
                return false;
            }

            var scrollingWindow = _activeScrollingWindow;
            var scrollingWorkflow = _activeScrollingWorkflow;
            if (scrollingWindow is not null)
            {
                if (!scrollingWindow.RequestCloseForExit()) return false;
                if (scrollingWorkflow is not null) await scrollingWorkflow.Task;
            }

            var recordingWorkflow = _activeRecordingWorkflow;
            if (_recording.IsRecording || recordingWorkflow is not null)
            {
                var decision = LocalizedDialogService.ShowCustom(
                    _recordingToolbar,
                    "当前正在录屏。停止并保存后退出、丢弃录屏并退出，还是取消退出？",
                    "退出 ShotPaste？",
                    "停止并保存",
                    "丢弃并退出",
                    "取消",
                    MessageBoxImage.Warning);
                if (decision == MessageBoxResult.Cancel) return false;

                _restartRecording = false;
                _discardRecording = decision == MessageBoxResult.No;
                if (_recording.IsRecording) _recording.Stop();
                if (recordingWorkflow is not null && !await recordingWorkflow.Task) return false;
            }

            _mainWindow?.CloseForExit();
            System.Windows.Application.Current.Shutdown();
            return true;
        }
        finally
        {
            if (!System.Windows.Application.Current.Dispatcher.HasShutdownStarted)
                _exitInProgress = false;
        }
    }

    public void Dispose()
    {
        _historyMaintenanceTimer?.Stop();
        _recordingCaptureExclusion.Dispose();
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
        _mcpServer?.Dispose();
        _operationGate.Dispose();
    }
}
