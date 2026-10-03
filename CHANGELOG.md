# Changelog

All notable changes to gonzabot are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Dates are when the change went
into production on the IFIMAR cluster.

## [Unreleased]

## [1.4.0] - 2026-10-03

### Added
- New `/workflow` command: persists multi-step task state across turns via a new
  `WORKFLOW_DB_PATH` SQLite file on the same NFS mount already proven safe for
  `history.db` (rollback-journal mode tolerates NFS; WAL does not).
- New `/segments` command: read-only introspection showing exactly which context
  segments would load for a given piece of text, and the resulting char/token
  estimate. Came out of a real question from Gonzalo ("podemos mejorar el árbol
  o es complicado para que vea cuál cargar") and has since been the main tool
  for diagnosing every trigger-regex gap below.
- `benchmarks` context segment split out of `core.txt` (which used to always load):
  now only loads when someone actually asks about records/TFLOPS, instead of
  being sent on every single request.

### Fixed
- `tutorial/vllm-service.sbatch`: the `vllm.jobid` tracking file had no self-healing
  against ending up owned by another user/root -- once that happened (real incident,
  2026-09-30), the job silently failed to write its own PID (`Permission denied` in
  the log, no visible error to the user). The heartbeat file already had this
  protection (`chmod 666` after every write); `vllm.jobid` didn't. Added `rm -f` +
  `chmod 666` around the write, matching the existing heartbeat pattern.
- `_DEV_MODE` compared the full host string against `http://gpu-01:8000/v1` instead
  of just the port. Once inference could run on either GPU chassis, a real prod
  session on `gpu-02:8000` got misclassified as dev purely because the host
  differed, and pointed the user at the wrong (dev/8001) recovery instructions.
  Reported live by Gonzalo: "si pones la s es imposible que vaya por 8001, algo
  no va." Now compares by port only (8000 = prod, anything else = dev).
- Auto-exec safety gating, found during a real end-to-end test ("multiplicación
  de matrices... cuando termine armame un latex"):
  - `_is_readonly_query` blocked every pipe unconditionally, so a model-suggested
    `ps -u gonzalo | wc -l` never ran and got hallucinated instead of executed.
    Now allows a pipe when every stage is read-only (`squeue`/`cat`/`sinfo` into
    `grep`/`wc`/`head`/`tail`), still blocks when any stage mutates
    (`| xargs scancel`) or edits in place (`sed -i`).
  - The model sometimes suggests a command as a bare line with no ` ``` ` fence;
    these were never picked up for the "run it?" prompt. Added detection for a
    bare line starting with a known real binary, still gated through the same
    `_is_readonly_query` check so a dangerous bare command isn't auto-offered.
  - A reasoning leak produced a fake single-line `free -h` table that happened to
    start with a known binary and no dangerous metacharacters, so it passed the
    readonly gate and nearly auto-executed as a literal (garbage) command. Added
    `_looks_like_reasoning_leak`, which recognizes internal-monologue phrasing
    ("el usuario... debo/debería ejecutar...") and blocks auto-exec from a
    response shaped like that. Initially only caught "debo"; a separate leak on
    a CUDA-version question used "debería" and slipped through, so both are
    now covered.
  - `/workflow`'s trigger picked an `echo '...#SBATCH...'` demonstration block
    instead of the real sbatch block, because both blocks merely *contained* the
    substring `#SBATCH`. Submission failed with "No partition specified" since
    the echo's literal first line wasn't an actual shebang. `_looks_like_real_sbatch`
    now requires a real shebang as line 1 and directives on their own lines, not
    just a substring match anywhere in the block.
  - A real ` ```python ` block (with working numpy code) was auto-executed as a
    shell command, because the auto-exec loop never checked a block's declared
    language before running it. `_is_shell_block` now only treats
    bash/sh/shell/no-language as shell; python/tex/c/etc. are excluded.
- GLM-4.5-Air reasoning leak on the newer vLLM engine (0.30.x): its parser can
  fail to close `<think>` and stop generating early, leaving the OpenAI-style
  `content` field empty while the real text -- including any generated script --
  lands in the renamed `reasoning` field (`reasoning_content` in older vLLM).
  `stream_response()` now has a rescue path: when `content` comes back empty but
  `reasoning` has real text, it recovers the text and re-extracts code blocks
  from it instead of silently returning nothing.
- `_RE_PYTHON` (the trigger deciding whether `python.txt`, with the correct
  `numpy.env` path, gets loaded) missed two real phrasings that never say
  "python"/"numpy" but clearly need it: "calculá la integral ... numéricamente"
  and "2 matrices aleatorias de 10x10". Both times the segment didn't load, the
  model hallucinated its own env file path instead of the documented one. Added
  numeric-method and linear-algebra trigger words. Deliberately did NOT add a
  bare "array" trigger: that collides with Slurm job arrays
  (`#SBATCH --array=1-N`, documented in `core.txt`) and would load `python.txt`
  for job-array questions that have nothing to do with numpy -- the same context
  dilution that originally forced `python.txt`/`sci-tools.txt` apart. Verified
  live with `/segments` both ways before and after.

## [1.3.3] - 2026-09-30

### Added
- New `power-save` context segment, from softadm's cluster-wide green computing work
  (28-29/9): symmetric `AllowQos` across GPU partitions, daily-rotating node `Weight`
  for consolidation, and native Slurm power-save (`SuspendTime=1800`, nodes woken
  on-demand). gonzabot can now explain a real, measured startup delay (~3.5-4.2 min
  waking a powered-down node vs. ~1s on an already-on one) instead of a user assuming
  their job hung. A short pointer also went into `core.txt` (always loaded) since "why
  is my job slow" is common enough phrasing that the segment's own trigger keywords
  might not always catch it.

## [1.3.2] - 2026-09-29

### Fixed
- A user checking the published `tutorial/vllm-service.sbatch` against the live
  service found it still showed the pre-migration Qwen2.5-72B-Instruct-AWQ
  config instead of the current GLM-4.5-Air one. Prompted a full from-scratch
  audit of every published file rather than just that one:
  - `tutorial/vllm-service.sbatch` rewritten to match the real running config
    (current spack-2026b CUDA path, `--reasoning-parser glm45`,
    `--enable-expert-parallel`, `HF_HUB_OFFLINE`/`TRANSFORMERS_OFFLINE`).
  - Both tutorial READMEs updated: the Qwen model was presented as current
    production instead of superseded history.
  - `tutorial/spack-load-wrapper.txt`: activation path pointed at
    `/usr/share/spack/setup-env.sh`, dead since the spack-2026b migration.
  - `tutorial/slurm-mail-notifications.txt`: referenced `context/hpc.txt`,
    renamed to `core.txt` a while back.
  - More seriously, the same audit found this wasn't just stale docs: the code
    path that auto-fixes multi-node scripts (LAMMPS, and module-load aliases
    for CASA/GSL/CUDA/AOCC/ADIOS2/ROOT) was hardcoding the same dead
    `/usr/share/spack/root/...` store and generating
    `spack --no-locks location -i`, a flag spack 1.2.2 no longer has (renamed
    to `--disable-locks`). Any script actually run through that auto-fix would
    have failed against a spack binary and package hashes that don't exist
    anymore. Fixed in code, not just examples — 118/118 selftest still passes.

## [1.3.1] - 2026-09-29

### Added
- CI: `--selftest`'s 100+ deterministic checks now run automatically on every push
  and PR via GitHub Actions, with a status badge on both READMEs. Three checks that
  intentionally verify real paths on the IFIMAR cluster still exist are satisfied
  with stub files in CI, documented inline so a future check doesn't silently break
  the pipeline.
- `CONTRIBUTING.md`, explicit about what's portable (the Python code) vs.
  site-specific (`context/*.txt`, which encodes this cluster's real
  hashes/paths).
- `SECURITY.md` with a real scope (command injection surface, `/run`'s sbatch
  submission, `/load` path handling) rather than boilerplate.
- Issue templates (bug report, feature request), a PR template, `.gitignore`.
- Release badge on both READMEs, linking to the tagged GitHub releases.

## [1.3.0] - 2026-09-29

### Added
- Tab-completion for recognized shell commands and `/`-commands in the interactive
  prompt — single match completes with a trailing space, ambiguous prefixes extend
  to the longest common prefix.
- `/run [N]`: submits the sbatch gonzabot just generated, the last code block by
  default or a specific `#REF N`. This was listed in the command reference for a
  while but never had a real handler — defined for the first time here, reusing
  the same submission path as the existing paste-and-type-"s" quick-submit.
  Refuses to run a block with no `#SBATCH` directives.
- `CHANGELOG.md` and tagged GitHub releases (this is the first entry using that
  workflow) — before this, downstream installs had no way to learn about updates
  short of a direct message.

## [1.2.0] - 2026-09-28

### Added
- Verified LAMMPS CPU→GPU conversion checklist in `md-sim.txt` (partition/gres/WORKDIR
  changes, `-sf gpu -pk gpu N`, and which pair styles actually support `/gpu` in this
  build) — tested end-to-end with a real run on an A100 before documenting it.
- Deterministic lint for `#SBATCH --workdir=...`/`--chdir=...` with shell variables —
  those directives are parsed by Slurm before any shell exists, so `$SLURM_JOB_ID`
  never expands. Previously only documented as prose.
- Deterministic lint for `source <file>.env` where the file exists on disk but is
  known to point at a dead Spack store (`os.path.exists()` alone can't catch this).
- Deterministic lints for a backgrounded job command (`&`) with no matching `wait`,
  and for `spack load` used while the `setup-env.sh` source line is commented out.
- Deterministic lint for a Spack hash assigned to a variable without its leading
  `/` and then used via `location -i $VAR` (an indirection the existing
  no-leading-slash lint didn't trace).
- New `--qos` REGLA ABSOLUTA: always emit an explicit QOS in generated
  `salloc`/`sbatch`, instead of silently relying on the Slurm default.
- `/diagnose` now recognizes the Munge "108 bytes" socket-pathname error and
  explains the real cause (a kernel `sockaddr_un` limit) instead of guessing.

### Changed
- Split `python.txt` into `python.txt` (Python packages only) and a new
  `sci-tools.txt` (gnuplot, Grace, ParaView, OVITO, PyCharm, R, GSL, ADIOS2,
  Apptainer, MPICH, GDAL, AOCC, Rust, LaTeX) — loading the full combined file for
  an unrelated question (e.g. gnuplot) was pushing requests into the context range
  where GLM-4.5-Air's reasoning leaks into the visible response (see
  [vllm-project/vllm#29763](https://github.com/vllm-project/vllm/issues/29763)).
  Reproduced the leak 3/3 times before the split, 0/3 after, for the same query.
- The reasoning-leak detector's own advice used to always suggest `/compact`,
  which does nothing in a fresh session with little history. It now checks for
  that case and suggests something that actually helps.
- `/branch`: relative file arguments are now resolved to absolute paths before
  building `WORKDIR`/`BRANCHDIR` (a bare `.` was leaking into the generated sbatch).
- `/branch`: the diff-block extractor now tolerates a trailing unclosed
  ` ```diff ` fence instead of silently dropping that branch with no warning.

### Fixed
- Several stale Spack hashes across `core.txt`/`python.txt`/`md-sim.txt`/
  `dft-qe.txt` that had gone dead after rebuilds, found by auditing every
  documented hash against the live store instead of trusting the docs.
- Simplified several packages (AOCC, MPICH, py-mpi4py, GDAL, py-rasterio,
  py-numba, NCCL) from hash-pinned to bare package-name resolution, after
  confirming each resolves unambiguously — removes a class of future staleness.

## [1.1.0] - 2026-09-15

### Added
- Bioacoustics segment (PAMGuard — first Maven/Java package in the stack).
- Lint catching GUI applications (PAMGuard, CASA viewer tools) submitted inside a
  batch `#SBATCH` script instead of an interactive session with a display.
- Lint catching hallucinated absolute paths invoked directly instead of the
  `spack load` + bare-command pattern.
- "Upstream contributions" section in both READMEs, documenting real PRs merged
  into `spack/spack-packages`, `potfit/potfit`, and `tensorflow/tensorflow`
  found while packaging this cluster's software stack.

### Fixed
- `/diagnose` no longer hallucinates a scavenger-preemption explanation for jobs
  that failed for an unrelated reason.
- A gzip/`.npz` lint that let a corruption bug through.
- Several stale context notes caught during a routine audit.

## [1.0.0] - 2026-08-30

Initial public release.

### Added
- Core assistant: reviews `sbatch` scripts and interactive requests against the
  cluster's real Slurm/Spack configuration before they run, combining
  deterministic lints with an LLM (GLM-4.5-Air, migrated from
  Qwen2.5-72B-Instruct-AWQ this release — see README for the comparison).
- Context split into topic segments (`core`, `spack`, `md-sim`, `dft-qe`,
  `particle-physics`, `gpu-custom`, `genomica`, `casa`, `otros-lang`, `python`),
  each loaded only when its keywords are actually relevant to the request.
- `/load`, `/save`, `/diff`, `/edit`, `/diagnose`, `/branch`, `/audit`, `/queue`,
  `/history`, `/model`, `/run`, `/help`.
- Multi-language docs (README + tutorial in English and Spanish).
