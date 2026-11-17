# SimLaunch: notes for AI agents

- [Read first](#read-first)
- [Commands](#commands)
- [Conventions and sharp edges](#conventions-and-sharp-edges)
- [Repository](#repository)

## Read first

SimLaunch is a command-line tool that snapshots a Julia project, prepares it
on a site and submits jobs there. Read `PLAN.md` before changing anything:
it is the design, its reasons and the plan.

Which file new content goes in:

- `README.md`: for users. What it does, installation, an example, the status.
- `SPEC.md`: for users. The reference for every key of a job spec. A new or
  changed key is described there.
- `CONVERTING.md`: for another project's maintainer or agent. How a
  hand-written batch script becomes a spec, and what does not carry over.
- `CLAUDE.md`: this file. Commands, rules, repository facts. Keep it short.
- `PLAN.md`: the design, its reasons and the milestones, with what has run
  where. `CODE.md` (the current design) and `HISTORY.md` are split off from
  it later.
- `TODO.md`, if present, is Erik's own list: do not modify it.

Keep the tables of contents current.

## Commands

```bash
julia --project=. -e 'using Pkg; Pkg.test()'            # about 2 min, runs local jobs
SIMLAUNCH_UPDATE_REFERENCE=1 julia --project=. -e 'using Pkg; Pkg.test()'
                                                        # rewrite test/reference/*.sh
julia --project=. -m SimLaunch submit <study> <spec> --site trillium --dry-run
```

`SIMLAUNCH_CACHE` and `SIMLAUNCH_SITES` move the snapshot cache and the
profile directory; the tests use both.

## Conventions and sharp edges

- A changed generated script changes `test/reference/*.sh`, one per site:
  regenerate them and read the diff.
- The tests run a Slurm site on the laptop: the profile `cluster` in
  `test/runtests.jl`, with `test/fakeslurm/sbatch`, `squeue` and `scancel`
  on the `PATH`. It covers the precompile job and its lock, chains, a
  stopped job's successor and a GPU job's header, not a real queue. MPI
  needs packages from the network and is not in the tests: try it by hand
  on `local`, whose profile has a `jll` recipe.
- Text for bash goes through `q` or `shpath` (`src/sites.jl`), never
  `Base.shell_escape`, which leaves `*` and `~` bare.
- A snippet for `readsite` must end with status 0: a trailing
  `[ -d x ] && echo x` makes the whole command fail. End with `; true`.
- `templates/job_helpers.sh` is copied into every script unchanged, so it
  reads only variables that `generate` always sets.
- An environment kind (`ENV_KINDS` in `src/spec.jl`) names the packages
  `templates/make_env.jl` adds. A new kind is a line there. The Julia files
  a study carries in its `tools/` are listed in `TOOLS` (`src/snapshot.jl`).
- Generated scripts are plain bash that must run without SimLaunch. The
  shared part is `templates/job_helpers.sh`.
- Manifests are never copied to a site, and nothing that depends on cores,
  threads, memory or time is shared between sites (PLAN.md, "Source
  snapshots" and "Job specs and generated scripts").
- A spec can be a Julia file. Only `load_spec` and `spec_toml`
  (`src/spec.jl`) know that; everything after them sees what TOML gives.
- A spec field that is not implemented is refused by name (`LATER_KEYS` in
  `src/spec.jl`), never ignored.
- `clean` and `--old-checkpoints` delete on a site: ask Erik first, as for
  a job. Never pass `yes = true` or `--yes` outside the tests.
- A study's compiled caches are its own: jobs and `prepare` run with
  `JULIA_DEPOT_PATH="<study>/depot:"`, never with `~/.julia` (PLAN.md,
  "Prepare").
- Cluster facts live in `sites/*.toml`. On a cluster, follow that cluster's
  skill: check the connection first, and never open one that needs MFA.
- Submitting a job, or anything else on a cluster, is visible to others: ask
  Erik first, each time.

## Repository

- Remote: `origin`, https://github.com/eschnett/SimLaunch.jl, branch `main`.
- CI: `.github/workflows/CI.yml` runs the tests on Linux and macOS, with
  Julia 1.12 and the newest. macOS has bash 3.2: generated scripts and the
  tests must run under it.
- Registered in Julia's General registry as `SimLaunch`. TagBot
  (`.github/workflows/TagBot.yml`) tags a version once its registration has
  merged. Registering a version is Erik's step, or done when he asks.
- Commit or push only when Erik asks. No `Co-Authored-By` lines.
