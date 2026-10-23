using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TeXLocal.Bridge;

namespace TeXLocal.Controls;

/// Home's and Settings' bar while TeX isn't found: Install TinyTeX, into the user's AppData with no UAC, and TeX Live's
/// link for the full distribution.
public sealed partial class TexBar : InfoBar
{
    /// The install under way, which a bar shown meanwhile follows, as pages come and go during it.
    static Task<TexStatus>? installing;

    public TexBar()
    {
        InitializeComponent();
        // The bar that started it alerts.
        Loaded += (_, _) =>
        {
            if (installing is { } task) App.Run(null, () => Follow(task));
        };
    }

    /// The status an install answers.
    public event Action<TexStatus>? Installed;

    void OnInstall(object sender, RoutedEventArgs e) => App.Run("Can't install TinyTeX", async () =>
    {
        if (App.Core is not { } core) return;
        installing = core.CallAsync<TexStatus>("install_tex");
        try { await Follow(installing); }
        finally { installing = null; }
    });

    async Task Follow(Task<TexStatus> task)
    {
        ShowBusy(true);
        try
        {
            var status = await task;
            IsOpen = !status.Available;
            Installed?.Invoke(status);
        }
        finally { ShowBusy(false); }
    }

    void ShowBusy(bool busy)
    {
        Install.IsEnabled = !busy;
        Ring.IsActive = busy;
        Ring.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        InstallText.Text = busy ? "Installing TinyTeX…" : "Install TinyTeX";
    }
}
