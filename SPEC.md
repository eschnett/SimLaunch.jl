# SimLaunch: job specs

A job spec is a TOML file that says what to run and what it needs, or a
Julia file that evaluates to the same. This is the reference for every key. [`README.md`](README.md) has an introduction,
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
- [A spec in Julia](#a-spec-in-julia)
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
every site. A spec written for one site names it, `site = "nibi"`, has
no site tables, and is refused elsewhere. A site without a table gets the
defaults, and must then find `time` at the top level if it is a cluster.

One spec makes one job: one batch allocation that holds all its runs. A
run's output directory is `<scratch>/<study>/<name>-<label>/`. Each job of
the run has a directory of its own in it, `001-<job ID>/`, with the run's
`output.log`, the files it writes, and `simlaunch-job.toml`: the job, when
it started, its host and the host's CPU model, the job's node list and
partition, and its GPUs.

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
| `node` | none | The node or nodes the job runs on, as Slurm writes a node list: `"cn099"`, `"cn[095-096]"` |
| `sbatch_args` | `[]` | Further lines of the batch header, as written: `["--switches=1"]`, `["--exclude=cn099"]` |
| `mpi` | the site's default, for a run with `ranks` | The MPI recipe of every run: see [MPI and placement](#mpi-and-placement) |
| `placement` | none | `"numa"` |
| `domains_per_rank` | a rank's share | The NUMA domains a rank is bound to, for the runs with `placement = "numa"`: see [MPI and placement](#mpi-and-placement) |
| `prefix` | none | Words before the Julia command: `"perf stat -e cache-misses"`, split as a shell would, or a list of words. Each word reaches the command as it is: a `$VAR` in it is not expanded |
| `launcher_args` | `[]` | Further arguments of the MPI launcher (`srun` or `mpiexec`), after the recipe's own, for the runs with `ranks`. They belong to one MPI, so to one site: write them in `[site.<name>]` |

The default of `threads` is the allocation's cores for sequential runs, the
cores divided by the number of runs for parallel ones, the cores divided by
the ranks on a node for a run with ranks, and one NUMA domain's cores for
a run without ranks that has `placement = "numa"`. With `domains_per_rank`
it is the cores of that many domains, and more threads are refused.

A partition can mix node types. A benchmark names its node with `node`, or
keeps off the nodes that differ with `sbatch_args = ["--exclude=cn099"]` or
a `--constraint`. A site's profile can do the same for every job in a
queue, and can mark a queue as taken only by name (`header` and `on_request`
in [`SITES.md`](SITES.md)). Which CPU a run got is in its `simlaunch-job.toml`.

## Runs

| Key | Default | Meaning |
| --- | --- | --- |
| `label` | required | The run's name within the spec |
| `cmd` | required | A script of the project and its arguments, split as a shell would. Starts in the run's own job directory. If it starts with `-`, it is Julia options instead, such as `-e '…'` |
| `threads` | the job's | A number, or a list: one run per count, labelled `<label>-t<N>` |
| `julia_args` | the job's | Replaces the job's |
| `vars` | the job's | Added to the job's |
| `env`, `mpi`, `placement`, `domains_per_rank`, `prefix`, `launcher_args` | the job's | As above, for this run. `launcher_args` needs `ranks`, and `domains_per_rank` a placement |
| `variant` | `"default"` | Which version of the study's packages: see [Environments](#environments) |
| `ranks` | none | MPI ranks; the run is then started by its recipe's launcher |
| `nodes` | the job's nodes with `ranks`, else 1 | The nodes the run's ranks are spread over |

`submit --run <label>` submits only the named runs, and only they are
checked against the site: a spec may hold a run that needs a recipe or a
placement another site has, as long as that run is not named here.

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
mpi = "jll"                         # a recipe of the site's profile; without it, the site's default
ranks = 8
threads = 8                         # per rank
placement = "numa"                  # rank i of the 8 on its node: NUMA domain i of 8
```

- `mpi` names a recipe in the site's profile, `[mpi.<recipe>]` (see [`SITES.md`](SITES.md)): which MPI
  binary, which launcher, which modules. Runs of one job may use different
  recipes.
- A run with `ranks` that names no recipe gets the site's default (`default`
  in its `[mpi]` table), and so does `mpi = "default"`. A spec that leaves
  `mpi` out runs on every site. The default is the standard MPI ABI on
  every site: on a cluster the site's own MPI through mpi_abi_wrapper, on
  the laptop MPIABI_jll. Name a recipe only to compare MPI libraries or to
  work around one.
- `ranks` starts the run through the recipe's launcher. A run with `mpi` but
  without `ranks` runs in the recipe's environment without a launcher.
- `placement = "numa"` binds each rank to its share of the node's NUMA
  domains, their cores and their memory, with `numactl`: rank i of the R on
  a node gets the D/R domains from i·D/R on. With 8 ranks on 8 domains that
  is one domain each; with 2 ranks, rank 0 has domains 0 to 3 and rank 1
  domains 4 to 7. R must divide D: `submit` refuses 3 ranks on 8 domains.
  A run without ranks gets domain 0. D is counted on the node when the run
  starts, and a node whose domains the ranks cannot share evenly ends the
  run at once; the profile's count is what `submit` checks.
- `domains_per_rank = k` binds a rank to k domains instead of its share,
  from the start of its share on: rank i gets the domains from ⌊i·D/R⌋. With
  2 ranks on 8 domains and `domains_per_rank = 1`, rank 0 has domain 0 and
  rank 1 domain 4. This keeps a rank the same while the number of ranks
  changes, as a scaling benchmark wants. R need not divide D then: R·k ≤ D
  is enough, and 4 ranks on 6 domains get domains 0, 1, 3 and 4. A run
  without ranks gets k domains from 0 on. At the top level or in a site
  table the key is for the runs that have a placement; a run that names it
  itself needs one. A node with fewer than R·k domains ends the run at once.
- A run's `vars` reach every rank on every node, under either launcher:
  `srun` passes the job's environment on, and for an `mpiexec` the
  variables are set again in front of each rank's command. Settings of
  Open MPI are best written this way (`vars = { OMPI_MCA_io = "romio321" }`);
  `launcher_args` is for what has no variable.
- Ranks started with `srun` end together: when one exits with an error, the
  others are stopped (`--kill-on-bad-exit=1`).
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
- `simlaunch after <study> <spec> --site <site>` runs the `[after]` command
  again, on the login node, when no job of the spec is queued or running.
  `SIMLAUNCH_JOBDIRS` is then each run's newest job directory, and `JOBID`
  the job they came from (several, separated by commas, if they differ).
  The output is printed and kept in the study's `logs/`. With `--checkout`,
  `PROJECT` is a copy of the project as it is on the laptop now, for a
  script that was wrong when the snapshot was taken; the log says which it
  was. The study's snapshot is not changed.
- `[combine] cmd` is a script of the project, run by `simlaunch combine`. It
  gets a run's job directories, oldest first, as its last arguments, and
  writes into its working directory, a new `combined-<n>/` of the run.

## A spec in Julia

A spec file that ends in `.jl` is evaluated, and the value of its last
expression is the spec: named tuples or dictionaries where TOML has tables,
tuples or arrays where it has lists. It is for a spec whose runs are a
product, where the TOML would be the same table many times:

```julia
runs = [(label = "$v-g$g-$m-$p", cmd = "bench/nested.jl $v $p", ranks = g, mpi = m)
        for v in ("v7", "v13"), g in (1, 2, 6), m in ("jll", "mpiabi"), p in ("staged", "direct")
        if !(m == "jll" && p == "direct")]

(name = "nested",
 site = Dict("nibi" => (time = "1:00:00", resources = (nodes = 1,), env = "test")),
 run = runs)
```

- The keys and their meaning are those of a TOML spec, and so are the
  checks. Everything else is Julia's: there is no key for a product, a
  condition or a variable.
- A site's name that is not a Julia name, such as `local` or `trillium-gpu`,
  needs a dictionary as above.
- A matrix of runs, as a comprehension over two ranges without a condition
  gives, is read in its order of storage: the first range varies fastest.
- The file is one file, evaluated in a module of its own with Julia's
  standard library. It cannot load the study's packages or `include`
  another file.
- It must give the same spec every time: `wait`, `after` and `resubmit`
  evaluate it again. No random numbers, dates or files that change.
- `submit` keeps what the file evaluated to beside the batch script on the
  site, as `jobs/<name>-<time>.toml`, and the file itself as `.jl`.
  `submit --dry-run` shows the runs without submitting.

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
