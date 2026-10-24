# Why agent-written code runs long

The evidence behind AGENTS.md's "Writing code"; most of it is 2025–2026 preprints.

- **SlopCodeBench** ([arXiv 2603.24755v2](https://arxiv.org/abs/2603.24755v2)): agents extending
  their own code score 0.44 verbosity and 0.68 erosion against 0.19 and 0.34 in human repositories,
  and worsen 5 to 6.6 times as fast as people with each change: logic patched into existing functions,
  hand-built lists, empty checks, single-use variables, duplicated structure. An "anti-slop" prompt
  lowered the start by 27–58% but not the rate of decline.
- **TRIM** ([arXiv 2607.18161](https://huggingface.co/papers/2607.18161)): agents keep edits from
  abandoned attempts; removing every edit the tests don't need cut patches by 18–33% with 327 of
  330 fixes still passing. Asking the model to minimise its own patch often failed.
- **RECAP** ([arXiv 2608.13292](https://arxiv.org/abs/2608.13292)): a refinement pass over the
  finished work beats asking for small patches as it goes.
- **More Code, Less Reuse** ([arXiv 2601.21276](https://arxiv.org/abs/2601.21276)): agents' pull
  requests pass over reuse, and reviewers accept them as readily.
- **Show and Tell** ([arXiv 2511.13972](https://arxiv.org/abs/2511.13972)): rules with a short
  example compressed most and held up best under revision.
- **GitClear 2025** ([report](https://devclass.com/2025/02/20/ai-is-eroding-code-quality-states-new-in-depth-report/),
  a vendor's own measures): in 2024 copied lines outnumbered moved ones; duplicated blocks rose
  eightfold.
- Models over-engineer correct code ([arXiv 2605.13280](https://arxiv.org/pdf/2605.13280)) and add
  mocks more often ([arXiv 2602.00409](https://arxiv.org/abs/2602.00409)). About 60% of the
  assertions they add later re-test branches already covered
  ([arXiv 2603.01409](https://arxiv.org/abs/2603.01409)). Comments that say little cost tokens
  without changing what an agent does ([arXiv 2605.20049](https://arxiv.org/pdf/2605.20049)).
- Context files such as AGENTS.md add over 20% to an agent's cost for no gain unless they hold
  only minimal requirements ([arXiv 2602.11988](https://arxiv.org/abs/2602.11988)).

Rules lower the start, not the slope: every change deletes as well as adds, and its diff is read for
leftovers.
