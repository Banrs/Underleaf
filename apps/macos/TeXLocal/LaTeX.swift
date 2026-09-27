import Foundation

// The LaTeX the source bar and the Insert and Format menus write, in one
// place. Titles are menu items here, so title case without the web's
// parentheticals: "Aligned Equations" is the web's "Align (multi-line math)".

/// A snippet to write at the cursor: a block, whose `body` is its id in
/// the editor page's one table of them (web/src/latex-data.js
/// `BLOCK_TEMPLATES`), or (`inline`) a command around the selection, "$0"
/// marking where the selection goes. `symbol`: the source bar has a button
/// for it, with that symbol; the rest are in its ⋯ menu.
struct Template {
    let title: String
    let body: String
    var symbol: String?
    var inline = false
}

extension ProjectModel {
    func insert(_ template: Template) {
        format(template.inline ? "inline" : "block", template.body)
    }
}

/// Blocks: web/src/sourcebar.js `INSERT_TEMPLATES`.
let insertTemplates = [
    Template(title: "Figure", body: "figure", symbol: "photo"),
    Template(title: "Table", body: "table", symbol: "tablecells"),
    Template(title: "Equation", body: "equation"),
    Template(title: "Aligned Equations", body: "align"),
    Template(title: "Code Block", body: "code"),
]

/// The lists: web/src/sourcebar.js `LIST_TEMPLATES`.
let listTemplates = [
    Template(title: "Bulleted List", body: "itemize", symbol: "list.bullet"),
    Template(title: "Numbered List", body: "enumerate", symbol: "list.number"),
    Template(title: "Description List", body: "description"),
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

/// The engines a project can compile with, for the Compile menu, the
/// inspector and the status bar.
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
