using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using Orientation = System.Windows.Controls.Orientation;

namespace ShotPaste.Windows.Views;

public sealed class AudioRecordingPreparationWindow : Window
{
    private readonly CheckBox _system;
    private readonly CheckBox _microphone;
    private readonly CheckBox _transcribe;
    private readonly CheckBox _ai;
    private readonly ComboBox _language;
    private readonly ComboBox _template;
    public bool SystemAudio => _system.IsChecked == true;
    public bool Microphone => _microphone.IsChecked == true;
    public bool Transcribe => _transcribe.IsEnabled && _transcribe.IsChecked == true;
    public bool UseAI => Transcribe && _ai.IsChecked == true;
    public string SpeechLanguage => (_language.SelectedItem as ComboBoxItem)?.Tag as string ?? "auto";
    public string OrganizationTemplate => (_template.SelectedItem as ComboBoxItem)?.Tag as string ?? "generalNotes";
    internal static string L(string key, string fallback) => LocalizationService.Text(LocalizationService.CurrentLanguage, key, fallback);

    public AudioRecordingPreparationWindow(AppSettings settings)
    {
        SetResourceReference(ForegroundProperty, "TextBrush");
        System.Windows.Automation.AutomationProperties.SetAutomationId(this, "AudioRecordingPreparationWindow");
        Title = L("audio-recording.start-button", "Start Audio Recording");
        Width = 450; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var body = new StackPanel { Margin = new Thickness(24) };
        _system = Toggle("audio-recording.system-audio", "System audio", settings.AudioRecordSystemAudio);
        _microphone = Toggle("audio-recording.microphone", "Microphone", settings.AudioRecordMicrophone);
        _transcribe = Toggle("audio-recording.automatic-transcription", "Automatic transcription", settings.AudioTranscriptionEnabled);
        _transcribe.IsEnabled = settings.RecordingTranscriptionCloudVerified && RecordingTranscriptionConfiguration.FromSettings(settings) is not null;
        _ai = Toggle("audio-recording.automatic-ai", "Automatic AI processing", settings.AudioTranscriptionUseAI);
        _language = new ComboBox { Margin = new Thickness(0, 8, 0, 16), MinWidth = 180 };
        var automatic = new ComboBoxItem { Content = L("common.automatic", "Auto"), Tag = "auto" };
        _language.Items.Add(automatic);
        _language.SelectedItem = automatic;
        foreach (var language in LocalizationService.SupportedLanguages)
        {
            var code = language.Code == "zh-TW" ? "zh-CN" : language.Code;
            if (_language.Items.OfType<ComboBoxItem>().Any(item => Equals(item.Tag, code))) continue;
            var item = new ComboBoxItem { Content = language.NativeName, Tag = code };
            _language.Items.Add(item);
            if (code == settings.AudioTranscriptionLanguage) _language.SelectedItem = item;
        }
        body.Children.Add(_system); body.Children.Add(_microphone);
        body.Children.Add(_transcribe); body.Children.Add(_ai);
        body.Children.Add(_language);
        _template = new ComboBox { Margin = new Thickness(0, 0, 0, 16) };
        _template.Items.Add(new ComboBoxItem { Content = L("audio-recording.template-general-notes", "General notes"), Tag = "generalNotes" });
        _template.Items.Add(new ComboBoxItem { Content = L("audio-recording.template-interview-qa", "Interview Q&A"), Tag = "interviewQA" });
        _template.SelectedIndex = settings.RecordingTranscriptionTemplate == "interviewQA" ? 1 : 0;
        System.Windows.Automation.AutomationProperties.SetName(_template, L("audio-recording.template", "Transcript template"));
        body.Children.Add(_template);
        body.Children.Add(new TextBlock { Text = L("audio-recording.windows-privacy-disclosure", "Transcription sends selected audio to your Volcengine account. AI processing sends transcript text to your configured provider."),
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 16) });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        var start = new Button { Content = L("audio-recording.start-button", "Start Audio Recording"), IsDefault = true, Padding = new Thickness(12, 6, 12, 6) };
        System.Windows.Automation.AutomationProperties.SetAutomationId(start, "AudioRecordingStart");
        start.Click += (_, _) => DialogResult = true;
        var cancel = new Button { Content = LocalizationService.TranslatePhrase("取消"), IsCancel = true, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 6, 12, 6) };
        buttons.Children.Add(start); buttons.Children.Add(cancel); body.Children.Add(buttons);
        void Update()
        {
            start.IsEnabled = SystemAudio || Microphone;
            _ai.IsEnabled = Transcribe && !string.IsNullOrWhiteSpace(settings.AgentModel) &&
                RecordingTranscriptAiProcessor.ValidEndpoint(settings.AgentEndpoint) &&
                (new Uri(settings.AgentEndpoint).IsLoopback || VolcengineTosSigner.ValidCredential(settings.AgentApiKey));
            if (!_ai.IsEnabled) _ai.IsChecked = false;
            _language.IsEnabled = Transcribe;
            _template.IsEnabled = UseAI;
        }
        foreach (var toggle in new[] { _system, _microphone, _transcribe, _ai })
        { toggle.Checked += (_, _) => Update(); toggle.Unchecked += (_, _) => Update(); }
        Content = body; Update();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
    }

    private static CheckBox Toggle(string key, string fallback, bool enabled) =>
        new() { Content = L(key, fallback), IsChecked = enabled, Margin = new Thickness(0, 6, 0, 6) };
}

