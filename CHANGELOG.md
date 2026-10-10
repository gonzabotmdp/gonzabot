# Changelog

All notable changes to gonzabot are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Dates are when the change went
into production on the IFIMAR cluster.

## [Unreleased]

## [1.7.0] - 2026-10-09

### Added
- Natural-language job submission: after gonzabot generates a job, saying
  "mandalo a la cola" / "sometelo" / "lanzalo" (or including that in the
  original request) offers to submit it. All files of the answer (input,
  scripts, sbatch) are saved to `~/gonzabot-jobs/<timestamp>/` and the sbatch
  is submitted from there, so sibling files really exist; a `cp
  "$SLURM_SUBMIT_DIR"/<file> .` is injected after `cd $WORKDIR` for sibling
  files the sbatch uses but does not create. Always asks `[s/N]` first, and the
  submitted job ID is added to the conversation context (previously the bot
  asked the user for the ID of a job it had just submitted).
- LAMMPS knowledge: canonical fcc template for pure metals (no hand-made
  `.data` files, no invented `potential` command, one atom type) and the rule
  that a wall-clock request ("10 minutes") is a `--time` limit plus `timer
  timeout`, never "N steps".

### Fixed
- Reasoning leak on vLLM 0.30: the model sometimes emits a literal
  `<think>...</think>` (with a leading space) inside `content`, which the
  `glm45` parser does not recognise. New `_ThinkFilter` splits that block
  into reasoning on the client, streaming-safe. Verified on the real bot with
  the exact request that used to leak (2/2 clean).
- Auto-execution of "read-only" blocks ran any text marked as bash whose
  first word was not on the deny-list, e.g. a LAMMPS input printed as
  `/bin/sh: units: not found`. The first word of every line must now be a real
  executable or shell builtin.
- vLLM server upgrade (production moved from 0.10.2 to 0.30.0, single engine):
  the `<think>\n` prefill trick needed by 0.10.x is now applied only when
  `GET /version` reports a server older than 0.20 (`_server_needs_think_prefill`);
  on newer servers it made the reasoning parser leak or return empty content.
- Context: GPU node driver is 580.178.04 on both nodes (CUDA 13 supported,
  `cuda@13.0.2` validated; 12.6.2 still preferred for compiling); R/Spack hash
  updates (r-makurhini) and the corrected `gonzabot-watcher.sh` (never submits a
  second vLLM job) synced from production.
- Spack hardening (the most requested topic), all deterministic post-processing
  in `_fix_sbatch`, each with selftests:
  - `spack load --sh X` written bare (no `eval`) does nothing; it is now wrapped
    in `eval $(...)` and the spack `setup-env.sh` lines are added if missing.
  - Aliases from `preferred-hashes.conf` (`lammps-cpu`, `lammps-gpu`, bare
    `lammps`, ...) only resolve in login shells; inside batch jobs they fail
    ("matches no installed packages" / ambiguous). They are rewritten to
    `/hash` (read from the live conf file; interactive use is left untouched).
  - GROMACS sbatch without environment: `GROMACS_DIR`/`OMPI_DIR`/`PATH` are
    injected (CPU jobs); relative input files are copied from
    `$SLURM_SUBMIT_DIR` after `cd $WORKDIR`; `$SPACK` used but never defined
    is defined before first use.
  - Context: never "module load" / `~/.bashrc` advice (core rule), mpi4py via
    its env file (bare `py-mpi4py` is ambiguous), geopandas documented as not
    installed, R packages (ggplot2, dplyr, sf, ...) must be loaded with
    `spack load` next to R (the old `R_LIBS` recipe only exposed base R), and
    `tidyverse` is not installed.
  - sbatch with `mpirun`/`mpiexec` that never loads OpenMPI (fails on the
    node with `mpirun: command not found`): the OpenMPI environment is injected.
  - sbatch in a `gpu*` partition without `--gres`/`--gpus` (job lands on a GPU
    node with no GPU assigned): `#SBATCH --gres=gpu:1` is added.
- Lost opening code fence: the `glm45` parser sometimes swallows the opening
  "```bash", which left the whole sbatch as one collapsed paragraph that
  skipped the post-processor. A bare `#!/bin/bash` / `#SBATCH` script is now
  re-fenced deterministically before rendering.
- Natural-language submission also understands "en un nodo" / "en el
  cluster" ("corrélo en un nodo"), and when a job is complete (real sbatch, no
  placeholders left to fill) the bot proactively asks "¿Lo mando a la cola?
  [s/N]".

