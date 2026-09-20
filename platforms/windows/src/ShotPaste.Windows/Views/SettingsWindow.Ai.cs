using System.Windows;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class SettingsWindow
{
    private void OnSaveProviderField(object sender, RoutedEventArgs e)
    {
        try
        {
            switch ((sender as FrameworkElement)?.Tag as string)
            {
                case "Endpoint":
                    var endpoint = ProviderEndpointBox.Text.Trim();
                    _ = TextTranslationService.ResolveEndpoint(endpoint, _draft.AgentApiProtocol);
                    _draft.AgentEndpoint = endpoint;
                    break;
                case "Model":
                    var model = ProviderModelBox.Text.Trim();
                    if (string.IsNullOrEmpty(model) || model.Length > 512) throw new ArgumentException();
                    _draft.AgentModel = model;
                    break;
                case "Key":
                    if (string.IsNullOrWhiteSpace(AgentApiKeyBox.Password)) return;
                    var key = AgentApiKeyBox.Password.Trim();
                    if (!VolcengineTosSigner.ValidCredential(key)) throw new ArgumentException();
                    _draft.AgentApiKey = key;
                    break;
            }
            if (!TryApplyDraft(showErrors: true)) return;
            if ((sender as FrameworkElement)?.Tag as string == "Key") AgentApiKeyBox.Clear();
            ProviderStatus.Text = LocalizationService.TranslatePhrase("配置已保存。");
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.Security.Cryptography.CryptographicException)
        {
            ProviderStatus.Text = LocalizationService.TranslatePhrase("配置无效，请检查地址、模型或 API Key。");
        }
    }

    private void UpdateTranslationPrompt()
    {
        if (_draft is null || TranslationPromptBox is null || BuiltinTranslationPrompt is null) return;
        TranslationPromptBox.Visibility = _draft.TranslationPromptMode == "custom" ? Visibility.Visible : Visibility.Collapsed;
        BuiltinTranslationPrompt.Visibility = _draft.TranslationPromptMode == "custom" ? Visibility.Collapsed : Visibility.Visible;
        BuiltinTranslationPrompt.Text = TextTranslationService.BuiltinPrompt;
    }
    private void OnTranslationPromptModeChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UpdateTranslationPrompt);
    private void OnRestoreTranslationPrompt(object sender, RoutedEventArgs e)
    {
        _draft.TranslationPromptMode = "builtin";
        _draft.TranslationPrompt = string.Empty;
        RefreshBindings();
        UpdateTranslationPrompt();
    }
}
