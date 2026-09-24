using System.Runtime.InteropServices;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace TeXLocal;

/// <summary>
/// Windows notifications, for a compile that finishes while TeXLocal is in
/// the background. A convenience: when Windows refuses them, nothing shows.
/// </summary>
internal static class Notifications
{
    private static bool attempted;
    private static bool registered;

    public static void Show(string text)
    {
        try
        {
            if (!attempted)
            {
                attempted = true;
                // Clicking one brings this window forward; without a handler
                // Windows would start a second copy of the app instead.
                AppNotificationManager.Default.NotificationInvoked += (_, _) =>
                    MainWindow.Instance.DispatcherQueue.TryEnqueue(() => MainWindow.Instance.Activate());
                AppNotificationManager.Default.Register();
                registered = true;
            }
            if (registered)
            {
                AppNotificationManager.Default.Show(new AppNotificationBuilder().AddText(text).BuildNotification());
            }
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
        }
    }

    public static void Unregister()
    {
        if (registered)
        {
            AppNotificationManager.Default.Unregister();
        }
    }
}
