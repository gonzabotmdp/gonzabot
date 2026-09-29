# Contributing

gonzabot started as a single-cluster tool (IFIMAR, CONICET/UNMDP) and is published
here in case it's useful elsewhere. Contributions are welcome, with one thing worth
understanding up front: **the code is portable, the `context/*.txt` files are not.**

## What's portable vs. site-specific

- `gonzabot` (the script itself): the CLI, the lints (`_fix_sbatch`,
  `_lint_filesystem`, etc.), `/branch`, `/diagnose`, `/run`, Tab-completion — all of
  this is generic. Bug fixes and new lints here are directly useful to anyone
  running gonzabot, regardless of their cluster.
- `context/*.txt`: these encode *this specific cluster's* real Spack hashes,
  partition names, filesystem layout, and installed software. They're published as
  a worked example of the format, not something another site can use as-is. If
  you're adapting gonzabot to your own cluster, you'll rewrite these — the segmented
  structure (one file per software family, loaded only when relevant) is the part
  worth keeping.

## Reporting a bug

Open an issue. Include what you asked gonzabot, what it generated or did, and what
you expected instead. If it's a lint false-positive/negative, the exact `sbatch`
snippet that triggered (or should have triggered) it is the most useful thing you
can paste in.

## Proposing a change

1. Fork, branch, make the change.
2. Run `./gonzabot --selftest` — it must pass (100+ deterministic checks, no live
   Slurm/vLLM required). CI runs this on every PR.
3. If you added a lint or fixed a bug, add a `_t(...)` case for it in `_selftest()`
   near the related tests — this codebase treats "found a real bug, fixed it, but
   didn't add a regression test for it" as an incomplete fix.
4. Open a PR describing what broke and how you found it (a real repro beats a
   hypothetical one).

## What's likely to be accepted

- Fixes to lints that produce a wrong warning, or fail to catch something they
  should.
- New deterministic lints for a class of bug you actually hit (not speculative
  ones).
- Portability improvements to the Python code (removing accidental couplings to
  this cluster's layout, like the one CI's stub-file step works around).
- Documentation fixes.

## What's less likely to be accepted as-is

- Changes to `context/*.txt` content (see above — these are IFIMAR-specific by
  design, though a genuinely generic *pattern* worth generalizing is welcome to
  discuss).
- New runtime dependencies. gonzabot is stdlib-only Python on purpose (nothing to
  install on a cluster login node you don't control).
