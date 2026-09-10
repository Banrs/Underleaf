//! Built-in project templates, ported verbatim from server/templates.js.
//! Each template maps relative file path → content.

const ARTICLE_BIB: &str = r#"@article{knuth1984,
  author  = {Knuth, Donald E.},
  title   = {Literate Programming},
  journal = {The Computer Journal},
  year    = {1984},
  volume  = {27},
  number  = {2},
  pages   = {97--111}
}
"#;

const BLANK_MAIN: &str = r#"\documentclass{article}
\begin{document}

Hello, world!

\end{document}
"#;

const ARTICLE_MAIN: &str = r#"\documentclass[11pt]{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{amsmath, amssymb}
\usepackage{graphicx}
\usepackage[margin=1in]{geometry}
\usepackage{hyperref}

\title{Your Title Here}
\author{Your Name}
\date{\today}

\begin{document}

\maketitle

\begin{abstract}
A short summary of your work goes here.
\end{abstract}

\section{Introduction}
Start writing here. Cite sources like this~\cite{knuth1984}.

\section{Method}
Inline math like $e^{i\pi} + 1 = 0$, or display math:
\begin{equation}
  \int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
  \label{eq:gauss}
\end{equation}
Reference equations like Equation~\ref{eq:gauss}.

\section{Conclusion}
Wrap it up.

\bibliographystyle{plain}
\bibliography{references}

\end{document}
"#;

const REPORT_MAIN: &str = r#"\documentclass[11pt]{report}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{amsmath, amssymb}
\usepackage{graphicx}
\usepackage[margin=1in]{geometry}
\usepackage{hyperref}

\title{Report Title}
\author{Your Name}
\date{\today}

\begin{document}

\maketitle
\tableofcontents

\chapter{Introduction}
Start writing here~\cite{knuth1984}.

\chapter{Background}
More content.

\bibliographystyle{plain}
\bibliography{references}

\end{document}
"#;

const BEAMER_MAIN: &str = r#"\documentclass{beamer}
\usetheme{metropolis} % falls back gracefully; try 'Madrid' if unavailable
\usepackage{amsmath}

\title{Presentation Title}
\author{Your Name}
\date{\today}

\begin{document}

\begin{frame}
  \titlepage
\end{frame}

\begin{frame}{Outline}
  \tableofcontents
\end{frame}

\section{First Section}

\begin{frame}{A Slide}
  \begin{itemize}
    \item First point
    \item Second point
    \item Third point
  \end{itemize}
\end{frame}

\begin{frame}{Math}
  \begin{equation*}
    \nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}
  \end{equation*}
\end{frame}

\end{document}
"#;

/// The files for a template; an unknown name falls back to `article`, as the
/// JS original did.
pub fn files(template: &str) -> &'static [(&'static str, &'static str)] {
    match template {
        "blank" => &[("main.tex", BLANK_MAIN)],
        "report" => &[("main.tex", REPORT_MAIN), ("references.bib", ARTICLE_BIB)],
        "beamer" => &[("main.tex", BEAMER_MAIN)],
        _ => &[("main.tex", ARTICLE_MAIN), ("references.bib", ARTICLE_BIB)],
    }
}

pub const NAMES: &[&str] = &["blank", "article", "report", "beamer"];
