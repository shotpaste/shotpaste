using Drawing = System.Drawing;
using ShotPaste.Windows.Services;

namespace ShotPaste.Windows.Tests;

public sealed class OcrCancellationTests
{
    private static readonly TimeSpan TestDeadline = TimeSpan.FromSeconds(5);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NativeCancellationRequestsCancelButKeepsResourcesUntilActualCompletion(bool rejectsCancellation)
    {
        var operation = new PendingNativeOperation(rejectsCancellation);
        using var cancellation = new CancellationTokenSource();
        var resource = new RetainedResource();
        async Task UseNativeResourceAsync()
        {
            using (resource)
            {
                await OcrService.AwaitNativeCompletionAsync(operation, cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();
            }
        }

        var work = UseNativeResourceAsync();
        try
        {
            cancellation.Cancel();
            await operation.CancelRequested.Task.WaitAsync(TestDeadline);
            Assert.False(work.IsCompleted);
            Assert.False(resource.IsDisposed);
            operation.Complete();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work.WaitAsync(TestDeadline));
            Assert.True(resource.IsDisposed);
        }
        finally { operation.Complete(); }
    }

    [Fact]
    public async Task PreCanceledTranslationDoesNotStartRecognition()
    {
        using var input = new Drawing.Bitmap(10, 10);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var calls = 0;
        var service = new OcrService((_, _) =>
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult<IReadOnlyList<OcrWordRegion>>([]);
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            service.RecognizeTranslationLinesAsync(input, cancellation.Token));

        Assert.Equal(0, calls);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task CancellationReturnsPromptlyAndKeepsNativeSnapshotUntilCompletion(bool timeout, bool lateFailure)
    {
        var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var finishNative = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Drawing.Bitmap? retainedSnapshot = null;
        var calls = 0;
        using var cancellation = new CancellationTokenSource();
        var service = new OcrService(async (snapshot, token) =>
        {
            if (Interlocked.Increment(ref calls) == 1)
            {
                retainedSnapshot = snapshot;
                Assert.Equal(cancellation.Token, token);
                started.TrySetResult(true);
                // Model a native recognizer that ignores cancellation until its
                // current operation has finished accessing the bitmap.
                await finishNative.Task;
                Assert.Equal(Drawing.Color.Red.ToArgb(), snapshot.GetPixel(0, 0).ToArgb());
                if (lateFailure) throw new InvalidOperationException("Late native failure after cancellation.");
            }
            return [new OcrWordRegion("recognized", new(0, 0, 1, 1))];
        });
        var input = new Drawing.Bitmap(10, 10);
        input.SetPixel(0, 0, Drawing.Color.Red);
        using var retryInput = new Drawing.Bitmap(10, 10);
        Task<IReadOnlyList<OcrWordRegion>>? retry = null;
        try
        {
            var request = service.RecognizeTranslationLinesAsync(input, cancellation.Token);
            await started.Task.WaitAsync(TestDeadline);
            if (timeout) cancellation.CancelAfter(TimeSpan.FromMilliseconds(30));
            else cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request.WaitAsync(TestDeadline));

            input.Dispose();
            Assert.NotNull(retainedSnapshot);
            Assert.Equal(Drawing.Color.Red.ToArgb(), retainedSnapshot.GetPixel(0, 0).ToArgb());

            using var canceledRetry = new CancellationTokenSource();
            var waiting = service.RecognizeTranslationLinesAsync(retryInput, canceledRetry.Token);
            canceledRetry.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting.WaitAsync(TestDeadline));
            Assert.Equal(1, Volatile.Read(ref calls));

            retry = service.RecognizeTranslationLinesAsync(retryInput);
            Assert.False(retry.IsCompleted);
            Assert.Equal(1, Volatile.Read(ref calls));
            finishNative.TrySetResult(true);
            var lines = await retry.WaitAsync(TestDeadline);
            Assert.Single(lines);
            Assert.Equal(2, Volatile.Read(ref calls));
            Assert.Throws<ArgumentException>(() => retainedSnapshot.GetPixel(0, 0));
        }
        finally
        {
            input.Dispose();
            finishNative.TrySetResult(true);
            if (retry is not null) await retry.WaitAsync(TestDeadline);
        }
    }

    private sealed class RetainedResource : IDisposable
    {
        public bool IsDisposed { get; private set; }
        public void Dispose() => IsDisposed = true;
    }

    private sealed class PendingNativeOperation(bool rejectsCancellation) : global::Windows.Foundation.IAsyncOperation<int>
    {
        public TaskCompletionSource<bool> CancelRequested { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public uint Id => 1;
        public global::Windows.Foundation.AsyncStatus Status { get; private set; } = global::Windows.Foundation.AsyncStatus.Started;
        public Exception ErrorCode => null!;
        public global::Windows.Foundation.AsyncOperationCompletedHandler<int> Completed { get; set; } = null!;
        public int GetResults() => 42;
        public void Cancel()
        {
            CancelRequested.TrySetResult(true);
            if (rejectsCancellation) throw new NotSupportedException("Native operation refuses cancellation.");
        }
        public void Close() { }
        public void Complete()
        {
            if (Status != global::Windows.Foundation.AsyncStatus.Started) return;
            Status = global::Windows.Foundation.AsyncStatus.Completed;
            Completed?.Invoke(this, Status);
        }
    }
}
