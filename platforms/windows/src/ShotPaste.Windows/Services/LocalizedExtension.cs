using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using Binding = System.Windows.Data.Binding;
using System.Windows.Markup;

namespace ShotPaste.Windows.Services;

/// <summary>Opt-in product copy. User-data bindings never enter localization.</summary>
[MarkupExtensionReturnType(typeof(object))]
public sealed class LocalizedExtension : MarkupExtension
{
    public string Key { get; set; } = string.Empty;
    public bool IsWindowTitle { get; set; }
    private static readonly LanguageSource Source = new();
    private static readonly PhraseConverter Converter = new();

    internal static void LanguageChanged() => Source.Notify();

    internal static Binding CreateBinding(string key, bool isWindowTitle = false) => new(nameof(LanguageSource.Language))
    {
        Source = Source,
        Mode = BindingMode.OneWay,
        Converter = Converter,
        ConverterParameter = (key, isWindowTitle)
    };

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        CreateBinding(Key, IsWindowTitle).ProvideValue(serviceProvider);

    private sealed class LanguageSource : INotifyPropertyChanged
    {
        public string Language => LocalizationService.CurrentLanguage;
        public event PropertyChangedEventHandler? PropertyChanged;
        public void Notify() => PropertyChanged?.Invoke(this, new(nameof(Language)));
    }

    private sealed class PhraseConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            var (key, isWindowTitle) = ((string, bool))parameter;
            var text = LocalizationService.TranslatePhrase(key, (string)value);
            return isWindowTitle ? AppBuildIdentity.Current.FormatWindowTitle(text) : text;
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
            throw new NotSupportedException();
    }
}
