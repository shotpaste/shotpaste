namespace ShotPaste.Windows.Services;

public sealed class QuickAccessCountdown
{
    private readonly TimeSpan _duration;
    private TimeSpan _remaining;
    private DateTimeOffset _deadline;

    public QuickAccessCountdown(TimeSpan duration)
    {
        _duration = duration > TimeSpan.Zero ? duration : TimeSpan.Zero;
        _remaining = _duration;
    }

    public bool IsRunning { get; private set; }

    public TimeSpan Remaining(DateTimeOffset now)
    {
        var remaining = IsRunning ? _deadline - now : _remaining;
        return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
    }

    public TimeSpan Reset(DateTimeOffset now)
    {
        _remaining = _duration;
        return Resume(now);
    }

    public void Pause(DateTimeOffset now)
    {
        _remaining = Remaining(now);
        IsRunning = false;
    }

    public TimeSpan Resume(DateTimeOffset now)
    {
        if (_remaining <= TimeSpan.Zero)
        {
            IsRunning = false;
            return TimeSpan.Zero;
        }

        _deadline = now + _remaining;
        IsRunning = true;
        return _remaining;
    }
}
