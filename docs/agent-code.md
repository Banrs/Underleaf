# Why agent-written code runs long

This is the research behind AGENTS.md's "Writing code" rules, gathered on 2026-10-19 for the October
concise pass (`docs/audit-2026-10.md`). Most of it is preprints from 2025–2026.

## What the studies found

**SlopCodeBench** (Orlanski et al., [arXiv 2603.24755](https://arxiv.org/abs/2603.24755))
- **Setup:** 15 coding agents extended their own solutions over 36 problems and 196 checkpoints.
- **Two measures:**
  - *Verbosity*: the share of lines flagged by 137 AST-grep rules or found to be structural clones.
  - *Erosion*: the share of complexity mass (cyclomatic complexity × √lines) that sits in functions
    with a complexity above 10.
- **Against 473 human Python repositories:** agents score 0.44 verbosity and 0.68 erosion, humans
  0.19 and 0.34. That is 2.3 and 2.0 times as much.
- **Over time:**
  - Agents get worse with each checkpoint: erosion rises in 77% of trajectories and verbosity in
    75.5%. Per checkpoint, verbosity grows about 7 times as fast as in the human median, and erosion
    about 5 times.
  - Human repositories erode too, in 53% of cases, only more slowly.
- **Why it grows:** agents patch new logic into the functions that exist instead of splitting it out,
  and early choices carry forward.
  - One `main()` went from complexity 13 to 92, and from 38 to 240 lines, over eight checkpoints. It
    dropped argparse for a hand-written flag loop, with the same two-branch block copied for each
    flag.
- **What they counted as verbose:**
  - lists rebuilt by hand where a filter would do;
  - empty checks guarding each loop iteration;
  - variables used once;
  - duplicated structure.
- **Prompts:**
  - An "anti-slop" prompt (no needless defensive checks or try/catch, single-use variables,
    comments no person would write, trivial wrappers, deep nesting, if/else ladders or piles of
    helpers) cut starting verbosity by 27–36% and erosion by 34–58%.
  - A plan-first prompt helped less.
  - Both cost about 12% more and solved slightly fewer checkpoints.
  - Neither changed the rate of decline: about 1.3 points per checkpoint.

**TRIM** (Mathai et al., [arXiv 2607.18161](https://huggingface.co/papers/2607.18161))
- Agents keep the edits from attempts they abandoned, including speculative changes and dead
  hypotheses. The paper calls this "CodeSlop": edits that can go without changing what the fix does.
- Replaying the trajectory and removing every edit the tests don't need cut patches by 17.9–32.9%
  across four agent scaffolds. On SWE-bench Verified it changed 20% fewer files, and 327 of the 330
  fixes still passed.
- Asking the model to minimise its own patch failed in 3.8–44.9% of cases.

**More Code, Less Reuse** (Huang et al., MSR 2026, [arXiv 2601.21276](https://arxiv.org/abs/2601.21276))
- Agents' pull requests pass over chances to reuse code, so they are more redundant than people's.
- Reviewers still react to them as well as or better than to people's: the code looks plausible.

**Show and Tell** (Bohr, [arXiv 2511.13972](https://arxiv.org/abs/2511.13972))
- Models drift towards correct but verbose code, with long documentation and defensive patterns.
- Rules plus a short example compressed most and held up best when the code was revised. Examples
  alone didn't hold.

**GitClear 2025** ([DevClass's report](https://devclass.com/2025/02/20/ai-is-eroding-code-quality-states-new-in-depth-report/))
- 211 million changed lines, 2020–2024.
- In 2024, copied lines outnumbered moved ones for the first time: moved lines, the sign of
  refactoring, fell 39.9%. Duplicated blocks of five lines or more rose eightfold.
- GitClear's reading: an assistant makes inserting a block easy and rarely proposes reusing a
  function elsewhere. GitClear sells code-review tools, and these are its own measures.

**Smaller findings**
- Models write correct but over-engineered code, with extra steps and roundabout control flow
  ([arXiv 2605.13280](https://arxiv.org/pdf/2605.13280)).
- Agents add mocks to tests more often: 36% of agents' commits against 26% of others'
  ([arXiv 2602.00409](https://arxiv.org/abs/2602.00409)).
- Comments that say little cost an agent input tokens without changing what it does. Some comments
  do steer where it looks ([arXiv 2605.20049](https://arxiv.org/pdf/2605.20049)).

## What it means here

The causes come in two kinds.

**From the start, before any iteration:**
- a default style of long docs, defensive checks and wrappers;
- new code written instead of reusing what exists;
- leftovers from exploration;
- tests at several levels.

**Compounding with each change:** logic patched into existing functions, and generality kept after
its use is gone. The October audit found every one of these in this code base:
- server-era commands and options no host sets;
- two readers for one shape;
- one rule tested at three levels.

What works, from the studies and the October pass:
- **Rules lower the start but not the slope.** So every change deletes as well as adds, and the diff is
  read for leftovers before committing. AGENTS.md has the rules.
- **Measure.** Count lines per commit, and keep tests in the crate, where rustc's dead-code lint finds
  code that only tests use.
- **Delete by owner.** First a read-only audit that names each candidate with its evidence, then cuts
  by file owner, each change built and tested where the toolchain allows.
- **Choose the model by task:**
  - Haiku for mechanical work;
  - Sonnet at medium for ordinary work;
  - Opus at medium or high for refactors across files and edits that can't be compiled where they are
    made;
  - higher effort only when a task needs it.
- **Remember humans erode too.** The rules hold for every change, whoever writes it.
