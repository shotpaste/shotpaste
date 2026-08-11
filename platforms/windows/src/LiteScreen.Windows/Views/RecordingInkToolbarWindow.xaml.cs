using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using LiteScreen.Windows.Interop;
using LiteScreen.Windows.Models;
using Forms = System.Windows.Forms;
using WpfButton = System.Windows.Controls.Button;
using WpfColor = System.Windows.Media.Color;
using WpfPoint = System.Windows.Point;

namespace LiteScreen.Windows.Views;

public partial class RecordingInkToolbarWindow : Window
{
    private readonly RecordingInkWindow _ink;
    private bool _initializing;

    public event EventHandler? CloseRequested;
    internal static uint CaptureExclusionAffinity => NativeMethods.WdaExcludeFromCapture;

    public RecordingInkToolbarWindow(RecordingInkWindow ink)
    {
        _ink = ink;
        _initializing = true;
        InitializeComponent();
        WidthSlider.Value = ink.State.StrokeWidth;
        FadeCheckBox.IsChecked = ink.State.FadeEnabled;
        RefreshPolicyEditor();
        _initializing = false;
        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) => PositionNearCapture();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (!App.UiTestMode) NativeMethods.SetWindowDisplayAffinity(handle, CaptureExclusionAffinity);
    }

    private void PositionNearCapture()
    {
        if (PresentationSource.FromVisual(this) is not HwndSource source) return;
        var toDip = source.CompositionTarget.TransformFromDevice;
        var bounds = _ink.CaptureBounds;
        var screen = Forms.Screen.FromRectangle(bounds);
        var captureTopLeft = toDip.Transform(new WpfPoint(bounds.Left, bounds.Top));
        var workTopLeft = toDip.Transform(new WpfPoint(screen.WorkingArea.Left, screen.WorkingArea.Top));
        var workBottomRight = toDip.Transform(new WpfPoint(screen.WorkingArea.Right, screen.WorkingArea.Bottom));
        Left = Math.Clamp(captureTopLeft.X + 8, workTopLeft.X + 8, Math.Max(workTopLeft.X + 8, workBottomRight.X - ActualWidth - 8));
        var above = captureTopLeft.Y - ActualHeight - 8;
        Top = above >= workTopLeft.Y ? above : Math.Min(workBottomRight.Y - ActualHeight - 8, captureTopLeft.Y + 8);
    }

    private void OnTool(object sender, RoutedEventArgs e)
    {
        if (sender is not WpfButton button || !Enum.TryParse(button.Tag?.ToString(), out RecordingAnnotationTool tool)) return;
        _ink.SelectTool(tool);
        RefreshPolicyEditor();
        foreach (var child in ToolPanel.Children.OfType<WpfButton>()) child.ClearValue(BackgroundProperty);
        button.Background = new SolidColorBrush(WpfColor.FromArgb(80, 124, 58, 237));
    }

    private void OnColor(object sender, RoutedEventArgs e)
    {
        if (sender is WpfButton { Tag: string color }) _ink.SetStrokeColor(color);
    }

    private void OnWidthChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_initializing) _ink.SetStrokeWidth(e.NewValue);
    }

    private void OnClearModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        if (ClearModePicker.SelectedItem is not ComboBoxItem item ||
            !Enum.TryParse(item.Tag?.ToString(), out RecordingAnnotationClearMode mode)) return;
        _ink.SetClearMode(mode);
        UpdateClearValueEditor();
    }

    private void UpdateClearValueEditor()
    {
        if (ClearValueBox is null || ClearValueUnit is null) return;
        var policy = _ink.CurrentPolicy;
        var hidden = policy.ClearMode == RecordingAnnotationClearMode.Manual;
        ClearValueBox.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
        ClearValueUnit.Visibility = ClearValueBox.Visibility;
        if (hidden) return;
        _initializing = true;
        ClearValueBox.Text = _ink.CurrentClearValue.ToString();
        ClearValueUnit.Text = policy.ClearMode == RecordingAnnotationClearMode.AfterSeconds ? "秒" : "笔";
        _initializing = false;
    }

    private void OnClearValueChanged(object sender, TextChangedEventArgs e)
    {
        if (!_initializing && int.TryParse(ClearValueBox.Text, out var value)) _ink.SetClearValue(value);
    }

    private void OnUndo(object sender, RoutedEventArgs e) => _ink.UndoLast();
    private void OnClear(object sender, RoutedEventArgs e) => _ink.ClearAnnotations();
    private void OnFadeChanged(object sender, RoutedEventArgs e)
    {
        if (!_initializing) _ink.SetFadeEnabled(FadeCheckBox.IsChecked == true);
    }

    private void RefreshPolicyEditor()
    {
        if (ClearModePicker is null) return;
        _initializing = true;
        var policy = _ink.CurrentPolicy;
        ClearModePicker.SelectedItem = ClearModePicker.Items.Cast<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals(item.Tag?.ToString(), policy.ClearMode.ToString(), StringComparison.OrdinalIgnoreCase));
        _initializing = false;
        UpdateClearValueEditor();
    }
    private void OnClose(object sender, RoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left) DragMove();
    }
}
