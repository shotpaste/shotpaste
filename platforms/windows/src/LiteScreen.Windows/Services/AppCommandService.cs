using System.Text.Json;
using System.Collections.Concurrent;

namespace LiteScreen.Windows.Services;

public sealed class AppCommandService : IDisposable
{
    private const int MaximumPayloadBytes = 32_768;
    private readonly string _queueDirectory;
    private readonly ConcurrentDictionary<string, byte> _processing = new(StringComparer.OrdinalIgnoreCase);
    private FileSystemWatcher? _watcher;
    private Action<IReadOnlyList<string>>? _handler;
    private int _disposed;

    public AppCommandService(string? instanceScope = null)
    {
        _queueDirectory = ResolveQueueDirectory(instanceScope);
    }

    public void Start(Action<IReadOnlyList<string>> handler)
    {
        if (_watcher is not null) return;
        _handler = handler;
        Directory.CreateDirectory(_queueDirectory);
        foreach (var temporary in Directory.EnumerateFiles(_queueDirectory, ".litescreen-command-*.tmp"))
        {
            try
            {
                if (File.GetLastWriteTimeUtc(temporary) < DateTime.UtcNow.AddMinutes(-1)) TryDelete(temporary);
            }
            catch (IOException) { }
        }
        _watcher = new FileSystemWatcher(_queueDirectory, ".litescreen-command-*.json")
        {
            NotifyFilter = NotifyFilters.FileName,
            IncludeSubdirectories = false,
            EnableRaisingEvents = true
        };
        _watcher.Created += OnCommandFile;
        _watcher.Renamed += OnCommandFile;
        foreach (var path in Directory.EnumerateFiles(_queueDirectory, ".litescreen-command-*.json"))
            QueueCommandFile(path);
    }

    public static async Task<bool> SendAsync(
        IReadOnlyList<string> arguments,
        int timeoutMilliseconds = 1500,
        string? instanceScope = null)
    {
        if (arguments.Count is 0 or > 32 || arguments.Sum(argument => argument.Length) > MaximumPayloadBytes)
            return false;
        var queueDirectory = ResolveQueueDirectory(instanceScope);
        var token = Guid.NewGuid().ToString("N");
        var temporary = Path.Combine(queueDirectory, $".litescreen-command-{token}.tmp");
        var destination = Path.ChangeExtension(temporary, ".json");
        try
        {
            Directory.CreateDirectory(queueDirectory);
            var payload = JsonSerializer.SerializeToUtf8Bytes(arguments);
            if (payload.Length > MaximumPayloadBytes) return false;
            using var timeout = new CancellationTokenSource(Math.Clamp(timeoutMilliseconds, 100, 5000));
            await File.WriteAllBytesAsync(temporary, payload, timeout.Token).ConfigureAwait(false);
            File.Move(temporary, destination);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            TryDelete(temporary);
            return false;
        }
    }

    private void OnCommandFile(object sender, FileSystemEventArgs e) => QueueCommandFile(e.FullPath);

    private void QueueCommandFile(string path)
    {
        if (!_processing.TryAdd(path, 0)) return;
        _ = ProcessCommandFileGuardedAsync(path);
    }

    private async Task ProcessCommandFileGuardedAsync(string path)
    {
        try { await ProcessCommandFileAsync(path); }
        finally { _processing.TryRemove(path, out _); }
    }

    private async Task ProcessCommandFileAsync(string path)
    {
        for (var attempt = 0; attempt < 10 && Volatile.Read(ref _disposed) == 0; attempt++)
        {
            try
            {
                var payload = await File.ReadAllBytesAsync(path);
                if (payload.Length is <= 0 or > MaximumPayloadBytes)
                {
                    TryDelete(path);
                    return;
                }
                var arguments = JsonSerializer.Deserialize<string[]>(payload) ?? [];
                if (arguments.Length is > 0 and <= 32 && arguments.Sum(argument => argument.Length) <= MaximumPayloadBytes)
                    _handler?.Invoke(arguments);
                TryDelete(path);
                return;
            }
            catch (FileNotFoundException) { return; }
            catch (JsonException) { TryDelete(path); return; }
            catch (IOException) when (attempt < 9) { await Task.Delay(40); }
            catch (IOException) { break; }
        }
        TryDelete(path);
    }

    private static string ResolveQueueDirectory(string? instanceScope) =>
        Path.GetFullPath(string.IsNullOrWhiteSpace(instanceScope) ? AppPaths.Root : instanceScope);

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        Interlocked.Exchange(ref _disposed, 1);
        if (_watcher is null) return;
        _watcher.EnableRaisingEvents = false;
        _watcher.Created -= OnCommandFile;
        _watcher.Renamed -= OnCommandFile;
        _watcher.Dispose();
        _watcher = null;
    }
}
