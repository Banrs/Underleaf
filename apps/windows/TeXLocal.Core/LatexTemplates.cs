namespace TeXLocal;

/// <summary>What the source bar and Format menu insert (web/src/sourcebar.js); "$0" marks the cursor.</summary>
public static class LatexTemplates
{
    /// <summary>Plain text, then the sectioning commands by outline level (an outline level is its index less one).</summary>
    public static readonly IReadOnlyList<(string Label, string Command)> HeadingLevels =
    [
        ("Normal text", ""), ("Part", "part"), ("Chapter", "chapter"), ("Section", "section"),
        ("Subsection", "subsection"), ("Subsubsection", "subsubsection"), ("Paragraph", "paragraph"),
    ];

    /// <summary>The level of the heading on a line, by its label in <see cref="HeadingLevels"/>.</summary>
    public static string LevelAt(IReadOnlyList<OutlineItem> outline, int line) =>
        HeadingLevels[outline.FirstOrDefault(o => o.Line == line) is { } heading ? heading.Level + 1 : 0].Label;

    /// <summary>Symbols by kind, inserted bare in math, in $…$ in text (web/src/sourcebar.js SYMBOL_GROUPS).</summary>
    public static readonly IReadOnlyList<(string Title, IReadOnlyList<(string Glyph, string Command)> Symbols)> SymbolGroups =
    [
        ("Greek", [("α", "\\alpha"), ("β", "\\beta"), ("γ", "\\gamma"), ("δ", "\\delta"), ("ε", "\\epsilon"),
            ("ζ", "\\zeta"), ("η", "\\eta"), ("θ", "\\theta"), ("κ", "\\kappa"), ("λ", "\\lambda"),
            ("μ", "\\mu"), ("ν", "\\nu"), ("ξ", "\\xi"), ("π", "\\pi"), ("ρ", "\\rho"), ("σ", "\\sigma"),
            ("τ", "\\tau"), ("φ", "\\phi"), ("χ", "\\chi"), ("ψ", "\\psi"), ("ω", "\\omega"),
            ("Γ", "\\Gamma"), ("Δ", "\\Delta"), ("Θ", "\\Theta"), ("Λ", "\\Lambda"), ("Π", "\\Pi"),
            ("Σ", "\\Sigma"), ("Φ", "\\Phi"), ("Ψ", "\\Psi"), ("Ω", "\\Omega")]),
        ("Operators", [("±", "\\pm"), ("×", "\\times"), ("÷", "\\div"), ("·", "\\cdot"), ("∑", "\\sum"),
            ("∏", "\\prod"), ("∫", "\\int"), ("∮", "\\oint"), ("√", "\\sqrt{}"), ("∂", "\\partial"),
            ("∇", "\\nabla"), ("∞", "\\infty"), ("∘", "\\circ"), ("⊗", "\\otimes"), ("⊕", "\\oplus")]),
        ("Relations", [("≤", "\\leq"), ("≥", "\\geq"), ("≠", "\\neq"), ("≈", "\\approx"), ("≡", "\\equiv"),
            ("∼", "\\sim"), ("∝", "\\propto"), ("∈", "\\in"), ("∉", "\\notin"), ("⊂", "\\subset"),
            ("⊆", "\\subseteq"), ("∪", "\\cup"), ("∩", "\\cap"), ("∅", "\\emptyset")]),
        ("Arrows and logic", [("→", "\\rightarrow"), ("←", "\\leftarrow"), ("↔", "\\leftrightarrow"),
            ("⇒", "\\Rightarrow"), ("⇐", "\\Leftarrow"), ("⇔", "\\Leftrightarrow"), ("↦", "\\mapsto"),
            ("∀", "\\forall"), ("∃", "\\exists"), ("¬", "\\neg"), ("∧", "\\wedge"), ("∨", "\\vee")]),
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
        [("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX")];

    public static string EngineName(string engine) =>
        Engines.FirstOrDefault(e => e.Id == engine).Name ?? engine;
}