### Tests
- `--selftest` grows from 212 to 246 checks. An out-of-tree evaluation set
  (30 real user requests, automatic checks for bash syntax, live Spack
  hashes, ambiguity and style) measured 91% -> 96% passing on the
  OpenMPI fix.

## [1.6.0] - 2026-10-08

### Added
- Phase 1 of internationalization ("no me quiero encerrar en español"):
  gonzabot can now run in English as well as Spanish (`_SUPPORTED_LANGS =
  ("es", "en")`). Only the model's own output is translated in this phase --
  the Spanish-language `context/*.txt` knowledge base is left untouched
  (GLM-4.5-Air reads Spanish context fine while answering in English), and
  Spanish-coupled deterministic heuristics (`_RE_SPANISH_PROSE`, etc.) are
  deliberately left for a later phase.
- `/lang` command (`/lang`, `/lang es`, `/lang en`) to switch language at
  runtime without restarting.
- `_detect_console_lang()`: resolves language as `GONZABOT_LANG` env override
  > `$LANG`/`$LC_ALL` (first 2 chars) > `_SITE_DEFAULT_LANG`. Initially
  designed as true per-session auto-detection, but live investigation (8/10)
  found that doesn't actually work over SSH: this cluster's `sshd_config` has
  no `AcceptEnv LANG`/`LC_*`, so the client's own locale never reaches the
  session, and the system locale is `C.UTF-8` for every user regardless of
  their own machine's language. `_SITE_DEFAULT_LANG` is therefore a
  deployment-level knob, not a per-user setting: it's `"es"` for IFIMAR/UNMDP
  specifically, and a cluster installing gonzabot elsewhere (e.g. an
  English-speaking site) changes that one constant (or sets `GONZABOT_LANG`)
  instead of relying on auto-detection to get it right.

### Fixed
- `/lang` (and any future slash command) could be correctly added to
  `_SLASH_CMDS` and `_KNOWN_SLASH_COMMANDS` and still silently fall through
  to the LLM as plain chat -- found live while testing `/lang` itself. Root
  cause: a third, previously-undocumented registry, a *local* `_KNOWN_CMDS`
  set rebuilt every main-loop iteration, is the actual gate that decides
  whether a `/command` enters the dispatch chain. Added `/lang` there too and
  commented the fragility in place so the next new command doesn't repeat
  this.
