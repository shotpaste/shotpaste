using System.Drawing;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using ShotPaste.Windows.Models;
using Forms = System.Windows.Forms;
using WpfApplication = System.Windows.Application;
using WpfContextMenu = System.Windows.Controls.ContextMenu;
using WpfMenuItem = System.Windows.Controls.MenuItem;
using WpfPath = System.Windows.Shapes.Path;
using WpfSeparator = System.Windows.Controls.Separator;

namespace ShotPaste.Windows.Services;

public sealed class TrayIconService : IDisposable
{
    private const string DefaultBalloonMessage = "操作未能完成，请重试。";
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.Timer _recordingTimer = new() { Interval = 250 };
    private readonly Func<TimeSpan>? _recordingElapsed;
    private Icon? _ownedIcon;
    private WpfContextMenu? _menu;
    private WpfMenuItem? _recordingItem;
    private WpfMenuItem? _oneShotItem;
    private WpfMenuItem? _pauseRecordingItem;
    private WpfSeparator? _recordingSeparator;
    private AppSettings _settings;
    private bool _isRecording;
    private bool _isPaused;
    private DateTimeOffset _recordingClickHandledUntil;

    public event EventHandler? RecordingRequested;
    public event EventHandler? PauseRecordingRequested;
    public event EventHandler? OneShotRequested;
    public event EventHandler? HistoryRequested;
    public event EventHandler? SettingsRequested;
    public event EventHandler? ExitRequested;

    public TrayIconService(AppSettings settings, Func<TimeSpan>? recordingElapsed = null)
    {
        _settings = settings;
        _recordingElapsed = recordingElapsed;
        _icon = new Forms.NotifyIcon { Text = AppBuildIdentity.Current.DisplayName, Visible = settings.ShowTrayIcon };
        try
        {
            var resource = WpfApplication.GetResourceStream(new Uri("pack://application:,,,/ShotPaste;component/Assets/shotpaste-icon.png"));
            if (resource is not null)
            {
                using var bitmap = new Bitmap(resource.Stream);
                using var resized = new Bitmap(bitmap, 32, 32);
                _ownedIcon = (Icon)Icon.FromHandle(resized.GetHicon()).Clone();
                _icon.Icon = _ownedIcon;
            }
        }
        catch (IOException) { _icon.Icon = SystemIcons.Application; }
        _icon.Icon ??= SystemIcons.Application;
        _menu = BuildMenu(settings);
        _recordingTimer.Tick += (_, _) => UpdateTooltip();
        _icon.MouseUp += OnTrayMouseUp;
        _icon.MouseClick += (_, args) =>
        {
            if (args.Button != Forms.MouseButtons.Left || !_isRecording || _settings.ShowRecordingToolbar) return;
            _recordingClickHandledUntil = DateTimeOffset.UtcNow.AddMilliseconds(Forms.SystemInformation.DoubleClickTime + 100);
            RecordingRequested?.Invoke(this, EventArgs.Empty);
        };
        _icon.DoubleClick += (_, _) =>
        {
            if (DateTimeOffset.UtcNow < _recordingClickHandledUntil) return;
            if (_isRecording) RecordingRequested?.Invoke(this, EventArgs.Empty);
            else HistoryRequested?.Invoke(this, EventArgs.Empty);
        };
    }

    public void ShowMessage(string? title, string? message, Forms.ToolTipIcon kind = Forms.ToolTipIcon.Info)
    {
        var content = NormalizeBalloonContent(title, message);
        ToastService.Show(content.Title, content.Message, kind);
    }

    public void DismissMessage() => ToastService.Dismiss();

    internal static (string Title, string Message) NormalizeBalloonContent(string? title, string? message)
    {
        var normalizedTitle = string.IsNullOrWhiteSpace(title) ? AppBuildIdentity.Current.DisplayName : title.Trim();
        var normalizedMessage = string.IsNullOrWhiteSpace(message) ? DefaultBalloonMessage : message.Trim();
        return (LocalizationService.TranslatePhrase(normalizedTitle),
            LocalizationService.TranslatePhrase(normalizedMessage));
    }

    public void UpdateShortcuts(AppSettings settings)
    {
        _settings = settings;
        _icon.Visible = settings.ShowTrayIcon;
        if (_menu is not null) _menu.IsOpen = false;
        _menu = BuildMenu(settings);
        UpdateTooltip();
    }

    public void UpdateRecordingState(bool isRecording, bool isPaused)
    {
        _isRecording = isRecording;
        _isPaused = isPaused;
        if (_oneShotItem is not null) _oneShotItem.IsEnabled = !isRecording;
        if (_recordingItem is not null)
        {
            _recordingItem.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
            _recordingItem.Header = LocalizationService.TranslatePhrase("停止录制", _settings.Language);
        }
        if (_pauseRecordingItem is not null)
        {
            _pauseRecordingItem.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
            _pauseRecordingItem.Header = LocalizationService.TranslatePhrase(isPaused ? "继续录制" : "暂停录制", _settings.Language);
            _pauseRecordingItem.Icon = CreateIcon(isPaused ? "Icon.Resume" : "Icon.Pause");
        }
        if (_recordingSeparator is not null)
            _recordingSeparator.Visibility = isRecording ? Visibility.Visible : Visibility.Collapsed;
        if (isRecording && _settings.ShowRecordingDurationInTray) _recordingTimer.Start();
        else _recordingTimer.Stop();
        UpdateTooltip();
    }

