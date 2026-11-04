#!/usr/bin/env python3
"""Small compressed/uncompressed fixtures and a deterministic 400-page document."""
import gzip
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
fixture = Path("crates/texlocal-latex/tests/fixtures/two-pages.synctex").read_bytes()
for compressed in (False, True):
    case = root / ("two-pages-gzip" if compressed else "two-pages-plain")
    case.mkdir(parents=True, exist_ok=True)
    (case / ("main.synctex.gz" if compressed else "main.synctex")).write_bytes(
        gzip.compress(fixture) if compressed else fixture
    )
    (case / "case.json").write_text(json.dumps({"input": "main.tex", "lines": 10}))

case = root / "compiled-400-pages"
case.mkdir(parents=True, exist_ok=True)
source = [
    r"\documentclass{article}",
    r"\usepackage{hyperref}",
    r"\begin{document}",
]
for page in range(1, 401):
    source.extend([
        rf"\section{{Section {page}}}\label{{section:{page}}}",
        rf"Page {page} contains ordinary text, a \textbf{{bold word}}, and inline math $x^2+y^2=z^2$.",
        r"\begin{equation} \sum_{i=1}^{n} i = \frac{n(n+1)}{2} \end{equation}",
        r"\begin{tabular}{ll} Left & Right \\ One & Two \end{tabular}",
        r"\begin{picture}(120,30)\put(0,0){\line(1,0){100}}\put(10,10){A picture}\end{picture}",
        rf"See section~\ref{{section:{page}}} and \href{{https://example.com}}{{a link}}.",
        r"\newpage" if page < 400 else r"\end{document}",
    ])
text = "\n".join(source) + "\n"
(case / "main.tex").write_text(text)
with (case / "build.log").open("w") as log:
    subprocess.run(
        ["latexmk", "-pdf", "-synctex=1", "-interaction=nonstopmode", "-halt-on-error", "main.tex"],
        cwd=case, stdout=log, stderr=subprocess.STDOUT, check=True,
    )
(case / "case.json").write_text(json.dumps({"input": "main.tex", "lines": len(source)}))
