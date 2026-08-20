using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using Drawing = System.Drawing;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Views;

public enum RecordingResizeHandle
{
    TopLeft,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left
}

public partial class RecordingRegionOverlayWindow : Window
{
    private const int WmNcHitTest = 0x0084;
    private const int HtTransparent = -1;
    private const int ResizeHandleHitSize = 10;
    private const int MinimumResizeSize = 50;
    private Drawing.Rectangle _region;
    private Drawing.Rectangle _windowBounds;
    private readonly bool _constrainToRegionScreen;
    private bool _showBorder = true;
    private bool _dimOutside = true;
    private bool _editingEnabled = true;
    private bool _dragging;
    private bool _resizing;
    private bool _showScrollingGuidance;
    private RecordingResizeHandle _activeHandle;
    private Drawing.Point _dragStart;
    private Drawing.Point _resizeStart;
    private Drawing.Rectangle _dragStartRegion;
    private Drawing.Rectangle _resizeStartRegion;
    private Drawing.Rectangle _dragBounds;

    public event Action<Drawing.Rectangle>? RegionChanged;

    public RecordingRegionOverlayWindow(
        Drawing.Rectangle region,
        Drawing.Rectangle virtualBounds,
        bool constrainToRegionScreen = false)
    {
        InitializeComponent();
        ShowInTaskbar = App.UiTestMode;
        _region = region;
        _dragBounds = System.Windows.Forms.Screen.FromRectangle(region).Bounds;
        _constrainToRegionScreen = constrainToRegionScreen;
        _windowBounds = constrainToRegionScreen ? _dragBounds : virtualBounds;
        Left = _windowBounds.Left;
        Top = _windowBounds.Top;
        Width = _windowBounds.Width;
        Height = _windowBounds.Height;
        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) => UpdateLayoutForRegion();
    }

    public void UpdateRegion(Drawing.Rectangle region)
    {
        _region = region;
        _dragBounds = System.Windows.Forms.Screen.FromRectangle(region).Bounds;
        if (_constrainToRegionScreen && _windowBounds != _dragBounds)
        {
            _windowBounds = _dragBounds;
            ApplyPhysicalWindowBounds();
        }
        if (IsLoaded) UpdateLayoutForRegion();
    }

    public void SetScrollingAppearance(bool capturing)
    {
        var accent = TryFindResource("Capture.SelectionBrush") as System.Windows.Media.Brush ??
                     System.Windows.Media.Brushes.DodgerBlue;
        TopLine.Fill = accent;
        RightLine.Fill = accent;
        BottomLine.Fill = accent;
        LeftLine.Fill = accent;
        _showBorder = true;
        _dimOutside = !capturing;
        SetInteractionEnabled(!capturing);
    }

    public void SetScrollingGuidance(string title, string? detail = null)
    {
        _showScrollingGuidance = !string.IsNullOrWhiteSpace(title);
        ScrollingGuidanceTitle.Text = title;
        ScrollingGuidanceDetail.Text = detail ?? string.Empty;
        ScrollingGuidanceDetail.Visibility = string.IsNullOrWhiteSpace(detail)
            ? Visibility.Collapsed
            : Visibility.Visible;
        if (IsLoaded) UpdateLayoutForRegion();
    }

    public void SetRecordingAppearance(bool dimOutside)
    {
        _showScrollingGuidance = false;
        SetInteractionEnabled(false);
        _showBorder = false;
        _dimOutside = dimOutside;
        if (App.UiTestMode)
        {
            System.Windows.Automation.AutomationProperties.SetItemStatus(
                this,
                dimOutside ? "Dimmed" : "OutlineOnly");
        }
        if (IsLoaded) UpdateLayoutForRegion();
    }

    public void SetInteractionEnabled(bool enabled)
    {
        _editingEnabled = enabled;
        _dragging = false;
        _resizing = false;
        SelectionHitTarget.ReleaseMouseCapture();
        SetClickThrough(!enabled);
        if (IsLoaded) UpdateLayoutForRegion();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var source = (HwndSource)PresentationSource.FromVisual(this);
        var handle = new WindowInteropHelper(this).Handle;
        var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
        var toolWindowStyle = App.UiTestMode ? 0 : NativeMethods.WsExToolWindow;
        NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle,
            new IntPtr((style & ~NativeMethods.WsExTransparent) | NativeMethods.WsExNoActivate | toolWindowStyle));
        if (!App.UiTestMode) WindowCaptureExclusionService.ExcludeCaptureControl(handle);
        source.AddHook(WndProc);
        ApplyPhysicalWindowBounds();
    }

    private void ApplyPhysicalWindowBounds()
    {
        if (PresentationSource.FromVisual(this) is not HwndSource source) return;
        var handle = source.Handle;
        if (handle == IntPtr.Zero) return;
        NativeMethods.SetWindowPos(
            handle,
            NativeMethods.HwndTopmost,
            _windowBounds.Left,
            _windowBounds.Top,
            _windowBounds.Width,
            _windowBounds.Height,
            NativeMethods.SwpNoActivate | NativeMethods.SwpNoOwnerZOrder);
    }

    private void UpdateLayoutForRegion()
    {
        OverlayCanvas.Width = ActualWidth;
        OverlayCanvas.Height = ActualHeight;
        var scaleX = ActualWidth / _windowBounds.Width;
        var scaleY = ActualHeight / _windowBounds.Height;
        var rect = new Rect(
            (_region.Left - _windowBounds.Left) * scaleX,
            (_region.Top - _windowBounds.Top) * scaleY,
            _region.Width * scaleX,
            _region.Height * scaleY);

        SetRect(DimTop, _dimOutside ? new Rect(0, 0, ActualWidth, Math.Max(0, rect.Top)) : Rect.Empty);
        SetRect(DimLeft, _dimOutside ? new Rect(0, rect.Top, Math.Max(0, rect.Left), Math.Max(0, rect.Height)) : Rect.Empty);
        SetRect(DimRight, _dimOutside ? new Rect(rect.Right, rect.Top, Math.Max(0, ActualWidth - rect.Right), Math.Max(0, rect.Height)) : Rect.Empty);
        SetRect(DimBottom, _dimOutside ? new Rect(0, rect.Bottom, ActualWidth, Math.Max(0, ActualHeight - rect.Bottom)) : Rect.Empty);

        const double thickness = 2;
        SetRect(TopLine, _showBorder ? new Rect(rect.Left, rect.Top, rect.Width, thickness) : Rect.Empty);
        SetRect(RightLine, _showBorder ? new Rect(rect.Right - thickness, rect.Top, thickness, rect.Height) : Rect.Empty);
        SetRect(BottomLine, _showBorder ? new Rect(rect.Left, rect.Bottom - thickness, rect.Width, thickness) : Rect.Empty);
        SetRect(LeftLine, _showBorder ? new Rect(rect.Left, rect.Top, thickness, rect.Height) : Rect.Empty);
        SetRect(SelectionHitTarget, _editingEnabled
            ? new Rect(
                rect.Left - ResizeHandleHitSize,
                rect.Top - ResizeHandleHitSize,
                rect.Width + ResizeHandleHitSize * 2,
                rect.Height + ResizeHandleHitSize * 2)
            : Rect.Empty);

        ScrollingGuidance.Visibility = _showScrollingGuidance ? Visibility.Visible : Visibility.Collapsed;
        if (_showScrollingGuidance)
        {
            var availableWidth = Math.Min(520, Math.Max(0, rect.Width - 32));
            if (availableWidth < 120)
            {
                ScrollingGuidance.Visibility = Visibility.Collapsed;
            }
            else
            {
                ScrollingGuidance.Width = availableWidth;
                ScrollingGuidance.Measure(new System.Windows.Size(availableWidth, double.PositiveInfinity));
                var height = ScrollingGuidance.DesiredSize.Height;
                var top = Math.Clamp(
                    rect.Top + rect.Height * 0.34 - height / 2,
                    rect.Top + 18,
                    Math.Max(rect.Top + 18, rect.Bottom - height - 18));
                Canvas.SetLeft(ScrollingGuidance, rect.Left + (rect.Width - availableWidth) / 2);
                Canvas.SetTop(ScrollingGuidance, top);
            }
        }
    }

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmNcHitTest) return IntPtr.Zero;
        NativeMethods.GetCursorPos(out var cursor);
        if (_editingEnabled &&
            (_region.Contains(cursor.X, cursor.Y) ||
             GetResizeHandle(new Drawing.Point(cursor.X, cursor.Y), _region) is not null))
        {
            return IntPtr.Zero;
        }
        handled = true;
        return new IntPtr(HtTransparent);
    }

    private void OnSelectionMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!_editingEnabled || e.ChangedButton != MouseButton.Left) return;
        NativeMethods.GetCursorPos(out var cursor);
        var handle = GetResizeHandle(new Drawing.Point(cursor.X, cursor.Y), _region);
        if (handle is not null)
        {
            _resizing = true;
            _activeHandle = handle.Value;
            _resizeStart = new Drawing.Point(cursor.X, cursor.Y);
            _resizeStartRegion = _region;
            SelectionHitTarget.CaptureMouse();
            e.Handled = true;
            return;
        }
        _dragStart = new Drawing.Point(cursor.X, cursor.Y);
        _dragStartRegion = _region;
        _dragging = true;
        SelectionHitTarget.CaptureMouse();
        e.Handled = true;
    }

    private void OnSelectionMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_editingEnabled) return;
        NativeMethods.GetCursorPos(out var cursor);
        if (_resizing && e.LeftButton == MouseButtonState.Pressed)
        {
            var next = ResizeRegion(
                _resizeStartRegion,
                _activeHandle,
                cursor.X - _resizeStart.X,
                cursor.Y - _resizeStart.Y,
                _dragBounds);
            if (next == _region) return;
            _region = next;
            UpdateLayoutForRegion();
            RegionChanged?.Invoke(_region);
            e.Handled = true;
            return;
        }
        if (_dragging && e.LeftButton == MouseButtonState.Pressed)
        {
            var next = MoveWithinBounds(
                _dragStartRegion,
                cursor.X - _dragStart.X,
                cursor.Y - _dragStart.Y,
                _dragBounds);
            if (next == _region) return;
            _region = next;
            UpdateLayoutForRegion();
            RegionChanged?.Invoke(_region);
            e.Handled = true;
            return;
        }
        UpdateResizeCursor(new Drawing.Point(cursor.X, cursor.Y));
    }

    private void UpdateResizeCursor(Drawing.Point cursor)
    {
        SelectionHitTarget.Cursor = GetResizeHandle(cursor, _region) switch
        {
            RecordingResizeHandle.TopLeft or RecordingResizeHandle.BottomRight => System.Windows.Input.Cursors.SizeNWSE,
            RecordingResizeHandle.TopRight or RecordingResizeHandle.BottomLeft => System.Windows.Input.Cursors.SizeNESW,
            RecordingResizeHandle.Top or RecordingResizeHandle.Bottom => System.Windows.Input.Cursors.SizeNS,
            RecordingResizeHandle.Left or RecordingResizeHandle.Right => System.Windows.Input.Cursors.SizeWE,
            _ => System.Windows.Input.Cursors.SizeAll
        };
    }

    private void OnSelectionMouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!_editingEnabled) return;
        NativeMethods.GetCursorPos(out var cursor);
        UpdateResizeCursor(new Drawing.Point(cursor.X, cursor.Y));
    }

    internal static Drawing.Rectangle MoveWithinBounds(
        Drawing.Rectangle region,
        int deltaX,
        int deltaY,
        Drawing.Rectangle bounds)
    {
        var maxX = Math.Max(bounds.Left, bounds.Right - region.Width);
        var maxY = Math.Max(bounds.Top, bounds.Bottom - region.Height);
        return new Drawing.Rectangle(
            Math.Clamp(region.X + deltaX, bounds.Left, maxX),
            Math.Clamp(region.Y + deltaY, bounds.Top, maxY),
            region.Width,
            region.Height);
    }

    internal static RecordingResizeHandle? GetResizeHandle(
        Drawing.Point point,
        Drawing.Rectangle region,
        int hitSize = ResizeHandleHitSize)
    {
        var onLeft = Math.Abs(point.X - region.Left) <= hitSize;
        var onRight = Math.Abs(point.X - region.Right) <= hitSize;
        var onTop = Math.Abs(point.Y - region.Top) <= hitSize;
        var onBottom = Math.Abs(point.Y - region.Bottom) <= hitSize;
        if (onLeft && onTop) return RecordingResizeHandle.TopLeft;
        if (onRight && onTop) return RecordingResizeHandle.TopRight;
        if (onLeft && onBottom) return RecordingResizeHandle.BottomLeft;
        if (onRight && onBottom) return RecordingResizeHandle.BottomRight;
        if (onTop) return RecordingResizeHandle.Top;
        if (onBottom) return RecordingResizeHandle.Bottom;
        if (onLeft) return RecordingResizeHandle.Left;
        if (onRight) return RecordingResizeHandle.Right;
        return null;
    }

    internal static Drawing.Rectangle ResizeRegion(
        Drawing.Rectangle region,
        RecordingResizeHandle handle,
        int deltaX,
        int deltaY,
        Drawing.Rectangle bounds)
    {
        var minWidth = Math.Min(MinimumResizeSize, region.Width);
        var minHeight = Math.Min(MinimumResizeSize, region.Height);
        var left = region.Left;
        var top = region.Top;
        var right = region.Right;
        var bottom = region.Bottom;
        var maxLeft = Math.Max(bounds.Left, right - minWidth);
        var maxTop = Math.Max(bounds.Top, bottom - minHeight);
        var minRight = Math.Min(bounds.Right, left + minWidth);
        var minBottom = Math.Min(bounds.Bottom, top + minHeight);

        switch (handle)
        {
            case RecordingResizeHandle.Left:
                left = Math.Clamp(left + deltaX, bounds.Left, maxLeft);
                break;
            case RecordingResizeHandle.Top:
                top = Math.Clamp(top + deltaY, bounds.Top, maxTop);
                break;
            case RecordingResizeHandle.Right:
                right = Math.Clamp(right + deltaX, minRight, bounds.Right);
                break;
            case RecordingResizeHandle.Bottom:
                bottom = Math.Clamp(bottom + deltaY, minBottom, bounds.Bottom);
                break;
            case RecordingResizeHandle.TopLeft:
                left = Math.Clamp(left + deltaX, bounds.Left, maxLeft);
                top = Math.Clamp(top + deltaY, bounds.Top, maxTop);
                break;
            case RecordingResizeHandle.TopRight:
                right = Math.Clamp(right + deltaX, minRight, bounds.Right);
                top = Math.Clamp(top + deltaY, bounds.Top, maxTop);
                break;
            case RecordingResizeHandle.BottomLeft:
                left = Math.Clamp(left + deltaX, bounds.Left, maxLeft);
                bottom = Math.Clamp(bottom + deltaY, minBottom, bounds.Bottom);
                break;
            case RecordingResizeHandle.BottomRight:
                right = Math.Clamp(right + deltaX, minRight, bounds.Right);
                bottom = Math.Clamp(bottom + deltaY, minBottom, bounds.Bottom);
                break;
        }
        return new Drawing.Rectangle(left, top, right - left, bottom - top);
    }

    private void OnSelectionMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (_dragging || _resizing)
        {
            _dragging = false;
            _resizing = false;
            SelectionHitTarget.ReleaseMouseCapture();
            e.Handled = true;
        }
    }

    private void SetClickThrough(bool clickThrough)
    {
        if (!IsLoaded) return;
        var handle = new WindowInteropHelper(this).Handle;
        var style = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle).ToInt64();
        style = clickThrough ? style | NativeMethods.WsExTransparent : style & ~NativeMethods.WsExTransparent;
        NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, new IntPtr(style));
    }

    private static void SetRect(FrameworkElement element, Rect rect)
    {
        if (rect.IsEmpty)
        {
            element.Width = 0;
            element.Height = 0;
            return;
        }
        Canvas.SetLeft(element, rect.Left);
        Canvas.SetTop(element, rect.Top);
        element.Width = Math.Max(0, rect.Width);
        element.Height = Math.Max(0, rect.Height);
    }
}
