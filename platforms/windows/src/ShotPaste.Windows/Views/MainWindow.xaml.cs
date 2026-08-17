using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Utilities;
using Button = System.Windows.Controls.Button;
using Panel = System.Windows.Controls.Panel;
using ListBox = System.Windows.Controls.ListBox;

namespace ShotPaste.Windows.Views;

public partial class MainWindow : Window
{
    private readonly AppController _controller;
    private readonly CaptureHistoryStore _history;
    private readonly SettingsStore _settings;
    private CancellationTokenSource? _filterCancellation;
    private bool _allowClose;
    private string _selectedKind = "Clipboard";
    private int _openHistoryMenus;
    private readonly System.Windows.Threading.DispatcherTimer _persistSizeTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(350)
    };
    public MainWindow(AppController controller, CaptureHistoryStore history, SettingsStore settings)
    {
        InitializeComponent();
        _controller = controller;
        _history = history;
        _settings = settings;
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        Title = LocalizationService.Text(settings.Current.Language, "history.title");
        Width = settings.Current.HistoryExpandedWidth;
        Height = settings.Current.HistoryExpandedHeight;
        DataContext = settings.Current;
        _selectedKind = settings.Current.HistoryDefaultFilter switch
        {
            "Scrolling" => "ScrollingScreenshot",
            "Screenshot" or "Recording" or "Clipboard" => settings.Current.HistoryDefaultFilter,
            _ => "Clipboard"
        };
        RootBackground.LayoutTransform = new ScaleTransform(
            settings.Current.HistoryScale,
            settings.Current.HistoryScale);
        ApplyHistoryBackgroundStyle();
        ApplyMotionPreference();
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
        UpdateKindPills();
        history.Items.CollectionChanged += (_, _) => Dispatcher.BeginInvoke(() => QueueFilter(TimeSpan.Zero));
        _persistSizeTimer.Tick += (_, _) =>
        {
            _persistSizeTimer.Stop();
            _settings.Save();
        };
        SizeChanged += OnHistorySizeChanged;
        LocationChanged += OnHistoryLocationChanged;
        Loaded += (_, _) =>
        {
            WindowAppearanceService.ConstrainToWorkingArea(this);
            PositionHistoryWindow();
        };
        Closed += (_, _) => SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    private void OnSystemParametersChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not null &&
            !e.PropertyName.Equals(nameof(SystemParameters.ClientAreaAnimation), StringComparison.Ordinal)) return;
        _ = Dispatcher.BeginInvoke(ApplyMotionPreference);
    }

    private void ApplyMotionPreference() => HistoryItems.ItemContainerStyle = AccessibilityPreferences.ReduceMotion
        ? (Style)FindResource("ReducedMotionHistoryListBoxItem")
        : null;

    public void RefreshLocalization()
    {
        Title = LocalizationService.Text(LocalizationService.CurrentLanguage, "history.title");
        LocalizationService.LocalizeWindow(this);
        HistoryItems.Items.Refresh();
    }

    public void ShowClipboardHistory()
    {
        ApplyHistoryPresentation();
        _selectedKind = "Clipboard";
        SearchBox.Clear();
        TimeFilter.SelectedIndex = 0;
        UpdateKindPills();
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    public void ShowDefaultHistory()
    {
        ApplyHistoryPresentation();
        _selectedKind = _settings.Current.HistoryDefaultFilter switch
        {
            "Scrolling" => "ScrollingScreenshot",
            "Screenshot" or "Recording" or "Clipboard" => _settings.Current.HistoryDefaultFilter,
            _ => "Clipboard"
        };
        SearchBox.Clear();
        TimeFilter.SelectedIndex = 0;
        UpdateKindPills();
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    public void ShowHistoryFilter(string? filter)
    {
        ApplyHistoryPresentation();
        _selectedKind = filter?.ToLowerInvariant() switch
        {
            "screenshot" => "Screenshot",
            "scrolling" => "ScrollingScreenshot",
            "recording" => "Recording",
            "clipboard" => "Clipboard",
            "all" => "Clipboard",
            _ => "Clipboard"
        };
        SearchBox.Clear();
        TimeFilter.SelectedIndex = 0;
        UpdateKindPills();
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    public void ApplyHistoryPresentation()
    {
        DataContext = _settings.Current;
        RootBackground.LayoutTransform = new ScaleTransform(
            _settings.Current.HistoryScale,
            _settings.Current.HistoryScale);
        ApplyHistoryBackgroundStyle();
        if (IsLoaded) Dispatcher.BeginInvoke(PositionHistoryWindow);
    }

    public void ApplyHistoryBackgroundStyle()
    {
        var resourceKey = _settings.Current.HistoryBackgroundStyle switch
        {
            "Solid" => "SurfaceBrush",
            "Hud" => "HistoryHudBrush",
            _ => "WindowBrush"
        };
        RootBackground.SetResourceReference(Panel.BackgroundProperty, resourceKey);
        SetResourceReference(BackgroundProperty, resourceKey);
    }

    private Rect CurrentWorkAreaInDips()
    {
        return WindowAppearanceService.WorkingAreaInDips(this);
    }

    private void PositionHistoryWindow()
    {
        var area = CurrentWorkAreaInDips();
        const double gap = 24d;
        var centeredLeft = area.Left + (area.Width - Width) / 2;
        var (requestedLeft, requestedTop) = _settings.Current.HistoryPosition switch
        {
            "BottomCenter" => (centeredLeft, area.Bottom - Height - gap),
            _ => (centeredLeft, area.Top + gap)
        };
        Left = Math.Clamp(requestedLeft, area.Left, Math.Max(area.Left, area.Right - Width));
        Top = Math.Clamp(requestedTop, area.Top, Math.Max(area.Top, area.Bottom - Height));
    }

    private void OnHistorySizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!IsLoaded || WindowState != WindowState.Normal) return;
        CaptureCurrentGeometry();
        _persistSizeTimer.Stop();
        _persistSizeTimer.Start();
    }

    private void OnHistoryLocationChanged(object? sender, EventArgs e)
    {
        if (!IsLoaded || WindowState != WindowState.Normal) return;
        CaptureCurrentGeometry();
        _persistSizeTimer.Stop();
        _persistSizeTimer.Start();
    }

    private void CaptureCurrentGeometry()
    {
        _settings.Current.HistoryExpandedWidth = ActualWidth;
        _settings.Current.HistoryExpandedHeight = ActualHeight;
        _settings.Current.HistoryExpandedLeft = Left;
        _settings.Current.HistoryExpandedTop = Top;
    }

    public void CloseForExit() { _allowClose = true; Close(); }

    private static bool FilterItem(CaptureHistoryItem item, string text, string selectedKind, DateTimeOffset? threshold)
    {
        if (text.Length > 0 &&
            !(item.Text?.Contains(text, StringComparison.CurrentCultureIgnoreCase) ?? false) &&
            !(item.FilePath?.Contains(text, StringComparison.CurrentCultureIgnoreCase) ?? false) &&
            !item.FilePaths.Any(path => path.Contains(text, StringComparison.CurrentCultureIgnoreCase))) return false;
        var typeMatches = MatchesHistoryKind(item.Kind, selectedKind);
        if (!typeMatches) return false;
        return threshold is null || item.CreatedAt >= threshold.Value;
    }

    internal static bool MatchesHistoryKind(CaptureKind kind, string selectedKind) => selectedKind switch
        {
            "Screenshot" => kind == CaptureKind.Screenshot,
            "ScrollingScreenshot" => kind == CaptureKind.ScrollingScreenshot,
            "Recording" => kind is CaptureKind.Recording or CaptureKind.Gif,
            // Clipboard History is the aggregate product history. The other
            // three pills narrow that collection to capture-specific subsets.
            "Clipboard" => true,
            _ => true
        };

    private void OnFilterChanged(object sender, EventArgs e)
    {
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        if (SearchPlaceholder is not null)
            SearchPlaceholder.Visibility = string.IsNullOrWhiteSpace(SearchBox?.Text) ? Visibility.Visible : Visibility.Collapsed;
        if (ClearSearchButton is not null)
            ClearSearchButton.Visibility = string.IsNullOrWhiteSpace(SearchBox?.Text) ? Visibility.Collapsed : Visibility.Visible;
        QueueFilter(TimeSpan.FromMilliseconds(150), resetScroll: true);
    }

    private void QueueFilter(TimeSpan delay, bool resetScroll = false)
    {
        if (SearchBox is null || TimeFilter is null || HistoryItems is null) return;
        _filterCancellation?.Cancel();
        _filterCancellation?.Dispose();
        _filterCancellation = new CancellationTokenSource();
        var cancellation = _filterCancellation.Token;
        var query = SearchBox.Text.Trim();
        var kind = _selectedKind;
        var daysText = (TimeFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "All";
        var threshold = int.TryParse(daysText, out var days) ? DateTimeOffset.Now.AddDays(-days) : (DateTimeOffset?)null;
        var snapshot = _history.Items.ToArray();
        _ = ApplyFilterAsync(snapshot, query, kind, threshold, delay, resetScroll, cancellation);
    }

    private async Task ApplyFilterAsync(
        IReadOnlyList<CaptureHistoryItem> snapshot,
        string query,
        string kind,
        DateTimeOffset? threshold,
        TimeSpan delay,
        bool resetScroll,
        CancellationToken cancellation)
    {
        try
        {
            if (delay > TimeSpan.Zero) await Task.Delay(delay, cancellation);
            var filtered = await Task.Run(() => snapshot
                .Where(item => FilterItem(item, query, kind, threshold))
                .ToArray(), cancellation);
            cancellation.ThrowIfCancellationRequested();
            await Dispatcher.InvokeAsync(() =>
            {
                if (cancellation.IsCancellationRequested) return;
                HistoryItems.ItemsSource = filtered;
                if (resetScroll && filtered.Length > 0) HistoryItems.ScrollIntoView(filtered[0]);
                UpdateEmptyState();
            });
        }
        catch (OperationCanceledException) { }
    }

    private void OnKindPill(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button) return;
        _selectedKind = button.Tag?.ToString() ?? "Clipboard";
        UpdateKindPills();
        OnFilterChanged(sender, e);
    }

    private void UpdateKindPills()
    {
        if (ScreenshotFilter?.Parent is not Panel panel) return;
        foreach (var button in panel.Children.OfType<Button>())
        {
            var selected = Equals(button.Tag?.ToString(), _selectedKind);
            if (selected)
            {
                button.SetResourceReference(Button.BackgroundProperty, "AccentSoftBrush");
                button.SetResourceReference(Button.ForegroundProperty, "AccentBrush");
                button.SetResourceReference(Button.BorderBrushProperty, "AccentBrush");
                AutomationProperties.SetItemStatus(button, LocalizedDialogService.Text("已选择"));
            }
            else
            {
                button.ClearValue(Button.BackgroundProperty);
                button.ClearValue(Button.ForegroundProperty);
                button.ClearValue(Button.BorderBrushProperty);
                AutomationProperties.SetItemStatus(button, string.Empty);
            }
        }
    }

    private void UpdateEmptyState()
    {
        if (EmptyState is null || HistoryItems is null) return;
        EmptyState.Visibility = HistoryItems.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnClearSearch(object sender, RoutedEventArgs e) => SearchBox.Clear();
    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ListBox list || !ReferenceEquals(list, HistoryItems)) return;
        var count = HistoryItems.SelectedItems.Count;
        SelectionActions.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectionSummary.Text = $"已选择 {count} 项";
    }

    private void OnCopySelection(object sender, RoutedEventArgs e) =>
        _controller.CopyHistoryItems(HistoryItems.SelectedItems.Cast<CaptureHistoryItem>());

    private void OnClearSelection(object sender, RoutedEventArgs e) => HistoryItems.UnselectAll();

    private async void OnDeleteSelection(object sender, RoutedEventArgs e)
    {
        var selected = HistoryItems.SelectedItems.Cast<CaptureHistoryItem>().ToArray();
        if (!ConfirmDeletion(selected.Length)) return;
        await DeleteItemsAsync(selected);
    }

    private async void OnOpenItem(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is CaptureHistoryItem item)
            await _controller.OpenHistoryItemAsync(item);
    }

    private void OnCopyItem(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not CaptureHistoryItem item) return;
        _controller.CopyHistoryItem(item);
    }

    private void OnRestoreItem(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is CaptureHistoryItem item) _controller.RestoreHistoryItem(item);
    }

    private void OnRevealItem(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not CaptureHistoryItem item) return;
        var path = item.ExistingFilePaths.FirstOrDefault() ?? item.FilePath;
        if (string.IsNullOrWhiteSpace(path)) return;
        try
        {
            var fullPath = Path.GetFullPath(path);
            var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            if (File.Exists(fullPath))
                start.ArgumentList.Add($"/select,{fullPath}");
            else if (Directory.Exists(fullPath))
                start.ArgumentList.Add(fullPath);
            else
                return;
            Process.Start(start);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            LocalizedDialogService.Show(this,
                LocalizationService.TranslatePhrase("无法在资源管理器中显示此项目：") + exception.Message,
                "ShotPaste", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnShowItemMenu(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { ContextMenu: { } menu } button) return;
        menu.PlacementTarget = button;
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void OnHistoryMenuOpened(object sender, RoutedEventArgs e) => _openHistoryMenus++;
    private void OnHistoryMenuClosed(object sender, RoutedEventArgs e) => _openHistoryMenus = Math.Max(0, _openHistoryMenus - 1);

    private async void OnClearHistory(object sender, RoutedEventArgs e)
    {
        if (LocalizedDialogService.Show(this, "清空全部历史？每条记录关联的截图、录屏和受管剪贴板文件会先移入 Windows 回收站；处理失败的记录会保留。", "ShotPaste", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
        {
            var result = await _history.ClearAsync();
            ShowRemovalFailures(result.Failures, result.RemovedCount, result.RequestedCount);
        }
    }

    private async void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.A && (System.Windows.Input.Keyboard.Modifiers & System.Windows.Input.ModifierKeys.Control) != 0)
        {
            HistoryItems.SelectAll(); e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.C && (System.Windows.Input.Keyboard.Modifiers & System.Windows.Input.ModifierKeys.Control) != 0)
        {
            _controller.CopyHistoryItems(HistoryItems.SelectedItems.Cast<CaptureHistoryItem>()); e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.Delete)
        {
            var selected = HistoryItems.SelectedItems.Cast<CaptureHistoryItem>().ToArray();
            if (ConfirmDeletion(selected.Length))
                await DeleteItemsAsync(selected);
            e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.Enter && HistoryItems.SelectedItem is CaptureHistoryItem item)
        {
            _controller.RestoreHistoryItem(item); e.Handled = true;
        }
    }

    private async void OnDeleteItem(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not CaptureHistoryItem item || !ConfirmDeletion(1)) return;
        await DeleteItemsAsync([item]);
    }

    private void OnItemDoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is ListBox { SelectedItem: CaptureHistoryItem item }) _controller.RestoreHistoryItem(item);
    }

    private bool ConfirmDeletion(int count)
    {
        if (count <= 0) return false;
        return LocalizedDialogService.ShowCustom(
            this,
            $"确定删除选中的 {count} 条历史记录吗？由 ShotPaste 保存的文件会移入 Windows 回收站，可以恢复。",
            "删除历史记录",
            "移入回收站",
            "取消",
            MessageBoxImage.Warning) == MessageBoxResult.Yes;
    }

    private void OnKeepOpenChanged(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        _settings.Current.HistoryKeepOpen = KeepOpenCheckBox.IsChecked == true;
        _settings.Save();
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        if (_settings.Current.HistoryKeepOpen || !IsVisible || App.UiTestMode) return;
        _ = Dispatcher.BeginInvoke(() =>
        {
            if (_settings.Current.HistoryKeepOpen || !IsVisible || IsActive || _openHistoryMenus > 0 ||
                OwnedWindows.Cast<Window>().Any(window => window.IsVisible)) return;
            Hide();
        }, System.Windows.Threading.DispatcherPriority.ContextIdle);
    }

    private async Task DeleteItemsAsync(IEnumerable<CaptureHistoryItem> items)
    {
        var requested = 0;
        var removed = 0;
        var failures = new List<HistoryRemovalFailure>();
        foreach (var item in items)
        {
            requested++;
            var result = await _history.RemoveAsync(item, true);
            if (result.RecordRemoved) removed++;
            failures.AddRange(result.Failures);
        }
        ShowRemovalFailures(failures, removed, requested);
    }

    private void ShowRemovalFailures(
        IReadOnlyList<HistoryRemovalFailure> failures,
        int removed,
        int requested)
    {
        if (failures.Count == 0) return;
        var detail = string.Join("\n", failures.Take(4).Select(failure =>
            $"{Path.GetFileName(failure.Path)}：{failure.Message}"));
        LocalizedDialogService.Show(
            this,
            $"已删除 {removed}/{requested} 条记录。其余项目未完成安全文件处理或历史数据库更新，对应记录仍保留，可重试。\n\n{detail}",
            "部分项目删除失败",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        _filterCancellation?.Cancel();
        CaptureCurrentGeometry();
        _persistSizeTimer.Stop();
        if (IsLoaded) _settings.Save();
        if (_allowClose) return;
        e.Cancel = true;
        Hide();
    }
}
