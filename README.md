# SimLaunch

A command-line tool, `simlaunch`, that takes a Julia project from the laptop
to a cluster and back: it copies an immutable snapshot of the project and the
packages it takes by path, instantiates and precompiles on the site, generates
the batch script from a short job spec and a site profile, and submits it with
[SimWatch](https://github.com/eschnett/simwatch) status files.

- [Status](#status)
- [Installation](#installation)
- [Example](#example)
- [Job specs](#job-specs)
- [Design](#design)

## Status

Milestone 1 of four. Working: the sites `local` and `trillium` (CPU),
`snapshot`, `prepare` on a login node, `submit` with `--dry-run`, per-site
spec tables and the resource check. Step S1's sweep of XCTS-harmonic has run
through it from one spec: all six runs on Trillium, and the one that fits
into the laptop's memory on `local`. Not yet: Symmetry, Nibi, GPUs,
environments other than the project's own, MPI, placement, checkpoints and
restarts, `status`, `fetch`, `clean`. A spec that uses one of these is
refused with the milestone that brings it.

## Installation

Needs Julia 1.12 or later, `rsync`, `ssh` and `git` on the laptop. Nothing
is installed on a site.

```bash
julia -e 'using Pkg; Pkg.Apps.develop(path="/path/to/SimLaunch")'
```

This puts `simlaunch` into `~/.julia/bin`. Without installing, run it as
`julia --project=/path/to/SimLaunch -m SimLaunch <command>`.

## Example

```bash
# the snapshot: the project and every package it takes by path
simlaunch snapshot ~/src/jl/XCTS-harmonic --study s1

# copy to the site, instantiate and precompile there
simlaunch prepare s1 --site trillium --spec jobs/s1-sweep.toml

# show the batch script and the queue, without submitting
simlaunch submit s1 jobs/s1-sweep.toml --site trillium --dry-run

# submit; prints the job ID and the simwatch command
simlaunch submit s1 jobs/s1-sweep.toml --site trillium
```

`--site local` runs the same study on the laptop, as a background process
under the same directory layout. A study is never rewritten: a changed source
needs a new study name.

On a site, a study's sources are in `<code>/<study>/` and its output in
`<scratch>/<study>/`, where `<code>` and `<scratch>` come from the site's
profile in [`sites/`](sites). Each run has a directory
`<scratch>/<study>/<spec>-<label>/` holding its `simwatch.toml` and one
directory per job, `001-<job ID>/`, which is made read-only when the job ends.
The job's own log is `<scratch>/<study>/logs/<spec>-<job ID>.out`.

## Job specs

A spec says what to run, which is the same on every site, and what it needs,
in a table per site. [`examples/s1-sweep.toml`](examples/s1-sweep.toml):

```toml
name = "sweep1"
project = "XCTS-harmonic"           # relative to the snapshot's src/

[site.trillium]                     # a 192-core node: the runs side by side
time = "3:00:00"
resources = { nodes = 1 }
mode = "parallel"
threads = 32

[site.local]                        # the laptop: one run after another
mode = "sequential"

[[run]]
label = "p6"
cmd = "examples/harmonic_single.jl p=6"
```

`cmd` is a script of the project and its arguments, started in the run's job
directory. Per run: `threads` (a list makes one run per count), `julia_args`
and `vars`. `submit --run <label>` submits only the named runs, for a site
that cannot hold them all. `submit` refuses a job that asks for more cores than its
allocation has, or more time or nodes than its queue allows.

## Design

[`PROPOSAL.md`](PROPOSAL.md) has the design, its reasons and the plan.
