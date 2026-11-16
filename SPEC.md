# SimLaunch: job specs

A job spec is a TOML file that says what to run and what it needs. This is
the reference for every key. [`README.md`](README.md) has an introduction,
[`CONVERTING.md`](CONVERTING.md) the way from a hand-written batch script
to a spec, and [`PLAN.md`](PLAN.md) the reasons.

- [Structure](#structure)
- [Top level](#top-level)
- [What a job needs](#what-a-job-needs)
- [Runs](#runs)
- [Environments](#environments)
- [MPI and placement](#mpi-and-placement)
- [Restarts](#restarts)
- [After the runs](#after-the-runs)
- [What a job is refused for](#what-a-job-is-refused-for)

## Structure

```toml
name = "sweep1"                     # top level: what is the same on every site

[site.trillium]                     # what the job needs on one site
time = "3:00:00"
resources = { nodes = 1 }

[site.local]

[[run]]                             # one command; one table per run
label = "p6"
cmd = "examples/harmonic_single.jl p=6"
```

A key of a site table may also stand at the top level, as the default for
every site. A spec written for one site names it, `site = "symmetry"`, has
no site tables, and is refused elsewhere. A site without a table gets the
defaults, and must then find `time` at the top level if it is a cluster.

One spec makes one job: one batch allocation that holds all its runs. A
run's output directory is `<scratch>/<study>/<name>-<label>/`.

An unknown key is an error, never ignored.

## Top level

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | required | The spec's name: part of the job's name and of every run's directory |
| `project` | the study's project | The project whose scripts run, relative to the study's `src/` |
| `site` | none | A site's name: the spec is for that site only |
| `checkpoints` | `false` | The runs continue from checkpoints: see [Restarts](#restarts) |
| `mutable_restarts` | `false` | For a driver that appends to its old output: see [Restarts](#restarts) |
| `[restart]` | none | The driver's restart arguments; required with `checkpoints` |
| `[after]` | none | A shell command after the last run |
| `[combine]` | none | A script that joins a chain's job directories |
| `[[run]]` | at least one | The runs |

## What a job needs

In `[site.<name>]`, or at the top level as a default.

| Key | Default | Meaning |
| --- | --- | --- |
| `time` | required on a cluster | The time limit: `"H:MM:SS"`, `"D-HH:MM:SS"`, `"MM:SS"` or minutes |
| `resources` | `{ nodes = 1 }` | `{ nodes = N }`: whole CPU nodes. `{ gpus = N }`: GPUs, with the cores and memory the site's profile gives each |
| `mode` | `"sequential"` | `"sequential"`: one run after another. `"parallel"`: all at once, sharing the cores |
| `threads` | see below | Julia threads of every run (per rank, for a run with ranks) |
| `pin` | `false` | `JULIA_EXCLUSIVE=1`, `srun --cpu-bind=none` and `-t N,0`. Sequential CPU jobs on a cluster only; not for a run with `ranks` or `placement` |
| `env` | `"default"` | The runs' environment: see [Environments](#environments) |
| `blas_threads` | `1` | `OPENBLAS_NUM_THREADS` |
| `julia_args` | `[]` | Julia options, such as `["--check-bounds=yes"]`. Each set is precompiled by `prepare` |
| `vars` | `{}` | Environment variables for the runs |
| `queue` | chosen by rule | A partition of the site. Without it, the first in the profile's order that fits |
| `node` | none | A named node, or a node list as Slurm writes it |
| `sbatch_args` | `[]` | Further lines of the batch header, as written: `["--switches=1"]` |
| `mpi` | none | The MPI recipe of every run: see [MPI and placement](#mpi-and-placement) |
| `placement` | none | `"numa"` |
| `prefix` | none | Words before the Julia command, as written: `"perf stat -e cache-misses"` |

The default of `threads` is the allocation's cores for sequential runs, the
cores divided by the number of runs for parallel ones, the cores divided by
the ranks on a node for a run with ranks, and one NUMA domain's cores with
`placement = "numa"`.

## Runs

| Key | Default | Meaning |
| --- | --- | --- |
| `label` | required | The run's name within the spec |
| `cmd` | required | A script of the project and its arguments, split as a shell would. Starts in the run's own job directory. If it starts with `-`, it is Julia options instead, such as `-e '…'` |
| `threads` | the job's | A number, or a list: one run per count, labelled `<label>-t<N>` |
| `julia_args` | the job's | Replaces the job's |
| `vars` | the job's | Added to the job's |
| `env`, `mpi`, `placement`, `prefix` | the job's | As above, for this run |
| `variant` | `"default"` | Which version of the study's packages: see [Environments](#environments) |
| `ranks` | none | MPI ranks; the run is then started by its recipe's launcher |
| `nodes` | the job's nodes with `ranks`, else 1 | The nodes the run's ranks are spread over |

`submit --run <label>` submits only the named runs.

## Environments

A run executes in one environment of the study, which `prepare` makes and
precompiles on the site.

- `env = "default"` is the project itself, as the snapshot holds it.
- Other environments are written by `prepare` into the study's `envs/`. The
  project's own `Project.toml` is never changed. `env` names kinds, joined
  by `+`:

  | Kind | Adds |
  | --- | --- |
  | `cuda` | CUDA.jl, and its runtime, fetched during `prepare` |
  | `metal` | Metal.jl |
  | `test` | the project's test dependencies: its `test/Project.toml`, or its `[extras]` and test target |
  | `mpi` | MPI.jl, set to the run's recipe. Added by itself to a run with `mpi` |

- `variant = "base"` uses another version of the project and its path
  packages, copied by `simlaunch snapshot … --variant base=<directory>`. The
  run's script is still the study's own; only the packages differ.

Each site resolves its own package versions. `prepare` must be given every
spec whose environments and Julia options a later `submit` uses.

## MPI and placement

```toml
[[run]]
label = "new-8x8"
cmd = "bench/nested.jl mpi"
mpi = "jll"                         # a recipe of the site's profile
ranks = 8
threads = 8                         # per rank
placement = "numa"                  # rank i of the 8 on its node: NUMA domain i
```

- `mpi` names a recipe in `sites/<site>.toml`, `[mpi.<recipe>]`: which MPI
  binary, which launcher, which modules. Runs of one job may use different
  recipes.
- `ranks` starts the run through the recipe's launcher. A run with `mpi` but
  without `ranks` runs in the recipe's environment without a launcher.
- `placement = "numa"` binds each rank to one NUMA domain, its cores and
  its memory, with `numactl`. A run without ranks gets domain 0.
- A job on several nodes has `resources = { nodes = N }`; a run's `nodes`
  says how many of them its ranks use.
- Runs with ranks need `mode = "sequential"`.

## Restarts

```toml
checkpoints = true

[restart]
to = "checkpoint"                   # required
from = "restart_from"               # required, unless mutable_restarts
walltime = "walltime"
margin = "0:05:00"
continue_code = 3
temporary = ["*.tmp", "*.tmp.*", ".*"]
compare = "test/compare_runs.jl"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `to` | required | The driver's argument for its own checkpoint directory. The driver gets `<to>=<job directory>/ck` |
| `from` | required | Its argument for an earlier job's checkpoints: `<from>=<earlier job directory>/ck`. Not passed to a run's first job |
| `walltime` | not passed | Its argument for the seconds it may run: the time limit minus `margin` |
| `margin` | `"0:05:00"` | The part of the time limit kept back |
| `continue_code` | none | The driver's exit code when it stopped at its walltime: the run is then `stopped`, not `failed` |
| `temporary` | as above | Names of checkpoints that are still being written, as file name patterns |
| `compare` | none | For `check-restart`: a script of the project that gets the uninterrupted run's job directory and then the chain's, and exits with 0 if they agree |

What the driver must do:

- write its output into its working directory, which is a new one for every
  job, and never into an earlier job's;
- write each checkpoint under a temporary name and rename it when it is
  whole;
- read checkpoints from the `from` directory, which is read-only;
- exit with 0 only when the run is complete.

`mutable_restarts = true` is for a driver that does not do this yet: all
jobs of a run share one directory, `to` is its `ck/`, there is no `from`,
and nothing is made read-only.

## After the runs

```toml
[after]
cmd = "awk -f \"$PROJECT\"/bench/mpitable.awk */*/output.log"

[combine]
cmd = "test/combine_chain.jl"
```

- `[after] cmd` is a shell command, run in the job after the last run, in
  the study's output directory. `PROJECT`, `SCRATCH`, `STUDY`, `SPEC`,
  `JOBID` and `SIMLAUNCH_JOBDIRS` (this job's directories) are set. Its
  output goes to the job's log.
- `[combine] cmd` is a script of the project, run by `simlaunch combine`. It
  gets a run's job directories, oldest first, as its last arguments, and
  writes into its working directory, a new `combined-<n>/` of the run.

## What a job is refused for

`submit` refuses a job before it reaches the queue when

- a run asks for more threads, times its ranks on a node, than the node or
  the GPUs' share has cores, or parallel runs together do;
- no queue takes its time, nodes or GPUs, with each queue's reason;
- a named queue does not fit: too long, too short, too many nodes or GPUs,
  pre-emptible without checkpoints;
- the site has no GPUs, no such MPI recipe, or no NUMA domains in its
  profile, and the spec asks for them;
- the study is not prepared on the site for an environment or for Julia
  options the spec uses;
- a job of a spec with checkpoints is queued or running already.

Not implemented, and refused by name: a run's `julia`, for another Julia
version. Memory is not checked.
