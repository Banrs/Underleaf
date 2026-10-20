using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using TeXLocal.Bridge;

namespace TeXLocal;

/// One running copy per library, as the Windows App SDK's single-instancing: a later launch hands its activation to the
/// first and exits, since a second core on the same projects would race the first's saves and builds.
public static partial class Program
{
    [STAThread]
    static void Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var first = AppInstance.FindOrRegisterForKey(Core.DefaultDataDir.ToLowerInvariant());
        if (first.IsCurrent)
        {
            Application.Start(_ =>
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                _ = new App();
            });
            return;
        }
        // Off this thread, with a wait that pumps COM, as Microsoft's sample; the first copy brings its window forward.
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        using var redirected = new ManualResetEvent(false);
        Task.Run(() =>
        {
            try { first.RedirectActivationToAsync(activation).AsTask().Wait(); }
            finally { redirected.Set(); }
        });
        _ = CoWaitForMultipleObjects(0, uint.MaxValue, 1, [redirected.SafeWaitHandle.DangerousGetHandle()], out _);
    }

    [LibraryImport("ole32.dll")]
    private static partial int CoWaitForMultipleObjects(uint flags, uint timeout, uint count, nint[] handles, out uint index);
}