    private void OnTrayMouseUp(object? sender, Forms.MouseEventArgs e)
    {
        if (e.Button != Forms.MouseButtons.Right || _menu is null) return;
        var menu = _menu;
        var dispatcher = WpfApplication.Current?.Dispatcher;
        if (dispatcher is null) return;
        _ = dispatcher.BeginInvoke(() =>
        {
            menu.Placement = PlacementMode.MousePoint;
            menu.IsOpen = false;
            menu.IsOpen = true;
        });
    }

    private WpfContextMenu BuildMenu(AppSettings settings)
    {
        var menu = new WpfContextMenu { StaysOpen = false };
        _recordingItem = CreateMenuItem("停止录制", null, "Icon.Stop", settings,
            () => RecordingRequested?.Invoke(this, EventArgs.Empty));
        _recordingItem.Visibility = _isRecording ? Visibility.Visible : Visibility.Collapsed;
        menu.Items.Add(_recordingItem);

        _pauseRecordingItem = CreateMenuItem(_isPaused ? "继续录制" : "暂停录制", null,
            _isPaused ? "Icon.Resume" : "Icon.Pause", settings,
            () => PauseRecordingRequested?.Invoke(this, EventArgs.Empty));
        _pauseRecordingItem.Visibility = _isRecording ? Visibility.Visible : Visibility.Collapsed;
        menu.Items.Add(_pauseRecordingItem);

        _recordingSeparator = CreateSeparator();
        _recordingSeparator.Visibility = _isRecording ? Visibility.Visible : Visibility.Collapsed;
        menu.Items.Add(_recordingSeparator);

        _oneShotItem = CreateMenuItem("一键 Shot", settings.OneShotHotkey, "Icon.OneShot", settings,
            () => OneShotRequested?.Invoke(this, EventArgs.Empty));
        _oneShotItem.IsEnabled = !_isRecording;
        menu.Items.Add(_oneShotItem);
        menu.Items.Add(CreateSeparator());
        menu.Items.Add(CreateMenuItem("剪贴板历史", settings.HistoryHotkey, "Icon.History", settings,
            () => HistoryRequested?.Invoke(this, EventArgs.Empty)));
        menu.Items.Add(CreateMenuItem("设置", null, "Icon.Settings", settings,
            () => SettingsRequested?.Invoke(this, EventArgs.Empty)));
        menu.Items.Add(CreateSeparator());
        menu.Items.Add(CreateMenuItem("退出 ShotPaste", null, "Icon.Exit", settings,
            () => ExitRequested?.Invoke(this, EventArgs.Empty)));
        return menu;
    }

    private static WpfMenuItem CreateMenuItem(
        string title,
        string? shortcut,
        string iconKey,
        AppSettings settings,
        Action action)
    {
        var item = new WpfMenuItem
        {
            Header = Label(title, settings),
            InputGestureText = settings.ShortcutsEnabled ? shortcut ?? string.Empty : string.Empty,
            Icon = CreateIcon(iconKey)
        };
        item.Click += (_, _) => action();
        return item;
    }

    private static WpfSeparator CreateSeparator()
    {
        var separator = new WpfSeparator();
        separator.SetResourceReference(FrameworkElement.StyleProperty, "MenuSeparator");
        return separator;
    }

    private static WpfPath CreateIcon(string resourceKey)
    {
        var icon = new WpfPath
        {
            Data = WpfApplication.Current?.TryFindResource(resourceKey) as Geometry,
            Width = 16,
            Height = 16,
            Stretch = Stretch.Uniform,
            Fill = System.Windows.Media.Brushes.Transparent,
            StrokeThickness = 1.7,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round
        };
        icon.SetResourceReference(Shape.StrokeProperty, "TextBrush");
        return icon;
    }

    private static string Label(string title, AppSettings settings) =>
        LocalizationService.TranslatePhrase(title, settings.Language);

    private void UpdateTooltip()
    {
        if (!_isRecording)
        {
            _icon.Text = AppBuildIdentity.Current.DisplayName;
            return;
        }
        var status = LocalizationService.TranslatePhrase(_isPaused ? "录制已暂停" : "正在录制", _settings.Language);
        var duration = _settings.ShowRecordingDurationInTray && _recordingElapsed is not null
            ? $" {_recordingElapsed():hh\\:mm\\:ss}"
            : string.Empty;
        var tooltip = $"{AppBuildIdentity.Current.DisplayName} · {status}{duration}";
        _icon.Text = tooltip[..Math.Min(63, tooltip.Length)];
    }

    public void Dispose()
    {
        _recordingTimer.Stop();
        _recordingTimer.Dispose();
        if (_menu is not null) _menu.IsOpen = false;
        _icon.Visible = false;
        _icon.Dispose();
        _ownedIcon?.Dispose();
    }
}
