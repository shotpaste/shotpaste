namespace LiteScreen.Windows.Services;

public static class AppPaths
{
    private static string _root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LiteScreen");

    public static string Root => _root;
    public static string Captures => Path.Combine(Root, "Captures");
    public static string ClipboardFiles => Path.Combine(Root, "ClipboardFiles");
    public static string Thumbnails => Path.Combine(Root, "Thumbnails");
    public static string Temp => Path.Combine(Root, "Temp");
    public static string HistoryDatabaseFile => Path.Combine(Root, "history.sqlite3");
    public static string SettingsFile => Path.Combine(Root, "settings.json");
    public static string RecordingRecoveryFile => Path.Combine(Root, "recording-recovery.json");

    internal static void ConfigureTestRoot(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("测试数据目录不能为空。", nameof(path));
        _root = Path.GetFullPath(path);
    }

    public static void EnsureCreated()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(Captures);
        Directory.CreateDirectory(ClipboardFiles);
        Directory.CreateDirectory(Thumbnails);
        Directory.CreateDirectory(Temp);
    }
}
