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
- `CLAUDE.md`: this file. Commands, rules, repository facts. Keep it short.
- `PLAN.md`: the design, its reasons and the milestones, with what has run
  where. `CODE.md` (the current design) and `HISTORY.md` are split off from
  it later.
- `TODO.md`, if present, is Erik's own list: do not modify it.

Keep the tables of contents current.

## Commands

```bash
julia --project=. -e 'using Pkg; Pkg.test()'            # about 30 s, runs local jobs
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
  `test/runtests.jl`, with `test/fakeslurm/sbatch` and `squeue` on the
  `PATH`. It covers the precompile job, its lock and a GPU job's header, not
  a real queue.
- An environment kind (`ENV_KINDS` in `src/spec.jl`) names the packages
  `templates/make_env.jl` adds. A new kind is a line there.
- Generated scripts are plain bash that must run without SimLaunch. The
  shared part is `templates/job_helpers.sh`.
- Manifests are never copied to a site, and nothing that depends on cores,
  threads, memory or time is shared between sites (PLAN.md, "Source
  snapshots" and "Job specs and generated scripts").
- A spec field of a later milestone is refused by name (`LATER_KEYS` in
  `src/spec.jl`), never ignored.
- A study's compiled caches are its own: jobs and `prepare` run with
  `JULIA_DEPOT_PATH="<study>/depot:"`, never with `~/.julia` (PLAN.md,
  "Prepare").
- Cluster facts live in `sites/*.toml`. On a cluster, follow that cluster's
  skill: check the connection first, and never open one that needs MFA.
- Submitting a job, or anything else on a cluster, is visible to others: ask
  Erik first, each time.

## Repository

- Remote: `origin`, https://github.com/eschnett/SimLaunch.jl, branch `main`.
- Commit or push only when Erik asks. No `Co-Authored-By` lines.
