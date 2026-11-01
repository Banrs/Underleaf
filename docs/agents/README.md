# Why agent code bloats, and what we check

The evidence behind AGENTS.md's "Writing code" rules, and the checks it supports in this repo. Researched 2026-11-02
from the full texts (arXiv HTML, METR's pages); every figure is the source's own. Tags: **[E]** a source measured it
directly; **[I]** inferred from a source that measured something next to it; **[J]** judgement, no source tested it.

## In short

- Bloat is iterative. Single agent patches look like human ones (Chen & Jiang); the damage accrues as an agent extends
  its own code (SlopCodeBench) and over months of a project (He et al.).
- Quality rules in a prompt lower where the code starts, not how fast it degrades, and cost a little correctness. So
  measure with tools rather than add rules.
- Agent code is longer per function, nested and layered deeper, and reuses less across files (Mao et al.).
- Context files: hand-written beat generated; neither significantly raises success; both cost about 20% more; repo
  overviews don't help; agents do run the commands a file names (Gloaguen et al.).
- Passing tests is not mergeable: maintainers would reject about half of test-passing agent PRs (METR).
- Repeated fixing decays within 2-3 attempts; restarting from the problem beats pushing on (Adnan & Kuhn).
- An LLM reviewer rejects correct code often, more so when asked to explain and fix (Jin & Chen).

## Sources

**1. SlopCodeBench.** Orlanski, Roy, Yun, Shin, Gu, Ge, Adila, Roberts, Sala, Albarghouthi (2026). *SlopCodeBench:
Benchmarking How Coding Agents Degrade Over Long-Horizon Iterative Tasks.* arXiv 2603.24755v2.
https://arxiv.org/abs/2603.24755v2
- Method: 36 problems, 196 checkpoints; at each the agent extends its own code from a prose spec, with no visible tests
  and no earlier conversation. 15 models in their own harnesses (Claude Code, Codex CLI, ...), Python only. Verbosity =
  share of lines hit by 137 ast-grep rules or in structural clones; erosion = share of complexity mass (CC x sqrt(SLOC))
  in functions with CC > 10.
- Found: best strict solve 14.8%; no problem solved end to end. Erosion rose in 77% of trajectories, verbosity in
  75.5%. Functions with CC >= 10 went from 3.6 to 23.7 on average, mean max CC from 27.5 to 69.0. Clone lines grew 96%
  while rule hits per line grew 0.3%: the growth is rewritten copies, not new anti-patterns. One `main()` went from 38 to
  240 lines across 8 checkpoints, seven flags each parsed by hand twice, no helper extracted.
- Against 473 human Python repos: 2.3x more verbose, 2.0x more eroded; per checkpoint verbosity grew 0.0144 vs 0.0022
  and erosion 0.0264 vs 0.0053 (human medians). Erosion rose in 77% of agent runs vs 53% of repos.
- Prompts: an "anti-slop" prompt listing what to avoid (trivial wrappers, single-use variables, abnormal defensive
  checks, comments a human wouldn't add, heavy nesting, many helpers) cut verbosity 27.5-35.6% and erosion 34.3-57.6%
  on three GPT models; the degradation per checkpoint stayed (about 1.3 points). Anti-slop and plan-first prompts cost
  12.1% more per checkpoint and lost 2.4 and 3.6 points of strict solve on average.
- Limits: Python, synthetic CLI/API tasks, agents never see their scores. The abstract says prompts cut quality issues
  "by up to a third" while section 3.4 gives larger erosion cuts; the figures above are section 3.4's.
- Here: [E] complexity piles into the function that is already biggest, so extract before adding a branch to it. [E] a
  rule list lowers the level but not the drift, so consolidation is measured (Checks 3-5), not exhorted.

**2. AI code in real repositories.** Mao, Zhao, Tang, Wang, Zhang (2026). *A Large-Scale Empirical Study of
AI-Generated Code in Real-World Repositories.* arXiv 2603.27130v2. https://arxiv.org/abs/2603.27130v2 (an empirical
study, not a review).
- Method: 12,749 commits and 19,816 files whose comments credit an LLM (rules plus an LLM classifier, spot-checked at
  85-95%), each matched with two human files from the same repo and language, of similar size. cloc, tree-sitter,
  jscpd, CodeQL, git history.
- Found: AI files are longer (256.6 vs 192.7 physical lines) with the same comment ratio (18.0% both), so the extra is
  code. Per function: more tokens, statements, conditions and loops, deeper nesting; call graphs deeper, not wider;
  fewer functions per file (6.6 vs 11.7). Less duplication (18.7% vs 25.9% of lines), from less cross-file reuse (17.2%
  vs 24.5%), which the authors read as one-off generation instead of shared utilities. Commits are smaller but revisited
  more at 30 and 90 days and slower to settle (in a minority of commits). High-risk CodeQL alerts 0.93 vs 0.46 per KLOC.
- Limits: only self-labelled AI code, mostly ChatGPT, Python and JavaScript; many effects are significant but tiny
  (Cohen's d 0.01 for tokens per function; about 0.5-0.7 for operators, content ratio, lexical density).
- Here: [E] layering and one-off code are the measured shape, so "no layer that only forwards" and "search before
  writing a helper" stand. [I] the authors advise treating AI output as a draft to consolidate.

**3. Do AGENTS.md files help?** Gloaguen, Mündler-Sasahara, Müller, Raychev, Vechev (2026). *Evaluating AGENTS.md: Are
Repository-Level Context Files Helpful for Coding Agents?* arXiv 2602.11988v3 (a preprint; it states no venue).
https://arxiv.org/abs/2602.11988
- Method: SWE-bench Lite (300 tasks) with generated files, and CTXbench (138 tasks from 12 niche repos with their
  developers' files); Claude Code + Sonnet 4.5, Codex + GPT-5.2 / GPT-5.1 mini, Qwen Code + Qwen3-30B; no file,
  generated file, developer file.
- Found: generated files lowered success by 0.5 and 2 points (not significant) and raised cost 20% and 23% (significant).
  Developer files raised success 2.4 points (p = 0.21 vs none; significantly above generated, p = 0.038) and cost up to
  19%. Agents obey the files: a tool the file names was used 1.6 times per task, under 0.01 when unnamed. Overviews did
  not get agents to the right files sooner. Generated files helped (+2.7 points) only once all other docs were deleted:
  they mostly repeat the README. File length showed no correlation with success or cost.
- Limits: Python; success = generated tests pass; one run per setting.
- Here: [E] keep AGENTS.md hand-written and limited to what the code and README don't say; name exact commands; no
  overviews or directory tours. Correction to an earlier summary: this study does not show long files hurt.

**4. AGENTS.md and efficiency.** Lulla, Mohsenimofidi, Galster, Zhang, Baltes, Treude (2026). *On the Impact of
AGENTS.md Files on the Efficiency of AI Coding Agents.* arXiv 2601.20404v2. https://arxiv.org/abs/2601.20404
- Codex (gpt-5.2-codex), 10 repos, 124 merged PRs of at most 100 lines, with and without the repo's own AGENTS.md:
  median wall-clock 28.6% lower, median output tokens 16.6% lower; median total tokens about equal. No correctness
  check beyond a 50-output sanity read.
- Here: [E] a real, human file speeds runs; it says nothing about the code's quality.

**5. What context files contain.** Chatlatanagulchai et al. (2025). *Agent READMEs: An Empirical Study of Context Files
for Agentic Coding.* arXiv 2511.12884. https://arxiv.org/abs/2511.12884
- 2,303 files from 1,925 repos: median 485 words (CLAUDE.md), 535 (Copilot), 335.5 (AGENTS.md for Codex); hard to read;
  edited every 1-3 days (median), by additions (median deletion under 15 words), so they grow. Security and
  performance appear in under 15% of files.
- Here: [I] these files accrete; delete a line when adding one.

**6. How many instructions?** Jaroslawicz, Whiting, Shah et al. (2025). *How Many Instructions Can LLMs Follow at
Once?* arXiv 2507.11538. https://arxiv.org/abs/2507.11538
- 20 models, 10-500 keyword instructions in one report-writing task: the best reach 68% at 500; reasoning models hold
  near-perfect to 100-250, others decay linearly or exponentially; early instructions are favoured.
- Limits: keyword inclusion, not coding. Here: [I] weak support for brevity (a 40-line file is far below where decay
  was measured) and for putting what matters most first.

**7. Cursor in open source.** He, Miller, Agarwal, Kästner, Vasilescu (2026). *Speed at the Cost of Quality: How Cursor
AI Increases Short-Term Velocity and Long-Term Complexity in Open-Source Projects.* MSR '26; arXiv 2511.04427v3.
https://arxiv.org/abs/2511.04427
- Method: 806 repos that added `.cursorrules` vs 1,380 matched controls, staggered difference-in-differences, monthly
  SonarQube.
- Found: lines added +281% in month one, +48% in month two, then no effect. Static-analysis warnings +30.3% and
  cognitive complexity +41.6% (the discussion says 25.1%), both persistent. Duplicated-line density: no significant
  change. Doubling complexity goes with 64.5% fewer lines added later; complexity rises even net of velocity.
- Limits: a rules file is a proxy for use; open source only; mid-2024 to mid-2025 tools.
- Here: [E] volume spikes and complexity stays, so report net lines and check complexity, not only duplication.

**8. METR's RCT and its 2026 update.** Becker, Rush, Barnes, Rein (2025). *Measuring the Impact of Early-2025 AI on
Experienced Open-Source Developer Productivity.* arXiv 2507.09089v2. https://arxiv.org/abs/2507.09089 Then Becker,
Rush, Cunningham, Rein, Mahamud (2026). *We are Changing our Developer Productivity Experiment Design.*
https://metr.org/blog/2026-02-24-uplift-update/
- RCT: 16 developers, 246 tasks in their own mature repos. AI-allowed tasks took 19% longer (CI +2% to +39%) while the
  developers believed they were 20% faster. Under 44% of Cursor generations accepted; 56% often needed major changes
  to clean AI code; about 9% of time went to reviewing and cleaning it; one developer lost an hour, reverted, and did it
  by hand. 47% more lines per forecast hour (not significant): the authors warn lines are not output.
- 2026: 57 developers, 800+ tasks: -18% (CI -38% to +9%) for returning developers, -4% (-15% to +9%) for new ones.
  METR calls this unreliable: developers now decline AI-free work, and 30-50% held back tasks.
- Here: [E] lines are a cost to justify, not progress. [I] the cleanup experts did by hand is the consolidation pass.

**9. Test-passing PRs maintainers wouldn't merge.** Whitfill, Wu, Becker, Rush (2026). *Many SWE-bench-Passing PRs Would
Not Be Merged into Main.* METR note.
https://metr.org/notes/2026-03-10-many-swe-bench-passing-prs-would-not-be-merged-into-main/
- 4 maintainers of scikit-learn, Sphinx and pytest blind-reviewed 296 agent PRs; they merged 68% of the original human
  patches. Normalised to that, merges ran 24.2 points (SE 2.7) below the grader, about half of passing PRs. Reasons:
  code quality and repo standards, breaking other code, not fixing the issue. Gains from Claude 4 Opus to Sonnet 4.5
  were mostly code quality.
- Limits: no CI for reviewers, one attempt, no iteration on feedback. Here: [E] tests passing is not done.

**10. One-shot agent patches.** Chen, Jiang (2025). *Evaluating Software Development Agents: Patch Patterns, Code
Quality, and Issue Complexity in Real-World GitHub Scenarios.* SANER 2025; arXiv 2410.12468.
https://arxiv.org/abs/2410.12468
- 4,892 patches from 10 agents on SWE-bench Verified: agents usually pick the gold patch's file but often a different
  function, which the tests then don't cover; some agents grow net size far more than gold; most add no bugs, keep or
  cut duplication, and some add small but significant complexity.
- Here: [E] one patch rarely shows the bloat; iteration does (1, 7). [E] code the tests don't reach isn't vouched for.

**11. Methods cut in review.** Watanabe, Shirai, Kashiwa, Iida (2026). *What to Cut? Predicting Unnecessary Methods in
Agentic Code Generation.* arXiv 2602.17091. https://arxiv.org/abs/2602.17091
- 12,343 methods added by agents in 1,664 merged Python PRs: 2.6% deleted before merge, 9.9% in PRs that were revised;
  deleted ones are longer with longer names. GPT-4o found 2.6% of them, praising a cut method's local quality.
- Here: [E] an LLM judges a function by how it reads, not whether anything needs it; the test is who calls it.

**12. Debugging decay.** Adnan, Kuhn (2025). *The Debugging Decay Index: Rethinking Debugging Strategies for Code LLMs.*
Scientific Reports; arXiv 2506.18403v2. https://arxiv.org/abs/2506.18403
- 18 models on HumanEval: debugging effectiveness decays exponentially, most models losing 60-80% within 2-3 attempts.
  A fresh start (history cleared, the original problem only) at the computed point improved all 6 models tried, same
  budget (e.g. 72.6% to 82.8%). Limits: single functions, not repositories.
- Here: [E] "revert after two failed fixes" matches the window; restart from the problem, not the failed attempts.

**13. Iterative LLM refactoring.** Peitek, Hess, Apel (2026). *From Restructuring to Stabilization: A Large-Scale
Experiment on Iterative Code Readability Refactoring with Large Language Models.* arXiv 2602.21833.
https://arxiv.org/abs/2602.21833
- GPT-5.1, 230 Java snippets, 5 rounds, 3 prompts: big changes first, then convergence; naming prompts can make names
  oscillate; each round broke under 1% of tests, at edge cases. The authors advise explicit stopping criteria.
- Here: [E] a consolidation pass converges fast; rerun tests after each round and stop when it only renames.

**14. Agentic refactoring.** Horikawa, Li, Kashiwa, Adams, Iida, Hassan (2026). *Agentic Refactoring: An Empirical
Study of AI Coding Agents.* TOSEM; arXiv 2511.04824v2. https://arxiv.org/abs/2511.04824
- 15,000 Java agent commits: 26.1% refactor; the top operations are renaming a variable (7.6%) and changing its type
  (6.8%); more low-level than humans (27.6% vs 24.4%); measured gains small, mostly from medium-level changes.
- Here: [I] point the consolidation pass at duplicates, long functions and forwarding layers, not names.

**15. LLM reviewers over-correct.** Jin, Chen (2026). *Are LLMs Reliable Code Reviewers? Systematic Overcorrection in
Requirement Conformance Judgement.* arXiv 2603.00539. https://arxiv.org/abs/2603.00539
- 5 models on HumanEval, MBPP, QuixBugs judged correct code non-conforming often; asking for explanations and fixes
  raised it (GPT-4o: 26.2% to 73.2% on HumanEval, 35.9% to 87.9% on MBPP).
- Here: [E] an LLM review is not evidence for reversing a settled decision; a failing test or a measurement is.

**16. GitClear (public summary only).** GitClear (2025). *AI Copilot Code Quality: 2025 Look Back at 12 Months of
Data.* https://www.gitclear.com/ai_assistant_code_quality_2025_research
- The page: 211M changed lines, 2020-2024; moved (refactored) lines fell from 25% (2021) to under 10% (2024),
  copy/pasted rose from 8.3% to 12.3%. The full report sits behind an email form and was not read; the figures are
  industry-wide trends, not lines attributed to AI. GitClear's 2026 report was only found in secondary coverage.
- Here: [I] duplication is a trend to check, not assume: He et al. found no change and Mao et al. less cross-file copy.

Read but not used: Nakashima et al., arXiv 2602.04226, and Peralta et al., arXiv 2605.22534, on rejected agent PRs.
Most rejections give no reason (67.9%) or are workflow, not agent failure (only 35.7% are), so they say little on size.

## The earlier counters, checked

| Counter | Verdict |
|---|---|
| Short hand-written agent files help, long or generated hurt | Corrected: hand-written beat generated and generated cost ~20% [E 3]; length had no measured effect [E 3]; brevity is [J] with weak [I 6] |
| Runnable checks | Confirmed [E]: agents run named tools (3); prompts don't stop drift (1) |
| Search by behaviour before writing a helper | Aim confirmed [E 1, 2, 11]; searching by behaviour rather than name is [J] |
| Keep structure and behaviour commits apart | [J]: no 2024-2026 source tested it; kept as a review aid |
| No speculative generality | Confirmed in part [E 1, 2, 11]: wrappers, extra helpers and deeper layers are the measured excess |
| Consolidation passes | Confirmed, sharpened [E 1, 13, 14]: measured, aimed at structure, stopped at convergence |
| Revert after two failed fixes | Confirmed [E 12]; sharpened: restart from the problem, not the attempts |
| Reverse a decision only with evidence | Confirmed [E 15]: an LLM's objection is not evidence |
| Clarity over brevity | [J]; consistent with 1 and 2 (bloat is clones and structure, not characters); packing is measured nowhere |
| Report net lines of code | Confirmed as a signal [E 7, 8]: a cost to justify, not output |
| Added: extract before growing the longest function | [E 1] |
| Added: passing tests is not done | [E 9, 10] |

## Checks

All commands run from the repo root; each was run here on 2026-11-02 unless marked unverified.

**1. Net lines per change** [E 7, 8]. Say the net in the report or PR, excluding generated code:

```sh
git diff --numstat main...HEAD -- '*.swift' '*.rs' ':!apps/macos/TeXLocal/Models/Wire.swift' \
  | awk '{a+=$1; d+=$2} END {printf "+%d -%d net %+d\n", a, d, a-d}'
git log --format='%h %s' --shortstat main..HEAD   # per commit
```

**2. Search before writing a helper** [E aim; J method]. Search for what the helper would call or produce, then for
names, then read the hits; same name doesn't mean same job (`fn range` in `texlocal-latex/src/syntax/` is three
different trait impls), and different names can do one.

```sh
rg -n --type swift 'replaceContents\(with' apps/macos          # by the API the helper would call
rg -n --type rust 'char_indices\(\)' crates                     # by the operation
rg -n --type swift '^\s*((private|fileprivate|static|override|@objc|@MainActor|nonisolated|final)\s+)*func \w+' apps/macos/TeXLocal
rg -n --type rust '^\s*(pub(\([a-z]+\))?\s+)?(const\s+)?(unsafe\s+)?fn \w+' crates
rg -n --type swift '^extension ' apps/macos/TeXLocal            # where shared helpers live
rg -nw 'helperName' apps crates                                 # its callers, before and after
```

**3. Duplication: jscpd 4.3.0** [I 1, 16]. Verified via the npx cache (`--offline` fails rather than downloads;
installing it is a download to ask about). Baseline at 50 tokens: Rust 6 clones, 34 lines (0.16%) in 93 files; Swift
none in 79 files. A new clone after a feature is a review question. Token clones only, not same-behaviour code.

```sh
npx --offline jscpd@4.3.0 --min-tokens 50 --reporters console --format swift,rust apps/macos/TeXLocal crates
```

**4. Dead code** [E 11]. Swift: Periphery 3.8.0 (Homebrew), verified; first run builds the app, later runs take about
12 s. Baseline: 152 findings, 146 of them assign-only fields in the generated `Wire.swift`; the other 6 are intended
(`init(coder:)` overrides, held observer tokens, unused action parameters). Rust: `dead_code` is on by default but
skips `pub` items; `cargo shear` (CI) finds unused dependencies.

```sh
periphery scan --project apps/macos/TeXLocal.xcodeproj --schemes TeXLocal --relative-results --quiet \
  --report-exclude '**/Models/Wire.swift' -- CODE_SIGNING_ALLOWED=NO
```

**5. Clippy beyond `tools/check.sh`** [I 1, 7, 11]. Hits counted on this workspace with clippy 0.1.99:
- Worth adding to `[workspace.lints.clippy]` (few hits now): `match_same_arms` (0), `redundant_else` (0),
  `unnecessary_wraps` (2: private functions that always return `Ok`/`Some`), `too_many_lines` (3 over 100 lines,
  erosion's shape).
- On demand, against a change: `single_call_fn` (168 workspace-wide, so never as `-D`) lists one-caller functions;
  `needless_pass_by_value` (14).
- Not worth it: `unreachable_pub` (262) and `redundant_pub_crate` (204) contradict each other; `similar_names` (12) and
  `module_name_repetitions` are naming noise; `cognitive_complexity`, whose own docs now disown the metric.

```sh
git diff --name-only main...HEAD -- '*.rs' > ${TMPDIR:-/tmp}/changed
cargo clippy --workspace --all-targets --message-format short -- -W clippy::single_call_fn -W clippy::too_many_lines \
  2>&1 | grep -F -f ${TMPDIR:-/tmp}/changed   # filters by file; read only the functions you added
```

**6. Before adding a branch to a long function** [E 1; J method]: in Rust, `too_many_lines` above; in Swift no
complexity tool was verified here (lizard covers Swift and Rust but isn't installed; unverified), so read its length
and extract the part you touch first.

**7. Done means the diff reads right, not only that tests pass** [E 9, 10]. Read `git diff main...HEAD` for edits
outside the task, code the tests don't reach, and the repo's conventions, then run `zsh tools/check.sh`.

**8. When to stop and revert** [E 12, 13; J thresholds]. Two fixes for one symptom have failed: reset to the last good
commit and start again from the problem statement and a note of what failed, not from the failed diff. In a
consolidation pass: stop once a round only renames, or as soon as a test breaks.

**9. Reversing a settled decision** [E 15]. Needs a failing test, a measurement, or a side-by-side with the Apple app;
an LLM review that calls code wrong is not enough.

**10. Changing AGENTS.md** [E 3; I 5, 6]. Add only what the code, README and tools don't already say: commands and
non-standard conventions, most important first, no overviews. Delete a line for each one added.
