# Security Policy

gonzabot runs on an HPC cluster's login node, executes shell commands on the
user's behalf (both a fixed allowlist of read-only/common commands and, via
`/run`, real `sbatch` submissions), and talks to a local LLM. Taking security
reports seriously here isn't optional.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Email
garroyo@ifimar-conicet.gob.ar directly with:

- What you found and why it's exploitable (a concrete input/scenario, not just
  "this looks risky").
- The impact you'd expect (e.g. command injection, privilege escalation,
  credential exposure).

You'll get a response acknowledging the report. There's no bug bounty — this is a
small, mostly-single-maintainer research-cluster tool — but real reports are taken
seriously and fixed.

## What's in scope

- Command injection through user input reaching a shell (the `_INJECT` pattern in
  `gonzabot`, the `_AUTO_RUN_CMDS` allowlist, `/run`'s sbatch submission path).
- Path traversal or unintended file access via `/load`, `/save`, `/edit`.
- Anything that lets a user's input make gonzabot execute something outside its
  documented allowlist of commands.
- Credential or token handling in the code itself (there shouldn't be any hardcoded
  secrets — if you find one, that's a real report).

## What's out of scope

- The specific cluster configuration in `context/*.txt` (real hostnames, hashes,
  internal paths) — that's operational detail for one site, not a vulnerability in
  the published code.
- The underlying vLLM/model server, Slurm, or Spack themselves — report those
  upstream.
- Social-engineering a human operator (e.g. "gonzabot could be tricked into telling
  a user something false if they lie about who they are") — worth a normal issue,
  not a security report, unless it crosses into an actual privilege boundary.
