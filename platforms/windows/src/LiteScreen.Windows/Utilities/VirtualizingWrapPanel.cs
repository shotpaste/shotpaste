using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Point = System.Windows.Point;
using Rect = System.Windows.Rect;
using Size = System.Windows.Size;

namespace LiteScreen.Windows.Controls;

/// <summary>
/// A fixed-cell wrapping panel that virtualizes complete rows. WPF's built-in
/// WrapPanel realizes every item, which makes a large capture history expensive.
/// </summary>
public sealed class VirtualizingWrapPanel : VirtualizingPanel, IScrollInfo
{
    public static readonly DependencyProperty ItemWidthProperty = DependencyProperty.Register(
        nameof(ItemWidth), typeof(double), typeof(VirtualizingWrapPanel),
        new FrameworkPropertyMetadata(286d, FrameworkPropertyMetadataOptions.AffectsMeasure));

    public static readonly DependencyProperty ItemHeightProperty = DependencyProperty.Register(
        nameof(ItemHeight), typeof(double), typeof(VirtualizingWrapPanel),
        new FrameworkPropertyMetadata(226d, FrameworkPropertyMetadataOptions.AffectsMeasure));

    private Size _extent;
    private Size _viewport;
    private Point _offset;
    private int _columns = 1;

    public double ItemWidth
    {
        get => (double)GetValue(ItemWidthProperty);
        set => SetValue(ItemWidthProperty, value);
    }

    public double ItemHeight
    {
        get => (double)GetValue(ItemHeightProperty);
        set => SetValue(ItemHeightProperty, value);
    }

    internal readonly record struct WrapLayout(
        int Columns,
        int Rows,
        int FirstIndex,
        int LastIndex,
        double ExtentHeight);

    internal static WrapLayout CalculateLayout(
        int itemCount,
        double availableWidth,
        double itemWidth,
        double itemHeight,
        double verticalOffset,
        double viewportHeight)
    {
        itemWidth = Math.Max(1, itemWidth);
        itemHeight = Math.Max(1, itemHeight);
        availableWidth = Math.Max(itemWidth, availableWidth);
        viewportHeight = Math.Max(0, viewportHeight);
        var columns = Math.Max(1, (int)Math.Floor(availableWidth / itemWidth));
        var rows = itemCount == 0 ? 0 : (int)Math.Ceiling(itemCount / (double)columns);
        var firstRow = Math.Max(0, (int)Math.Floor(Math.Max(0, verticalOffset) / itemHeight));
        var visibleRows = Math.Max(1, (int)Math.Ceiling(viewportHeight / itemHeight) + 1);
        var firstIndex = Math.Min(itemCount, firstRow * columns);
        var lastIndex = itemCount == 0
            ? -1
            : Math.Min(itemCount - 1, ((firstRow + visibleRows) * columns) - 1);
        return new WrapLayout(columns, rows, firstIndex, lastIndex, rows * itemHeight);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        var owner = ItemsControl.GetItemsOwner(this);
        var itemCount = owner?.Items.Count ?? 0;
        var width = NormalizeViewportLength(availableSize.Width, ActualWidth, ItemWidth);
        var height = NormalizeViewportLength(availableSize.Height, ActualHeight, ItemHeight * 2);
        var layout = CalculateLayout(itemCount, width, ItemWidth, ItemHeight, _offset.Y, height);
        _columns = layout.Columns;
        UpdateScrollInfo(new Size(width, layout.ExtentHeight), new Size(width, height));

        var generator = ItemContainerGenerator ?? owner?.ItemContainerGenerator;
        if (generator is null)
        {
            // A previously collapsed virtualizing panel can be measured once
            // before WPF reconnects its item generator. Retry after the
            // visibility/layout transition instead of crashing the window.
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded,
                new Action(InvalidateMeasure));
            return new Size(width, height);
        }
        CleanupItems(generator, layout.FirstIndex, layout.LastIndex);
        if (layout.LastIndex < layout.FirstIndex) return new Size(width, height);
        var startPosition = generator.GeneratorPositionFromIndex(layout.FirstIndex);
        var childIndex = startPosition.Offset == 0 ? startPosition.Index : startPosition.Index + 1;
        using (generator.StartAt(startPosition, GeneratorDirection.Forward, true))
        {
            for (var itemIndex = layout.FirstIndex; itemIndex <= layout.LastIndex; itemIndex++, childIndex++)
            {
                var child = (UIElement)generator.GenerateNext(out var newlyRealized);
                if (newlyRealized)
                {
                    if (childIndex >= InternalChildren.Count) AddInternalChild(child);
                    else InsertInternalChild(childIndex, child);
                    generator.PrepareItemContainer(child);
                }
                child.Measure(new Size(ItemWidth, ItemHeight));
            }
        }

        return new Size(width, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var generator = ItemContainerGenerator ?? ItemsControl.GetItemsOwner(this)?.ItemContainerGenerator;
        if (generator is null) return finalSize;
        var contentWidth = _columns * ItemWidth;
        var leading = Math.Max(0, (finalSize.Width - contentWidth) / 2);
        for (var childIndex = 0; childIndex < InternalChildren.Count; childIndex++)
        {
            var itemIndex = generator.IndexFromGeneratorPosition(new GeneratorPosition(childIndex, 0));
            if (itemIndex < 0) continue;
            var row = itemIndex / _columns;
            var column = itemIndex % _columns;
            InternalChildren[childIndex].Arrange(new Rect(
                leading + column * ItemWidth - _offset.X,
                row * ItemHeight - _offset.Y,
                ItemWidth,
                ItemHeight));
        }
        return finalSize;
    }

