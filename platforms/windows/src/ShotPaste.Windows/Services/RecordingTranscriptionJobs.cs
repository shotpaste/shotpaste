using System.Collections.Concurrent;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ShotPaste.Windows.Services;

public sealed class RecordingTranscriptionPart
{
    public string SourcePath { get; set; } = "";
    public string Role { get; set; } = "audio";
    public string SourceHash { get; set; } = "";
    public string ObjectKey { get; set; } = "";
    public Guid RequestId { get; set; }
    public Guid? ProviderTaskId { get; set; }
    public bool UploadStarted { get; set; }
    public bool UploadCompleted { get; set; }
    public bool SubmitAttempted { get; set; }
    public bool CleanupPending { get; set; }
    public long StartMilliseconds { get; set; }
    public long DurationMilliseconds { get; set; }
    public int PollAttempts { get; set; }
    public DateTimeOffset? RetryAfter { get; set; }
    public string? TerminalFailure { get; set; }
    public bool NoSpeech { get; set; }
    public RecordingTranscript? Transcript { get; set; }
}
public sealed class RecordingTranscriptionJob
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public string RecordingPath { get; set; } = "";
    public string ProtectedConfiguration { get; set; } = "";
    public string State { get; set; } = "queued";
    public string? Error { get; set; }
    public string? AiText { get; set; }
    public string? AiPolishedText { get; set; }
    public RecordingAiStructured? AiArtifact { get; set; }
    public List<RecordingAiBatch> AiBatches { get; set; } = [];
    public bool AiRequested { get; set; }
    public bool CancelRequested { get; set; }
    public bool ResubmitRequested { get; set; }
    public List<RecordingTranscriptionPart> Parts { get; set; } = [];
    [System.Text.Json.Serialization.JsonIgnore] public bool HasTranscript => Parts.Any(part => part.Transcript is not null);
    [System.Text.Json.Serialization.JsonIgnore] public bool CleanupPending => Parts.Any(part => part.CleanupPending);
    [System.Text.Json.Serialization.JsonIgnore] public bool RequiresResubmission => Parts.Any(part => part.TerminalFailure is not null);
    [System.Text.Json.Serialization.JsonIgnore] public long UploadedBytes { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public long UploadTotalBytes { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public string DisplayName => Path.GetFileName(RecordingPath);
    [System.Text.Json.Serialization.JsonIgnore] public string RawText => string.Join("\n\n", Parts.Where(part => part.Transcript is not null).Select(part => Parts.Count > 1 ? $"[{part.Role}]\n{part.Transcript!.Text}" : part.Transcript!.Text));
    public string TimedText() => string.Join("\n", Parts.Where(part => part.Transcript is not null)
        .SelectMany(part => part.Transcript!.Utterances.Select(utterance => (part.Role, part.StartMilliseconds, Utterance: utterance)))
        .OrderBy(item => item.StartMilliseconds + item.Utterance.StartMilliseconds).ThenBy(item => item.Role, StringComparer.Ordinal)
        .Select(item => $"[{FormatTimestamp(item.StartMilliseconds + item.Utterance.StartMilliseconds)} – {FormatTimestamp(item.StartMilliseconds + item.Utterance.EndMilliseconds)}] [{item.Role}] {item.Utterance.Text}"));
    internal static string FormatTimestamp(long milliseconds) => $"{milliseconds / 3_600_000:00}:{milliseconds / 60_000 % 60:00}:{milliseconds / 1000 % 60:00}.{milliseconds % 1000:000}";
}

/// <summary>Durable receipts own cloud work, independently of any result window lifetime.</summary>
public sealed class RecordingTranscriptionJobs
{
    public static RecordingTranscriptionJobs Shared { get; } = new();
    private readonly ConcurrentDictionary<Guid, RecordingTranscriptionJob> _jobs = new();
    private readonly ConcurrentDictionary<Guid, CancellationTokenSource> _running = new();
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _jobOwnership = new();
    private readonly SemaphoreSlim _slots = new(2);
    private readonly object _persistence = new();
    private readonly VolcengineRecordingTranscriptionService _service = new();
    private bool _loaded;
    private static string DirectoryPath => Path.Combine(AppPaths.Root, "TranscriptionResults");
    public event EventHandler? Changed;
    public IReadOnlyList<RecordingTranscriptionJob> Jobs { get { Load(); return _jobs.Values.OrderByDescending(job => job.CreatedAt).ToArray(); } }
    private static string Protect(RecordingTranscriptionConfiguration config)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(config);
        try { return Convert.ToBase64String(ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser)); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private static RecordingTranscriptionConfiguration Configuration(RecordingTranscriptionJob job)
    {
        byte[]? bytes = null;
        try
        {
            bytes = ProtectedData.Unprotect(Convert.FromBase64String(job.ProtectedConfiguration), null, DataProtectionScope.CurrentUser);
            var config = JsonSerializer.Deserialize<RecordingTranscriptionConfiguration>(bytes) ?? throw new JsonException();
            if (!Guid.TryParse(config.InstallationId, out _) || !VolcengineTosSigner.ValidBucket(config.Bucket)) throw new JsonException();
            foreach (var part in job.Parts) VolcengineRecordingTranscriptionService.ValidateOwnedKey(config, part.ObjectKey);
            return config;
        }
        catch (Exception exception) when (exception is CryptographicException or FormatException or JsonException)
        { throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidConfiguration); }
        finally { if (bytes is not null) CryptographicOperations.ZeroMemory(bytes); }
    }
    private void Load()
    {
        lock (_persistence)
        {
            if (_loaded) return;
            string[] files;
            try { files = Directory.Exists(DirectoryPath) ? Directory.GetFiles(DirectoryPath, "*.json") : []; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { return; } // An unavailable results store must not prevent local capture startup.
            foreach (var file in files)
            {
                try
                {
                    if (new FileInfo(file).Length > 64 * 1024 * 1024) continue;
                    var job = JsonSerializer.Deserialize<RecordingTranscriptionJob>(File.ReadAllText(file));
                    if (job is null || !ValidReceipt(job) || Path.GetFileName(file) != job.Id.ToString("N") + ".json") continue;
                    _jobs.TryAdd(job.Id, job);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { /* Preserve malformed receipts for recovery. */ }
            }
            _loaded = true;
        }
    }
    internal static bool ValidReceipt(RecordingTranscriptionJob? job) => job is not null &&
        job.Id != Guid.Empty && !string.IsNullOrWhiteSpace(job.RecordingPath) &&
        !string.IsNullOrWhiteSpace(job.ProtectedConfiguration) && job.Parts is { Count: >= 1 and <= 4096 } &&
        job.AiBatches is not null && job.Parts.All(part => part is not null &&
            !string.IsNullOrWhiteSpace(part.SourcePath) && !string.IsNullOrWhiteSpace(part.ObjectKey) &&
            part.SourceHash is not null && part.Role is not null && part.StartMilliseconds >= 0 && part.DurationMilliseconds >= 0 &&
            part.PollAttempts >= 0 && (!part.SubmitAttempted || part.RequestId != Guid.Empty) &&
            (part.Transcript is null || part.Transcript.Utterances is not null && part.Transcript.Text is not null));
    private void Save(RecordingTranscriptionJob job)
    {
        lock (_persistence)
        {
            Directory.CreateDirectory(DirectoryPath);
            var path = Path.Combine(DirectoryPath, job.Id.ToString("N") + ".json");
            var temporary = path + ".tmp";
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, job); stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        NotifyChanged();
    }
    private void NotifyChanged()
    {
        if (Changed is not { } changed) return;
        foreach (EventHandler observer in changed.GetInvocationList())
            try { observer(this, EventArgs.Empty); } catch (Exception) { /* Observers cannot change durable task success. */ }
    }
    public RecordingTranscriptionJob Start(string sourcePath, RecordingTranscriptionConfiguration config, IReadOnlyList<(string Path, string Role)>? sources = null, bool deferRun = false)
    {
        lock (_persistence)
        {
        Load();
        var fullPath = Path.GetFullPath(sourcePath);
        // Capture recovery may replay the handoff after its job was saved but
        // before the capture receipt was acknowledged. Reuse the same consent.
        var existing = _jobs.Values.FirstOrDefault(job => string.Equals(job.RecordingPath, fullPath, StringComparison.OrdinalIgnoreCase));
        if (existing is not null) return existing;
        var job = new RecordingTranscriptionJob { RecordingPath = fullPath, ProtectedConfiguration = Protect(config), AiRequested = config.UseAI };
        foreach (var source in sources ?? [(sourcePath, "audio")])
        {
            if (!File.Exists(source.Path)) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
            job.Parts.Add(new() { SourcePath = Path.GetFullPath(source.Path), Role = source.Role,
                ObjectKey = config.Prefix + job.Id.ToString("N") + "/" + Guid.NewGuid().ToString("N") + ".m4a" });
        }
        if (job.Parts.Count is < 1 or > 2) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
        Save(job); _jobs[job.Id] = job;
        if (!deferRun) _ = RunAsync(job);
        return job;
        }
    }
    public void ResumePending()
    {
        Load();
        foreach (var job in _jobs.Values)
        {
            if (job.State is not ("completed" or "failed" or "cancelled")) _ = RunAsync(job);
            else if (job.CleanupPending) _ = CleanupOnlyAsync(job);
        }
    }
    public void Retry(RecordingTranscriptionJob job, bool allowResubmission = false)
    {
        if (_running.ContainsKey(job.Id)) return;
        if (job.RequiresResubmission && !allowResubmission) return;
        job.ResubmitRequested = job.RequiresResubmission && allowResubmission;
        job.CancelRequested = false; job.Error = null; job.State = "queued"; Save(job); _ = RunAsync(job);
    }
    public void Cancel(RecordingTranscriptionJob job)
    {
        job.CancelRequested = true; Save(job);
        if (_running.TryGetValue(job.Id, out var cancellation)) cancellation.Cancel();
        else { job.State = "cancelled"; Save(job); _ = CleanupOnlyAsync(job); }
    }
    public void Shutdown()
    {
        // Interrupted tasks retain their explicit capture consent and original request IDs for next launch.
        foreach (var cancellation in _running.Values) cancellation.Cancel();
    }
    private void State(RecordingTranscriptionJob job, string state) { job.State = state; Save(job); }
    private async Task RunAsync(RecordingTranscriptionJob job)
    {
        using var cancellation = new CancellationTokenSource();
        if (!_running.TryAdd(job.Id, cancellation)) return;
        var acquired = false;
        var ownership = _jobOwnership.GetOrAdd(job.Id, _ => new SemaphoreSlim(1));
        var ownsJob = false;
        RecordingTranscriptionPart? currentPart = null;
        try
        {
            await _slots.WaitAsync(cancellation.Token); acquired = true;
            await ownership.WaitAsync(cancellation.Token); ownsJob = true;
            if (job.CancelRequested) throw new OperationCanceledException(cancellation.Token);
            var config = Configuration(job);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
            timeout.CancelAfter(TimeSpan.FromMinutes(45));
            var token = timeout.Token;
            if (job.ResubmitRequested) await ResetConfirmedPartsAsync(job, config, token);
            for (var partIndex = 0; partIndex < job.Parts.Count; partIndex++)
            {
                timeout.CancelAfter(TimeSpan.FromMinutes(45));
                var part = job.Parts[partIndex];
                currentPart = part;
                if (part.Transcript is not null || part.NoSpeech) continue;
                if (part.TerminalFailure is not null)
                    throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Service, part.TerminalFailure);
                if (!part.SubmitAttempted)
                {
                    State(job, "preparing");
                    // Retry never transcribes a replacement file under the old recording's identity.
                    var hash = await SourceChecksumAsync(part.SourcePath, token);
                    if (part.SourceHash.Length != 0 && part.SourceHash != hash)
                        throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
                    part.SourceHash = hash;
                    if (part.DurationMilliseconds == 0)
                        part.DurationMilliseconds = await VolcengineRecordingTranscriptionService.DurationMillisecondsAsync(part.SourcePath, token) - part.StartMilliseconds;
                    Save(job);
                    var temporary = Path.Combine(DirectoryPath, job.Id.ToString("N") + "-prepared.m4a");
                    var prepared = await VolcengineRecordingTranscriptionService.PrepareAudioPartAsync(part.SourcePath, temporary,
                        part.StartMilliseconds, part.DurationMilliseconds, token);
                    if (await SourceChecksumAsync(part.SourcePath, token) != part.SourceHash)
                        throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
                    SplitPreparedPart(job, partIndex, prepared.DurationMilliseconds, config);
                    Save(job); // Ranges are durable before the first upload or paid request.
                    await _service.CheckStorageAsync(config, token);
                    if (!part.UploadCompleted)
                    {
                        // An interrupted upload may have reached TOS. Remove our own key before a fresh PUT.
                        if (part.UploadStarted) await _service.DeleteAsync(config, part.ObjectKey, token);
                        job.UploadedBytes = 0; job.UploadTotalBytes = prepared.Data.LongLength;
                        part.UploadStarted = true; part.CleanupPending = true; State(job, "uploading");
                        var lastProgress = System.Diagnostics.Stopwatch.GetTimestamp();
                        await _service.UploadAsync(prepared.Data, config, part.ObjectKey, token, (sent, total) =>
                        {
                            job.UploadedBytes = sent; job.UploadTotalBytes = total;
                            var now = System.Diagnostics.Stopwatch.GetTimestamp();
                            if (sent == total || now - lastProgress >= System.Diagnostics.Stopwatch.Frequency / 10)
                            { lastProgress = now; NotifyChanged(); }
                        });
                        part.UploadCompleted = true; Save(job);
                    }
                    PersistSubmissionIntent(part, () => State(job, "submitting"));
                    var signer = new VolcengineTosSigner(config.AccessKey, config.SecretKey);
                    try
                    {
                        var (body, response) = await VolcengineRecordingTranscriptionService.SendAsync(
                            VolcengineTranscriptionProtocol.Request(config.ApiKey, part.RequestId, signer.SignedGet(config.Bucket, part.ObjectKey), config.SourceLanguage), token);
                        using (response)
                        {
                            if (VolcengineTranscriptionProtocol.Status(response) != "20000000") throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidResponse);
                            using var receipt = JsonDocument.Parse(body);
                            if (receipt.RootElement.TryGetProperty("task_id", out var id) && id.ValueKind != JsonValueKind.Null)
                                part.ProviderTaskId = id.GetGuid();
                        }
                        Save(job);
                    }
                    catch (HttpRequestException) { /* Uncertain submission: only query its original request ID. */ }
                    catch (RecordingTranscriptionException error) when (IsTransient(error) ||
                        error.Failure is RecordingTranscriptionFailure.InvalidResponse or RecordingTranscriptionFailure.Connection or RecordingTranscriptionFailure.ResponseTooLarge)
                    { /* A malformed or unavailable acknowledgement cannot authorize another submit. */ }
                    catch (Exception error) when (error is JsonException or FormatException or InvalidOperationException)
                    { /* Accepted but malformed receipt: query the persisted request ID. */ }
                }
                State(job, "recognizing");
                var transientFailures = 0;
                while (part.Transcript is null)
                {
                    token.ThrowIfCancellationRequested();
                    if (part.PollAttempts >= 120)
                    {
                        part.TerminalFailure = "QueryLimit";
                        throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Timeout);
                    }
                    var delay = part.RetryAfter is { } due ? due - DateTimeOffset.UtcNow : TimeSpan.Zero;
                    if (delay > TimeSpan.FromMinutes(1)) return; // Maintenance resumes at the persisted Retry-After.
                    if (delay > TimeSpan.Zero) await Task.Delay(delay, token);
                    try
                    {
                        part.PollAttempts++; Save(job);
                        var (body, response) = await VolcengineRecordingTranscriptionService.SendAsync(
                            VolcengineTranscriptionProtocol.Request(config.ApiKey, part.ProviderTaskId ?? part.RequestId), token);
                        using (response)
                        {
                            part.RetryAfter = response.Headers.RetryAfter?.Date ?? (response.Headers.RetryAfter?.Delta is { } delta ? DateTimeOffset.UtcNow + delta : null);
                            Save(job);
                            if (VolcengineTranscriptionProtocol.Status(response) == "20000000")
                            {
                                PersistTranscript(part, VolcengineTranscriptionProtocol.ParseTranscript(body), () => State(job, "saving"));
                                break;
                            }
                        }
                        transientFailures = 0;
                    }
                    catch (RecordingTranscriptionException error) when (error.ServiceCode == "20000003")
                    {
                        part.NoSpeech = true;
                        try { Save(job); } catch { part.NoSpeech = false; throw; }
                        break;
                    }
                    catch (Exception error) when (IsTransient(error))
                    {
                        if (++transientFailures >= 3) throw;
                    }
                    await Task.Delay(TimeSpan.FromSeconds(Math.Min(5 + part.PollAttempts, 30)), token);
                }
                await CleanupAsync(job, config, token);
            }
            currentPart = null;
            if (!job.HasTranscript) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.EmptyTranscript);
            if (job.AiRequested && string.IsNullOrEmpty(job.AiText))
            {
                State(job, "organizing");
                await RecordingTranscriptAiProcessor.ProcessJobAsync(job, config, token, () => Save(job));
                Save(job);
            }
            State(job, "completed");
        }
        catch (OperationCanceledException)
        {
            job.State = job.CancelRequested ? "cancelled" : cancellation.IsCancellationRequested ? "interrupted" : "failed";
            job.Error = job.State == "failed" ? "Timeout" : null;
            TrySave(job);
        }
        catch (Exception exception)
        {
            if (currentPart is not null && exception is RecordingTranscriptionException failure &&
                ((failure.Failure == RecordingTranscriptionFailure.Service && !IsTransient(failure)) ||
                 failure.Failure is RecordingTranscriptionFailure.InvalidResponse or RecordingTranscriptionFailure.EmptyTranscript))
                currentPart.TerminalFailure = failure.ServiceCode ?? failure.Failure.ToString();
            job.State = "failed";
            job.Error = exception is RecordingTranscriptionException recorded ? recorded.Failure + (recorded.ServiceCode is null ? "" : " (" + recorded.ServiceCode + ")") : "Connection";
            TrySave(job);
        }
        finally
        {
            if (ownsJob) await CleanupOnlyAsync(job, ownsJob: true);
            _running.TryRemove(job.Id, out _);
            if (ownsJob) ownership.Release();
            if (acquired) _slots.Release();
            NotifyChanged();
        }
    }
    internal static void PersistSubmissionIntent(RecordingTranscriptionPart part, Action save)
    {
        var previousId = part.RequestId;
        part.RequestId = Guid.NewGuid(); part.SubmitAttempted = true;
        try { save(); }
        catch { part.RequestId = previousId; part.SubmitAttempted = false; throw; }
    }
    internal static void PersistTranscript(RecordingTranscriptionPart part, RecordingTranscript transcript, Action save)
    {
        var previous = part.Transcript;
        part.Transcript = transcript;
        try { save(); }
        catch { part.Transcript = previous; throw; }
    }
    internal static void SplitPreparedPart(RecordingTranscriptionJob job, int index, long preparedMilliseconds,
        RecordingTranscriptionConfiguration config)
    {
        var part = job.Parts[index];
        if (preparedMilliseconds <= 0 || preparedMilliseconds > part.DurationMilliseconds ||
            preparedMilliseconds > VolcengineRecordingTranscriptionService.MaximumPartMilliseconds)
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
        if (preparedMilliseconds == part.DurationMilliseconds) return;
        if (job.Parts.Count >= 4096) throw new RecordingTranscriptionException(RecordingTranscriptionFailure.AudioTooLong);
        var remainder = new RecordingTranscriptionPart
        {
            SourcePath = part.SourcePath, SourceHash = part.SourceHash, Role = part.Role,
            StartMilliseconds = checked(part.StartMilliseconds + preparedMilliseconds),
            DurationMilliseconds = part.DurationMilliseconds - preparedMilliseconds,
            ObjectKey = config.Prefix + job.Id.ToString("N") + "/" + Guid.NewGuid().ToString("N") + ".m4a"
        };
        part.DurationMilliseconds = preparedMilliseconds;
        var next = job.Parts.ToList();
        next.Insert(index + 1, remainder);
        job.Parts = next; // Publish one stable list; result windows can enumerate safely.
    }
    private static async Task<string> SourceChecksumAsync(string sourcePath, CancellationToken token)
    {
        if ((File.GetAttributes(sourcePath) & FileAttributes.ReparsePoint) != 0)
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.InvalidRecording);
        await using var source = File.OpenRead(sourcePath);
        return Convert.ToHexString(await SHA256.HashDataAsync(source, token));
    }
    private static bool IsTransient(Exception error) => error is HttpRequestException ||
        error is RecordingTranscriptionException { Failure: RecordingTranscriptionFailure.Service } failure &&
        int.TryParse(failure.ServiceCode, out var code) && (code == 429 || code is >= 500 and <= 599);
    private async Task ResetConfirmedPartsAsync(RecordingTranscriptionJob job, RecordingTranscriptionConfiguration config, CancellationToken token)
    {
        await CleanupAsync(job, config, token);
        if (job.Parts.Any(part => part.TerminalFailure is not null && part.CleanupPending))
            throw new RecordingTranscriptionException(RecordingTranscriptionFailure.Connection);
        var archives = Path.Combine(DirectoryPath, "ArchivedRequests");
        Directory.CreateDirectory(archives);
        var path = Path.Combine(archives, job.Id.ToString("N") + "-" + Guid.NewGuid().ToString("N") + ".json");
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { JsonSerializer.Serialize(stream, job); stream.Flush(flushToDisk: true); }
        foreach (var part in job.Parts.Where(part => part.TerminalFailure is not null))
        {
            part.TerminalFailure = null; part.SubmitAttempted = false; part.UploadStarted = false; part.UploadCompleted = false;
            part.RequestId = Guid.Empty; part.ProviderTaskId = null; part.PollAttempts = 0; part.RetryAfter = null;
            part.ObjectKey = config.Prefix + job.Id.ToString("N") + "/" + Guid.NewGuid().ToString("N") + ".m4a";
        }
        job.ResubmitRequested = false;
        Save(job);
    }
    private void TrySave(RecordingTranscriptionJob job) { try { Save(job); } catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { } }
    private async Task CleanupAsync(RecordingTranscriptionJob job, RecordingTranscriptionConfiguration config, CancellationToken token)
    {
        foreach (var part in job.Parts.Where(part => part.CleanupPending &&
            (part.Transcript is not null || part.NoSpeech || part.TerminalFailure is not null || job.CancelRequested)))
        {
            try
            {
                await _service.DeleteAsync(config, part.ObjectKey, token);
                part.CleanupPending = false;
                if (part.Transcript is null) { part.UploadCompleted = false; part.UploadStarted = false; }
                Save(job);
            }
            catch (Exception) when (!token.IsCancellationRequested) { /* Keep receipt for independent cleanup retry. */ }
        }
    }
    private async Task CleanupOnlyAsync(RecordingTranscriptionJob job, bool ownsJob = false)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        var ownership = _jobOwnership.GetOrAdd(job.Id, _ => new SemaphoreSlim(1));
        var acquired = false;
        try
        {
            if (!ownsJob) { await ownership.WaitAsync(timeout.Token); acquired = true; }
            await CleanupAsync(job, Configuration(job), timeout.Token);
        }
        catch (Exception) { /* Credentials or connectivity can be restored; never clear an unverified deletion. */ }
        finally { if (acquired) ownership.Release(); }
    }
}
