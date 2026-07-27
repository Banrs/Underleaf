import Foundation

// New-project starter files. (The Electron app's set lives in server/templates.js;
// this is a trimmed parity copy — extend as needed.)
enum Templates {
    static func files(for template: String) -> [(String, String)] {
        switch template {
        case "blank":
            return [("main.tex", "\\documentclass{article}\n\\begin{document}\n\n\\end{document}\n")]
        case "beamer":
            return [("main.tex", """
            \\documentclass{beamer}
            \\title{Title}
            \\author{Your Name}
            \\begin{document}
            \\frame{\\titlepage}
            \\begin{frame}{First slide}
              Content here.
            \\end{frame}
            \\end{document}
            """)]
        case "report":
            return [("main.tex", """
            \\documentclass[11pt]{report}
            \\usepackage[utf8]{inputenc}
            \\title{Report Title}
            \\author{Your Name}
            \\begin{document}
            \\maketitle
            \\chapter{Introduction}
            Start writing here.
            \\end{document}
            """)]
        default: // article
            return [
                ("main.tex", """
                \\documentclass[11pt]{article}
                \\usepackage[utf8]{inputenc}
                \\usepackage[T1]{fontenc}
                \\usepackage{amsmath, amssymb}
                \\usepackage{graphicx}
                \\usepackage[margin=1in]{geometry}
                \\usepackage{hyperref}

                \\title{Your Title Here}
                \\author{Your Name}
                \\date{\\today}

                \\begin{document}
                \\maketitle

                \\begin{abstract}
                A short summary of your work goes here.
                \\end{abstract}

                \\section{Introduction}
                Start writing here. Cite sources like this~\\cite{knuth1984}.

                \\bibliographystyle{plain}
                \\bibliography{references}
                \\end{document}
                """),
                ("references.bib", "@book{knuth1984,\n  title={The TeXbook},\n  author={Knuth, Donald E.},\n  year={1984},\n  publisher={Addison-Wesley}\n}\n"),
            ]
        }
    }
}
