using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Utilities;
using Button = System.Windows.Controls.Button;
using Panel = System.Windows.Controls.Panel;
using Brush = System.Windows.Media.Brush;
using ListBox = System.Windows.Controls.ListBox;

namespace ShotPaste.Windows.Views;

public partial class MainWindow : Window
{
    private readonly AppController _controller;
    private readonly CaptureHistoryStore _history;
    private readonly SettingsStore _settings;
    private CancellationTokenSource? _filterCancellation;
    private bool _allowClose;
    private string _selectedKind = "Screenshot";
    private bool _applyingHistoryMode;
    private bool _restoreListFocus;
    private double _compactHorizontalOffset;
    private double _expandedVerticalOffset;
    private readonly System.Windows.Threading.DispatcherTimer _persistSizeTimer = new()
    {
        Interval = TimeSpan.FromMilliseconds(350)
    };
    public bool IsCompactMode { get; private set; }

    public MainWindow(AppController controller, CaptureHistoryStore history, SettingsStore settings)
    {
        InitializeComponent();
        _controller = controller;
        _history = history;
        _settings = settings;
        Title = LocalizationService.Text(settings.Current.Language, "history.title");
        SourceInitialized += (_, _) => ApplyActivationStyle();
        ApplyHistoryMode("Compact");
        ApplyHistoryBackgroundStyle();
        _selectedKind = settings.Current.DefaultHistoryFilter;
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
            if (IsCompactMode) PositionCompactPanel(_settings.Current.HistoryPanelPosition);
            else PositionExpandedWindow();
            RestoreViewState();
        };
        QueueFilter(TimeSpan.Zero);
    }

    public void RefreshLocalization()
    {
        Title = LocalizationService.Text(LocalizationService.CurrentLanguage, "history.title");
        LocalizationService.LocalizeWindow(this);
        HistoryItems.Items.Refresh();
        CompactHistoryItems.Items.Refresh();
    }

    public void ApplyHistoryMode(string? mode)
    {
        var selectedItem = ActiveHistoryItems.SelectedItem;
        _restoreListFocus = ActiveHistoryItems.IsKeyboardFocusWithin;
        CaptureScrollOffset();
        _applyingHistoryMode = true;
        IsCompactMode = string.Equals(mode, "Compact", StringComparison.OrdinalIgnoreCase);
        HistoryItems.Visibility = IsCompactMode ? Visibility.Collapsed : Visibility.Visible;
        CompactHistoryItems.Visibility = IsCompactMode ? Visibility.Visible : Visibility.Collapsed;
        TopBar.Visibility = IsCompactMode ? Visibility.Collapsed : Visibility.Visible;
        FilterBar.Visibility = IsCompactMode ? Visibility.Collapsed : Visibility.Visible;
        HeaderUtilities.Visibility = IsCompactMode ? Visibility.Collapsed : Visibility.Visible;
        SelectionActions.Visibility = !IsCompactMode && HistoryItems.SelectedItems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        HistoryContent.Margin = IsCompactMode ? new Thickness(12, 12, 2, 6) : new Thickness(20, 0, 8, 14);
        if (IsCompactMode)
        {
            var scale = Math.Clamp(_settings.Current.HistoryPanelScale, 0.75d, 1.5d);
            MinWidth = 560 * scale;
            MinHeight = 200 * scale;
            Width = _settings.Current.HistoryCompactWidth * scale;
            Height = _settings.Current.HistoryCompactHeight * scale;
            ShowInTaskbar = App.UiTestMode;
            Topmost = true;
            WindowStartupLocation = WindowStartupLocation.Manual;
            PositionCompactPanel(_settings.Current.HistoryPanelPosition);
        }
        else
        {
            MinWidth = 860;
            MinHeight = 520;
            Width = _settings.Current.HistoryExpandedWidth;
            Height = _settings.Current.HistoryExpandedHeight;
            ShowInTaskbar = true;
            Topmost = false;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            PositionExpandedWindow();
        }
        UpdateHistoryModeToggle();
        _applyingHistoryMode = false;
        if (selectedItem is not null)
        {
            ActiveHistoryItems.SelectedItem = selectedItem;
            ActiveHistoryItems.ScrollIntoView(selectedItem);
        }
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, new Action(RestoreViewState));
        ApplyActivationStyle();
        QueueFilter(TimeSpan.Zero);
    }

    public void ToggleHistoryMode()
    {
        CaptureCurrentGeometry();
        ApplyHistoryMode(IsCompactMode ? "Expanded" : "Compact");
    }

    public void ShowAllExpanded()
    {
        _selectedKind = "All";
        UpdateKindPills();
        ApplyHistoryMode("Expanded");
    }

    public void ApplyHistoryBackgroundStyle()
    {
        var source = FindResource(_settings.Current.HistoryBackgroundStyle == "Solid" ? "SurfaceBrush" : "WindowBrush") as Brush;
        if (source is null) return;
        var brush = source.CloneCurrentValue();
        if (_settings.Current.HistoryBackgroundStyle == "Hud") brush.Opacity = 0.92;
        RootBackground.Background = brush;
        Background = brush;
    }

    private ListBox ActiveHistoryItems => IsCompactMode ? CompactHistoryItems : HistoryItems;

    private void PositionCompactPanel(string? position)
    {
        const double margin = 18;
        var area = CurrentWorkAreaInDips();
        if (string.Equals(position, "TopCenter", StringComparison.OrdinalIgnoreCase))
        {
            Left = Math.Max(area.Left + margin, area.Left + (area.Width - Width) / 2);
            Top = area.Top + margin;
            return;
        }
        var onLeft = string.Equals(position, "TopLeft", StringComparison.OrdinalIgnoreCase) ||
                     string.Equals(position, "BottomLeft", StringComparison.OrdinalIgnoreCase);
        var onTop = string.Equals(position, "TopLeft", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(position, "TopRight", StringComparison.OrdinalIgnoreCase);
        Left = onLeft ? area.Left + margin : Math.Max(area.Left + margin, area.Right - Width - margin);
        Top = onTop ? area.Top + margin : Math.Max(area.Top + margin, area.Bottom - Height - margin);
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

    private void PositionExpandedWindow()
    {
        var area = CurrentWorkAreaInDips();
        var requestedLeft = _settings.Current.HistoryExpandedLeft ?? area.Left + (area.Width - Width) / 2;
        var requestedTop = _settings.Current.HistoryExpandedTop ?? area.Top + (area.Height - Height) / 2;
        Left = Math.Clamp(requestedLeft, area.Left, Math.Max(area.Left, area.Right - Width));
        Top = Math.Clamp(requestedTop, area.Top, Math.Max(area.Top, area.Bottom - Height));
    }

    private void CaptureScrollOffset()
    {
        var scroller = FindVisualChild<ScrollViewer>(ActiveHistoryItems);
        if (scroller is null) return;
        if (IsCompactMode) _compactHorizontalOffset = scroller.HorizontalOffset;
        else _expandedVerticalOffset = scroller.VerticalOffset;
    }

    private void RestoreViewState()
    {
        var scroller = FindVisualChild<ScrollViewer>(ActiveHistoryItems);
        if (scroller is not null)
        {
            if (IsCompactMode) scroller.ScrollToHorizontalOffset(_compactHorizontalOffset);
            else scroller.ScrollToVerticalOffset(_expandedVerticalOffset);
        }
        if (_restoreListFocus)
        {
            ActiveHistoryItems.Focus();
            _restoreListFocus = false;
        }
    }

    private void OnHistorySizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_applyingHistoryMode || !IsLoaded || WindowState != WindowState.Normal) return;
        CaptureCurrentGeometry();
        _persistSizeTimer.Stop();
        _persistSizeTimer.Start();
    }

    private void OnHistoryLocationChanged(object? sender, EventArgs e)
    {
        if (_applyingHistoryMode || !IsLoaded || IsCompactMode || WindowState != WindowState.Normal) return;
        CaptureCurrentGeometry();
        _persistSizeTimer.Stop();
        _persistSizeTimer.Start();
    }

    private void CaptureCurrentGeometry()
    {
        if (IsCompactMode)
        {
            var scale = Math.Clamp(_settings.Current.HistoryPanelScale, 0.75d, 1.5d);
            _settings.Current.HistoryCompactWidth = ActualWidth / scale;
            _settings.Current.HistoryCompactHeight = ActualHeight / scale;
            return;
        }
        _settings.Current.HistoryExpandedWidth = ActualWidth;
        _settings.Current.HistoryExpandedHeight = ActualHeight;
        _settings.Current.HistoryExpandedLeft = Left;
        _settings.Current.HistoryExpandedTop = Top;
    }

    private void OnToggleHistoryMode(object sender, RoutedEventArgs e)
    {
        ToggleHistoryMode();
    }

    private void UpdateHistoryModeToggle()
    {
        if (HistoryModeToggle is null) return;
        HistoryModeToggle.Content = IsCompactMode ? "↗" : "↙";
        HistoryModeToggle.ToolTip = LocalizedDialogService.Text(IsCompactMode ? "展开剪贴板历史面板" : "切换到紧凑剪贴板历史面板");
    }

    private void ApplyActivationStyle()
    {
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
        style = IsCompactMode ? style | NativeMethods.WsExNoActivate : style & ~NativeMethods.WsExNoActivate;
        NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, new IntPtr(style));
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
        QueueFilter(TimeSpan.Zero);
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        if (ClearSearchButton is not null)
            ClearSearchButton.Visibility = string.IsNullOrWhiteSpace(SearchBox?.Text) ? Visibility.Collapsed : Visibility.Visible;
        QueueFilter(TimeSpan.FromMilliseconds(150));
    }

    private void QueueFilter(TimeSpan delay)
    {
        if (SearchBox is null || TimeFilter is null || HistoryItems is null || CompactHistoryItems is null) return;
        _filterCancellation?.Cancel();
        _filterCancellation?.Dispose();
        _filterCancellation = new CancellationTokenSource();
        var cancellation = _filterCancellation.Token;
        var query = SearchBox.Text.Trim();
        var kind = _selectedKind;
        var daysText = (TimeFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "All";
        var threshold = int.TryParse(daysText, out var days) ? DateTimeOffset.Now.AddDays(-days) : (DateTimeOffset?)null;
        var snapshot = _history.Items.ToArray();
        _ = ApplyFilterAsync(snapshot, query, kind, threshold, delay, cancellation);
    }

    private async Task ApplyFilterAsync(
        IReadOnlyList<CaptureHistoryItem> snapshot,
        string query,
        string kind,
        DateTimeOffset? threshold,
        TimeSpan delay,
        CancellationToken cancellation)
    {
        try
        {
            if (delay > TimeSpan.Zero) await Task.Delay(delay, cancellation);
            var filtered = await Task.Run(() => snapshot
                .Where(item => FilterItem(item, query, kind, threshold))
                .Take(IsCompactMode ? Math.Clamp(_settings.Current.HistoryPanelMaxItems, 3, 50) : int.MaxValue)
                .ToArray(), cancellation);
            cancellation.ThrowIfCancellationRequested();
            await Dispatcher.InvokeAsync(() =>
            {
                if (cancellation.IsCancellationRequested) return;
                HistoryItems.ItemsSource = filtered;
                CompactHistoryItems.ItemsSource = filtered;
                UpdateEmptyState();
            });
        }
        catch (OperationCanceledException) { }
    }

    private void OnKindPill(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button) return;
        _selectedKind = button.Tag?.ToString() ?? "Screenshot";
        UpdateKindPills();
        OnFilterChanged(sender, e);
    }

    private void UpdateKindPills()
    {
        if (ScreenshotFilter?.Parent is not Panel panel) return;
        foreach (var button in panel.Children.OfType<Button>())
        {
            var selected = Equals(button.Tag?.ToString(), _selectedKind);
            button.Background = selected ? (Brush)FindResource("AccentSoftBrush") : (Brush)FindResource("SurfaceSecondaryBrush");
            button.Foreground = selected ? (Brush)FindResource("AccentBrush") : (Brush)FindResource("TextBrush");
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
        if (sender is not ListBox list || !ReferenceEquals(list, ActiveHistoryItems)) return;
        if (IsCompactMode)
        {
            SelectionActions.Visibility = Visibility.Collapsed;
            return;
        }
        var count = HistoryItems.SelectedItems.Count;
        SelectionActions.Visibility = !IsCompactMode && count > 0 ? Visibility.Visible : Visibility.Collapsed;
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
        var activeItems = ActiveHistoryItems;
        if (e.Key == System.Windows.Input.Key.A && (System.Windows.Input.Keyboard.Modifiers & System.Windows.Input.ModifierKeys.Control) != 0)
        {
            activeItems.SelectAll(); e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.C && (System.Windows.Input.Keyboard.Modifiers & System.Windows.Input.ModifierKeys.Control) != 0)
        {
            _controller.CopyHistoryItems(activeItems.SelectedItems.Cast<CaptureHistoryItem>()); e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.Delete)
        {
            var selected = activeItems.SelectedItems.Cast<CaptureHistoryItem>().ToArray();
            if (ConfirmDeletion(selected.Length))
                foreach (var item in selected) await _history.RemoveAsync(item, true);
            e.Handled = true;
        }
        else if (e.Key == System.Windows.Input.Key.Enter && activeItems.SelectedItem is CaptureHistoryItem item)
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

    private void OnCompactMouseWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
    {
        var scroller = FindVisualChild<ScrollViewer>(CompactHistoryItems);
        if (scroller is null) return;
        scroller.ScrollToHorizontalOffset(scroller.HorizontalOffset - e.Delta);
        e.Handled = true;
    }

    private static T? FindVisualChild<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match) return match;
            var descendant = FindVisualChild<T>(child);
            if (descendant is not null) return descendant;
        }
        return null;
    }

    private static bool ConfirmDeletion(int count)
    {
        if (count <= 0) return false;
        return LocalizedDialogService.Show(
            $"确定删除选中的 {count} 条剪贴板历史记录？托管的临时文件也会一并删除。",
            "ShotPaste",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning) == MessageBoxResult.OK;
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        _filterCancellation?.Cancel();
        CaptureScrollOffset();
        CaptureCurrentGeometry();
        _persistSizeTimer.Stop();
        if (IsLoaded) _settings.Save();
        if (_allowClose) return;
        e.Cancel = true;
        Hide();
    }
}
