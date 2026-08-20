using System.Runtime.InteropServices;

namespace ShotPaste.Windows.Services;

internal sealed record RecoverableFileResult(string Path, bool Succeeded, bool WasMissing, string? Error = null);

internal interface IRecoverableFileOperations
{
    RecoverableFileResult MoveToRecycleBin(string path);
}

/// <summary>
/// Sends user-visible files to the Windows Recycle Bin without displaying the
/// shell's own progress/error UI. Callers change database state only on success.
/// </summary>
internal sealed class ShellRecoverableFileOperations : IRecoverableFileOperations
{
    private const uint FoDelete = 0x0003;
    private const ushort FofSilent = 0x0004;
    private const ushort FofNoConfirmation = 0x0010;
    private const ushort FofAllowUndo = 0x0040;
    private const ushort FofNoErrorUi = 0x0400;

    public RecoverableFileResult MoveToRecycleBin(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return new RecoverableFileResult(path ?? string.Empty, true, true);

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(path);
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return new RecoverableFileResult(path, false, false, exception.Message);
        }

        if (!File.Exists(fullPath) && !Directory.Exists(fullPath))
            return new RecoverableFileResult(fullPath, true, true);

        var operation = new ShellFileOperation
        {
            Function = FoDelete,
            From = fullPath + '\0' + '\0',
            Flags = FofSilent | FofNoConfirmation | FofAllowUndo | FofNoErrorUi
        };
        var code = SHFileOperation(ref operation);
        if (code == 0 && !operation.Aborted)
            return new RecoverableFileResult(fullPath, true, false);

        var detail = operation.Aborted
            ? "Windows 已取消移入回收站操作。"
            : $"Windows 回收站操作失败（0x{code:X4}）。";
        return new RecoverableFileResult(fullPath, false, false, detail);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShellFileOperation
    {
        public IntPtr Owner;
        public uint Function;
        [MarshalAs(UnmanagedType.LPWStr)] public string From;
        [MarshalAs(UnmanagedType.LPWStr)] public string? To;
        public ushort Flags;
        [MarshalAs(UnmanagedType.Bool)] public bool Aborted;
        public IntPtr NameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? ProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref ShellFileOperation operation);
}
