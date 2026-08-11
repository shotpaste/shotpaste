using System.Drawing;
using System.Windows;
using Forms = System.Windows.Forms;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public sealed class TrayIconService : IDisposable
{
    private const string DefaultBalloonTitle = "ShotPaste";
    private const string DefaultBalloonMessage = "操作未能完成，请重试。";
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.Timer _recordingTimer = new() { Interval = 250 };
    private readonly Func<TimeSpan>? _recordingElapsed;
    private Icon? _ownedIcon;
    private Forms.ToolStripMenuItem? _recordingItem;
    private Forms.ToolStripMenuItem? _oneShotItem;
    private Forms.ToolStripMenuItem? _pauseRecordingItem;
    private Forms.ToolStripSeparator? _recordingSeparator;
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
        _icon = new Forms.NotifyIcon { Text = "ShotPaste", Visible = settings.ShowTrayIcon };
        try
        {
            var resource = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Assets/shotpaste-icon.png"));
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
        _icon.ContextMenuStrip = BuildMenu(settings);
        _recordingTimer.Tick += (_, _) => UpdateTooltip();
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
        _icon.BalloonTipTitle = content.Title;
        _icon.BalloonTipText = content.Message;
        _icon.BalloonTipIcon = kind;
        _icon.ShowBalloonTip(2500);
    }

    /// <summary>
    /// Dismisses an outstanding shell notification before a capture starts.
    /// NotifyIcon does not expose a close-balloon API; briefly removing and
    /// restoring the same icon reliably retracts its notification while keeping
    /// the configured menu and event handlers intact.
    /// </summary>
    public void DismissMessage()
    {
        if (!_icon.Visible) return;
        _icon.Visible = false;
        _icon.Visible = true;
    }

    internal static (string Title, string Message) NormalizeBalloonContent(string? title, string? message)
    {
        var normalizedTitle = string.IsNullOrWhiteSpace(title) ? DefaultBalloonTitle : title.Trim();
        var normalizedMessage = string.IsNullOrWhiteSpace(message) ? DefaultBalloonMessage : message.Trim();
        return (LocalizationService.TranslatePhrase(normalizedTitle),
            LocalizationService.TranslatePhrase(normalizedMessage));
    }

    public void UpdateShortcuts(AppSettings settings)
    {
        _settings = settings;
        _icon.Visible = settings.ShowTrayIcon;
        var previous = _icon.ContextMenuStrip;
        _icon.ContextMenuStrip = BuildMenu(settings);
        previous?.Dispose();
        UpdateTooltip();
    }

    public void UpdateRecordingState(bool isRecording, bool isPaused)
    {
        _isRecording = isRecording;
        _isPaused = isPaused;
        if (_oneShotItem is not null) _oneShotItem.Enabled = !isRecording;
        if (_recordingItem is not null)
        {
            _recordingItem.Visible = isRecording;
            _recordingItem.Text = LocalizationService.TranslatePhrase("停止录制", _settings.Language);
        }
        if (_pauseRecordingItem is not null)
        {
            _pauseRecordingItem.Visible = isRecording;
            _pauseRecordingItem.Text = LocalizationService.TranslatePhrase(isPaused ? "继续录制" : "暂停录制", _settings.Language);
        }
        if (_recordingSeparator is not null) _recordingSeparator.Visible = isRecording;
        if (isRecording && _settings.ShowRecordingDurationInTray) _recordingTimer.Start();
        else _recordingTimer.Stop();
        UpdateTooltip();
    }

    private Forms.ContextMenuStrip BuildMenu(AppSettings settings)
    {
        var menu = new Forms.ContextMenuStrip();
        _recordingItem = new Forms.ToolStripMenuItem(
            LocalizationService.TranslatePhrase("停止录制", settings.Language),
            null, (_, _) => RecordingRequested?.Invoke(this, EventArgs.Empty)) { Visible = _isRecording };
        menu.Items.Add(_recordingItem);
        _pauseRecordingItem = new Forms.ToolStripMenuItem(LocalizationService.TranslatePhrase(_isPaused ? "继续录制" : "暂停录制", settings.Language), null,
            (_, _) => PauseRecordingRequested?.Invoke(this, EventArgs.Empty)) { Visible = _isRecording };
        menu.Items.Add(_pauseRecordingItem);
        _recordingSeparator = new Forms.ToolStripSeparator { Visible = _isRecording };
        menu.Items.Add(_recordingSeparator);
        _oneShotItem = new Forms.ToolStripMenuItem(
            Label("一键 Shot", settings.OneShotHotkey, settings),
            null,
            (_, _) => OneShotRequested?.Invoke(this, EventArgs.Empty)) { Enabled = !_isRecording };
        menu.Items.Add(_oneShotItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Label("剪贴板历史", settings.HistoryHotkey, settings), null, (_, _) => HistoryRequested?.Invoke(this, EventArgs.Empty));
        menu.Items.Add(LocalizationService.TranslatePhrase("设置", settings.Language), null, (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(LocalizationService.TranslatePhrase("退出 ShotPaste", settings.Language), null, (_, _) => ExitRequested?.Invoke(this, EventArgs.Empty));
        return menu;
    }

    private static string Label(string title, string shortcut, AppSettings settings)
    {
        var localized = LocalizationService.TranslatePhrase(title, settings.Language);
        return settings.ShortcutsEnabled && !string.IsNullOrWhiteSpace(shortcut) ? $"{localized}    {shortcut}" : localized;
    }

    private void UpdateTooltip()
    {
        if (!_isRecording)
        {
            _icon.Text = "ShotPaste";
            return;
        }
        var status = LocalizationService.TranslatePhrase(_isPaused ? "录制已暂停" : "正在录制", _settings.Language);
        var duration = _settings.ShowRecordingDurationInTray && _recordingElapsed is not null
            ? $" {_recordingElapsed():hh\\:mm\\:ss}"
            : string.Empty;
        var tooltip = $"ShotPaste · {status}{duration}";
        _icon.Text = tooltip[..Math.Min(63, tooltip.Length)];
    }

    public void Dispose()
    {
        _recordingTimer.Stop();
        _recordingTimer.Dispose();
        _icon.Visible = false;
        _icon.Dispose();
        _ownedIcon?.Dispose();
    }
}
