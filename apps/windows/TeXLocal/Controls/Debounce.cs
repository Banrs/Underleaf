using Microsoft.UI.Dispatching;

namespace TeXLocal.Controls;

/// Work done once a burst of calls pauses: each Restart puts it off again. On the UI thread.
public sealed class Debounce
{
    readonly DispatcherQueueTimer timer = DispatcherQueue.GetForCurrentThread().CreateTimer();

    public Debounce(double milliseconds, Action work)
    {
        (timer.Interval, timer.IsRepeating) = (TimeSpan.FromMilliseconds(milliseconds), false);
        timer.Tick += (_, _) => work();
    }

    public bool Waiting => timer.IsRunning;

    public void Restart()
    {
        timer.Stop();
        timer.Start();
    }

    public void Stop() => timer.Stop();
}
