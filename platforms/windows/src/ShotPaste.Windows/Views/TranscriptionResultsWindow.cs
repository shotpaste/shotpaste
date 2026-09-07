using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ShotPaste.Windows.Services;
using Button = System.Windows.Controls.Button;
using ListBox = System.Windows.Controls.ListBox;
using TextBox = System.Windows.Controls.TextBox;
using ComboBox = System.Windows.Controls.ComboBox;
using Orientation = System.Windows.Controls.Orientation;

namespace ShotPaste.Windows.Views;

public sealed class TranscriptionResultsWindow : Window
{
    private readonly ListBox _list = new() { Margin = new Thickness(16), DisplayMemberPath = "Label" };
    private readonly RecordingTranscriptionJobs _jobs = RecordingTranscriptionJobs.Shared;
    private readonly TextBox _search = new() { MinWidth = 240, Margin = new Thickness(0, 0, 12, 0) };
    private readonly ComboBox _filter = new() { MinWidth = 150 };
    private readonly TextBlock _empty = new() { Margin = new Thickness(20), TextWrapping = TextWrapping.Wrap };
    private readonly Dictionary<Guid, RecordingTranscriptWindow> _details = [];
    private sealed record Row(RecordingTranscriptionJob Job, string Label);
    private static string L(string key) => LocalizationService.Text(LocalizationService.CurrentLanguage, key);
    public TranscriptionResultsWindow()
    {
        System.Windows.Automation.AutomationProperties.SetAutomationId(this, "TranscriptionResultsWindow");
        SetResourceReference(ForegroundProperty, "TextBrush");
        _list.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "TextBrush");
        _list.SetResourceReference(System.Windows.Controls.Control.BackgroundProperty, "SurfaceBrush");
        _empty.SetResourceReference(TextBlock.ForegroundProperty, "SecondaryTextBrush");
        Title = LocalizationService.TranslatePhrase("转写结果"); Width = 720; Height = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
        var grid = new DockPanel();
        var filters = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16) };
        _search.ToolTip = L("recording.results.search");
        System.Windows.Automation.AutomationProperties.SetName(_search, L("recording.results.search"));
        System.Windows.Automation.AutomationProperties.SetName(_filter, L("recording.results.filter"));
        _filter.Items.Add(new ComboBoxItem { Content = L("recording.results.all"), Tag = "all" });
        _filter.Items.Add(new ComboBoxItem { Content = L("recording.results.audio"), Tag = "audio" });
        _filter.Items.Add(new ComboBoxItem { Content = L("recording.results.video"), Tag = "video" });
        _filter.SelectedIndex = 0;
        filters.Children.Add(_search); filters.Children.Add(_filter);
        DockPanel.SetDock(filters, Dock.Top); grid.Children.Add(filters);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16) };
        var open = new Button { Content = LocalizationService.TranslatePhrase("打开"), MinWidth = 90 };
        open.Click += (_, _) => Open(); actions.Children.Add(open);
        var retry = new Button { Content = LocalizationService.TranslatePhrase("重试"), MinWidth = 90, Margin = new Thickness(8, 0, 0, 0) };
        retry.Click += (_, _) =>
        {
            if (_list.SelectedItem is not Row row || row.Job.State is not ("failed" or "cancelled" or "interrupted")) return;
            if (row.Job.RequiresResubmission)
            {
                if (LocalizedDialogService.Show(this, L("recording.cloud.uncertain"), L("recording.cloud.resubmit"),
                    MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                _jobs.Retry(row.Job, true);
            }
            else _jobs.Retry(row.Job);
        };
        actions.Children.Add(retry);
        DockPanel.SetDock(actions, Dock.Bottom); grid.Children.Add(actions);
        var content = new Grid(); content.Children.Add(_list); content.Children.Add(_empty); grid.Children.Add(content); Content = grid;
        _list.MouseDoubleClick += (_, _) => Open();
        _list.KeyDown += (_, e) => { if (e.Key == Key.Enter) Open(); };
        _search.TextChanged += (_, _) => Refresh(); _filter.SelectionChanged += (_, _) => Refresh();
        _jobs.Changed += OnChanged; Closed += (_, _) => _jobs.Changed -= OnChanged; Refresh();
    }
    private void OnChanged(object? sender, EventArgs e) { if (!Dispatcher.HasShutdownStarted) _ = Dispatcher.BeginInvoke(Refresh); }
    private void Refresh()
    {
        var selected = (_list.SelectedItem as Row)?.Job.Id;
        var rows = _jobs.Jobs.Where(job => Matches(job, (_filter.SelectedItem as ComboBoxItem)?.Tag as string ?? "all", _search.Text))
            .Select(job => new Row(job, $"{job.CreatedAt.LocalDateTime:g}  {job.DisplayName}  ·  {RecordingTranscriptWindow.StateText(job.State)}")).ToArray();
        _list.ItemsSource = rows;
        _empty.Text = L(_jobs.Jobs.Count == 0 ? "recording.results.empty" : "recording.results.no-matches");
        _empty.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (selected is not null) _list.SelectedItem = _list.Items.Cast<Row>().FirstOrDefault(row => row.Job.Id == selected);
    }
    internal static bool Matches(RecordingTranscriptionJob job, string filter, string query)
    {
        var audio = new[] { ".m4a", ".wav", ".mp3", ".flac" }.Contains(Path.GetExtension(job.RecordingPath), StringComparer.OrdinalIgnoreCase);
        if (filter == "audio" && !audio || filter == "video" && audio) return false;
        return string.IsNullOrWhiteSpace(query) || job.DisplayName.Contains(query.Trim(), StringComparison.CurrentCultureIgnoreCase) ||
            job.CreatedAt.LocalDateTime.ToString("g").Contains(query.Trim(), StringComparison.CurrentCultureIgnoreCase) ||
            job.CreatedAt.LocalDateTime.ToString("yyyy-MM-dd").Contains(query.Trim(), StringComparison.Ordinal);
    }
    public void SelectRecording(string path)
    {
        _search.Text = ""; _filter.SelectedIndex = 0; Refresh();
        _list.SelectedItem = _list.Items.Cast<Row>().FirstOrDefault(row => string.Equals(row.Job.RecordingPath, path, StringComparison.OrdinalIgnoreCase));
        if (_list.SelectedItem is not null) _list.ScrollIntoView(_list.SelectedItem);
    }
    private void Open()
    {
        if (_list.SelectedItem is not Row row) return;
        if (_details.TryGetValue(row.Job.Id, out var existing)) { existing.Activate(); return; }
        var detail = new RecordingTranscriptWindow(row.Job);
        _details[row.Job.Id] = detail;
        detail.Closed += (_, _) => _details.Remove(row.Job.Id);
        detail.Show();
    }
}
