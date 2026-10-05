using System.Text.Json;
using ShotPaste.Windows.Models;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class TranslationSettingsTests
{
    [Fact]
    public void ExistingSettingsKeepProviderAndDefaultTranslationSharingOff()
    {
        var settings = JsonSerializer.Deserialize<AppSettings>("""{"AgentEndpoint":"https://example.com/v1/messages","AgentModel":"configured","AgentApiProtocol":"anthropicMessages"}""")!;
        SettingsStore.Normalize(settings);
        Assert.False(settings.TranslationSendRecognizedText);
        Assert.Equal("configured", settings.AgentModel);
        Assert.Equal("anthropicMessages", settings.AgentApiProtocol);
        Assert.Equal(15, settings.TranslationTimeoutSeconds);
    }

    [Theory]
    [InlineData(0, 5)]
    [InlineData(900, 120)]
    public void TranslationSettingsAreBoundedAndSurviveSerialization(int input, int expected)
    {
        var settings = new AppSettings { TranslationSendRecognizedText = true, TranslationTimeoutSeconds = input,
            TranslationUseCustomPrompt = true, TranslationPrompt = new string('a', 2100) };
        SettingsStore.Normalize(settings);
        var restored = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(settings))!;
        Assert.Equal(expected, restored.TranslationTimeoutSeconds);
        Assert.Equal(2000, restored.TranslationPrompt.Length);
        Assert.True(restored.TranslationSendRecognizedText);
        Assert.True(restored.TranslationUseCustomPrompt);
    }

    [Theory]
    [InlineData("en-US")]
    [InlineData("ja-JP")]
    [InlineData("ko-KR")]
    [InlineData("de-DE")]
    [InlineData("fr-FR")]
    [InlineData("es-ES")]
    [InlineData("ru-RU")]
    [InlineData("vi-VN")]
    public void TranslationWindowCopyIsLocalized(string language)
    {
        foreach (var phrase in new[] { "译文", "复制图片", "复制文字", "源语言", "目标语言",
            "图片中的长译文可能被裁切；完整内容可在译文标签中查看和复制。" })
            Assert.NotEqual(phrase, LocalizationService.TranslatePhrase(phrase, language));
    }
}
