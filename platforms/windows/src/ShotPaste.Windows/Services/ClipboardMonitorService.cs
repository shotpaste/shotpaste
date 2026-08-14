using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using ShotPaste.Windows.Interop;
using ShotPaste.Windows.Models;

namespace ShotPaste.Windows.Services;

public sealed class ClipboardMonitorService : IDisposable
{
    internal const string ExcludeFromMonitorFormat = "ExcludeClipboardContentFromMonitorProcessing";
    internal const string CanIncludeInHistoryFormat = "CanIncludeInClipboardHistory";
    private static readonly string[] TransientFormats =
    [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword"
    ];

    private readonly CaptureHistoryStore _history;
    private readonly SettingsStore _settings;
    private readonly HwndSource _source;
    private readonly SemaphoreSlim _captureGate = new(1, 1);
    private string? _lastFingerprint;

    public ClipboardMonitorService(CaptureHistoryStore history, SettingsStore settings)
    {
        _history = history;
        _settings = settings;
        _source = new HwndSource(new HwndSourceParameters("ShotPasteClipboard")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = new IntPtr(-3)
        });
        _source.AddHook(WindowProc);
        NativeMethods.AddClipboardFormatListener(_source.Handle);
    }

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != NativeMethods.WmClipboardUpdate) return IntPtr.Zero;
        if (!_settings.Current.ClipboardHistoryEnabled) return IntPtr.Zero;
        _ = CaptureClipboardAsync();
        return IntPtr.Zero;
    }

    private async Task CaptureClipboardAsync()
    {
        await _captureGate.WaitAsync();
        try
        {
            var data = System.Windows.Clipboard.GetDataObject();
            if (data is null || ShouldIgnoreClipboardData(data)) return;

            if (System.Windows.Clipboard.ContainsFileDropList())
            {
                var sourcePaths = System.Windows.Clipboard.GetFileDropList()
                    .Cast<string>()
                    .Where(path => File.Exists(path) || Directory.Exists(path))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                var added = await CaptureFileDropAsync(sourcePaths, _history, AppPaths.ClipboardFiles);
                _lastFingerprint = added.LastOrDefault()?.ContentHash ?? _lastFingerprint;
            }
            else if (System.Windows.Clipboard.ContainsImage())
            {
                var image = System.Windows.Clipboard.GetImage();
                if (image is null) return;
                var bytes = EncodePng(image);
                var fingerprint = ComputeHash("image", bytes);
                if (await IsDuplicateAsync(fingerprint)) return;

                var path = CaptureOutputNaming.NewPath(AppPaths.Captures, CaptureKind.ClipboardImage, ".png");
                await File.WriteAllBytesAsync(path, bytes);
                await _history.AddFileAsync(path, CaptureKind.ClipboardImage, contentHash: fingerprint);
                _lastFingerprint = fingerprint;
            }
            else if (System.Windows.Clipboard.ContainsText())
            {
                var text = System.Windows.Clipboard.GetText();
                if (string.IsNullOrWhiteSpace(text)) return;
                var fingerprint = ComputeTextHash(text);
                if (await IsDuplicateAsync(fingerprint)) return;
                await _history.AddTextAsync(text, fingerprint);
                _lastFingerprint = fingerprint;
            }
        }
        catch (ExternalException) { }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        finally { _captureGate.Release(); }
    }

    private async Task<bool> IsDuplicateAsync(string fingerprint) =>
        string.Equals(_lastFingerprint, fingerprint, StringComparison.Ordinal) ||
        await _history.ContainsContentHashAsync(fingerprint);

    internal static bool ShouldIgnoreClipboardData(System.Windows.IDataObject data) =>
        ShouldIgnoreClipboardData(data, AppBuildIdentity.Current);

    internal static bool ShouldIgnoreClipboardData(System.Windows.IDataObject data, AppBuildIdentity identity)
    {
        try
        {
            if (data.GetDataPresent(identity.InternalClipboardWriteMarkerFormat, false)) return true;
            if (data.GetDataPresent(ExcludeFromMonitorFormat, false)) return true;
            if (TransientFormats.Any(format => data.GetDataPresent(format, false))) return true;
            if (!data.GetDataPresent(CanIncludeInHistoryFormat, false)) return false;
            return IsZeroDword(data.GetData(CanIncludeInHistoryFormat, false));
        }
        catch (ExternalException)
        {
            // Privacy-biased behavior: never persist a clipboard item whose
            // privacy marker cannot be inspected reliably.
            return true;
        }
    }

    private static bool IsZeroDword(object? value)
    {
        return value switch
        {
            null => true,
            int number => number == 0,
            uint number => number == 0,
            byte[] bytes when bytes.Length >= sizeof(uint) => BitConverter.ToUInt32(bytes, 0) == 0,
            MemoryStream stream => ReadDword(stream) == 0,
            _ => true
        };
    }

    private static uint ReadDword(MemoryStream stream)
    {
        var position = stream.Position;
        try
        {
            stream.Position = 0;
            Span<byte> bytes = stackalloc byte[sizeof(uint)];
            return stream.Read(bytes) == bytes.Length ? BitConverter.ToUInt32(bytes) : 0;
        }
        finally { stream.Position = position; }
    }

    internal static byte[] EncodePng(BitmapSource image)
    {
        using var stream = new MemoryStream();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        encoder.Save(stream);
        return stream.ToArray();
    }

    internal static string ComputeHash(string kind, ReadOnlySpan<byte> data)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(kind));
        hash.AppendData([0]);
        hash.AppendData(data);
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    internal static string ComputeTextHash(string text)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes("text\0"));
        const int chunkSize = 4096;
        for (var offset = 0; offset < text.Length; offset += chunkSize)
        {
            var length = Math.Min(chunkSize, text.Length - offset);
            hash.AppendData(Encoding.UTF8.GetBytes(text.Substring(offset, length)));
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    internal static Task<string> ComputeFilesHashAsync(IReadOnlyList<string> paths) => Task.Run(() =>
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes("files\0"));
        foreach (var path in paths.OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase))
            AppendPathHash(hash, path, Path.GetFileName(path));
        return Convert.ToHexString(hash.GetHashAndReset());
    });

    private static void AppendPathHash(IncrementalHash hash, string path, string relativePath)
    {
        if (File.Exists(path))
        {
            hash.AppendData(Encoding.UTF8.GetBytes("F\0" + relativePath.Replace('\\', '/') + "\0"));
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[81920];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) hash.AppendData(buffer, 0, read);
            return;
        }
        if (!Directory.Exists(path)) return;

        hash.AppendData(Encoding.UTF8.GetBytes("D\0" + relativePath.Replace('\\', '/') + "\0"));
        foreach (var child in Directory.EnumerateFileSystemEntries(path).OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase))
        {
            if ((File.GetAttributes(child) & FileAttributes.ReparsePoint) != 0) continue;
            AppendPathHash(hash, child, Path.Combine(relativePath, Path.GetFileName(child)));
        }
    }

    internal static Task<IReadOnlyList<string>> PersistFilesAsync(IReadOnlyList<string> sourcePaths, string managedRoot) => Task.Run<IReadOnlyList<string>>(() =>
    {
        Directory.CreateDirectory(managedRoot);
        var bundle = Path.Combine(managedRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(bundle);
        var persisted = new List<string>();
        try
        {
            foreach (var source in sourcePaths)
            {
                var destination = UniqueDestination(bundle, Path.GetFileName(source));
                if (File.Exists(source)) File.Copy(source, destination, false);
                else if (Directory.Exists(source)) CopyDirectory(source, destination);
                else continue;
                persisted.Add(destination);
            }
            if (persisted.Count == 0) Directory.Delete(bundle, true);
            return persisted;
        }
        catch
        {
            if (Directory.Exists(bundle)) Directory.Delete(bundle, true);
            throw;
        }
    });

    internal static async Task<IReadOnlyList<CaptureHistoryItem>> CaptureFileDropAsync(
        IReadOnlyList<string> sourcePaths,
        CaptureHistoryStore history,
        string managedRoot)
    {
        var added = new List<CaptureHistoryItem>();
        foreach (var sourcePath in sourcePaths
                     .Where(path => File.Exists(path) || Directory.Exists(path))
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var fingerprint = await ComputeFilesHashAsync([sourcePath]);
                if (await history.ContainsContentHashAsync(fingerprint)) continue;
                var persisted = await PersistFilesAsync([sourcePath], managedRoot);
                var path = persisted.SingleOrDefault();
                if (string.IsNullOrWhiteSpace(path)) continue;
                added.Add(await history.AddClipboardPathAsync(path, fingerprint));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Continue with the other clipboard paths; one inaccessible item
                // must not collapse the entire multi-file history event.
            }
        }
        return added;
    }

    private static string UniqueDestination(string directory, string name)
    {
        var candidate = Path.Combine(directory, name);
        if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        var stem = Path.GetFileNameWithoutExtension(name);
        var extension = Path.GetExtension(name);
        for (var index = 2; ; index++)
        {
            candidate = Path.Combine(directory, $"{stem} ({index}){extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
        {
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) continue;
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), false);
        }
        foreach (var directory in Directory.EnumerateDirectories(source))
        {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) continue;
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
        }
    }

    public void Dispose()
    {
        NativeMethods.RemoveClipboardFormatListener(_source.Handle);
        _source.RemoveHook(WindowProc);
        _source.Dispose();
        _captureGate.Dispose();
    }
}
