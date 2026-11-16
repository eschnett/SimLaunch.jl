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

Milestone 2 of four, partly run.

- Run on clusters:
  - `trillium` (CPU): step S1's sweep of XCTS-harmonic, six runs side by
    side, and a pinned thread scan of TreeWaveOLDG, 1 to 192 threads.
  - `fir` (CPU): S1's sweep from the same spec, with the same results.
  - `trillium-gpu`: a TreeGeneralizedHarmonic octant row on one H100, in the
    `cuda` environment.
  - `symmetry`: the same row on one H200, after a precompile job on an H200
    node.
  - `local`: the one run of S1's sweep that fits into the laptop's memory.
- Tested on the laptop only, with stand-ins for `sbatch` and `squeue`: the
  profile `nibi`, CPU jobs on Symmetry, GPU jobs on Fir, and a precompile
  lock that is held or stale.
- Not yet: MPI, placement, checkpoints and restarts, the choice of a queue by
  rule, `status`, `fetch`, `clean`. A spec that uses one of these is refused
  with the milestone that brings it.
- Known gap: the studies of a site share one Julia depot. Preparing one
  study can make another study's compiled cache stale; that study's next job
  then stops at its check, and `prepare` run again repairs it.

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
# on Symmetry and Nibi the login node is another CPU: prepare submits a
# short precompile job and waits for it; interrupted, it continues when run again

# show the batch script and the queue, without submitting
simlaunch submit s1 jobs/s1-sweep.toml --site trillium --dry-run

# submit; prints the job ID and the simwatch command
simlaunch submit s1 jobs/s1-sweep.toml --site trillium
```

`--site local` runs the same study on the laptop, as a background process
under the same directory layout. A study is never rewritten: a changed source
needs a new study name.

Each site resolves its own package versions. `prepare` keeps a copy of every
manifest a site wrote in `~/.cache/simlaunch/.sites/` and prints the packages
whose versions differ from the study's other prepared sites.

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

A GPU job asks for GPUs instead of a node, and names the environment that
adds the device package:

```toml
[site.symmetry]
time = "1:00:00"
resources = { gpus = 1 }
env = "cuda"                        # the project and CUDA.jl, written by prepare
```

`prepare` writes that environment into the study as `envs/default-cuda/`; the
project's own `Project.toml` is not changed. The cores and the memory of a
GPU job follow from the site's profile.

`cmd` is a script of the project and its arguments, started in the run's job
directory. Per run: `threads` (a list makes one run per count), `julia_args`
and `vars`. `submit --run <label>` submits only the named runs, for a site
that cannot hold them all. `submit` refuses a job that asks for more cores than its
allocation has, or more time or nodes than its queue allows.

## Design

[`PROPOSAL.md`](PROPOSAL.md) has the design, its reasons and the plan.
