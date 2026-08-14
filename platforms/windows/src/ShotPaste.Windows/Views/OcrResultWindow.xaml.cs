using System.Diagnostics;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Interop;
using System.Windows.Threading;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public partial class OcrResultWindow : Window
{
    private readonly OcrRecognitionResult _result;
    private readonly DispatcherTimer _dismissTimer = new() { Interval = TimeSpan.FromSeconds(10) };

    public OcrResultWindow(OcrRecognitionResult result)
    {
        _result = result;
        InitializeComponent();
        WindowAppearanceService.Attach(this, WindowBackdropKind.Acrylic);
        DataContext = result;
        _dismissTimer.Tick += (_, _) => Close();
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
            NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
                new IntPtr(style | NativeMethods.WsExToolWindow));
        };
        Loaded += (_, _) =>
        {
            _ = Dispatcher.BeginInvoke(PositionAtBottom, DispatcherPriority.Loaded);
            _dismissTimer.Start();
            _ = Dispatcher.BeginInvoke(() =>
            {
                var peer = FrameworkElementAutomationPeer.FromElement(ResultLiveRegion) ??
                           new FrameworkElementAutomationPeer(ResultLiveRegion);
                peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }, DispatcherPriority.ContextIdle);
        };
        ContentRendered += (_, _) => PositionAtBottom();
        SizeChanged += (_, _) =>
        {
            if (IsLoaded) PositionAtBottom();
        };
        Closed += (_, _) => _dismissTimer.Stop();
    }

    private void OnOpenLink(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button { Tag: string value } || string.IsNullOrWhiteSpace(value)) return;
        var target = value.Contains('@') && !value.Contains("://", StringComparison.Ordinal)
            ? "mailto:" + value
            : value.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + value : value;
        if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https" or "mailto")) return;
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }

    private void OnCopy(object sender, RoutedEventArgs e) => ClipboardWriter.SetText(_result.Text);
    private void OnClose(object sender, RoutedEventArgs e) => Close();
    private void OnMouseEnter(object sender, System.Windows.Input.MouseEventArgs e) => _dismissTimer.Stop();
    private void OnMouseLeave(object sender, System.Windows.Input.MouseEventArgs e) => _dismissTimer.Start();

    private void PositionAtBottom()
    {
        var area = WindowAppearanceService.WorkingAreaInDips(this);
        Left = Math.Clamp(area.Left + (area.Width - ActualWidth) / 2,
            area.Left + 12, Math.Max(area.Left + 12, area.Right - ActualWidth - 12));
        Top = Math.Max(area.Top + 12, area.Bottom - ActualHeight - 16);
    }
}
