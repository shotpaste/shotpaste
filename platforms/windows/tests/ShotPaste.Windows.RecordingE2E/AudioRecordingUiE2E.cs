using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Views;

namespace ShotPaste.Windows.RecordingE2E;

/// <summary>Rendered production WPF windows with local fixtures; no cloud, microphone or application-controller claim.</summary>
internal static class AudioRecordingUiE2E
{
    internal static async Task<object> RunAsync(string root)
    {
        var application = Application.Current;
        var resources = application.Resources;
        application.Resources = ProductResources();
        try
        {
            var preparation = await VerifyPreparationAsync(root);
            var results = await VerifyResultsAsync(root);
            var contrast = await VerifyDarkAudioContrastAsync(root);
            return new { Preparation = preparation, Results = results, DarkTheme = contrast,
                Scope = "Production WPF window rendering, local control events and synthetic stored results; tray and application-controller routing require separate acceptance" };
        }
        finally { application.Resources = resources; }
    }

    private static async Task<object> VerifyPreparationAsync(string root)
    {
        var settings = new AppSettings
        {
            AudioRecordSystemAudio = false,
            AudioRecordMicrophone = false,
            AudioTranscriptionEnabled = true,
            AudioTranscriptionUseAI = true,
            RecordingTranscriptionCloudVerified = false
        };
        var window = new AudioRecordingPreparationWindow(settings);
        try
        {
            window.Show();
            await RenderAsync(window);
            var start = Descendants<Button>(window).Single(button => button.IsDefault);
            var toggles = Descendants<CheckBox>(window).ToArray();
            var system = toggles.Single(toggle => Equals(toggle.Content,
                AudioRecordingPreparationWindow.L("audio-recording.system-audio", "System audio")));
            var microphone = toggles.Single(toggle => Equals(toggle.Content,
                AudioRecordingPreparationWindow.L("audio-recording.microphone", "Microphone")));
            if (start.IsEnabled || window.Transcribe || window.UseAI ||
                toggles.Count(toggle => !toggle.IsEnabled) != 2 ||
                Descendants<ComboBox>(window).Any(combo => combo.IsEnabled))
                throw new InvalidOperationException("Preparation did not gate empty sources and unconfigured cloud/AI choices.");
            system.IsChecked = true;
            if (!start.IsEnabled || !window.SystemAudio || window.Microphone)
                throw new InvalidOperationException("System-audio selection did not enable standalone recording.");
            system.IsChecked = false;
            microphone.IsChecked = true;
            if (!start.IsEnabled || window.SystemAudio || !window.Microphone)
                throw new InvalidOperationException("Microphone selection did not enable preparation independently.");
            microphone.IsChecked = false;
            if (start.IsEnabled)
                throw new InvalidOperationException("Deselecting both audio sources left recording enabled.");
            system.IsChecked = true;
            await RenderAsync(window);
            var screenshot = SaveWindow(window, Path.Combine(root, "audio-preparation.png"));
            return new { NoSourceDisabledStart = true, SourceChoicesIndependent = true,
                UnconfiguredTranscriptionAndAiDisabled = true, Screenshot = screenshot,
                Microphone = "Preparation choice only; no microphone capture" };
        }
        finally { window.Close(); }
    }

    private static async Task<object> VerifyDarkAudioContrastAsync(string root)
    {
        ThemeService.Apply("Dark");
        using var service = new AudioRecordingService();
        var control = new AudioRecordingControlWindow(service);
        var preparation = new AudioRecordingPreparationWindow(new AppSettings());
        try
        {
            control.Show();
            await RenderAsync(control);
            var expected = Application.Current.TryFindResource("TextBrush") as SolidColorBrush
                ?? throw new InvalidOperationException("Dark theme text brush is unavailable.");
            foreach (var text in Descendants<TextBlock>(control))
                if (text.Foreground is not SolidColorBrush foreground || foreground.Color != expected.Color)
                    throw new InvalidOperationException("Audio control status does not follow the dark theme text color.");
            SaveWindow(control, Path.Combine(root, "audio-control-dark.png"));
            preparation.Show();
            await RenderAsync(preparation);
            foreach (var text in Descendants<TextBlock>(preparation))
                if (text.Foreground is not SolidColorBrush foreground || foreground.Color != expected.Color)
                    throw new InvalidOperationException("Audio preparation disclosure does not follow the dark theme text color.");
            SaveWindow(preparation, Path.Combine(root, "audio-preparation-dark.png"));
            return new { ControlAndDisclosureUseThemeTextBrush = true };
        }
        finally
        {
            preparation.Close();
            control.CloseAfterCompletion();
            ThemeService.Apply("Light");
        }
    }

