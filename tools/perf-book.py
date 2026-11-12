#!/usr/bin/env python3
"""Writes the 400-page book the performance tests time: main.tex, 40 chapters, 200 references.

python3 tools/perf-book.py <folder>, then `latexmk -pdf -synctex=-1 -outdir=build main.tex` in it for the PDF.
"""
import pathlib
import random
import sys

random.seed(7)
root = pathlib.Path(sys.argv[1])
(root / "chapters").mkdir(parents=True, exist_ok=True)
words = ("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore "
         "magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat").split()


def para(n=90):
    return " ".join(random.choice(words) for _ in range(n)).capitalize() + "."


(root / "refs.bib").write_text("\n".join(
    f"@article{{ref{i},\n  author = {{Author {i} and Other {i}}},\n  title = {{Title number {i}}},\n"
    f"  journal = {{Journal {i % 17}}},\n  year = {{{1990 + i % 35}}}\n}}\n" for i in range(200)))
for c in range(40):
    out = [f"\\chapter{{Chapter {c}}}\\label{{ch:{c}}}\n"]
    for s in range(10):
        out.append(f"\\section{{Section {c}.{s}}}\\label{{sec:{c}-{s}}}\n")
        for _ in range(4):
            out.append(para() + f" See \\ref{{sec:{random.randrange(40)}-{random.randrange(10)}}} and \\cite{{ref{random.randrange(200)}}}.\n\n")
        out.append(f"\\begin{{equation}}\\label{{eq:{c}-{s}}}\n  \\int_0^{{{s+1}}} x^{{{c}}} \\, dx = "
                   f"\\frac{{{s+1}^{{{c+1}}}}}{{{c+1}}} + \\sum_{{k=1}}^{{n}} \\alpha_k\n\\end{{equation}}\n")
        out.append("\\begin{itemize}\n" + "".join(f"  \\item {para(12)}\n" for _ in range(3)) + "\\end{itemize}\n\n")
    (root / "chapters" / f"ch{c:02}.tex").write_text("".join(out))
(root / "main.tex").write_text("\\documentclass{book}\n\\usepackage{amsmath}\n\\begin{document}\n\\tableofcontents\n"
                               + "".join(f"\\input{{chapters/ch{c:02}}}\n" for c in range(40))
                               + "\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n")
