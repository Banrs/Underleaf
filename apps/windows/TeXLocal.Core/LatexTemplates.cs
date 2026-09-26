namespace TeXLocal;

/// <summary>
/// What the source's format bar and the Format menu insert — the web editor
/// bar's heading, reference, list and insert menus (web/src/workspace.js
/// editorToolbar, INSERT_TEMPLATES), as apps/macos has them. "$0" marks where
/// the cursor lands.
/// </summary>
public static class LatexTemplates
{
    /// <summary>The sectioning commands, in the order the outline ranks them.</summary>
    public static readonly IReadOnlyList<(string Label, string Template)> Headings =
    [
        ("Part", "\\part{$0}\n"), ("Chapter", "\\chapter{$0}\n"), ("Section", "\\section{$0}\n"),
        ("Subsection", "\\subsection{$0}\n"), ("Subsubsection", "\\subsubsection{$0}\n"), ("Paragraph", "\\paragraph{$0} "),
    ];

    /// <summary>Cross-references, citations and links; each opens completion inside its braces.</summary>
    public static readonly IReadOnlyList<(string Label, string Template)> References =
    [
        ("Reference", "\\ref{$0}"), ("Equation reference", "\\eqref{$0}"), ("Citation", "\\cite{$0}"),
        ("Label", "\\label{$0}"), ("Link", "\\href{$0}{}"), ("URL", "\\url{$0}"),
    ];

    public static readonly IReadOnlyList<(string Label, string Template)> Lists =
    [
        ("Bulleted list", "\\begin{itemize}\n  \\item $0\n\\end{itemize}\n"),
        ("Numbered list", "\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n"),
        ("Description list", "\\begin{description}\n  \\item[$0] \n\\end{description}\n"),
    ];

    /// <summary>Environments; the lists are in <see cref="Lists"/>.</summary>
    public static readonly IReadOnlyList<(string Label, string Template)> Environments =
    [
        ("Figure", "\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n"),
        ("Table", "\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n"),
        ("Equation", "\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n"),
        ("Align (multi-line math)", "\\begin{align}\n  $0 \\\\\n\\end{align}\n"),
        ("Code block", "\\begin{verbatim}\n$0\n\\end{verbatim}\n"),
    ];

    /// <summary>The engines a project can compile with: the core's id, then its name.</summary>
    public static readonly IReadOnlyList<(string Id, string Name)> Engines =
    [
        ("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX"),
    ];

    public static string EngineName(string engine) =>
        Engines.FirstOrDefault(e => e.Id == engine).Name ?? engine;
}
