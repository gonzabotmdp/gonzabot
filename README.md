# gonzabot

**English** | [Español](README.es.md)

![license](https://img.shields.io/badge/license-MIT-blue) ![python](https://img.shields.io/badge/python-3%20stdlib%20only-green)

AI assistant for users of an HPC cluster (Slurm + Spack), built to catch
configuration mistakes, resource misuse, and oversized resource requests in
`sbatch` scripts **before** the job runs and fails or wastes compute hours.

Runs on a local model via [vLLM](https://github.com/vllm-project/vllm) —
in production with **GLM-4.5-Air** since 2026-08-30 (previously
Qwen2.5-72B-Instruct-AWQ, see the "Model comparison" section below for why
we migrated) — with no external Python dependencies beyond the standard
library.

Developed and used in production on the HPC cluster at IFIMAR (CONICET /
UNMDP, Argentina).

## Motivation

On a shared HPC cluster it's common to lose compute hours to avoidable
mistakes: `--mem`/`--time` misjudged, environment variables that resolve
wrong inside a script, mis-configured parallelism (`--ntasks` that doesn't
match the program's real parallelism), relative paths that break when
moving to a temporary work directory, etc. gonzabot talks with the user in
natural language, understands their script and intent, and suggests the
corrected `sbatch` — citing the reason for each change.

## Measured results

Real cases from cluster users, comparing execution time before and after
applying gonzabot's suggestion (same node, same data):

- LAMMPS (sequential parameter sweep → job array): **~2.7x** faster.
- Quantum ESPRESSO/`ph.x` (phonons, `--ntasks` not scaled with `-nimage`):
  validated for real — scaling up `-nimage` without proportionally scaling
  `--ntasks` ended up being **44% slower**, not faster (nimage 4 → 27.1
  min, nimage 8 with the same `--ntasks` → 39.2 min).

Real example — we asked gonzabot live (fresh session, response shown
unedited) how to parallelize a phonon calculation with `ph.x -nimage 4`.
This is exactly what it generated, on 2026-08-29:

```diff
 #SBATCH --nodes=1
-#SBATCH --ntasks=16
+#SBATCH --ntasks=64
 #SBATCH --cpus-per-task=1

-mpirun -np 16 ph.x -nimage 4 -in input.in
+mpirun -np 64 --bind-to core --map-by core ph.x -nimage 4 -in input.in
```

(the `-` line is the naive way to ask for it — same `--ntasks` as without
`-nimage` — the `+` line is gonzabot's actual answer: it scales `--ntasks`
to 64 so each of the 4 images gets its own 16 MPI processes, instead of
splitting 16 processes across the 4 images). Full real script in
[`tutorial/ph_x_fonones_real.sbatch`](tutorial/ph_x_fonones_real.sbatch).

## Model comparison

We evaluated whether a different model handled the classic "lost in the
middle" problem better. Systematic comparison between
Qwen2.5-72B-Instruct-AWQ (in production until 2026-08-30) and GLM-4.5-Air,
same infrastructure, same questions:

- Rule-following quality: GLM-4.5-Air won most of the individual cases we
  tested — including a real case where it correctly diagnosed a failed
  job (`/diagnose`) that Qwen reported as "no errors" (false negative).
- Speed: Qwen2.5-72B is ~30% faster generating, on our hardware (A100
  80GB) — the real cost of migrating.
- Known limitation, still open in production: the `/branch` command
  (generates 3 candidate fixes, runs them, compares results) doesn't work
  reliably with GLM-4.5-Air — the model doesn't always respect the
  structured diff format that command requires. It worked fine with
  Qwen2.5-72B.

With quality as the main criterion, **GLM-4.5-Air went into production on
2026-08-30**. The regression-testing that followed the migration (testing
live, against real infrastructure, cases that already worked well with
Qwen) found and fixed 4 new bugs specific to GLM that hadn't shown up in
the earlier systematic comparison — GROMACS invoked without `mpirun`, a
GPU requested alongside a Spack build with no CUDA support, a real Spack
hash missing the leading `/` — and along the way uncovered a real
pre-existing contradiction in the site documentation (`context/spack.txt`
said two different things about whether GROMACS resolves without a hash).
None of these are LLM bugs: they all live in the post-processor or in
`context/`, see "Architecture" below.

Along the way, using GLM-4.5-Air led us to find and report a real vLLM bug
— reasoning content (`<think>...</think>`) sometimes leaks unseparated
into the visible response during tool-free streaming, on long contexts.
Report and standalone repro:
[vllm-project/vllm#29763 (comment)](https://github.com/vllm-project/vllm/issues/29763#issuecomment-5470158016)

## Architecture

- `gonzabot` — interactive CLI in pure Python 3 (stdlib only: `sqlite3` to
  persist sessions, `urllib` to talk to vLLM's OpenAI-compatible
  endpoint). No `pip install` required.
- `context/` — plain-text files injected as cluster context. Split into
  topical segments (cross-cutting rules always loaded, plus one file per
  software family — molecular dynamics, DFT, particle physics, GPU/CUDA,
  genomics, Python, etc.), each with its own keyword trigger — so a
  question about one specific tool doesn't drag in irrelevant context
  from the others.
- Deterministic post-processing (doesn't depend on the LLM) on the
  generated `sbatch`: detects and fixes frequent patterns (badly-quoted
  heredocs, `cd $WORKDIR` injected over relative paths that already
  worked, stray `\$` outside heredocs, `module load` with an ambiguous
  Spack package name, decorative comment separators misread as hash
  hallucination, etc.), with a test suite (`gonzabot --selftest`).
- `gonzabot-watcher.sh` — a lightweight cron that starts the vLLM service
  on demand (via a flag file) if it isn't running. Shutdown on idle is
  handled by the vLLM job itself (see
  `tutorial/vllm-service.sbatch`), not the watcher — so between the two,
  no GPUs sit idle-but-reserved when nobody's using the service.

## Case study: an AI "researcher" using gonzabot end-to-end (2026-08-30)

To stress-test gonzabot the way a real user would — not synthetic
benchmark prompts — we ran a full session where an AI agent played the
role of an IFIMAR researcher and used **only** gonzabot (never a manual
edit) from idea to deliverable, in a single terminal, against the live
production instance. (The actual session transcripts are in Spanish,
since that's the real language spoken at IFIMAR.)

**Part 1 — a real research idea, generated, submitted, debugged, and
written up.** The "researcher" proposed studying the thermal behavior of
the Heusler alloy Fe₂CrGa near its Curie temperature (molecular dynamics
+ DFT validation), asked gonzabot for a test LAMMPS `sbatch`, and ran it
for real. Over several iterations, this surfaced and fixed **5 genuine
bugs** live: `spack env activate` silently narrowing package visibility
and breaking valid hashes (which had earlier caused `/diagnose` to
misdiagnose a perfectly valid hash as broken), a `create_box` with no
`create_atoms` afterward (empty simulation cell), a missing regex trigger
that meant a LaTeX/PDF request never loaded the site's "TeXLive is
currently broken" note, and — found while chasing that last one down — a
**cluster-wide** documentation bug: the `--no-locks` flag referenced as
"critical" in 15+ places across `context/*.txt` doesn't exist at all in
the installed Spack 1.2.2 (`spack --help` doesn't list it; using it fails
immediately with `unrecognized arguments`). All five are fixed in
`context/` and the deterministic post-processor, with new `--selftest`
cases.

**Part 2 — reproducing a real negative result from the literature.** We
searched arXiv for an open-access negative-results physics paper and
picked F.-X. Coudert's [*"Failure to Reproduce the Results of 'A new
transferable interatomic potential for molecular dynamics simulations of
borosilicate glasses'"*](https://arxiv.org/abs/2305.14958) (2023) — a
documented case where the original authors' LAMMPS files had incorrect
boron/silicon atomic masses, and "fixing" them makes the potential agree
*worse* with experiment (because the potential's B–B parameters were
themselves fit against the buggy masses). We downloaded the author's own
published input file (`50B/md.inp`, unmodified) from
[fxcoudert/citable-data](https://github.com/fxcoudert/citable-data), had
gonzabot generate the wrapping `sbatch` on the first try (no bugs this
time), and ran the full melt-quench protocol for real (3120 atoms,
Buckingham + PPPM, 3.01M timesteps, ~1h15m wall time on 32 CPU cores):

| Source | Density (g/cm³) | Masses |
|---|---:|---|
| Experimental (Wang et al.) | 2.453 | — |
| Wang et al. 2018 (as published) | 2.467 | **incorrect** |
| Coudert 2023 (his reproduction) | 2.520 | correct |
| **This run (IFIMAR, 2026-08-30)** | **2.536** | correct |

We reproduced Coudert's finding independently: correcting the masses
moves the density *away* from experiment (Δ=0.082) rather than toward it,
compared to the original buggy potential (Δ=0.014) — and our value lands
close to Coudert's own (Δ=0.016), a small and expected gap between
independent MD runs (seed, LAMMPS version, hardware). Honest caveat: this
is a single run of a single composition (50B out of the paper's nine) —
a demo of gonzabot's real-world capability, not a statistically rigorous
independent validation (that would need multiple seeds).

## Usage

```
./gonzabot                 # normal conversation
./gonzabot --new           # force a new session (ignore previous history)
./gonzabot --selftest      # run the post-processor's test suite
```

Inside a session: `/load <file>` to hand it an existing script, `/edit`
for a specific revision request, `/diagnose` to have it read a failed
job's log and explain the cause, `/audit` to review all of a user's
active jobs, `/save` / `/saveall` to persist the suggested `sbatch`.

## Configuration

`context/core.txt` (always loaded) plus the per-software-family segments
(`context/md-sim.txt`, `context/dft-qe.txt`, `context/python.txt`, etc.)
are included here as a real example (IFIMAR site). Editable in plain
text, without touching code, to adapt to another cluster: hardware,
Slurm partitions, available Spack packages, and rules learned from real
cases.

The model endpoint (vLLM host/port) is configured at the top of
`gonzabot`.

## Tutorial: how we set it up

[`tutorial/`](tutorial/) has the real log and scripts we used to stand
all of this up at IFIMAR: serving the model with vLLM (with automatic
shutdown on idle), on-demand startup, the Spack wrapper for ambiguous
hashes, and Slurm mail notifications.

## License

MIT — see `LICENSE`.