- Making `/lang en` actually produce English output took three separate,
  independently-verified fixes, not one -- each confirmed by sending the
  exact assembled prompt directly to the live vLLM endpoint, bypassing
  gonzabot's own client, before being judged sufficient:
  1. `_BASE_PROMPT_ES` itself contained a hardcoded "respond in whatever
     language the user writes in" instruction that directly contradicted
     English mode. Stripped via `_MIRROR_LANG_SENTENCE` when `_LANG != "es"`.
  2. `core.txt` (always-loaded context) separately hardcoded "Español
     rioplatense informal -- vos, dale, che", more specific/recent than (1)
     and still forcing Spanish on its own. Stripped dynamically in
     `_ctx_for_probe()` so `/lang` also works mid-session without a restart.
  3. Even with both of the above removed, the model's internal `<think>`
     reasoning still alternated roughly 50/50 Spanish/English at the
     cluster's real sampling settings (`temperature=0.3, top_p=0.8,
     top_k=20`) -- genuine sampling variance, not a leftover instruction
     (confirmed at `temperature=0` the model followed the directive 100% of
     the time). Fixed by repeating the English directive a second time as
     `_LANG_REMINDER_SUFFIX`, appended at the very end of the fully-assembled
     prompt to exploit LLM recency bias -- verified 6/6 English afterward at
     the cluster's real (non-zero) sampling settings, vs. ~50/50 before.
     Confirmed live in production: two real Spanish-language questions
     ("cual es la particion cpu/gpu del cluster") both answered fully in
     English, think-block included, with `/lang en` active.

20 new/updated `--selftest` checks (190 -> 210) across this work.

## [1.5.0] - 2026-10-08

### Added
- Persistent session working directory (`_SESSION_CWD`). Every auto-exec
  command used to run in its own isolated `subprocess.run()`, so a `cd`
  could never actually stick for the next command -- gonzabot would
  (correctly, but unhelpfully) say "I can't run this directly." `cd` is now
  intercepted before reaching the LLM, resolved against a real tracked
  directory, and applied as `cwd=` to every subsequent auto-exec call
  (both the user's own raw commands and whatever the model suggests), so it
  persists for the rest of the conversation like a real shell would.

### Fixed
- A command typed/pasted directly by the user (not a model suggestion) runs
  completely raw via `subprocess.run()`, with no `_is_readonly_query` gate.
  Live incident: `srun -p gpu nvidia-smi --format=csv,noheader,nounits, solo
  lectura, sin pedir confirmación` -- probably copied from an earlier
  suggestion with the explanation glued onto the same line -- got shell-run
  verbatim, and bash handed the trailing Spanish clause to `nvidia-smi` as
  literal arguments (`ERROR: Option solo is not recognized`). A real command
  on this cluster never uses "comma + space" between its own arguments
  (`--format=csv,noheader,nounits` is packed tight); that's now used as the
  signal to detect and cut off pasted prose. Initially this just blocked the
  command and asked for confirmation, but per live feedback ("tiene que
  correr la parte que anda porque sino no hace nada") it now strips the
  contamination and runs the real command automatically, falling back to a
  confirmation prompt only when no clean cut point can be found.
- `srun -p gpu nvidia-smi ...` without `--gres=gpu:N` can land in a context
  where no GPU is visible at all (`No devices were found`, exit code 6) due
  to cgroup isolation, even though the node has real GPUs. Added the same
  kind of automatic note the `nvidia-smi`/`nvtop` path already had, pointing
  at the missing flag instead of leaving the user to guess.

190+ new/updated `--selftest` checks across both fixes. Found via the exact
real conversation (not a synthetic test) where a user asked gonzabot to
check GPU resources.

## [1.4.2] - 2026-10-08

### Fixed
- `VLLM_BASE` was hardcoded to `gpu-01` for both the health check and the real
  chat-completion requests. Since inference can run on either GPU chassis
  (gpu-01 or gpu-02, depending on scheduling), a prod session would sometimes
  wait the full 5-minute startup timeout and report "Timeout esperando el
  servicio" even though the real service had come up healthy in under a
  minute -- just on the other node. Reported live ("ayer no cargaba"),
  confirmed from the actual job logs: the two sessions that failed landed on
  gpu-02, the two that worked landed on gpu-01. New `_resolve_vllm_host()`
  asks `squeue` (the controller, not slurmdbd) for the real running node
  before every health check, and updates `VLLM_BASE` in place once it
  confirms the service is healthy there -- so chat requests after that also
  go to the right place, not just the health check. No behavior change in
  dev mode.
- `/run` (no explicit `#REF` number) always took the literal last code block
  in a response, even when that block was just "how you'd run this"
  (`chmod +x script.sh && sbatch script.sh`) rather than the sbatch itself,
  which could sit one block earlier in the same response. Now searches
  backward for the last block that actually looks like a real sbatch
  (reusing `_looks_like_real_sbatch` from the 1/10 fix) before giving up.
- A generated script using `python3 << EOF` with `import numpy` (or
  pandas/scipy/matplotlib) sometimes skipped activating any environment at
  all -- `python.txt` documents the right `numpy.env` path, but the model
  doesn't always follow it (confirmed with two runs of the identical
  request: one included it, one didn't). The job would then fail with
  `ModuleNotFoundError`, confirmed to not be a gonzabot transmission bug by
  reproducing the exact same script by hand. New `_fix_missing_python_env()`
  in the `_fix_sbatch` postprocessor detects this pattern (no existing
  `source .../envs/*.env`, `spack load`, or venv/conda activation) and
  injects the right `source` line before the `python3`/`python` invocation.

All three found and fixed using a live test case ("multiply two random 10x10
matrices on a node, save all three in a PDF") run end-to-end 3 times in a
row until it produced a real, independently verified PDF (`np.allclose`
against the actual `.npy` arrays saved by the job, not just "the job exited
0"). 190/190 `--selftest`.

## [1.4.1] - 2026-10-04

### Fixed
- `_wf_reconcile()` called `subprocess.run(["squeue", ...])` with no handling
  for the binary not existing -- true on the cluster, but not on a GitHub
  Actions runner, which has no Slurm installed. The 1.4.0 release broke CI for
  exactly this reason: `--selftest` crashed with an uncaught `FileNotFoundError`
  (`FileNotFoundError: [Errno 2] No such file or directory: 'squeue'`,
  `gonzabot` line 469) instead of running its ~180 checks. Now catches
  `FileNotFoundError` and treats "can't even ask squeue" the same as "job's
  not in the queue anymore," falling through to the existing output-file-based
  completed/failed inference -- no behavior change on the real cluster, where
  `squeue` always exists. Added a regression test that monkeypatches
  `subprocess.run` to raise exactly this error and confirms `_wf_reconcile`
  recovers instead of propagating it.

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
