#!/usr/bin/env python3
"""Compare exact-line navigation; mismatches are evidence, not a failing gate."""
import gzip
import json
import re
import subprocess
import tempfile
import sys
from pathlib import Path

root, baseline, upstream = map(Path, sys.argv[1:])

def read_probe(binary, pdf, name, lines):
    run = subprocess.run(
        [str(binary), str(pdf), name, str(lines)], text=True, capture_output=True
    )
    result = {"exit": run.returncode, "inputs": [], "forward": {}}
    for line in run.stdout.splitlines():
        fields = line.split("\t")
        if fields[0] == "I":
            result["inputs"].append(fields[2])
        elif fields[0] == "T":
            result["parse_ms"] = float(fields[1]) * 1000
            result["query_us"] = float(fields[2]) * 1e6
            result["found"] = int(fields[3])
        elif fields[0] == "F":
            result["forward"][int(fields[1])] = fields[2:]
    result["inputs"].sort()
    if run.stderr:
        result["stderr"] = run.stderr[-3000:]
    return result

reports = []
cases = sorted(root.glob("*/case.json"))
assert len(cases) >= 9, f"missing captured/generated cases: {cases}"
for case in cases:
    config = json.loads(case.read_text())
    pdf = case.parent / "main.pdf"
    plain = pdf.with_suffix(".synctex")
    data = plain.read_bytes() if plain.exists() else gzip.decompress(
        pdf.with_suffix(".synctex.gz").read_bytes()
    )
    inputs = re.findall(r"(?m)^Input:\d+:(.*)$", data.decode("utf-8"))
    suffix = config["input"]
    name = next(n for n in inputs if n == suffix or n.endswith("/" + suffix))
    results = [read_probe(b, pdf, name, config["lines"]) for b in (baseline, upstream)]
    old, new = results
    assert old["exit"] == 0, old
    missing_inputs = sorted(set(old["inputs"]) - set(new["inputs"]))
    page_differences, inverse_differences, box_differences = [], [], []
    for line, before in old["forward"].items():
        after = new["forward"].get(line, ["0"])
        if before[0] != after[0]:
            page_differences.append({"line": line, "baseline": before[0], "upstream": after[0]})
        elif before[0] != "0":
            if before[5:] != after[5:]:
                inverse_differences.append({"line": line, "baseline": before[5:], "upstream": after[5:]})
            if any(abs(float(a) - float(b)) > 0.25 for a, b in zip(before[1:5], after[1:5])):
                box_differences.append(line)
    normalized = None
    if case.parent.name.startswith("live-"):
        # Test the smallest plausible compatibility fix independently: ignore
        # TeXpresso's completed-input markers, without repairing its contents.
        clean = re.sub(rb"(?m)^/\d+\n", b"", data)
        with tempfile.TemporaryDirectory() as temporary:
            candidate = Path(temporary) / "main.pdf"
            candidate.with_suffix(".synctex").write_bytes(clean)
            normalized = read_probe(upstream, candidate, name, config["lines"])
        normalized = {
            **{k: v for k, v in normalized.items() if k not in ("inputs", "forward")},
            "missing_inputs": sorted(set(old["inputs"]) - set(normalized["inputs"])),
            "page_differences": sum(
                before[0] != normalized["forward"].get(line, ["0"])[0]
                for line, before in old["forward"].items()
            ),
        }
    summary = {
        "case": case.parent.name,
        "source_lines": config["lines"],
        "has_postamble": b"Postamble:" in data,
        "ends_in_newline": data.endswith(b"\n"),
        "synctex_tail": data.decode("utf-8").splitlines()[-12:] if new["exit"] else None,
        "without_input_end_markers": normalized,
        "missing_inputs": missing_inputs,
        "page_differences": len(page_differences),
        "inverse_differences": len(inverse_differences),
        "box_differences_over_quarter_point": len(box_differences),
        "baseline": {k: v for k, v in old.items() if k not in ("inputs", "forward")},
        "upstream": {k: v for k, v in new.items() if k not in ("inputs", "forward")},
        "first_page_differences": page_differences[:5],
        "first_inverse_differences": inverse_differences[:5],
    }
    print(json.dumps(summary, sort_keys=True), flush=True)
    reports.append({"summary": summary, "baseline": old, "upstream": new})
(root / "results.json").write_text(json.dumps(reports, indent=2) + "\n")
