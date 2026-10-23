using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace TeXLocal.Pages;

/// What the workspace shows of its session, which WorkspacePage.xaml binds one way: the page sets these, not the controls.
/// Each set is told, even of the same value, so a toggle the reader clicked that changed nothing is set back.
public sealed partial class WorkspaceModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public bool TexFound { get; set => Set(ref field, value); }
    public bool Compiling { get; set => Set(ref field, value); }
    public string BuildState { get; set => Set(ref field, value); } = "No build yet";
    public string Errors { get; set => Set(ref field, value); } = "0";
    public string Warnings { get; set => Set(ref field, value); } = "0";
    public string WarningsLabel { get; set => Set(ref field, value); } = "0 warnings";
    public bool Unsaved { get; set => Set(ref field, value); }
    public string Caret { get; set => Set(ref field, value); } = "Ln 1, Col 1";
    public string Words { get; set => Set(ref field, value); } = "";
    public bool HasPdf { get; set => Set(ref field, value); }
    public string Page { get; set => Set(ref field, value); } = "No PDF";
    public string Zoom { get; set => Set(ref field, value); } = "100%";
    /// Word's slider: 100% at its middle, each step either side doubling or halving.
    public double ZoomStep { get; set => Set(ref field, value); }
    public bool CanGoBack { get; set => Set(ref field, value); }
    public bool CanGoForward { get; set => Set(ref field, value); }
    /// LaTeX's commands, for a .tex file that shows.
    public bool Latex { get; set => Set(ref field, value); } = true;
    public bool Bold { get; set => Set(ref field, value); }
    public bool Italic { get; set => Set(ref field, value); }
    public bool Underline { get; set => Set(ref field, value); }
    public string Style { get; set => Set(ref field, value); } = "Normal text";

    public static string CompileGlyph(bool compiling) => compiling ? "\uE71A" : "\uE768";
    public static string CompileLabel(bool compiling) => compiling ? "Stop" : "Compile";
    public static string CompileTip(bool compiling) => compiling ? "Stop (Shift+F5)" : "Compile (Ctrl+Enter)";

    void Set<T>(ref T slot, T value, [CallerMemberName] string name = "")
    {
        slot = value;
        PropertyChanged?.Invoke(this, new(name));
    }
}
