import Foundation

// The LaTeX the source bar and the Format menu write, in one place. Titles
// are menu items here, so title case without the web's parentheticals:
// "Aligned Equations" is the web's "Align (multi-line math)".

/// A snippet to write at the cursor: a block, or (`inline`) a command
/// around the selection. "$0" marks where the cursor lands. `symbol`: the
/// source bar has a button for it, with that symbol; the rest are in its
/// ⋯ menu.
struct Template {
    let title: String
    let body: String
    var symbol: String?
    var inline = false
}

extension ProjectModel {
    func insert(_ template: Template) {
        format(template.inline ? "inline" : "insert", template.body)
    }
}

/// Blocks: web/src/sourcebar.js `INSERT_TEMPLATES`.
let insertTemplates = [
    Template(title: "Figure", body: "\\begin{figure}[h]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{$0}\n  \\caption{}\n  \\label{fig:}\n\\end{figure}\n", symbol: "photo"),
    Template(title: "Table", body: "\\begin{table}[h]\n  \\centering\n  \\caption{$0}\n  \\label{tab:}\n  \\begin{tabular}{lcc}\n    \\hline\n     &  &  \\\\\n    \\hline\n  \\end{tabular}\n\\end{table}\n", symbol: "tablecells"),
    Template(title: "Equation", body: "\\begin{equation}\n  $0\n  \\label{eq:}\n\\end{equation}\n"),
    Template(title: "Aligned Equations", body: "\\begin{align}\n  $0 \\\\\n\\end{align}\n"),
    Template(title: "Code Block", body: "\\begin{verbatim}\n$0\n\\end{verbatim}\n"),
]

/// The lists: web/src/sourcebar.js `LIST_TEMPLATES`.
let listTemplates = [
    Template(title: "Bulleted List", body: "\\begin{itemize}\n  \\item $0\n\\end{itemize}\n", symbol: "list.bullet"),
    Template(title: "Numbered List", body: "\\begin{enumerate}\n  \\item $0\n\\end{enumerate}\n", symbol: "list.number"),
    Template(title: "Description List", body: "\\begin{description}\n  \\item[$0] \n\\end{description}\n"),
]

/// Cross-references, citations and links; each opens completion inside
/// its braces.
let referenceTemplates = [
    Template(title: "Reference", body: "\\ref{$0}", symbol: "number", inline: true),
    Template(title: "Equation Reference", body: "\\eqref{$0}", inline: true),
    Template(title: "Citation", body: "\\cite{$0}", symbol: "text.quote", inline: true),
    Template(title: "Label", body: "\\label{$0}", inline: true),
    Template(title: "Link", body: "\\href{$0}{}", symbol: "link", inline: true),
    Template(title: "URL", body: "\\url{$0}", inline: true),
]

/// The section levels, as the line's style: plain text, then the
/// sectioning commands in the order the web's outline ranks them.
let headingLevels: [(String, String)] = [
    ("Normal Text", ""), ("Part", "part"), ("Chapter", "chapter"), ("Section", "section"),
    ("Subsection", "subsection"), ("Subsubsection", "subsubsection"), ("Paragraph", "paragraph"),
]

/// The engines a project can compile with, for the Compile menu and the
/// inspector.
let texEngines = [("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX")]

/// Symbols by kind, each inserted as its command: the palette LaTeX editors
/// keep beside the source (TeXstudio, TeXShop, Overleaf).
let symbolGroups: [(String, [(String, String)])] = [
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
    ("Arrows and Logic", [("→", "\\rightarrow"), ("←", "\\leftarrow"), ("↔", "\\leftrightarrow"),
                          ("⇒", "\\Rightarrow"), ("⇐", "\\Leftarrow"), ("⇔", "\\Leftrightarrow"), ("↦", "\\mapsto"),
                          ("∀", "\\forall"), ("∃", "\\exists"), ("¬", "\\neg"), ("∧", "\\wedge"), ("∨", "\\vee")]),
]
