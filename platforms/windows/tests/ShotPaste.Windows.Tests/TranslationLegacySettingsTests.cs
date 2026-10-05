using System.Text.Json;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class TranslationLegacySettingsTests
{
    [Theory]
    [InlineData("custom", true)]
    [InlineData("builtin", false)]
    [InlineData("Custom", false)]
    [InlineData("", false)]
    public void PublishedPromptPreferenceMigratesWithoutRestoringImplicitSharing(string oldMode, bool useCustom)
    {
        var json = JsonSerializer.Serialize(new
        {
            TranslationPromptMode = oldMode,
            TranslationPrompt = "Preserve code and URLs.",
            TranslationSendsRecognizedText = true,
            AgentEndpoint = "http://10.0.0.1:8080/chat/v1/completions",
            AgentModel = "existing-model",
            AgentApiProtocol = "openAICompatible",
            AgentApiKeyProtected = "synthetic-protected-placeholder"
        });

        var settings = SettingsStore.DeserializeSettings(json);

        Assert.Equal(useCustom, settings.TranslationUseCustomPrompt);
        Assert.Equal("Preserve code and URLs.", settings.TranslationPrompt);
        Assert.False(settings.TranslationSendRecognizedText);
        Assert.Equal("http://10.0.0.1:8080/chat/v1/completions", settings.AgentEndpoint);
        Assert.Equal("existing-model", settings.AgentModel);
        Assert.Equal("openAICompatible", settings.AgentApiProtocol);
        Assert.Equal("synthetic-protected-placeholder", settings.AgentApiKeyProtected);
        var modern = SettingsStore.DeserializeSettings(JsonSerializer.Serialize(settings));
        Assert.Equal(useCustom, modern.TranslationUseCustomPrompt);
        Assert.False(modern.TranslationSendRecognizedText);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ExplicitModernPromptChoiceWinsOverLegacyCustomMode(bool modernChoice)
    {
        var json = JsonSerializer.Serialize(new
        {
            TranslationPromptMode = "custom",
            TranslationUseCustomPrompt = modernChoice,
            TranslationSendsRecognizedText = true
        });

        var settings = SettingsStore.DeserializeSettings(json);

        Assert.Equal(modernChoice, settings.TranslationUseCustomPrompt);
        Assert.False(settings.TranslationSendRecognizedText);
    }

    [Fact]
    public void LegacyPreferenceDoesNotOverrideAnExplicitModernSharingChoice()
    {
        var settings = SettingsStore.DeserializeSettings("""{"TranslationPromptMode":"custom","TranslationSendRecognizedText":true}""");
        Assert.True(settings.TranslationUseCustomPrompt);
        Assert.True(settings.TranslationSendRecognizedText);
    }

    [Fact]
    public void MissingLegacyPreferenceAndNullDocumentKeepSafeDefaults()
    {
        foreach (var json in new[] { "{}", "null", "{\"TranslationPromptMode\":null}" })
        {
            var settings = SettingsStore.DeserializeSettings(json);
            Assert.False(settings.TranslationUseCustomPrompt);
            Assert.False(settings.TranslationSendRecognizedText);
        }
    }
}
