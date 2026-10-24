#!/usr/bin/env python3
"""Erosion and clones, as SlopCodeBench measures them (arXiv 2603.24755): code written by agents
gathers complexity into a few functions and repeats itself several times faster than people's, and
instructions alone don't stop it. CI fails a change that raises either above LIMITS; lower them as
the code improves. Needs `pip install lizard==1.24.2` and Node (`npx jscpd`)."""
import csv, io, json, math, re, subprocess, sys, tempfile

# The share of complexity (CC × √lines) in functions with CC over 10, per language's app code;
# and the share of lines jscpd finds repeated.
LIMITS = {"rs": 0.47, "swift": 0.25, "clones": 0.05}

files = subprocess.run(["git", "ls-files", "crates/*.rs", "apps/*.swift"],
                       capture_output=True, text=True, check=True).stdout.split()
code = [f for f in files if not re.search(r"(/tests/|tests\.rs$|/stubs\.rs$|Tests/)", f)]
out = subprocess.run([sys.executable, "-m", "lizard", "--csv", *code], capture_output=True, text=True).stdout

# A Rust file's inline test module, which runs to its end; `#[cfg(test)] mod tests;` names a file of its own.
def in_tests(path, line, starts={}):
    if path not in starts:
        lines = open(path, encoding="utf-8").read().splitlines()
        starts[path] = next((i + 1 for i in range(len(lines) - 1) if path.endswith(".rs")
                             and lines[i] == "#[cfg(test)]" and re.match(r"mod \w+ \{", lines[i + 1])), math.inf)
    return line >= starts[path]

mass, eroded = {}, {}
for row in csv.reader(io.StringIO(out)):
    nloc, ccn, path, start = int(row[0]), int(row[1]), row[6], int(row[9])
    if in_tests(path, start):
        continue
    lang, m = path.rsplit(".", 1)[1], ccn * math.sqrt(nloc)
    mass[lang] = mass.get(lang, 0) + m
    eroded[lang] = eroded.get(lang, 0) + (m if ccn > 10 else 0)
found = {lang: eroded[lang] / mass[lang] for lang in mass}

with tempfile.TemporaryDirectory() as report:
    subprocess.run(["npx", "--yes", "jscpd@4.3.0", "--silent", "--gitignore", "--reporters", "json",
                    "--output", report, "--format", "swift,rust", "apps", "crates"],
                   capture_output=True, check=True)
    found["clones"] = json.load(open(f"{report}/jscpd-report.json"))["statistics"]["total"]["percentage"]

over = [k for k, v in found.items() if v > LIMITS[k] + 0.005]
for k, v in found.items():
    print(f"{k:7} {v:.3f}  (limit {LIMITS[k]})" + ("  ← over" if k in over else ""))
sys.exit(1 if over else 0)
