**English** | [Español](README.es.md)

# Tutorial: how we set up gonzabot at IFIMAR

This isn't an installer — it's the real log of steps and scripts we used
to stand up gonzabot on our cluster, so another HPC admin can replicate
the approach (not necessarily every literal command, which will depend on
their own infrastructure).

Note on paths — two separate rules, don't mix them up:

1. **Mount name, depends on the node.** The login node (where users log
   in) and the compute nodes (CPU and GPU) mount the NFS as
   `/mnt/cpu-data/` and `/mnt/gpu-data/`. A separate admin node (not where
   regular users log in) mounts the same NFS as `/data/cpu/` and
   `/data/gpu/`. That's why you'll see both styles across different
   scripts in this repo: `gonzabot-watcher.sh` runs via cron on the admin
   node (`/data/gpu/...`); `vllm-service.sbatch` runs inside a job on a
   compute node (`/mnt/gpu-data/...`).

2. **Which of the two (cpu-data / gpu-data) exists on each node**, apart
   from the naming. GPU compute nodes only have `gpu-data` mounted —
   `cpu-data` doesn't exist there. CPU compute nodes are the reverse: only
   `cpu-data`, no `gpu-data`. Only the login node has both mounted at
   once. An `sbatch` to the GPU partition with a WorkDir under
   `.../cpu-data/...` fails instantly (Slurm can't `chdir`), and vice
   versa — before submitting a job, check that the path actually exists
   on the target partition, don't assume "it's the same NFS" means
   everything is visible from everywhere.

Adapt this to your own cluster's real mount layout — and if you have more
than two node categories, don't assume either of these two patterns is
binary.

## 1. Serving the model with vLLM

`download-model.sh` — we download the model from HuggingFace with
`huggingface_hub.snapshot_download` (Llama 3.3 70B as the example here;
we ended up running Qwen2.5-72B-Instruct-AWQ in production, see
`vllm-service.sbatch`).

`vllm-service.sbatch` — the real Slurm job that starts the service. Two
ideas from the script worth copying as-is:

- **Lives in the `inference` partition** (not `gpu`), as a long-running
  service (`--time=16:00:00`) rather than a one-off compute job.
- **Built-in idle watchdog**: a background subprocess
  (`while sleep 60; do ...`) checks a "heartbeat" file — every gonzabot
  request touches it — and if `IDLE_MINUTES` pass with no activity, the
  job cancels itself (`scancel $SLURM_JOB_ID`). This way the service
  doesn't hold compute GPUs when nobody's using it, with no external
  daemon needed.

## 2. On-demand startup

The service above shuts itself down on idle — but something has to turn
it back on when a user needs it. That's
[`gonzabot-watcher.sh`](../gonzabot-watcher.sh) (repo root): a lightweight
cron (run by a regular user, no root) that checks a flag file every
minute and submits `vllm-service.sbatch` if needed.

## 3. Resolving ambiguous Spack hashes

`spack-load-wrapper.txt` — the real problem and solution we found when
`spack load package` failed because multiple builds of the same package
were installed (`Error: fftw matches multiple packages`). A wrapper that
redefines `spack load` to automatically resolve the preferred hash.

## 4. Slurm mail notifications

`slurm-mail-notifications.txt` — how we fixed `--mail-user`/`--mail-type`
when `sendmail` came disabled by default (`/bin/false`), using `ssmtp` as
a lightweight SMTP relay (Gmail App Password or institutional SMTP).

## What's NOT here

We left out the VPN/firewall setup (WireGuard + OPNsense) we use to give
access to external collaborators — not because it's complicated, but
because the real document has our institution's full network topology
(public IPs, firewall rules). The general pattern is simple enough
anyway: WireGuard running directly on the perimeter firewall, one peer
per external collaborator, `AllowedIPs` scoped only to the login node
(never `0.0.0.0/0`) so it doesn't break the user's own network.

## 5. How to iterate without breaking what your researchers are already using

Not part of the code and not mandatory, but it's the most practical
recommendation we have: run **two instances** of gonzabot — a "dev" one
(its own port, for you) where you test code or `context/` changes, and a
"prod" one (the one your real users hit) that only gets updated after the
change is validated in dev. `context/*.txt` can be hot-edited (immediate
effect, nothing to restart); changes to gonzabot's *code* require each
user to reopen their session to pick up the new binary. We learned this
the hard way: testing code changes directly against the real instance, a
bug mid-test could have hit someone with a real job running at that
moment.

If you adopt something similar: watch out for the "dev" instance ending
up with logic or paths hardcoded to your own testing session (happened to
us — our dev had a mode-detection check with a path to a personal
directory, which we almost ended up publishing in this very repo). Before
copying from dev to a public release, diff the two files and confirm the
only differences are genuinely dev-specific, not accidents.

## How this relates to the cluster's "knowledge"

Everything above is infrastructure — configured once. The `context/*.txt`
files at the repo root are different: that's the cluster-specific
knowledge (hardware, partitions, Spack packages, rules learned from real
user bugs) that gonzabot uses in every conversation. To adapt gonzabot to
another cluster, the infrastructure above gets replicated once; `context/`
gets rewritten from scratch with your own cluster's real data.
