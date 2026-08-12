using System.Net.Http;
using System.Windows;
using System.Windows.Input;
using System.Text.Json;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using WpfTextBox = System.Windows.Controls.TextBox;

namespace ShotPaste.Windows.Views;

public partial class SettingsWindow : Window
{
    private readonly SettingsStore _store;
    private readonly AppUpdateService _updateService = new();
    private AppSettings _draft;
    private Uri? _availableUpdatePageUri;

    public SettingsWindow(SettingsStore store, string? initialTab = null)
    {
        InitializeComponent();
        _store = store;
        _draft = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(store.Current)) ?? new AppSettings();
        DataContext = _draft;
        UpdateStatus.Text = $"{LocalizedDialogService.Text("当前版本")}: {_updateService.CurrentVersionString}";
        SelectInitialTab(initialTab);
        Loaded += async (_, _) => await RefreshRecordingFormatSupportAsync();
    }

    private async Task RefreshRecordingFormatSupportAsync()
    {
        var support = await RecordingFormatCapabilityService.ProbeAsync();
        var decision = RecordingFormatCapabilityService.Resolve(
            _draft.RecordingVideoFormat,
            _draft.RecordingVideoCodec,
            support);
        RecordingHevcItem.IsEnabled = support.HevcEncoderAvailable;
        RecordingHevcItem.ToolTip = support.HevcEncoderAvailable
            ? $"Windows 已检测到 {support.HevcEncoderCount} 个 HEVC 编码器。"
            : "当前系统没有可用的 HEVC 编码器；选择或导入 HEVC 时会安全回退到 H.264。";
        RecordingMovItem.ToolTip = "ScreenRecorderLib 6.6 仅输出 ISO MP4；导入 MOV 偏好时 Windows 会安全输出 MP4。";
        RecordingFormatStatus.Text = decision.UsedFallback
            ? $"当前偏好将实际输出 {decision.ActualContainer.ToUpperInvariant()} / {DisplayRecordingCodec(decision.ActualCodec)}。{support.Detail}"
            : $"可用：{decision.ActualContainer.ToUpperInvariant()} / {DisplayRecordingCodec(decision.ActualCodec)}。{support.Detail}";
    }

    private static string DisplayRecordingCodec(string codec) => codec.Equals("Hevc", StringComparison.OrdinalIgnoreCase)
        ? "HEVC (H.265)"
        : "H.264";

    private async void OnRecordingFormatChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.DataBind);
        await RefreshRecordingFormatSupportAsync();
    }

    private void SelectInitialTab(string? tab)
    {
        var item = UrlSchemeService.NormalizeSettingsTab(tab) switch
        {
            "general" => GeneralTab,
            "capture-recording" => CaptureRecordingTab,
            "quick-access" => QuickAccessTab,
            "history" => HistoryTab,
            "shortcuts-appearance" => ShortcutsTab,
            "scrolling" => ScrollingTab,
            "screenshot" => ScreenshotTab,
            "advanced" => AdvancedTab,
            _ => null
        };
        if (item is not null) item.IsSelected = true;
    }

    private void OnChooseDirectory(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            InitialDirectory = _draft.SaveDirectory,
            Description = LocalizedDialogService.Text("选择 ShotPaste 保存目录"),
            UseDescriptionForTitle = true
        };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            _draft.SaveDirectory = dialog.SelectedPath;
        DataContext = null;
        DataContext = _draft;
    }

    private void OnHotkeyGotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (sender is WpfTextBox textBox)
            textBox.SelectAll();
    }

    private void OnHotkeyPreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not WpfTextBox textBox || textBox.IsKeyboardFocusWithin)
            return;

        e.Handled = true;
        textBox.Focus();
    }

    private void OnHotkeyPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (sender is not WpfTextBox textBox)
            return;

        e.Handled = true;
        if (e.Key == Key.Escape)
        {
            textBox.GetBindingExpression(WpfTextBox.TextProperty)?.UpdateTarget();
            Keyboard.ClearFocus();
            return;
        }

        if (e.Key is Key.Delete or Key.Back)
        {
            if (textBox.Tag is string clearPropertyName && typeof(AppSettings).GetProperty(clearPropertyName) is { PropertyType: not null } clearProperty)
            {
                clearProperty.SetValue(_draft, string.Empty);
                textBox.GetBindingExpression(WpfTextBox.TextProperty)?.UpdateTarget();
            }
            return;
        }

        if (!HotkeyGestureFormatter.TryFormat(e.Key, e.SystemKey, Keyboard.Modifiers, out var gesture))
            return;

        if (textBox.Tag is not string propertyName)
            return;

        var property = typeof(AppSettings).GetProperty(propertyName);
        if (property?.PropertyType != typeof(string))
            return;

        property.SetValue(_draft, gesture);
        textBox.GetBindingExpression(WpfTextBox.TextProperty)?.UpdateTarget();
        textBox.SelectAll();
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (_draft.ShortcutsEnabled)
        {
            var gestures = GetHotkeys().Where(entry => !string.IsNullOrWhiteSpace(entry.Gesture)).ToArray();
            if (gestures.Any(entry => !GlobalHotkeyService.TryParseGesture(entry.Gesture, out _, out _)))
            {
                LocalizedDialogService.Show(this, "快捷键格式无效。请使用类似 Ctrl+Shift+4 的组合。", "ShotPaste", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            var conflicts = gestures.GroupBy(entry => entry.Gesture, StringComparer.OrdinalIgnoreCase)
                .Where(group => group.Count() > 1)
                .Select(group => $"{group.Key}：{string.Join("、", group.Select(entry => entry.Name))}")
                .ToArray();
            if (conflicts.Length > 0)
            {
                LocalizedDialogService.Show(this, "快捷键存在内部冲突：\n\n" + string.Join("\n", conflicts), "ShotPaste", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
        }
        _draft.JpegQuality = Math.Clamp(_draft.JpegQuality, 1, 100);
        _draft.HistoryRetentionDays = Math.Max(0, _draft.HistoryRetentionDays);
        _draft.HistoryMaxCount = Math.Max(0, _draft.HistoryMaxCount);
        _draft.DiagnosticsRetentionDays = Math.Clamp(_draft.DiagnosticsRetentionDays, 1, 30);
        _draft.HistoryPanelScale = Math.Clamp(_draft.HistoryPanelScale, 0.75d, 1.5d);
        _draft.HistoryPanelMaxItems = Math.Clamp(_draft.HistoryPanelMaxItems, 3, 50);
        _draft.QuickAccessAutoDismissSeconds = Math.Clamp(_draft.QuickAccessAutoDismissSeconds, 3, 30);
        _draft.QuickAccessScale = Math.Clamp(_draft.QuickAccessScale, 0.75d, 1.5d);
        _draft.RecordingGifFps = Math.Clamp(_draft.RecordingGifFps, 5, 30);
        try
        {
            _draft.SaveDirectory = Path.GetFullPath(_draft.SaveDirectory);
            Directory.CreateDirectory(_draft.SaveDirectory);
            _store.Replace(_draft);
            DialogResult = true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            LocalizedDialogService.Show(this, "无法保存设置：" + exception.Message, "ShotPaste",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void OnPreviewRecordingEffects(object sender, RoutedEventArgs e)
    {
        var width = Math.Min(520, Math.Max(320, ActualWidth - 180));
        var localTopLeft = new System.Windows.Point((ActualWidth - width) / 2d, Math.Max(90, ActualHeight / 2d - 90));
        var localBottomRight = new System.Windows.Point(localTopLeft.X + width, localTopLeft.Y + 180);
        var screenTopLeft = PointToScreen(localTopLeft);
        var screenBottomRight = PointToScreen(localBottomRight);
        var preview = new System.Drawing.Rectangle(
            (int)Math.Round(screenTopLeft.X),
            (int)Math.Round(screenTopLeft.Y),
            Math.Max(1, (int)Math.Round(screenBottomRight.X - screenTopLeft.X)),
            Math.Max(1, (int)Math.Round(screenBottomRight.Y - screenTopLeft.Y)));
        var clicks = new MouseClickOverlayWindow(preview, _draft);
        var keys = new KeystrokeOverlayWindow(preview, _draft);
        try
        {
            clicks.Show();
            keys.Show();
            clicks.ShowClick(new System.Drawing.Point(preview.Left + preview.Width / 2, preview.Top + preview.Height / 2), false);
            keys.ShowGesture("Ctrl + Shift + 5");
            await Task.Delay(Math.Max(_draft.RecordingClickDurationMs, _draft.RecordingKeystrokeDurationMs) + 350);
        }
        finally
        {
            clicks.Close();
            keys.Close();
        }
    }

    private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;

    private async void OnCheckForUpdates(object sender, RoutedEventArgs e)
    {
        CheckForUpdatesButton.IsEnabled = false;
        CheckForUpdatesButton.Content = LocalizedDialogService.Text("正在检查更新...");
        UpdateStatus.Text = LocalizedDialogService.Text("正在检查更新...");
        try
        {
            var result = await _updateService.CheckForUpdatesAsync();
            _draft.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            if (result.Availability == AppUpdateAvailability.UpdateAvailable)
            {
                _availableUpdatePageUri = result.LatestRelease.PageUri;
                _draft.LastPromptedUpdateVersion = result.LatestRelease.Version.ToString();
                UpdateStatus.Text = $"{LocalizedDialogService.Text("发现新版本")} · v{result.LatestRelease.Version}";
                OpenUpdatePageButton.Content = LocalizedDialogService.Text("前往 GitHub");
                OpenUpdatePageButton.Visibility = Visibility.Visible;
                if (ShowUpdateAvailablePrompt(result) == MessageBoxResult.Yes)
                    OpenTarget(result.LatestRelease.PageUri.AbsoluteUri);
            }
            else
            {
                _availableUpdatePageUri = null;
                OpenUpdatePageButton.Visibility = Visibility.Collapsed;
                UpdateStatus.Text = $"{LocalizedDialogService.Text("ShotPaste 已是最新版本。")} · v{result.CurrentVersion}";
                LocalizedDialogService.Show(
                    this,
                    $"{LocalizedDialogService.Text("ShotPaste 已是最新版本。")}\n\n{LocalizedDialogService.Text("当前版本")}: {result.CurrentVersion}",
                    LocalizedDialogService.Text("软件更新"),
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException or InvalidDataException)
        {
            _availableUpdatePageUri = null;
            OpenUpdatePageButton.Visibility = Visibility.Collapsed;
            UpdateStatus.Text = LocalizedDialogService.Text("无法检查更新，请确认网络连接后重试。");
            App.WriteQuickAccessLog($"GitHub update check failed: {exception.GetType().Name}");
            LocalizedDialogService.Show(
                this,
                "无法检查更新，请确认网络连接后重试。",
                "软件更新",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
        finally
        {
            CheckForUpdatesButton.Content = LocalizedDialogService.Text("检查更新");
            CheckForUpdatesButton.IsEnabled = true;
        }
    }

    private MessageBoxResult ShowUpdateAvailablePrompt(AppUpdateCheckResult result) =>
        LocalizedDialogService.Show(
            this,
            $"{LocalizedDialogService.Text("当前版本")}: {result.CurrentVersion}\n" +
            $"{LocalizedDialogService.Text("最新版本")}: {result.LatestRelease.Version}\n\n" +
            LocalizedDialogService.Text("是否前往 GitHub Release 页面下载更新？"),
            LocalizedDialogService.Text("软件更新"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Information);

    private void OnOpenUpdatePage(object sender, RoutedEventArgs e)
    {
        if (_availableUpdatePageUri is not null)
            OpenTarget(_availableUpdatePageUri.AbsoluteUri);
    }

    private void OnOpenReportPage(object sender, RoutedEventArgs e) => OpenTarget("https://github.com/shotpaste/shotpaste/issues");

    private void OnOpenLogDirectory(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(AppPaths.Root);
        OpenTarget(AppPaths.Root);
    }

    private void OnOpenLegalNotices(object sender, RoutedEventArgs e)
    {
        var localNotices = Path.Combine(AppContext.BaseDirectory, "THIRD_PARTY_NOTICES.md");
        OpenTarget(File.Exists(localNotices)
            ? localNotices
            : "https://github.com/shotpaste/shotpaste/blob/main/THIRD_PARTY_NOTICES.md");
    }

    private static void OpenTarget(string target) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target) { UseShellExecute = true });

    private (string Name, string Gesture)[] GetHotkeys() =>
    [
        ("One Shot", _draft.OneShotHotkey),
        ("剪贴板历史", _draft.HistoryHotkey), ("切换剪贴板历史布局", _draft.HistoryModeHotkey),
        ("录屏暂停/继续", _draft.RecordingPauseHotkey),
        ("录屏标注", _draft.RecordingAnnotationHotkey), ("重新录制", _draft.RecordingRestartHotkey),
        ("删除当前录屏", _draft.RecordingDeleteHotkey)
    ];

    private void OnResetHotkeys(object sender, RoutedEventArgs e)
    {
        var defaults = new AppSettings();
        CopyHotkeys(defaults);
    }

    private void OnClearHotkeys(object sender, RoutedEventArgs e)
    {
        var empty = new AppSettings
        {
            OneShotHotkey = string.Empty,
            HistoryHotkey = string.Empty, HistoryModeHotkey = string.Empty,
            RecordingPauseHotkey = string.Empty, RecordingAnnotationHotkey = string.Empty,
            RecordingRestartHotkey = string.Empty, RecordingDeleteHotkey = string.Empty
        };
        CopyHotkeys(empty);
    }

    private void CopyHotkeys(AppSettings source)
    {
        _draft.OneShotHotkey = source.OneShotHotkey;
        _draft.HistoryHotkey = source.HistoryHotkey; _draft.HistoryModeHotkey = source.HistoryModeHotkey;
        _draft.RecordingPauseHotkey = source.RecordingPauseHotkey;
        _draft.RecordingAnnotationHotkey = source.RecordingAnnotationHotkey;
        _draft.RecordingRestartHotkey = source.RecordingRestartHotkey; _draft.RecordingDeleteHotkey = source.RecordingDeleteHotkey;
        DataContext = null;
        DataContext = _draft;
    }

    private void OnRestoreDefaults(object sender, RoutedEventArgs e)
    {
        if (LocalizedDialogService.Show(this, "恢复默认设置？当前快捷键会保留。", "ShotPaste",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;

        var previous = _draft;
        _draft = new AppSettings
        {
            ShortcutsEnabled = previous.ShortcutsEnabled,
            OneShotHotkey = previous.OneShotHotkey,
            HistoryHotkey = previous.HistoryHotkey,
            HistoryModeHotkey = previous.HistoryModeHotkey,
            RecordingPauseHotkey = previous.RecordingPauseHotkey,
            RecordingAnnotationHotkey = previous.RecordingAnnotationHotkey,
            RecordingRestartHotkey = previous.RecordingRestartHotkey,
            RecordingDeleteHotkey = previous.RecordingDeleteHotkey
        };
        DataContext = null;
        DataContext = _draft;
    }
}