    private void CleanupItems(IItemContainerGenerator generator, int firstIndex, int lastIndex)
    {
        if (generator is not IRecyclingItemContainerGenerator recyclingGenerator) return;
        for (var childIndex = InternalChildren.Count - 1; childIndex >= 0; childIndex--)
        {
            var position = new GeneratorPosition(childIndex, 0);
            var itemIndex = generator.IndexFromGeneratorPosition(position);
            if (itemIndex >= firstIndex && itemIndex <= lastIndex) continue;
            recyclingGenerator.Recycle(position, 1);
            RemoveInternalChildRange(childIndex, 1);
        }
    }

    private static double NormalizeViewportLength(double measured, double actual, double fallback)
    {
        if (!double.IsInfinity(measured) && !double.IsNaN(measured) && measured > 0) return measured;
        if (!double.IsNaN(actual) && actual > 0) return actual;
        return fallback;
    }

    private void UpdateScrollInfo(Size extent, Size viewport)
    {
        var changed = !AreClose(_extent, extent) || !AreClose(_viewport, viewport);
        _extent = extent;
        _viewport = viewport;
        _offset = new Point(
            CoerceOffset(_offset.X, _extent.Width, _viewport.Width),
            CoerceOffset(_offset.Y, _extent.Height, _viewport.Height));
        if (changed) ScrollOwner?.InvalidateScrollInfo();
    }

    private static bool AreClose(Size left, Size right) =>
        Math.Abs(left.Width - right.Width) < 0.5 && Math.Abs(left.Height - right.Height) < 0.5;

    private static double CoerceOffset(double value, double extent, double viewport) =>
        Math.Max(0, Math.Min(value, Math.Max(0, extent - viewport)));

    protected override void OnItemsChanged(object sender, ItemsChangedEventArgs args)
    {
        base.OnItemsChanged(sender, args);
        InvalidateMeasure();
    }

    protected override void BringIndexIntoView(int index)
    {
        if (index < 0) return;
        SetVerticalOffset(index / Math.Max(1, _columns) * ItemHeight);
    }

    public bool CanHorizontallyScroll { get; set; }
    public bool CanVerticallyScroll { get; set; } = true;
    public double ExtentWidth => _extent.Width;
    public double ExtentHeight => _extent.Height;
    public double ViewportWidth => _viewport.Width;
    public double ViewportHeight => _viewport.Height;
    public double HorizontalOffset => _offset.X;
    public double VerticalOffset => _offset.Y;
    public ScrollViewer? ScrollOwner { get; set; }

    public void LineUp() => SetVerticalOffset(VerticalOffset - ItemHeight / 3);
    public void LineDown() => SetVerticalOffset(VerticalOffset + ItemHeight / 3);
    public void PageUp() => SetVerticalOffset(VerticalOffset - ViewportHeight);
    public void PageDown() => SetVerticalOffset(VerticalOffset + ViewportHeight);
    public void MouseWheelUp() => SetVerticalOffset(VerticalOffset - ItemHeight);
    public void MouseWheelDown() => SetVerticalOffset(VerticalOffset + ItemHeight);
    public void LineLeft() => SetHorizontalOffset(HorizontalOffset - 16);
    public void LineRight() => SetHorizontalOffset(HorizontalOffset + 16);
    public void PageLeft() => SetHorizontalOffset(HorizontalOffset - ViewportWidth);
    public void PageRight() => SetHorizontalOffset(HorizontalOffset + ViewportWidth);
    public void MouseWheelLeft() => SetHorizontalOffset(HorizontalOffset - 48);
    public void MouseWheelRight() => SetHorizontalOffset(HorizontalOffset + 48);

    public void SetHorizontalOffset(double offset)
    {
        if (!CanHorizontallyScroll) offset = 0;
        offset = CoerceOffset(offset, ExtentWidth, ViewportWidth);
        if (Math.Abs(offset - _offset.X) < 0.1) return;
        _offset.X = offset;
        ScrollOwner?.InvalidateScrollInfo();
        InvalidateArrange();
    }

    public void SetVerticalOffset(double offset)
    {
        if (!CanVerticallyScroll) offset = 0;
        offset = CoerceOffset(offset, ExtentHeight, ViewportHeight);
        if (Math.Abs(offset - _offset.Y) < 0.1) return;
        _offset.Y = offset;
        ScrollOwner?.InvalidateScrollInfo();
        InvalidateMeasure();
    }

    public Rect MakeVisible(Visual visual, Rect rectangle)
    {
        var container = visual as UIElement;
        while (container is not null && !InternalChildren.Contains(container))
            container = VisualTreeHelper.GetParent(container) as UIElement;
        if (container is null) return Rect.Empty;
        var index = ItemsControl.GetItemsOwner(this)?.ItemContainerGenerator.IndexFromContainer(container) ?? -1;
        if (index < 0) return Rect.Empty;
        var top = index / Math.Max(1, _columns) * ItemHeight;
        var bottom = top + ItemHeight;
        if (top < VerticalOffset) SetVerticalOffset(top);
        else if (bottom > VerticalOffset + ViewportHeight) SetVerticalOffset(bottom - ViewportHeight);
        return new Rect(0, top, ItemWidth, ItemHeight);
    }
}
