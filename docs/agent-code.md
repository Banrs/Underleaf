# Why agent-written code runs long

The findings behind AGENTS.md's "Writing code" rules, which carry the practice. Most are
preprints from 2025–2026.

- **SlopCodeBench** ([arXiv 2603.24755](https://arxiv.org/abs/2603.24755)): 15 agents extending
  their own code over 196 checkpoints score 0.44 verbosity and 0.68 erosion against 0.19 and 0.34
  in 473 human repositories, and grow worse with each change, about 5–7 times as fast as people.
  They patch logic into existing functions; the verbose code is hand-built lists, empty checks,
  single-use variables and duplicated structure. An "anti-slop" prompt cut starting verbosity by
  27–36% and erosion by 34–58%, but not the rate of decline.
- **TRIM** ([arXiv 2607.18161](https://huggingface.co/papers/2607.18161)): agents keep edits from
  abandoned attempts; removing every edit the tests don't need cut patches by 18–33% with 327 of
  330 fixes still passing. Asking the model to minimise its own patch often failed.
- **More Code, Less Reuse** ([arXiv 2601.21276](https://arxiv.org/abs/2601.21276)): agents'
  pull requests pass over reuse, and reviewers accept them as readily, since the code looks plausible.
- **Show and Tell** ([arXiv 2511.13972](https://arxiv.org/abs/2511.13972)): rules with a short
  example compressed most and held up best under revision.
- **GitClear 2025** ([report](https://devclass.com/2025/02/20/ai-is-eroding-code-quality-states-new-in-depth-report/)):
  in 2024 copied lines outnumbered moved ones for the first time; duplicated blocks rose eightfold.
  GitClear sells review tools and these are its own measures.
- Models over-engineer correct code ([arXiv 2605.13280](https://arxiv.org/pdf/2605.13280)), add
  mocks more often ([arXiv 2602.00409](https://arxiv.org/abs/2602.00409)), and comments that say
  little cost tokens without changing what an agent does ([arXiv 2605.20049](https://arxiv.org/pdf/2605.20049)).
- Context files such as AGENTS.md add over 20% to an agent's cost for no gain unless they hold
  only minimal requirements (ETH Zürich, 2026).

Rules lower the start but not the slope, so every change deletes as well as adds and the diff is
read for leftovers. People's code erodes too, more slowly.
