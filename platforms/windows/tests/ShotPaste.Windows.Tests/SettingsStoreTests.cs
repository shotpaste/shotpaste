using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class SettingsStoreTests
{
    [Fact]
    public void Constructor_NormalizesDiagnosticsRetention()
    {
        var store = new SettingsStore(new AppSettings
        {
            DiagnosticsRetentionDays = 0
        });

        Assert.Equal(1, store.Current.DiagnosticsRetentionDays);
        Assert.Equal(AppSettings.CurrentSchemaVersion, store.Current.SchemaVersion);
    }

    [Fact]
    public void Constructor_NormalizesQuickAccessActionsAndRecordingLimits()
    {
        var settings = new AppSettings
        {
            QuickAccessActions = ["Copy", "Unknown", "Drag", "Delete", "Open", "SaveOrOpen", "Edit", "Close"],
            RecordingAnnotationClearSeconds = 0,
            RecordingAnnotationMaxCount = 500
        };

        var store = new SettingsStore(settings);

        Assert.Equal(6, store.Current.QuickAccessActions.Count);
        Assert.DoesNotContain("Unknown", store.Current.QuickAccessActions);
        Assert.DoesNotContain("Edit", store.Current.QuickAccessActions);
        Assert.DoesNotContain("Drag", store.Current.QuickAccessActions);
        Assert.DoesNotContain("Open", store.Current.QuickAccessActions);
        Assert.Contains("SaveOrOpen", store.Current.QuickAccessActions);
        Assert.Contains("Delete", store.Current.QuickAccessActions);
        Assert.Equal(1, store.Current.RecordingAnnotationClearSeconds);
        Assert.Equal(200, store.Current.RecordingAnnotationMaxCount);
    }

    [Fact]
    public void Constructor_NormalizesRecordingEffectsAndBackfillsPerToolPolicies()
    {
        var store = new SettingsStore(new AppSettings
        {
            RecordingClickRadius = 500,
            RecordingClickOpacity = -1,
            RecordingClickRippleCount = 9,
            RecordingClickLeftColor = "invalid",
            RecordingKeystrokePosition = "Center",
            RecordingKeystrokeVisibility = "AllKeys",
            RecordingAnnotationToolPolicies = []
        });

        Assert.Equal(96, store.Current.RecordingClickRadius);
        Assert.Equal(0.1, store.Current.RecordingClickOpacity);
        Assert.Equal(5, store.Current.RecordingClickRippleCount);
        Assert.Equal("#FF7C3AED", store.Current.RecordingClickLeftColor);
        Assert.Equal("BottomCenter", store.Current.RecordingKeystrokePosition);
        Assert.Equal("All", store.Current.RecordingKeystrokeVisibility);
        Assert.Equal(Enum.GetNames<RecordingAnnotationTool>().Length,
            store.Current.RecordingAnnotationToolPolicies.Count);
    }

    [Theory]
    [InlineData("pt-BR")]
    [InlineData("it-IT")]
    [InlineData("unknown")]
    public void Constructor_ReplacesLocalesNotPresentInMacCatalog(string locale)
    {
        var store = new SettingsStore(new AppSettings { Language = locale });

        Assert.Equal("System", store.Current.Language);
    }

    [Fact]
    public void NewSettings_DefaultToFullHistoryPresentation()
    {
        var store = new SettingsStore(new AppSettings());

        Assert.Equal("Hud", store.Current.HistoryBackgroundStyle);
        Assert.Equal(980, store.Current.HistoryExpandedWidth);
        Assert.Equal(680, store.Current.HistoryExpandedHeight);
        Assert.Equal(30, store.Current.HistoryRetentionDays);
        Assert.Equal(1_000, store.Current.HistoryMaxCount);
    }

    [Fact]
    public void Constructor_ClampsPersistedHistorySizesToReachableRanges()
    {
        var store = new SettingsStore(new AppSettings
        {
            HistoryExpandedWidth = 9999,
            HistoryExpandedHeight = 10
        });

        Assert.Equal(2400, store.Current.HistoryExpandedWidth);
        Assert.Equal(520, store.Current.HistoryExpandedHeight);
    }

    [Fact]
    public void Constructor_NormalizesPersistedExpandedHistoryCoordinates()
    {
        var store = new SettingsStore(new AppSettings
        {
            HistoryExpandedLeft = double.PositiveInfinity,
            HistoryExpandedTop = -250_000
        });

        Assert.Null(store.Current.HistoryExpandedLeft);
        Assert.Equal(-100_000, store.Current.HistoryExpandedTop);
    }
}
