using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;
using ShotPaste.Windows.Views;
using System.Xml.Linq;

namespace ShotPaste.Windows.Tests;

public sealed class AppControllerFlowTests
{
    [Theory]
    [InlineData(true, false, false, true)]
    [InlineData(false, false, false, false)]
    [InlineData(true, true, true, false)]
    [InlineData(false, false, true, true)]
    public void OwnApplicationVisibility_UsesIndependentScreenshotAndRecordingSettings(
        bool excludeScreenshots, bool includeInRecording, bool forRecording, bool expectedHide)
    {
        var settings = new AppSettings
        {
            ExcludeOwnApplicationFromScreenshots = excludeScreenshots,
            IncludeShotPasteInRecording = includeInRecording
        };

        Assert.Equal(expectedHide, AppController.ShouldHideOwnApplication(settings, forRecording));
    }

    [Fact]
    public void RecordingToolbar_ExposesMicrophoneLevelAndDistinctStateFeedback()
    {
        var xaml = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "RecordingToolbarWindow.xaml"));
        var code = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "RecordingToolbarWindow.xaml.cs"));

        Assert.Contains("RecordingMicrophoneLevel", xaml, StringComparison.Ordinal);
        Assert.Contains("RecordingMicrophoneState", xaml, StringComparison.Ordinal);
        Assert.Contains("MicrophoneFeedbackState.NoInput", code, StringComparison.Ordinal);
        Assert.Contains("MicrophoneFeedbackState.Muted", code, StringComparison.Ordinal);
        Assert.Contains("MicrophoneFeedbackState.Disconnected", code, StringComparison.Ordinal);
        Assert.Contains("_recording.StateChanged += OnRecordingStateChanged", code, StringComparison.Ordinal);
    }
    [Fact]
    public void OrdinaryCaptureEntryPoints_AreAbsent()
    {
        var controller = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "AppController.cs"));
        var urls = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "UrlSchemeService.cs"));
        var tray = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "TrayIconService.cs"));
        var hotkeys = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "GlobalHotkeyService.cs"));

        foreach (var removed in new[]
                 {
                     "CaptureAreaAnnotate", "CaptureFullscreen", "CaptureOcr",
                     "AppCommand.CaptureArea", "HotkeyAction.AreaAnnotate",
                     "AreaAnnotateRequested", "FullscreenRequested", "OcrRequested", "ScrollingRequested"
                 })
        {
            Assert.DoesNotContain(removed, controller, StringComparison.Ordinal);
            Assert.DoesNotContain(removed, urls, StringComparison.Ordinal);
            Assert.DoesNotContain(removed, tray, StringComparison.Ordinal);
            Assert.DoesNotContain(removed, hotkeys, StringComparison.Ordinal);
        }
        Assert.DoesNotContain("public void CaptureScrolling(", controller, StringComparison.Ordinal);
    }

    [Fact]
    public void OneShot_UsesSharedFrozenSelectionAndExistingExecutionFlows()
    {
        var controller = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "AppController.cs"));
        var start = controller.IndexOf("public void StartOneShot()", StringComparison.Ordinal);
        var end = controller.IndexOf("private async Task StartOneShotRecordingAsync", start, StringComparison.Ordinal);

        Assert.True(start >= 0 && end > start, "StartOneShot method was not found.");
        var method = controller[start..end];
        Assert.Contains("SelectOneShotAsync(recordingOptions)", method, StringComparison.Ordinal);
        Assert.Contains("CaptureScrollingCoreAsync(result.Rectangle)", method, StringComparison.Ordinal);
        Assert.Contains("StartOneShotRecordingAsync(result.Rectangle, result.RecordingOptions)", method, StringComparison.Ordinal);
        Assert.Contains("case OneShotMode.Ocr when result.Image is not null:", method, StringComparison.Ordinal);
        Assert.Contains("ProcessOcrImageAsync(result.Image)", method, StringComparison.Ordinal);
        Assert.Contains("FinishImageCaptureAsync", method, StringComparison.Ordinal);
        Assert.Contains("ShowClipboardHistory()", method, StringComparison.Ordinal);

        Assert.Contains("await ExecuteRecordingRequestAsync(request);", controller, StringComparison.Ordinal);
        Assert.Contains("_tray.OneShotRequested += (_, _) => StartOneShot();", controller, StringComparison.Ordinal);
        Assert.Contains("case HotkeyAction.OneShot: StartOneShot();", controller, StringComparison.Ordinal);
    }

    [Fact]
    public void ClipboardHistoryEntryPoints_OpenFullPanelOnClipboardFilter()
    {
        var controller = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "AppController.cs"));
        var historyWindow = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "MainWindow.xaml.cs"));

        Assert.Contains("public void ShowHistory()", controller, StringComparison.Ordinal);
        Assert.Contains("private void ShowClipboardHistory() => ShowHistory();",
            controller, StringComparison.Ordinal);
        Assert.Contains("_mainWindow.ShowClipboardHistory();", controller, StringComparison.Ordinal);
        Assert.Contains("public void ShowClipboardHistory()", historyWindow, StringComparison.Ordinal);
        Assert.Contains("_selectedKind = \"Clipboard\";", historyWindow, StringComparison.Ordinal);
        Assert.DoesNotContain("DefaultHistoryFilter", controller, StringComparison.Ordinal);
        Assert.DoesNotContain("ApplyHistoryMode", historyWindow, StringComparison.Ordinal);
    }

    [Fact]
    public void OneShotOverlay_ExposesFourTabsAndOcrActionAndLocksAfterInteraction()
    {
        var xaml = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml"));
        var code = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml.cs"));

        Assert.Contains("OneShotScreenshot", xaml, StringComparison.Ordinal);
        Assert.Contains("OneShotScrolling", xaml, StringComparison.Ordinal);
        Assert.Contains("OneShotRecording", xaml, StringComparison.Ordinal);
        Assert.Contains("OneShotClipboard", xaml, StringComparison.Ordinal);
        Assert.Contains("OneShotOcr", xaml, StringComparison.Ordinal);
        Assert.Contains("AnnotationOcrIcon", xaml, StringComparison.Ordinal);
        Assert.Contains("private bool CommitOneShotMode()", code, StringComparison.Ordinal);
        Assert.Contains("UpdateOneShotSwitcherVisibility();", code, StringComparison.Ordinal);
        Assert.Contains("ShouldShowOneShotSwitcher(_oneShotCommitted, isDrawingSelection)", code,
            StringComparison.Ordinal);
        Assert.Contains("OneShotMode.Ocr", code, StringComparison.Ordinal);
        Assert.Contains("OneShotOcrPixelRect", code, StringComparison.Ordinal);
        Assert.Contains("button.IsEnabled = !_oneShotCommitted || selected", code, StringComparison.Ordinal);
        Assert.Contains("OneShotPhysicalRectangle()", code, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(false, false, true)]
    [InlineData(false, true, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, false)]
    public void OneShotSwitcher_OnlyShowsWhileModeCanSwitchAndSelectionIsIdle(
        bool isCommitted,
        bool isDrawingSelection,
        bool expected)
    {
        Assert.Equal(expected,
            InlineAnnotateWindow.ShouldShowOneShotSwitcher(isCommitted, isDrawingSelection));
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public void OneShotSelection_DragsOnlyBeforeToolCommit(
        bool isCommitted,
        bool expected)
    {
        Assert.Equal(expected,
            InlineAnnotateWindow.ShouldMoveSelectionOnCanvasDrag(isCommitted));
    }

    [Fact]
    public void OneShotToolbarDragDoesNotCommitTheSelectedMode()
    {
        var code = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml.cs"));
        var start = code.IndexOf("private void OnMoveMouseDown", StringComparison.Ordinal);
        var end = code.IndexOf("private void OnToolbarMoveMouseMove", start, StringComparison.Ordinal);

        Assert.True(start >= 0 && end > start, "One Shot toolbar drag handler was not found.");
        var method = code[start..end];
        Assert.DoesNotContain("CommitOneShotMode", method, StringComparison.Ordinal);
        Assert.Contains("_draggingOneShotToolbar = true", method, StringComparison.Ordinal);
        Assert.Contains("CaptureMouse()", method, StringComparison.Ordinal);
        Assert.DoesNotContain("MoveButton.CaptureMouse()", method, StringComparison.Ordinal);
        Assert.Contains("if (_draggingOneShotToolbar && e.ChangedButton == MouseButton.Left)", code, StringComparison.Ordinal);
        Assert.Contains("MoveOneShotToolbar(e.GetPosition(OverlayCanvas))", code, StringComparison.Ordinal);
    }

    [Fact]
    public void OneShotRecordingOptions_UseReadableTextOnTheDarkHud()
    {
        var xaml = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml"));
        var document = XDocument.Parse(xaml);
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";

        foreach (var name in new[]
                 {
                     "OneShotVideo", "OneShotGif", "OneShotRecordingCursor",
                     "OneShotSystemAudio", "OneShotMicrophone"
                 })
        {
            var control = Assert.Single(document.Descendants(),
                element => string.Equals((string?)element.Attribute(x + "Name"), name, StringComparison.Ordinal));
            Assert.Equal("{DynamicResource HudTextBrush}", (string?)control.Attribute("Foreground"));
        }
    }

    [Fact]
    public void OneShotToolbarDrag_DoesNotCommitTheSelectedModeAndKeepsWindowCapture()
    {
        var code = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml.cs"));
        var start = code.IndexOf("private void OnMoveMouseDown", StringComparison.Ordinal);
        var end = code.IndexOf("private void OnToolbarMoveMouseMove", start, StringComparison.Ordinal);

        Assert.True(start >= 0 && end > start, "One Shot toolbar drag handler was not found.");
        var method = code[start..end];
        Assert.DoesNotContain("CommitOneShotMode", method, StringComparison.Ordinal);
        Assert.Contains("_draggingOneShotToolbar = true", method, StringComparison.Ordinal);
        Assert.Contains("CaptureMouse()", method, StringComparison.Ordinal);
        Assert.DoesNotContain("MoveButton.CaptureMouse()", method, StringComparison.Ordinal);
        Assert.Contains("if (_draggingOneShotToolbar && e.ChangedButton == MouseButton.Left)", code,
            StringComparison.Ordinal);
        Assert.Contains("MoveOneShotToolbar(e.GetPosition(OverlayCanvas))", code, StringComparison.Ordinal);
    }

    [Fact]
    public void OneShotSwitcherDrag_DoesNotCommitTheSelectedModeAndKeepsWindowCapture()
    {
        var xaml = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml"));
        var code = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml.cs"));
        var start = code.IndexOf("private void OnOneShotDragMouseDown", StringComparison.Ordinal);
        var end = code.IndexOf("private bool CommitOneShotMode", start, StringComparison.Ordinal);

        Assert.True(start >= 0 && end > start, "One Shot switcher drag handler was not found.");
        var method = code[start..end];
        Assert.Contains("PreviewMouseLeftButtonDown=\"OnOneShotDragMouseDown\"", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain("CommitOneShotMode", method, StringComparison.Ordinal);
        Assert.Contains("_draggingOneShotSwitcher = true", method, StringComparison.Ordinal);
        Assert.Contains("CaptureMouse()", method, StringComparison.Ordinal);
        Assert.DoesNotContain("OneShotDragHandle.CaptureMouse()", method, StringComparison.Ordinal);
        Assert.Contains("if (_draggingOneShotSwitcher && e.ChangedButton == MouseButton.Left)", code,
            StringComparison.Ordinal);
        Assert.Contains("MoveOneShotSwitcher(e.GetPosition(OverlayCanvas))", code, StringComparison.Ordinal);
    }

    [Fact]
    public void IndependentAnnotationEditor_IsAbsentFromProductSurfaces()
    {
        Assert.False(File.Exists(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "AnnotateWindow.xaml")));
        Assert.False(File.Exists(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "AnnotationLauncherWindow.xaml")));
        Assert.False(File.Exists(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "SelectionOverlayWindow.xaml")));
        Assert.False(File.Exists(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "RecordingSetupWindow.xaml")));

        foreach (var relativePath in new[]
                 {
                     new[] { "Services", "AppController.cs" },
                     new[] { "Services", "TrayIconService.cs" },
                     new[] { "Services", "GlobalHotkeyService.cs" },
                     new[] { "Services", "UrlSchemeService.cs" },
                     new[] { "Views", "InlineAnnotateWindow.xaml" },
                     new[] { "Views", "MainWindow.xaml" },
                     new[] { "Views", "QuickAccessWindow.xaml" },
                     new[] { "Views", "SettingsWindow.xaml" }
                 })
        {
            var source = File.ReadAllText(FindRepositoryFile(
                "platforms", "windows", "src", "ShotPaste.Windows", relativePath[0], relativePath[1]));
            Assert.DoesNotContain("OpenAnnotate", source, StringComparison.Ordinal);
            Assert.DoesNotContain("InlineOpenEditor", source, StringComparison.Ordinal);
            Assert.DoesNotContain("QuickAccessEdit", source, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void OneShotToolbar_OrderMatchesMacAndUsesOnlySharedIconTemplates()
    {
        var xaml = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml"));
        var document = XDocument.Parse(xaml);
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";

        var toolbar = Assert.Single(document.Descendants(), element =>
            string.Equals((string?)element.Attribute(x + "Name"), "ToolbarContent", StringComparison.Ordinal));
        var orderedIds = toolbar.Descendants()
            .Select(element => (string?)element.Attribute("AutomationProperties.AutomationId"))
            .Where(value => value is not null)
            .Select(value => value!)
            .ToArray();

        Assert.Equal(
            [
                "OneShotMoveToolbar", "InlineToolSelection", "InlineToolRectangle",
                "InlineToolFilledRectangle", "InlineToolOval", "InlineToolArrow", "InlineToolLine",
                "InlineToolText", "InlineToolHighlighter", "InlineToolBlur", "InlineToolSpotlight",
                "InlineToolCounter", "InlineToolPencil", "InlineUndo", "InlineRedo", "OneShotOcr",
                "OneShotPin", "OneShotCopy", "OneShotCancel", "OneShotDone"
            ],
            orderedIds);
        Assert.Contains("Content=\"Text\"", xaml, StringComparison.Ordinal);
        Assert.Contains("ContentTemplate=\"{StaticResource AnnotationTextIcon}\"", xaml, StringComparison.Ordinal);
        Assert.Contains("Content=\"Blur\"", xaml, StringComparison.Ordinal);
        Assert.Contains("ContentTemplate=\"{StaticResource AnnotationBlurIcon}\"", xaml, StringComparison.Ordinal);
        Assert.Contains("ContentTemplate=\"{StaticResource AnnotationToolbarDragIcon}\"", xaml,
            StringComparison.Ordinal);
    }

    [Fact]
    public void OneShotPropertiesAndSelectionMatchMacInteractionContract()
    {
        var xaml = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml"));
        var code = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "InlineAnnotateWindow.xaml.cs"));

        Assert.Contains("x:Name=\"PropertiesBar\" Visibility=\"Collapsed\" Height=\"38\"", xaml,
            StringComparison.Ordinal);
        Assert.Contains("x:Key=\"InlineColorSwatchButton\"", xaml, StringComparison.Ordinal);
        Assert.Contains("Tag=\"Blur:Washi\"", xaml, StringComparison.Ordinal);
        Assert.Contains("Tag=\"ArrowType:Outlined\"", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain("CustomColor", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("FavoriteColor", xaml, StringComparison.OrdinalIgnoreCase);

        Assert.Contains("private readonly HashSet<UIElement> _selectedElements", code, StringComparison.Ordinal);
        Assert.Contains("SelectionMarquee.Visibility = Visibility.Visible", code, StringComparison.Ordinal);
        Assert.Contains("PushManipulationEdit", code, StringComparison.Ordinal);
        Assert.Contains("Key.Left or Key.Right or Key.Up or Key.Down", code, StringComparison.Ordinal);
        Assert.Contains("if (e.Key == Key.Delete && _selectedElements.Count > 0)", code, StringComparison.Ordinal);
        Assert.Contains("private readonly Stack<EditAction> _undo", code, StringComparison.Ordinal);
        Assert.Contains("private readonly Stack<EditAction> _redo", code, StringComparison.Ordinal);
    }

    [Fact]
    public void ToolKeySettingsAndOrdinarySelectionServices_AreDeleted()
    {
        var settings = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Models", "AppSettings.cs"));
        var settingsView = File.ReadAllText(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Views", "SettingsWindow.xaml"));

        Assert.DoesNotContain("RecordingAnnotationTemporaryModifier", settings, StringComparison.Ordinal);
        Assert.DoesNotContain("RecordingAnnotationTemporaryHoldDurationMs", settings, StringComparison.Ordinal);
        Assert.DoesNotContain("临时切换键", settingsView, StringComparison.Ordinal);
        Assert.False(File.Exists(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "LiveSelectionInputService.cs")));
        Assert.False(File.Exists(FindRepositoryFile(
            "platforms", "windows", "src", "ShotPaste.Windows", "Services", "LiveSelectionRawInputService.cs")));
    }

    private static string FindRepositoryFile(params string[] relativeParts)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, ".git")) &&
               !File.Exists(Path.Combine(directory.FullName, ".git")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        return Path.Combine([directory!.FullName, .. relativeParts]);
    }
}
