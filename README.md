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
- [After a job](#after-a-job)
- [Restarts](#restarts)
- [Design](#design)

## Status

Milestones 1 to 3 of four are implemented. Milestone 2 has run on
clusters, in part; milestone 3 (queue rules, `status`, `fetch`, `usage`,
`clean`, restart chains, `check-restart`, variants, MPI and placement) has
run on the laptop only.

- Run on clusters:
  - `trillium` (CPU): step S1's sweep of XCTS-harmonic, six runs side by
    side, and a pinned thread scan of TreeWaveOLDG, 1 to 192 threads.
  - `fir` (CPU): S1's sweep from the same spec, with the same results.
  - `trillium-gpu`: a TreeGeneralizedHarmonic octant row on one H100, in the
    `cuda` environment.
  - `symmetry`: the same row on one H200, after a precompile job on an H200
    node.
  - `local`: the one run of S1's sweep that fits into the laptop's memory.
- Tested on the laptop only, with stand-ins for `sbatch`, `squeue` and
  `scancel`: the profile `nibi`, CPU jobs on Symmetry, GPU jobs on Fir, a
  precompile lock that is held or stale, a chain of jobs, a pre-empted job
  that submits its successor, and `check-restart`.
- Run on the laptop by hand: two versions of a package in one job, with MPI
  ranks under MPICH_jll's `mpiexec`.
- Read only, never run: scripts with `srun` launchers, `numactl` placement,
  several nodes, or a site's own MPI.
- Not yet: a run's own Julia version (`julia = "+1.13"`), which a spec is
  refused for; the memory part of the resource check; `--snapshot-pins`.

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

Each study has its own compiled caches on a site (`<code>/<study>/depot/`),
so preparing one study does not disturb another. Each site resolves its own
package versions. `prepare` keeps a copy of every
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

The queue is the first in the site's profile that fits the job; `--queue`
names another. On Trillium that is `debug` for a job of up to an hour while
no other job of yours is there, and `compute` otherwise.

Further fields, each described in [`PLAN.md`](PLAN.md):

| Field | Meaning |
| --- | --- |
| `env = "test+cuda"` | kinds joined by `+`: `cuda`, `metal`, `test` (the test dependencies), `mpi` |
| `variant = "base"` | another version of the package, added by `snapshot --variant base=<directory>` |
| `ranks = 8`, `mpi = "jll"` | MPI ranks, started by a recipe of the site's profile; `threads` is then per rank |
| `nodes = 2` | in `resources`: the job's nodes; in a run: the nodes its ranks are spread over |
| `placement = "numa"` | one NUMA domain per rank, with `numactl` |
| `pin = true` | `JULIA_EXCLUSIVE=1` under `srun --cpu-bind=none`; not with `ranks` or `placement` |
| `node = "cn095"` | a named node |
| `sbatch_args`, `prefix` | lines for the batch header, and words before the Julia command, as written |
| `[after] cmd` | a shell command after the last run |

[`examples/treeamr-nested.toml`](examples/treeamr-nested.toml) uses most of
them.

## After a job

```bash
simlaunch status s1                 # one table of the study's runs on all its sites
simlaunch fetch s1                  # results into <project>/.claude/data/s1/<site>/
simlaunch usage s1                  # what each job holds on disk, as it recorded it
simlaunch clean s1 --site trillium  # lists the study's directories there; deletes after a yes
```

`fetch` leaves checkpoints (`ck/`) and files above 100 MB on the site;
`--with-checkpoints` and `--max-size` change that. `clean` refuses while a
job of the study is queued or running, and never touches the snapshot on the
laptop.

## Restarts

A run that checkpoints is a chain of jobs. Each job writes into a directory
of its own and reads the checkpoints of an earlier one; what a job wrote is
read-only once it has ended.

```toml
checkpoints = true

[restart]
to = "checkpoint"                   # the driver's argument for its own checkpoints: checkpoint=<job directory>/ck
from = "restart_from"               # for an earlier job's: restart_from=<earlier job directory>/ck
walltime = "walltime"               # for the seconds it may run
continue_code = 3                   # its exit code when it stopped at the walltime
compare = "test/compare_runs.jl"    # for check-restart
```

```bash
simlaunch submit s2 jobs/long.toml --site trillium --chain 3   # three jobs, one after another
simlaunch resubmit s2 jobs/long.toml --site trillium           # the next job, later
simlaunch clean s2 --site trillium --old-checkpoints           # all but each run's newest
simlaunch check-restart s2 jobs/short.toml --site trillium     # does the driver keep the contract?
```

The driver must write each checkpoint under a temporary name (`*.tmp`) and
rename it when it is whole. On a pre-emptible queue (Symmetry's `h200preq`,
which a GPU job with checkpoints gets) a stopped job submits its successor
itself; to end such a chain, create the file `STOP` in the study's output
directory and cancel the job. `check-restart` runs a spec once in one job
and once stopped and continued, and passes when the stopped job's directory
is unchanged and the project's `compare` script accepts the pieces. A driver
that still appends to its old output runs with `mutable_restarts = true`
([`examples/treegh-octant-chain.toml`](examples/treegh-octant-chain.toml)).

## Design

[`PLAN.md`](PLAN.md) has the design, its reasons and the plan.