public sealed class AudioRecordingControlWindow : Window
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly TextBlock _status = new() { VerticalAlignment = VerticalAlignment.Center, MinWidth = 150 };
    private readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal };
    private readonly Button _pause;
    private bool _allowClose;
    public event EventHandler? StopRequested;
    public event EventHandler? DiscardRequested;
    public event EventHandler? RestartRequested;
    public AudioRecordingControlWindow(AudioRecordingService service)
    {
        SetResourceReference(ForegroundProperty, "TextBrush");
        System.Windows.Automation.AutomationProperties.SetAutomationId(this, "AudioRecordingControlWindow");
        Title = AudioRecordingPreparationWindow.L("audio-recording.recording", "Audio recording");
        SizeToContent = SizeToContent.WidthAndHeight; ResizeMode = ResizeMode.NoResize;
        Topmost = true; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var body = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12) };
        body.Children.Add(_status); body.Children.Add(_buttons);
        _pause = Add("暂停录制", () => service.TogglePause());
        var stop = Add("停止录制", () => StopRequested?.Invoke(this, EventArgs.Empty));
        System.Windows.Automation.AutomationProperties.SetAutomationId(stop, "AudioRecordingStop");
        Add("重新开始", () => RestartRequested?.Invoke(this, EventArgs.Empty));
        Add("丢弃", () => DiscardRequested?.Invoke(this, EventArgs.Empty));
        _timer.Tick += (_, _) =>
        {
            if (_buttons.IsEnabled) _status.Text = $"{Title}  {service.Elapsed:hh\\:mm\\:ss}";
            _pause.Content = LocalizationService.TranslatePhrase(service.IsPaused ? "继续录制" : "暂停录制");
        };
        Content = body;
        Loaded += (_, _) => _timer.Start();
        Closed += (_, _) => _timer.Stop();
        Closing += (_, args) => { if (!_allowClose) { args.Cancel = true; StopRequested?.Invoke(this, EventArgs.Empty); } };
        WindowAppearanceService.Attach(this, WindowBackdropKind.Mica);
    }
    private Button Add(string title, Action action)
    {
        var button = new Button { Content = LocalizationService.TranslatePhrase(title), Margin = new Thickness(4, 0, 0, 0), Padding = new Thickness(8, 5, 8, 5) };
        button.Click += (_, _) => action(); _buttons.Children.Add(button); return button;
    }
    public void SetSaving(bool saving)
    {
        _buttons.IsEnabled = !saving;
        if (saving) _status.Text = AudioRecordingPreparationWindow.L("audio-recording.saving", "Saving audio…");
    }
    public void CloseAfterCompletion() { _allowClose = true; Close(); }
}