    private static async Task<object> VerifyResultsAsync(string root)
    {
        const string rawText = "Synthetic native UI fixture. No speech service was contacted.";
        var job = new RecordingTranscriptionJob
        {
            RecordingPath = Path.Combine(AppPaths.Captures, "SyntheticAudioResult.m4a"),
            ProtectedConfiguration = "completed-ui-fixture-never-submitted",
            State = "completed",
            AiPolishedText = "Synthetic polished text.",
            AiText = "Synthetic organized notes.",
            Parts = [new RecordingTranscriptionPart
            {
                SourcePath = Path.Combine(root, "synthetic-source.m4a"), Role = "system",
                ObjectKey = "synthetic-ui-fixture", DurationMilliseconds = 1000,
                Transcript = new RecordingTranscript(rawText, 1000,
                    [new RecordingUtterance(rawText, 0, 1000, null)])
            }]
        };
        var directory = Path.Combine(AppPaths.Root, "TranscriptionResults");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, job.Id.ToString("N") + ".json"), JsonSerializer.Serialize(job));
        var browser = new TranscriptionResultsWindow();
        try
        {
            browser.Show();
            await RenderAsync(browser);
            var list = Descendants<ListBox>(browser).Single();
            var search = Descendants<TextBox>(browser).Single();
            var filter = Descendants<ComboBox>(browser).Single();
            if (list.Items.Count != 1) throw new InvalidOperationException("Stored synthetic result was not loaded.");
            filter.SelectedIndex = 2;
            if (list.Items.Count != 0) throw new InvalidOperationException("Video filter retained an audio result.");
            filter.SelectedIndex = 1;
            if (list.Items.Count != 1) throw new InvalidOperationException("Audio filter lost its audio result.");
            search.Text = "no-such-result";
            if (list.Items.Count != 0) throw new InvalidOperationException("Result search did not filter unmatched names.");
            search.Text = "SyntheticAudioResult";
            if (list.Items.Count != 1) throw new InvalidOperationException("Result search did not match the stored filename.");
            browser.SelectRecording(job.RecordingPath);
            if (list.SelectedItem is null) throw new InvalidOperationException("Result selection did not locate its recording.");
            await RenderAsync(browser);
            var browserScreenshot = SaveWindow(browser, Path.Combine(root, "audio-results-browser.png"));
            var open = Descendants<Button>(browser).Single(button => Equals(button.Content, LocalizationService.TranslatePhrase("打开")));
            ((IInvokeProvider)new ButtonAutomationPeer(open)).Invoke();
            await Task.Delay(350);
            var detail = Application.Current.Windows.OfType<RecordingTranscriptWindow>().Single();
            try
            {
                await RenderAsync(detail);
                var raw = (TextBox)detail.FindName("TranscriptText");
                var timed = (TextBox)detail.FindName("TimedText");
                var polished = (TextBox)detail.FindName("PolishedText");
                var organized = (TextBox)detail.FindName("AiText");
                if (raw.Text != rawText || !timed.Text.Contains("00:00:01.000") ||
                    polished.Text != job.AiPolishedText || organized.Text != job.AiText ||
                    !((Button)detail.FindName("CopyButton")).IsEnabled ||
                    !((Button)detail.FindName("SaveButton")).IsEnabled)
                    throw new InvalidOperationException("Transcript detail did not expose raw, timed, polished and organized synthetic output.");
                var detailScreenshot = SaveWindow(detail, Path.Combine(root, "audio-transcript-detail.png"));
                return new { StoredLocalFixtureLoaded = true, SearchAndAudioVideoFilters = true,
                    SelectedResultOpened = true, FourResultFormsAvailable = true,
                    BrowserScreenshot = browserScreenshot, DetailScreenshot = detailScreenshot,
                    Cloud = "No processing, retry, resubmission or paid service request" };
            }
            finally { detail.Close(); }
        }
        finally { browser.Close(); }
    }

    private static async Task RenderAsync(Window window)
    {
        window.Topmost = true;
        window.Activate();
        await window.Dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
        await Task.Delay(100);
    }

    private static string SaveWindow(Window window, string path)
    {
        // RenderTargetBitmap omits the DWM/Mica backdrop and produces misleading
        // transparent images. Capture only this visible fixture window's bounds.
        var bounds = AutomationElement.FromHandle(new WindowInteropHelper(window).Handle).Current.BoundingRectangle;
        using var bitmap = new System.Drawing.Bitmap(Math.Max(1, (int)Math.Round(bounds.Width)),
            Math.Max(1, (int)Math.Round(bounds.Height)));
        using var graphics = System.Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen((int)Math.Round(bounds.Left), (int)Math.Round(bounds.Top), 0, 0, bitmap.Size);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        return path;
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject parent) where T : DependencyObject
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        {
            if (child is T match) yield return match;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }

    private static ResourceDictionary ProductResources()
    {
        var resources = new ResourceDictionary();
        foreach (var path in new[] { "DesignTokens.xaml", "Themes/Colors.Light.xaml", "AnnotationIcons.xaml", "Icons.xaml",
            "Controls/Common.xaml", "Controls/Buttons.xaml", "Controls/CheckBox.xaml", "Controls/RadioButton.xaml",
            "Controls/TextBox.xaml", "Controls/ComboBox.xaml", "Controls/Slider.xaml", "Controls/ScrollBar.xaml",
            "Controls/Menu.xaml", "Controls/Tabs.xaml" })
            resources.MergedDictionaries.Add(new ResourceDictionary { Source = AppBuildIdentity.ResourceUri("Resources/" + path) });
        return resources;
    }
}
