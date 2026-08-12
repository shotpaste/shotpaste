using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
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
        ApplyHistoryBackgroundStyle();
        UpdateKindPills();
        history.Items.CollectionChanged += (_, _) => Dispatcher.BeginInvoke(() => QueueFilter(TimeSpan.Zero));
        _persistSizeTimer.Tick += (_, _) =>
        {
            _persistSizeTimer.Stop();
            _settings.Save();
        };
        SizeChanged += OnHistorySizeChanged;
        LocationChanged += OnHistoryLocationChanged;
        Loaded += (_, _) => PositionHistoryWindow();
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    public void RefreshLocalization()
    {
        Title = LocalizationService.Text(LocalizationService.CurrentLanguage, "history.title");
        LocalizationService.LocalizeWindow(this);
        HistoryItems.Items.Refresh();
    }

    public void ShowClipboardHistory()
    {
        _selectedKind = "Clipboard";
        SearchBox.Clear();
        TimeFilter.SelectedIndex = 0;
        UpdateKindPills();
        QueueFilter(TimeSpan.Zero, resetScroll: true);
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
        var cursor = System.Windows.Forms.Cursor.Position;
        var physical = System.Windows.Forms.Screen.FromPoint(cursor).WorkingArea;
        var source = PresentationSource.FromVisual(this) as System.Windows.Interop.HwndSource;
        if (source?.CompositionTarget is null) return SystemParameters.WorkArea;
        var transform = source.CompositionTarget.TransformFromDevice;
        var topLeft = transform.Transform(new System.Windows.Point(physical.Left, physical.Top));
        var bottomRight = transform.Transform(new System.Windows.Point(physical.Right, physical.Bottom));
        return new Rect(topLeft, bottomRight);
    }

    private void PositionHistoryWindow()
    {
        var area = CurrentWorkAreaInDips();
        var requestedLeft = _settings.Current.HistoryExpandedLeft ?? area.Left + (area.Width - Width) / 2;
        var requestedTop = _settings.Current.HistoryExpandedTop ?? area.Top + (area.Height - Height) / 2;
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
        var typeMatches = selectedKind switch
        {
            "Screenshot" => item.Kind == CaptureKind.Screenshot,
            "ScrollingScreenshot" => item.Kind == CaptureKind.ScrollingScreenshot,
            "Recording" => item.Kind is CaptureKind.Recording or CaptureKind.Gif,
            "Clipboard" => ClipboardFileClassifier.IsClipboardKind(item.Kind),
            _ => true
        };
        if (!typeMatches) return false;
        return threshold is null || item.CreatedAt >= threshold.Value;
    }

    private void OnFilterChanged(object sender, EventArgs e)
    {
        QueueFilter(TimeSpan.Zero, resetScroll: true);
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
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
    private void OnSettings(object sender, RoutedEventArgs e) => _controller.ShowSettings();

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
        foreach (var item in selected)
            await _history.RemoveAsync(item, true);
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

    private async void OnClearHistory(object sender, RoutedEventArgs e)
    {
        if (LocalizedDialogService.Show(this, "清空剪贴板历史？已保存的截图和视频文件会保留。", "ShotPaste", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
            await _history.ClearAsync();
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
                foreach (var item in selected) await _history.RemoveAsync(item, true);
            e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.Enter && HistoryItems.SelectedItem is CaptureHistoryItem item)
        {
            _controller.RestoreHistoryItem(item); e.Handled = true;
        }
    }

    private async void OnDeleteItem(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is CaptureHistoryItem item) await _history.RemoveAsync(item, true);
    }

    private void OnItemDoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is ListBox { SelectedItem: CaptureHistoryItem item }) _controller.RestoreHistoryItem(item);
    }

    private bool ConfirmDeletion(int count)
    {
        if (count <= 0) return false;
        return LocalizedDialogService.Show(
            this,
            $"确定删除选中的 {count} 条剪贴板历史记录？托管的临时文件也会一并删除。",
            "ShotPaste",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning) == MessageBoxResult.OK;
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
