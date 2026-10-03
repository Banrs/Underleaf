import Foundation

// LaTeX templates shared by the toolbar and Insert and Format menus.

/// A core catalog block, or an inline command with "$0" for the selection.
/// A symbol makes it available as a Customize Toolbar button.
struct Template {
    let title: String
    let body: String
    var symbol: String?
    var inline = false
}

extension ProjectModel {
    func insert(_ template: Template) {
        editor.perform(template.inline ? .inline : .block, template.body)
    }
}

let mathTemplates = [
    Template(title: "Equation", body: "equation"),
    Template(title: "Aligned Equations", body: "align"),
]

let insertTemplates = [
    Template(title: "Figure", body: "figure", symbol: "photo"),
    Template(title: "Table", body: "table", symbol: "tablecells"),
    Template(title: "Code Block", body: "code"),
]

let listTemplates = [
    Template(title: "Bulleted List", body: "itemize", symbol: "list.bullet"),
    Template(title: "Numbered List", body: "enumerate", symbol: "list.number"),
    Template(title: "Description List", body: "description"),
]

/// Cross-references, citations and links; with nothing selected, a
/// reference or citation offers what can go in its braces.
let referenceTemplates = [
    Template(title: "Reference", body: "\\ref{$0}", symbol: "number.sign", inline: true),
    Template(title: "Equation Reference", body: "\\eqref{$0}", inline: true),
    Template(title: "Citation", body: "\\cite{$0}", symbol: "text.quote", inline: true),
    Template(title: "Label", body: "\\label{$0}", inline: true),
    Template(title: "Link", body: "\\href{$0}{}", symbol: "link", inline: true),
    Template(title: "URL", body: "\\url{$0}", inline: true),
]

/// A line's style: plain text or a sectioning command (`command` without
/// the backslash; empty for plain text).
nonisolated struct HeadingLevel: Hashable {
    let title: String
    let command: String

    static let normalText = HeadingLevel(title: "Normal Text", command: "")

    /// Indexed by the core's outline depth (analyze.rs), so the order is fixed.
    static let sections = [
        HeadingLevel(title: "Part", command: "part"),
        HeadingLevel(title: "Chapter", command: "chapter"),
        HeadingLevel(title: "Section", command: "section"),
        HeadingLevel(title: "Subsection", command: "subsection"),
        HeadingLevel(title: "Subsubsection", command: "subsubsection"),
        HeadingLevel(title: "Paragraph", command: "paragraph"),
    ]

    static let all = [normalText] + sections

    static func atDepth(_ depth: Int) -> HeadingLevel? {
        sections.indices.contains(depth) ? sections[depth] : nil
    }
}

/// The engines a project can compile with: (the core's id, the menu title).
let texEngines = [("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX")]

/// Symbols by kind, each inserted as its command.
let symbolGroups: [(String, [(String, String)])] = [
    ("Greek", [("α", "\\alpha"), ("β", "\\beta"), ("γ", "\\gamma"), ("δ", "\\delta"), ("ϵ", "\\epsilon"),
               ("ζ", "\\zeta"), ("η", "\\eta"), ("θ", "\\theta"), ("κ", "\\kappa"), ("λ", "\\lambda"),
               ("μ", "\\mu"), ("ν", "\\nu"), ("ξ", "\\xi"), ("π", "\\pi"), ("ρ", "\\rho"), ("σ", "\\sigma"),
               ("τ", "\\tau"), ("ϕ", "\\phi"), ("χ", "\\chi"), ("ψ", "\\psi"), ("ω", "\\omega"),
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
