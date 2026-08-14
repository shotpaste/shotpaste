using System.Net.Http;
using System.Windows;
using System.Windows.Input;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Animation;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using WpfTextBox = System.Windows.Controls.TextBox;

namespace ShotPaste.Windows.Views;

public partial class SettingsWindow : Window
{
    private readonly SettingsStore _store;
    private readonly Action? _settingsApplied;
    private readonly AppUpdateService _updateService = new();
    private AppSettings _draft;
    private Uri? _availableUpdatePageUri;
    private System.Windows.Point _quickActionDragOrigin;
    private int _quickActionDragIndex = -1;
    private readonly System.Windows.Threading.DispatcherTimer _liveApplyTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(180)
    };
    private bool _readyForLiveApply;
    private bool _refreshingBindings;

    public SettingsWindow(SettingsStore store, string? initialTab = null, Action? settingsApplied = null)
    {
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        _store = store;
        _settingsApplied = settingsApplied;
        _draft = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(store.Current)) ?? new AppSettings();
        DataContext = _draft;
        UpdateStatus.Text = $"{LocalizedDialogService.Text("当前版本")}: {_updateService.CurrentVersionString}";
        SelectInitialTab(initialTab);
        Loaded += async (_, _) =>
        {
            WindowAppearanceService.ConstrainToWorkingArea(this);
            UpdateUrlSchemeLabel();
            UpdateQuickAccessPreview();
            await RefreshHistoryStorageAsync();
            await RefreshRecordingFormatSupportAsync();
            _readyForLiveApply = true;
        };
        _liveApplyTimer.Tick += (_, _) =>
        {
            _liveApplyTimer.Stop();
            _ = TryApplyDraft(showErrors: false);
        };
        AddHandler(System.Windows.Controls.Primitives.ToggleButton.CheckedEvent, new RoutedEventHandler(OnLiveSettingChanged));
        AddHandler(System.Windows.Controls.Primitives.ToggleButton.UncheckedEvent, new RoutedEventHandler(OnLiveSettingChanged));
        AddHandler(System.Windows.Controls.Primitives.Selector.SelectionChangedEvent,
            new System.Windows.Controls.SelectionChangedEventHandler(OnLiveSelectionChanged));
        AddHandler(System.Windows.Controls.Primitives.RangeBase.ValueChangedEvent,
            new RoutedPropertyChangedEventHandler<double>(OnLiveRangeChanged));
        AddHandler(Keyboard.LostKeyboardFocusEvent, new KeyboardFocusChangedEventHandler(OnLiveKeyboardFocusLost));
        Closed += (_, _) =>
        {
            _liveApplyTimer.Stop();
            if (_readyForLiveApply) _ = TryApplyDraft(showErrors: false);
        };
    }

    private void UpdateUrlSchemeLabel()
    {
        if (!AppBuildIdentity.Current.IsDebug || UrlSchemeCheckBox.Content is not string label) return;
        UrlSchemeCheckBox.Content = label.Replace(
            "shotpaste://",
            $"{AppBuildIdentity.Current.UrlScheme}://",
            StringComparison.OrdinalIgnoreCase);
    }

    private void OnCopyMcpConfiguration(object sender, RoutedEventArgs e)
    {
        EnsureMcpToken();
        var configuration = JsonSerializer.Serialize(new
        {
            mcpServers = new Dictionary<string, object>
            {
                ["shotpaste"] = new
                {
                    url = $"http://127.0.0.1:{_draft.McpServerPort}/mcp",
                    headers = new Dictionary<string, string>
                    {
                        ["Authorization"] = $"Bearer {_draft.McpServerAuthToken}"
                    }
                }
            }
        }, new JsonSerializerOptions { WriteIndented = true });
        System.Windows.Clipboard.SetText(configuration);
        McpServerStatusText.Text = "连接配置已复制；其中包含私密 Token，请勿公开或提交到仓库。";
        ScheduleLiveApply();
    }

    private void EnsureMcpToken()
    {
        if (!string.IsNullOrWhiteSpace(_draft.McpServerAuthToken)) return;
        _draft.McpServerAuthToken = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
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
            "scrolling" or "screenshot" => CaptureRecordingTab,
            "appearance" => AppearanceTab,
            "advanced" => AdvancedTab,
            _ => null
        };
        if (item is not null) item.IsSelected = true;
    }

    private void OnSettingsTabChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!IsLoaded || !ReferenceEquals(e.Source, SettingsTabs)) return;
        if (AccessibilityPreferences.ReduceMotion) return;
        _ = Dispatcher.BeginInvoke(() =>
        {
            if (SettingsTabs.Template.FindName("PART_SelectedContentHost", SettingsTabs) is not System.Windows.Controls.ContentPresenter host) return;
            host.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(150))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
            var translate = host.RenderTransform as TranslateTransform ?? new TranslateTransform();
            host.RenderTransform = translate;
            translate.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(4, 0, TimeSpan.FromMilliseconds(150))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
        });
    }

    private void OnLiveSettingChanged(object sender, RoutedEventArgs e) => ScheduleLiveApply();
    private void OnLiveSelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e) => ScheduleLiveApply();
    private void OnLiveRangeChanged(object sender, RoutedPropertyChangedEventArgs<double> e) => ScheduleLiveApply();
    private void OnLiveKeyboardFocusLost(object sender, KeyboardFocusChangedEventArgs e) => ScheduleLiveApply();

    private void ScheduleLiveApply()
    {
        if (!_readyForLiveApply || _refreshingBindings) return;
        _liveApplyTimer.Stop();
        _liveApplyTimer.Start();
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
        RefreshBindings();
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
        if (TryApplyDraft(showErrors: true)) DialogResult = true;
    }

    private bool TryApplyDraft(bool showErrors)
    {
        if (_draft.ShortcutsEnabled)
        {
            var gestures = GetHotkeys().Where(entry => !string.IsNullOrWhiteSpace(entry.Gesture)).ToArray();
            if (gestures.Any(entry => !GlobalHotkeyService.TryParseGesture(entry.Gesture, out _, out _)))
            {
                if (showErrors) LocalizedDialogService.Show(this, "快捷键格式无效。请使用类似 Ctrl+Shift+4 的组合。", "ShotPaste", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
            var conflicts = gestures.GroupBy(entry => entry.Gesture, StringComparer.OrdinalIgnoreCase)
                .Where(group => group.Count() > 1)
                .Select(group => $"{group.Key}：{string.Join("、", group.Select(entry => entry.Name))}")
                .ToArray();
            if (conflicts.Length > 0)
            {
                if (showErrors) LocalizedDialogService.Show(this, "快捷键存在内部冲突：\n\n" + string.Join("\n", conflicts), "ShotPaste", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
        }
        _draft.JpegQuality = Math.Clamp(_draft.JpegQuality, 1, 100);
        _draft.HistoryRetentionDays = Math.Max(0, _draft.HistoryRetentionDays);
        _draft.HistoryMaxCount = Math.Max(0, _draft.HistoryMaxCount);
        _draft.DiagnosticsRetentionDays = Math.Clamp(_draft.DiagnosticsRetentionDays, 1, 30);
        _draft.QuickAccessAutoDismissSeconds = Math.Clamp(_draft.QuickAccessAutoDismissSeconds, 3, 30);
        _draft.QuickAccessScale = Math.Clamp(_draft.QuickAccessScale, 0.75d, 1.5d);
        _draft.RecordingGifFps = Math.Clamp(_draft.RecordingGifFps, 5, 30);
        try
        {
            _draft.SaveDirectory = Path.GetFullPath(_draft.SaveDirectory);
            Directory.CreateDirectory(_draft.SaveDirectory);
            if (_draft.McpServerEnabled) EnsureMcpToken();
            var persisted = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(_draft)) ?? new AppSettings();
            _store.Replace(persisted);
            _settingsApplied?.Invoke();
            if (McpServerStatusText is not null)
                McpServerStatusText.Text = _draft.McpServerEnabled
                    ? $"监听地址：http://127.0.0.1:{_draft.McpServerPort}/mcp"
                    : "MCP Server 已关闭；仅启用时监听本机回环地址。";
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            if (showErrors) LocalizedDialogService.Show(this, "无法保存设置：" + exception.Message, "ShotPaste",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
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

    private void OnQuickActionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        _ = Dispatcher.BeginInvoke(UpdateQuickAccessPreview, System.Windows.Threading.DispatcherPriority.DataBind);
    }

    private async void OnRefreshHistoryStorage(object sender, RoutedEventArgs e) =>
        await RefreshHistoryStorageAsync();

    private void OnOpenHistoryDirectory(object sender, RoutedEventArgs e) => OpenTarget(AppPaths.Root);

    private async Task RefreshHistoryStorageAsync()
    {
        if (HistoryStorageUsageText is null) return;
        HistoryStorageUsageText.Text = "正在计算存储占用…";
        try
        {
            var bytes = await Task.Run(() => Directory.Exists(AppPaths.Root)
                ? Directory.EnumerateFiles(AppPaths.Root, "*", SearchOption.AllDirectories)
                    .Sum(path =>
                    {
                        try { return new FileInfo(path).Length; }
                        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return 0L; }
                    })
                : 0L);
            HistoryStorageUsageText.Text = $"历史与缩略图占用：{FormatByteSize(bytes)}";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            HistoryStorageUsageText.Text = $"无法读取存储占用：{exception.Message}";
        }
    }

    private static string FormatByteSize(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        var value = (double)Math.Max(0, bytes);
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; }
        return $"{value:0.#} {units[unit]}";
    }

    private void OnQuickActionDragStart(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: not null } handle ||
            !int.TryParse(handle.Tag.ToString(), out _quickActionDragIndex)) return;
        _quickActionDragOrigin = e.GetPosition(this);
    }

    private void OnQuickActionDragMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (_quickActionDragIndex < 0 || e.LeftButton != MouseButtonState.Pressed) return;
        var current = e.GetPosition(this);
        if (Math.Abs(current.X - _quickActionDragOrigin.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(current.Y - _quickActionDragOrigin.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        System.Windows.DragDrop.DoDragDrop((DependencyObject)sender, _quickActionDragIndex, System.Windows.DragDropEffects.Move);
        _quickActionDragIndex = -1;
    }

    private void OnQuickActionHandleKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Alt) == 0 ||
            sender is not FrameworkElement { Tag: not null } handle ||
            !int.TryParse(handle.Tag.ToString(), out var sourceIndex)) return;
        var delta = e.Key switch
        {
            Key.Left or Key.Up => -1,
            Key.Right or Key.Down => 1,
            _ => 0
        };
        var targetIndex = sourceIndex + delta;
        if (delta == 0 || targetIndex is < 0 or > 5) return;
        EnsureQuickActionSlots();
        (_draft.QuickAccessActions[sourceIndex], _draft.QuickAccessActions[targetIndex]) =
            (_draft.QuickAccessActions[targetIndex], _draft.QuickAccessActions[sourceIndex]);
        RefreshQuickActionDesigner();
        e.Handled = true;
    }

    private void OnQuickActionDrop(object sender, System.Windows.DragEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: not null } target ||
            !int.TryParse(target.Tag.ToString(), out var targetIndex) ||
            e.Data.GetData(typeof(int)) is not int sourceIndex ||
            sourceIndex == targetIndex) return;
        EnsureQuickActionSlots();
        (_draft.QuickAccessActions[sourceIndex], _draft.QuickAccessActions[targetIndex]) =
            (_draft.QuickAccessActions[targetIndex], _draft.QuickAccessActions[sourceIndex]);
        RefreshQuickActionDesigner();
        e.Handled = true;
    }

    private void OnResetQuickActions(object sender, RoutedEventArgs e)
    {
        _draft.QuickAccessActions = ["Copy", "SaveOrOpen", "Close", "Delete", "Pin", "None"];
        RefreshQuickActionDesigner();
    }

    private void RefreshQuickActionDesigner()
    {
        RefreshBindings();
        UpdateQuickAccessPreview();
    }

    private void RefreshBindings()
    {
        _refreshingBindings = true;
        try
        {
            DataContext = null;
            DataContext = _draft;
        }
        finally { _refreshingBindings = false; }
        ScheduleLiveApply();
    }

    private void EnsureQuickActionSlots()
    {
        _draft.QuickAccessActions ??= [];
        while (_draft.QuickAccessActions.Count < 6) _draft.QuickAccessActions.Add("None");
        if (_draft.QuickAccessActions.Count > 6) _draft.QuickAccessActions = _draft.QuickAccessActions.Take(6).ToList();
    }

    private void UpdateQuickAccessPreview()
    {
        if (QuickPreviewAction1 is null) return;
        EnsureQuickActionSlots();
        var buttons = new[]
        {
            QuickPreviewAction1, QuickPreviewAction2, QuickPreviewAction3,
            QuickPreviewAction4, QuickPreviewAction5, QuickPreviewAction6
        };
        for (var index = 0; index < buttons.Length; index++)
        {
            var action = _draft.QuickAccessActions[index];
            buttons[index].Content = action switch
            {
                "Copy" => "复制", "SaveOrOpen" => "保存", "Close" => "关闭",
                "Delete" => "删除", "Pin" => "贴图", _ => "—"
            };
            buttons[index].Opacity = action == "None" ? 0.35 : 1;
            buttons[index].IsEnabled = action != "None";
        }
    }

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
        ("剪贴板历史", _draft.HistoryHotkey),
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
            HistoryHotkey = string.Empty,
            RecordingPauseHotkey = string.Empty, RecordingAnnotationHotkey = string.Empty,
            RecordingRestartHotkey = string.Empty, RecordingDeleteHotkey = string.Empty
        };
        CopyHotkeys(empty);
    }

    private void CopyHotkeys(AppSettings source)
    {
        _draft.OneShotHotkey = source.OneShotHotkey;
        _draft.HistoryHotkey = source.HistoryHotkey;
        _draft.RecordingPauseHotkey = source.RecordingPauseHotkey;
        _draft.RecordingAnnotationHotkey = source.RecordingAnnotationHotkey;
        _draft.RecordingRestartHotkey = source.RecordingRestartHotkey; _draft.RecordingDeleteHotkey = source.RecordingDeleteHotkey;
        RefreshBindings();
    }

    private void OnRestoreDefaults(object sender, RoutedEventArgs e)
    {
        if (LocalizedDialogService.Show(this, "恢复全部默认设置？全局快捷键也会恢复默认值。", "ShotPaste",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;

        _draft = new AppSettings();
        RefreshBindings();
    }
}
