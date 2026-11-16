# SimLaunch: notes for AI agents

- [Read first](#read-first)
- [Commands](#commands)
- [Conventions and sharp edges](#conventions-and-sharp-edges)
- [Repository](#repository)

## Read first

SimLaunch is a command-line tool that snapshots a Julia project, prepares it
on a site and submits jobs there. Read `PROPOSAL.md` before changing anything:
it is the design, its reasons and the plan.

Which file new content goes in:

- `README.md`: for users. What it does, installation, an example, the status.
- `CLAUDE.md`: this file. Commands, rules, repository facts. Keep it short.
- `PROPOSAL.md`: the design and the plan, until it is split into `CODE.md`
  (the current design), `PLAN.md` (the milestones) and `HISTORY.md`.
- `TODO.md`, if present, is Erik's own list: do not modify it.

Keep the tables of contents current.

## Commands

```bash
julia --project=. -e 'using Pkg; Pkg.test()'            # about 20 s, runs local jobs
SIMLAUNCH_UPDATE_REFERENCE=1 julia --project=. -e 'using Pkg; Pkg.test()'
                                                        # rewrite test/reference/*.sh
julia --project=. -m SimLaunch submit <study> <spec> --site trillium --dry-run
```

`SIMLAUNCH_CACHE` and `SIMLAUNCH_SITES` move the snapshot cache and the
profile directory; the tests use both.

## Conventions and sharp edges

- A changed generated script changes `test/reference/trillium-hello.sh`:
  regenerate it and read the diff.
- Generated scripts are plain bash that must run without SimLaunch. The
  shared part is `templates/job_helpers.sh`.
- Manifests are never copied to a site, and nothing that depends on cores,
  threads, memory or time is shared between sites (PROPOSAL.md, "Source
  snapshots" and "Job specs and generated scripts").
- A spec field of a later milestone is refused by name (`LATER_KEYS` in
  `src/spec.jl`), never ignored.
- Cluster facts live in `sites/*.toml`. On a cluster, follow that cluster's
  skill: check the connection first, and never open one that needs MFA.
- Submitting a job, or anything else on a cluster, is visible to others: ask
  Erik first, each time.

## Repository

- Remote: `origin`, https://github.com/eschnett/SimLaunch.jl, branch `main`.
- Commit or push only when Erik asks. No `Co-Authored-By` lines.
