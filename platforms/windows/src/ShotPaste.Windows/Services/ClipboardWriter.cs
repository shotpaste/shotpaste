using System.Collections.Specialized;
using System.Windows.Media.Imaging;
using WpfClipboard = System.Windows.Clipboard;
using WpfDataObject = System.Windows.DataObject;

namespace ShotPaste.Windows.Services;

internal static class ClipboardWriter
{
    internal static void SetText(string text) =>
        WpfClipboard.SetDataObject(CreateTextDataObject(text), copy: true);

    internal static void SetImage(BitmapSource image)
    {
        var data = CreateMarkedDataObject(AppBuildIdentity.Current);
        data.SetImage(image);
        WpfClipboard.SetDataObject(data, copy: true);
    }

    internal static void SetFileDropList(StringCollection paths)
    {
        var data = CreateMarkedDataObject(AppBuildIdentity.Current);
        data.SetFileDropList(paths);
        WpfClipboard.SetDataObject(data, copy: true);
    }

    internal static WpfDataObject CreateTextDataObject(string text, AppBuildIdentity? identity = null)
    {
        var data = CreateMarkedDataObject(identity ?? AppBuildIdentity.Current);
        data.SetText(text);
        return data;
    }

    private static WpfDataObject CreateMarkedDataObject(AppBuildIdentity identity)
    {
        var data = new WpfDataObject();
        data.SetData(identity.InternalClipboardWriteMarkerFormat, BitConverter.GetBytes(1u));
        return data;
    }
}
