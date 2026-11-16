# SimLaunch: design and plan

2026-11-16 · Erik Schnetter

The design of SimLaunch, its reasons and its milestones. Milestones 1 and 2
are implemented; [Plan and open questions](#plan-and-open-questions) says
what has run where. Sections on status, fetch, restarts, variants, MPI and
placement describe what milestones 3 and 4 will build.

**Contents**

- [Summary](#summary)
- [The problem](#the-problem)
- [What the other packages need](#what-the-other-packages-need)
- [Concepts](#concepts)
- [Site profiles](#site-profiles)
- [Source snapshots](#source-snapshots)
- [Prepare](#prepare)
- [Job specs and generated scripts](#job-specs-and-generated-scripts)
- [Submit, status, fetch and restarts](#submit-status-fetch-and-restarts)
- [Immutable outputs and restarts](#immutable-outputs-and-restarts)
- [A session with the tool](#a-session-with-the-tool)
- [Implementation](#implementation)
- [Migrating the existing scripts](#migrating-the-existing-scripts)
- [Non-goals](#non-goals)
- [Plan and open questions](#plan-and-open-questions)

## Summary

SimLaunch is one small command-line tool, `simlaunch`, that takes a Julia
project from the laptop to any of six sites and back: `local`, `symmetry`,
`nibi`, `fir`, `trillium` (CPU) and `trillium-gpu`. It copies an immutable snapshot
of every modified package, instantiates and precompiles in the right place,
generates the batch script from a short job spec and a site profile, submits
it with SimWatch, and fetches the results.

The tool runs on the laptop only. On the clusters it leaves plain files: a
source tree, a bash batch script and an output directory. Nothing of its own
has to be installed or kept running there.

A study's sources are the same on every site; its setup is not. Each site
resolves its own manifests (the laptop takes Metal, Symmetry takes CUDA), and
a job spec keeps everything that depends on cores, threads, memory or time in
a table per site.

Everything a job writes is immutable once the job has ended. Every job writes
a directory of its own, a restart reads its predecessor's checkpoint without
touching its files, and combining a chain's outputs is a separate step. The
tool enforces this by default, with a per-spec opt-out for drivers not yet
converted.

It replaces knowledge that now lives in four skills and about forty
hand-written scripts across five projects: TreeAMR's 13 benchmark scripts,
TreeWaveOLDG's 11 job scripts, TreeGRRMHD's suite script,
TreeGeneralizedHarmonic's (`symmetry-run.sh`, `ci/full-suite-symmetry.sh`,
the `bench/symmetry_mpi_*.sh` family), XCTS (`copy-to-symmetry.sh`,
`launch.sh`, `run.sh`) and the per-study scripts written in scratch
directories. The design follows SimFactory's machine database and simulation
layout, without its Cactus-specific parts.

**Order of work:** a first version that runs step S1's sweep on Trillium and
the laptop (done); then the other sites and the device environments (done,
except for two runs that wait on Nibi and on Symmetry's CPU nodes); then
queue rules, status, fetch and restarts; then the existing scripts are
rewritten on top of it one at a time.

## The problem

Every new job re-derives the same cluster facts, and the mistakes show up
hours later in a queue. The sites differ in almost every dimension a job
script touches:

| | Symmetry | Nibi | Trillium CPU | Trillium GPU |
| --- | --- | --- | --- | --- |
| User | `eschnetter` | `eschnett` | `eschnett` | `eschnett` |
| Connection | local tunnel | MFA master | MFA master | via `trig-login01` |
| Account | none | `def-eschnett` | `def-eschnett` | `def-eschnett` |
| Partition | must be chosen | must not be given | `compute` or `debug` | `compute`, `debug`, `compute_h200`, … |
| Node | 64 cores, whole node | 192 cores, by core or node | 192 cores, whole node | 24 cores per H100 |
| Memory | `--mem` required on H200 | 256 MB/core default | whole node | fixed per GPU |
| Login node CPU | Intel, unlike compute | Sapphire Rapids, unlike compute | same as compute | same as compute |
| Precompile on | a compute node | a compute node | the login node | `trig-login01` |
| Compute internet | yes | yes | no | no |
| `/home` in jobs | writable | writable | read-only | read-only |
| Environment into job | passed | passed | `--export=NONE` | `--export=NONE` |
| Multi-GPU MPI | HPC-X, `--bind-to none` | system Open MPI, patched Julia | mpi_abi_wrapper, patched Julia | not yet set up |

Step S1 of TreeGeneralizedHarmonic alone (2026-11-15) hit five of these:

- XCTS takes six sibling checkouts through `../` path sources, and finding
  and copying them was done by hand, twice.
- The Nibi sweep had to be rewritten for Trillium: no precompile in the job
  (read-only depot), no core or memory requests, an offline flag.
- Both CPU clusters were down at once; moving a study meant a new tree, a new
  script and a new SimWatch directory.
- Symmetry's suite cannot run with `JULIA_EXCLUSIVE=1`, `mpi_tests.jl` needs
  `HYDRA_LAUNCHER=fork` inside SLURM, and a pre-empted `h200preq` job can end
  `FAILED` instead of requeued. Each is a line in `CLAUDE.md` that a new
  script must remember.
- Rsyncing changed sources into a directory whose jobs are running rewrites
  the package image they have mapped. Every long study therefore needs its own
  remote directory, which is a convention, not a guarantee.

## What the other packages need

TreeAMR (13 scripts), TreeGRRMHD (2) and TreeWaveOLDG (11) all fit the
design, and they need seven things beyond TreeGeneralizedHarmonic's and
XCTS's scripts. Each is in the section named in the last column.

| Need | Who | Example | Where |
| --- | --- | --- | --- |
| Several versions of a package in one job, on one node | TreeAMR, TreeWaveOLDG | `symmetry_nested.sh` with `TREEAMR_NESTED_VERSIONS="base=… step1=… step2=…"`; `benchmark.sh`'s baseline repository | Source snapshots: variants |
| An environment that develops the package and adds others, leaving its `Project.toml` alone | all three | CUDA beside the package (`symmetry_gpu.sh`, `gpu.sh`); the test dependencies with relative sources made absolute (`symmetry_copies.sh`); TreeWaveOLDG's `bin/Project.toml` | Prepare: environments |
| Runs one after another, each a SimWatch stage, rows kept as printed | TreeAMR, TreeWaveOLDG | thread scans at 1, 8, 16, 32 and 64; `prescribed.sh`'s stage per run | Job specs: sequential runs |
| Placement in a node: pinned threads, a rank per NUMA domain, a fixed node, perf counters | TreeAMR, TreeWaveOLDG | `symmetry_mpi.sh` binds rank i of R to domain i·8/R; `symmetry_affinity.sh` on cn099 | Job specs: placement |
| Several MPI builds, rank counts and nodes | TreeAMR | MPICH_jll under `srun --mpi=pmi2` against HPC-X's `mpiexec`; 1 to 8 ranks on one node, then 2 and 4 nodes | Job specs: MPI |
| A Julia version and flags per run | TreeGRRMHD | its suite at `julia +1.13` and at the release, and with `--check-bounds=yes` | Job specs: per-run fields |
| A step after the runs, inside the job | TreeAMR, TreeWaveOLDG | `mpitable.awk`'s weak-scaling table; rows echoed at the end of the log | Job specs: `[after]` |

The rest was covered already. TreeGRRMHD's per-commit suite is
TreeGeneralizedHarmonic's script with another queue (`amddebugq`, since its
suite takes 12–21 minutes). Every TreeWaveOLDG script already splits its work
as `prepare` does: develop on the login node, precompile on the node type that
runs. TreeAMR's Float32 device runs on the laptop's Metal are the `local` site
with a `metal` environment.

## Concepts

Five words carry the design: a **site** is where jobs run, described by its
profile; a **study** is one immutable snapshot of a project and its path
packages; a **job** is one batch allocation, generated from a spec; a **run**
is one command inside a job, with its own output directory and SimWatch
status; **fetch** brings a run's results home.

```
on the laptop
  project + its packages ──snapshot──▶ study snapshot          job spec   site profile
  (the worktree and its ../           (taken once, never         │            │
   siblings, as edited)                changed; SHAs and         └──submit────┤
                                       diffs recorded)                        │
                                            │ prepare                         │
on each site                                ▼                                 ▼
                                       prepared copy ───used by───▶ batch job (generated,
                                       (instantiated, precompiled,   then queued; one
                                        no network needed after)     allocation)
                                                                              │
                                                                              ▼
  results in .claude/data/<study>/<site>/<run>/ ◀──────fetch───────── runs (a scratch
                                                                       directory each,
                                                                       SimWatch, logs)
```

A study may hold several variants of its packages, for comparisons inside one
job. It can be prepared on several sites at once. The sources are then
identical everywhere; the resolved packages and the resources are each
site's own. One spec is submitted to each site, with a table per site for
what differs, and the results come back to one directory per site in the
project.

## Site profiles

Each site is one TOML file in SimLaunch's repository, `sites/<name>.toml`, and
it is the single place a cluster fact is written down. The skills then point
at the profiles instead of repeating them.

A profile has five tables. `[connect]` says how to reach the site and how to
check first; `[paths]` where code and output go; `[slurm]` the account and the
queue rules; `[julia]` which Julia, which modules and where to precompile;
`[env]` what every job exports. Trillium's CPU profile, abbreviated:

```toml
name = "trillium"

[connect]
host = "trillium"
check = "ssh -O check trillium"      # MFA: never open a new connection
hint = "run: ssh -fN trillium"

[paths]
code = "/home/eschnett/claude/studies"     # read-only in jobs
scratch = "/scratch/eschnett/claude/studies"

[slurm]
account = "def-eschnett"
export_env = false                     # sbatch runs with --export=NONE
node = { cores = 192, numa = 8, mem = "767000M", whole = true }
queues = [
  { partition = "debug",   max_time = "1:00:00",  max_nodes = 4, one_at_a_time = true },
  { partition = "compute", max_time = "24:00:00" },
]

[julia]
bin = "~/.juliaup/bin/julia"
bin_mpi = "~/claude/julia-1.13.4-trillium/bin/julia"   # setrpaths-patched
modules = []                           # a pure Julia job needs none; the MPI recipe loads StdEnv/2023
precompile_on = "login"               # login node is Zen 5 like the compute nodes
compute_internet = false               # prepare fetches everything; jobs run offline

[env]
JULIA_PKG_OFFLINE = "true"
```

The other profiles differ where the table above says they do. Symmetry's has
`precompile_on = "compute"`, which makes `prepare` submit a short precompile
job, and per-partition rules: `amddebugq` up to an hour, `amdq` beyond,
`h200preq` only for runs that checkpoint, and `h200debugq` never chained.
Nibi's and Fir's have `partition = false`, since their submit filters choose.
`local` has no `[slurm]` table at all: its jobs run as background processes
under the same layout.

A site's GPUs are a table of their own, `[slurm.gpu]`: the batch option that
asks for them, the cores and memory that go with each GPU, the most a job
gets, and the GPU queues. Symmetry's:

```toml
[slurm.gpu]                            # H200, 141 GB
request = "--gres=gpu:h200:%d"
cores = 8                              # per GPU
mem = "64G"                            # per GPU; always given
max = 8
default_queue = "h200debugq"
queues = [
  { partition = "h200debugq", max_time = "1:00:00",  max_gpus = 2 },
  { partition = "h200q",      max_time = "24:00:00" },
]
```

Where the GPU nodes are another CPU than the CPU nodes, the table says where
to precompile for them. Fir's login and CPU nodes are both Zen 5 and its GPU
nodes Zen 4, so its profile has `precompile_on = "login"` under `[julia]` and
`precompile_on = "compute"` under `[slurm.gpu]`. Symmetry's H200 nodes are
Intel, a third CPU type besides its login node and its AMD nodes.

Trillium's GPU cluster is a Slurm cluster of its own with its own login node,
so it is a site of its own, `trillium-gpu`. Its `[connect]` table has
`host = "trillium"` for files, since both clusters see the same file systems,
and `via = "trig-login01"` for commands, which run there through the first
connection. Its directories are not the CPU cluster's, since the two prepare
for different CPUs.

A profile also lists its known traps as data the generator acts on, for
example `exclusive_breaks_threaded_subprocess = true` on Symmetry, so a
test-suite job is written without `JULIA_EXCLUSIVE`.

## Source snapshots

A snapshot is a copy of the project and every package it takes by path,
written once and never changed. It is taken once on the laptop, into
`~/.cache/simlaunch/<study>/`, and `prepare` copies that same tree to each
site, so every site of a study runs identical sources. A changed source makes
a new study, so a running job never sees its package image rewritten;
`simlaunch snapshot` refuses a study name that already exists.

**What goes in.** The tool reads `Project.toml` and `Manifest.toml` and
collects every package with a `path` entry: `[sources]` paths such as XCTS's
six siblings. A package added with `Pkg.develop` alone is named in the
manifest only, and is refused until it has a `[sources]` entry. It follows those
packages' own path sources too. GitHub-pinned packages stay pins by default,
so a run resolves what CI tests; `--snapshot-pins` copies the local checkouts
of named pins instead, for an unpushed change to TreeAMR or SpacetimeMetrics.
When a pinned package has a checkout beside the project (`../<Name>`) whose
commit or working tree differs from the pin, `snapshot` prints a warning that
names the package and the option.

**Layout.** Packages keep their relative positions, so `../HexCGSEM` still
resolves:

```
<code root>/<study>/
  src/XCTS-harmonic/        the project
  src/HexCGSEM/  src/HexMeshes/  src/SpacetimeMetrics/  …
  variants/<name>/src/…     further versions, for comparisons in one job
  envs/<variant>-<kind>/    environments written by prepare
  depot/                    the study's Julia depot: its compiled caches
  snapshot.toml             what was copied, from where, at which commit
  jobs/                     generated batch scripts
<scratch root>/<study>/
  <run>/                    one directory per run, and one per job inside it
```

**Variants.** A study can hold several named versions of the same packages,
for comparisons that must run in one job on one node (two nominally identical
Symmetry nodes have measured 20 % apart).
`simlaunch snapshot . --study nested --variant base=~/src/jl/TreeAMR-main`
writes the second version to `variants/base/src/`, with its own entry in
`snapshot.toml`. A run names its variant; each variant gets its own
environments and its own precompiled image, so the versions differ only in
the package.

**Provenance.** `snapshot.toml` records, per package, the local path, the git
branch and SHA, and whether the tree was dirty; a dirty tree also gets its
`git diff` saved beside it. A result can then always be traced to the exact
code that made it, including uncommitted changes, which is the normal state
while a study is being developed.

**What is excluded.** `.git`, every `Manifest.toml`, editor backups, `out/`,
checkpoints and anything listed in a `.simlaunchignore` file.

**Manifests are not copied.** A manifest names what one machine resolved, for
one Julia version: Metal on the laptop, CUDA on Symmetry. Each site therefore
resolves its own in `prepare`, also for a project that tracks its manifest
(XCTS). Identical sources thus do not guarantee identical dependency
versions; `prepare` records what each site resolved and reports the
differences ([Prepare](#prepare)).

**Cost.** A snapshot is a few tens of MB (XCTS's seven trees: 36 MB) and a few
seconds of rsync. A study that is reused for many runs pays it once. Old
snapshots are removed with `simlaunch clean`, never automatically.

## Prepare

`simlaunch prepare` makes a snapshot runnable at its site: after it, a job
needs no network, writes nothing to the depot and compiles nothing it did not
compile before. It runs once per study and site, for the specs it is given,
and again only when a spec adds an environment, a Julia version or Julia
flags.

1. **Registry and instantiate**, on the login node, with
   `JULIA_PKG_PRECOMPILE_AUTO=0`: `Pkg.Registry.update()`, then
   `Pkg.instantiate()`. The login nodes of all three clusters reach GitHub and
   the package server.
2. **Environments.** A run executes in an environment the tool writes inside
   the study, `envs/<variant>-<kind>/Project.toml`. It `Pkg.develop`s the
   snapshot's packages by path and adds what the spec names: CUDA or Metal,
   MPI and MPIPreferences set to the site's binary, the package's test
   dependencies (its `test/Project.toml`, relative `[sources]` made absolute,
   so a suite runs on a device), a script environment such as TreeWaveOLDG's
   `bin/Project.toml`, or single packages such as `OrdinaryDiffEqLowOrderRK`
   for a benchmark's comparison rows. The package's own `Project.toml` never
   changes, since CI must not install a device package. The default kind is
   the project itself, as the snapshot holds it. A run at another Julia
   version, such as TreeGRRMHD's floor run at 1.13, gets its own copy of its
   environment, since a manifest is written per version.
3. **Downloads that happen at first use**, fetched now on sites without
   compute-node internet: CUDA's runtime artifacts
   (`using CUDA; CUDA.versioninfo()` on `trig-login01`), and the test
   dependencies. A suite job runs `test/runtests.jl` in the prepared `test`
   environment, not `Pkg.test`, whose sandbox resolves and precompiles when
   the job runs.
4. **Precompile where the profile says**, once for every combination of
   environment, Julia version and Julia flags the specs name, since
   `--check-bounds=yes` has its own cache. On Trillium, on the login node of
   the matching cluster. On Symmetry and Nibi, whose login nodes are a
   different CPU from the compute nodes, `prepare` submits a short precompile
   job on the target partition, on the node type of the job that will use it.
   `prepare` can be interrupted while that job waits in the queue; run again,
   it finds the job and continues.

**The study's depot.** Every study has a Julia depot of its own on each site,
`<code root>/<study>/depot/`, and its jobs run with
`JULIA_DEPOT_PATH="<depot>:"`: the study's depot, then the depots that come
with Julia, and not `~/.julia`. Its `compiled/` directory holds the study's
precompiled caches; `packages`, `artifacts`, `registries`, `clones` and
`scratchspaces` are links into the site's depot, since what is installed
there is written once and never changes. The reason is a failure seen on
Trillium on 2026-11-16: with one shared depot, preparing a second study wrote
a newer cache of a package both use (SpecialFunctions), and the first study's
caches, built against the older one, were then rejected and compiled again.
A study's caches are now touched only by its own `prepare`, so they are as
immutable as its sources, and `clean` removes them with the study. The cost
is disk space in the code root: each study compiles its dependencies again
(XCTS-harmonic on Trillium: 104 MB, half a minute).

**The precompile lock.** Two of the tool's jobs never precompile on one site
at once. The lock is a directory on the site, made by `prepare` over
ssh (`mkdir` is atomic), holding the precompile job's ID and removed by that
job's exit trap; a lock whose job `squeue` no longer knows is stale and is
taken over. The lock binds only what the tool submits. A hand-written script
that precompiles, such as `ci/full-suite-symmetry.sh` before it is migrated,
does not see it.

**Resolved versions.** The manifests `prepare` writes stay on the site, in
the study's `envs/` and beside the project for the default kind. They are not
resolved again once prepare has succeeded, and they are fetched with every
run's results. `prepare` prints the packages whose versions differ from the
study's other prepared sites, so a difference is seen before the jobs run.
It cannot remove one: a site may be unable to install what another resolved.

Prepare writes its log to `<scratch root>/<study>/prepare.log`. `submit`
refuses a job whose study is not prepared on that site, or whose spec names a
combination prepare has not compiled, and says which. The generated script
checks the same before each run (`Base.isprecompiled` under the run's Julia
and flags) and fails at once, since a stale cache on a read-only depot
otherwise means a silent compile in every run.

## Job specs and generated scripts

A job spec says what to run and what it needs; the site profile turns it into
a batch script. What to run is the same on every site. What it needs is not:
time, threads, memory, the split of a node among the runs and the device
environment follow the site's hardware, so they sit in a table per site.
Moving a study to another site means adding that site's table, not writing a
new script.

The spec is a TOML file kept with the study's sources, for example
`jobs/s1-sweep.toml`. Step S1's sweep, which ran on Nibi and Trillium
from two hand-written scripts:

```toml
name = "sweep1"
project = "XCTS-harmonic"           # relative to the snapshot's src/
checkpoints = false                 # true: a chain of jobs, one directory each
blas_threads = 1

[site.trillium]                     # a 192-core node: the six runs side by side
time = "3:00:00"
resources = { nodes = 1 }           # or { gpus = 1 }, { gpus = 4 } with ranks per run
mode = "parallel"                   # default "sequential"
threads = 32                        # per run
pin = false                         # true: JULIA_EXCLUSIVE + srun --cpu-bind=none
env = "default"                     # or "cuda", "mpi", "test+cuda", … built by prepare

[site.nibi]                         # the same node size
time = "3:00:00"
resources = { nodes = 1 }
mode = "parallel"
threads = 32

[site.local]                        # the laptop: one run after another
mode = "sequential"

[[run]]
label = "p6"
cmd = "examples/harmonic_single.jl p=6"

[[run]]
label = "p8r2"
cmd = "examples/harmonic_single.jl p=8 M=4 M_h=4 M_f=4 M_i=4 M_s=8"
# … four more
```

**Per site.** `time`, `resources`, `mode`, `threads`, `pin`, `env`, memory
and the placement fields are read from `[site.<name>]`. A value at the top
level is a default for every site, meant for what does not depend on
hardware. A site without a table gets its profile's defaults (one node,
sequential runs, the default environment) and must be given a `time`.
`threads` defaults to the allocation's cores in sequential mode, and to the
cores divided by the runs in parallel mode. `submit` checks the result
against the profile and refuses a job that asks for more cores, memory or
GPUs than its allocation holds, such as six runs of 32 threads on a 64-core
Symmetry node.

**Parallel or sequential.** `mode = "parallel"` starts every run at once with
its share of the cores, as the S1 sweep did. `mode = "sequential"`, the
default, runs them in order, each a SimWatch stage of the job, as every
TreeAMR and TreeWaveOLDG script does. Either way each run's output goes to its
own directory as it is printed, so a job that runs out of time keeps what it
measured, and the job log echoes it at the end.

**Per-run fields** override the job's: `variant`, `env`, `threads` (a list
expands into a scan, `threads = [1, 8, 16, 32, 64]`), `julia` (a juliaup
channel such as `"+1.13"`), `julia_args` (`["--check-bounds=yes"]`), `ranks`,
`nodes`, `placement`, `mpi`, and `vars` for environment variables a script
reads, such as TreeWaveOLDG's `TREEWAVEOLDG_RUNS`. An `[after]` table names
one shell command run inside the job after the last run, for a table such as
TreeAMR's `mpitable.awk`.

**Placement.** `pin = true` is `JULIA_EXCLUSIVE=1` with
`srun --cpu-bind=none` and `-t N,0`. `placement = "numa"` binds rank i of R to
NUMA domain i·D/R with `numactl --cpunodebind --membind`, D from the profile
(8 on Symmetry's EPYC 7543 nodes and on Trillium, 6 on Nibi).
`node = "cn095"` fixes the node for a benchmark, and every job records
`lscpu`'s model.

**MPI.** `mpi` names a recipe in the site profile: `jll` (MPICH_jll under
`srun --mpi=pmi2`, or its own `mpiexec` with Hydra forking the ranks) or
`system` (HPC-X on Symmetry, Open MPI on Nibi, the mpi_abi_wrapper on
Trillium). Runs of one job may use different recipes and rank counts, which is
how TreeAMR compares MPICH_jll with HPC-X at 1 to 8 ranks. `nodes` above 1
restricts the queue choice to queues that allow it (on Symmetry `amdq`, since
`amddebugq` takes one node).

**Escape hatch.** `sbatch_args` adds lines to the batch header as written,
and a run's `prefix` is put before its Julia command as written. A need that
one script has, such as `symmetry_affinity.sh`'s perf counters, uses these
and becomes a field of its own only when a second script needs it.

A benchmark of two versions in one job, as `symmetry_nested.sh` runs it. Its
node, ranks and placement are Symmetry's, so it names its one site and the
tool refuses any other:

```toml
name = "nested-ab"
site = "symmetry"                   # written for this hardware only
time = "1:00:00"
resources = { nodes = 1 }
node = "cn095"
pin = true

[[run]]
label = "base-8r"
variant = "base"
cmd = "bench/nested.jl"
ranks = 8
threads = 8
placement = "numa"
mpi = "jll"

[[run]]
label = "new-8r"
variant = "default"
cmd = "bench/nested.jl"
ranks = 8
threads = 8
placement = "numa"
mpi = "jll"
# … 1, 2 and 4 ranks, both variants
```

**What the generator writes**, for every site, so no script forgets it:

- the `#!` line, the account, the time, and resources in the site's terms
  (whole nodes on Trillium, `--mem` always on Symmetry, no partition on Nibi);
- every `module load` and variable inside the script, since Trillium passes
  no environment;
- the Julia binary, plain, patched or a juliaup channel, the run's
  environment, and `JULIA_LOAD_PATH` for a stacked one;
- thread and BLAS counts, and pinning only when asked and safe (never for a
  test suite on a site with the `JULIA_EXCLUSIVE` trap);
- the output directory under scratch, a new one for every job and made
  read-only when the job ends, and an absolute `--output` path beside it;
- a check before each run that its environment is precompiled for this Julia
  and these flags;
- SimWatch: one live status file per run, marked running, then finished or
  failed with the exit code;
- for `checkpoints = true`: `--no-requeue`, the earlier job directories made
  read-only, the newest complete checkpoint among them passed as the restart
  source, the restart and walltime arguments, and on pre-emption a successor
  that starts only after this job has ended
  ([Immutable outputs and restarts](#immutable-outputs-and-restarts)).

**Queue choice.** The tool picks the cheapest queue that fits the spec, by
rules in the profile:

| Site | Fits in 1 h | Longer | GPU, no checkpoints | GPU with checkpoints |
| --- | --- | --- | --- | --- |
| Symmetry | `amddebugq` | `amdq` | `h200q` (`h200debugq` once, never chained) | `h200preq` |
| Nibi | chosen by the submit filter | same | same | same |
| Trillium | `debug` if no other debug job | `compute` | `compute` (H100) | `compute` |

`--queue` overrides the choice; the tool then still checks the spec against
that queue's limits and refuses with the limit it breaks.

## Submit, status, fetch and restarts

**Submit** copies the generated script into the study's `jobs/`, submits it
from the right login node (`trig-login01` for Trillium's GPUs), and marks
every run's SimWatch directory queued with the job ID before returning. A
study's runs are therefore visible in SimWatch from the moment they exist.

**Status** is SimWatch's: `simlaunch status` runs `simwatch --print` on each
site that holds runs of the named studies and prints one table. Erik's own
view stays `simwatch <site>:<dir>`, which the tool prints at submission.

**Fetch** copies a run's results back to
`.claude/data/<study>/<site>/<run>/` in the project the study came from:
logs, CSVs, `records.csv`, `simwatch.toml`, plots, `snapshot.toml` and the
site's resolved manifests. The site is part of the path, so the same spec run
on two sites never lands in one directory. Checkpoints and other files above
a size limit stay on the cluster unless `--with-checkpoints` is given. The
analysis scripts that read `.claude/data` (`test/aligned_study.jl`,
`test/harmonic_spin_study.jl` and the rest) read a run's directory as they
do now.

A run with checkpoints comes back as its job directories, unchanged, with its
`combined-<n>/` directories beside them. An analysis script that wants one
series reads a combined directory.

**Restart chains.** A run with `checkpoints = true` is a chain of jobs, each
in a directory of its own;
[Immutable outputs and restarts](#immutable-outputs-and-restarts) has the
layout and the rules. `simlaunch resubmit <run>` submits the next job of the
chain, and `--chain N` submits N jobs with `--dependency=afterany`, which
suits Trillium's and Nibi's 24 h limits.

**Cleanup.** `simlaunch clean <study>` lists what it would delete on each site
(snapshot, scratch, checkpoints, with sizes) and deletes only after
confirmation, first restoring write permission on the job directories it made
read-only. Nothing is ever deleted automatically: step H1's checkpoints alone
reached 94 GB, and deleting checkpoints has been Erik's decision each time.

## Immutable outputs and restarts

Everything a job writes is immutable once the job has ended: no later job,
restart or requeue appends to it or rewrites it, and it can only be deleted.
The tool enforces this for every job through the layout and file
permissions: a job gets a new directory and makes it read-only when it ends.
For a spec with `checkpoints = true` the same holds along the chain; a spec
can opt out of that part while its driver is converted.

Enforcing it now costs little. Every package's job scripts are rewritten for
the tool anyway, and today only TreeGeneralizedHarmonic's drivers checkpoint
(`octant_runs.jl`, `binary_runs.jl`, `hole_runs.jl`), so they are the only
code that has to change.

**Layout.** A run with checkpoints is a chain of jobs, each in a directory of
its own:

```
<scratch root>/<study>/<run>/
  simwatch.toml          live status of the whole run, updated by every job (exempt)
  slurm-2864584.out      Slurm's own log of one job ID
  001-2864584/           the first job: its logs, CSVs, plots, ck/
  002-2864611/           a restart: reads 001-2864584/ck/, writes only here
  combined-1/            written by a combine step, never by a job
```

**What the generated script does.**

- Each job writes only into its own new directory, numbered in order and named
  with its job ID. It never opens an earlier one for writing.
- Before it starts, a job makes its predecessor's directory read-only
  (`chmod -R a-w`), so a driver that tries to append to an old file fails at
  once instead of silently changing a result. A job does the same to its own
  directory in its exit trap; when a job is killed before its trap runs, its
  successor does it.
- No job runs twice under one job ID. Every job is submitted with
  `--no-requeue`, and `--open-mode=append` is never used. A pre-empted job
  submits its successor from its SIGTERM handler within the 30 s grace, unless
  a `--chain` successor is already pending; this is the branch on exit code
  143 that step B1's scripts already have. The successor is submitted with
  `--dependency=afterany:` and the job's own ID, so it cannot start, and
  cannot make this directory read-only, while this job still writes. A node
  failure ends the chain, and
  `simlaunch resubmit` or a pending `--chain` successor continues it.
- Slurm's `--output` goes to `slurm-<jobid>.out` beside the job directories,
  since Slurm cannot write into a directory that does not exist yet. With
  unique job IDs it, too, is written by one job only.
- `simwatch.toml` is live status, not output: each job updates the run's one
  file, and SimWatch's `previous_job_ids` records the chain.

**The driver's side.** A restartable driver takes two separate arguments,
named in the spec: where to read the newest checkpoint from, and where to
write its own.

```toml
[restart]
from = "restart_from"    # an earlier job's ck/, read-only
to = "checkpoint"        # this job's own ck/
walltime = "walltime"    # seconds: the job's time limit minus a startup margin
```

The first job gets only `to`. A driver writes its CSVs and records into its
working directory, which is the job directory, so a restart starts new files
rather than extending old ones.

`from` is not always the predecessor's `ck/`: a job killed before its first
checkpoint leaves none. The script passes the `ck/` of the newest job
directory that holds a complete checkpoint, and no `from` when there is none.
The tool cannot tell a complete checkpoint from a partial one by itself, so
the driver must write each checkpoint under a temporary name and rename it
when it is whole; the tool then ignores temporary names. This is a
requirement on the driver that the tool can test but not enforce.

**Checking a driver.** `simlaunch check-restart <spec>` runs a short chain
of the spec twice on one site: once uninterrupted, once with its first job
killed after a checkpoint. It passes when the killed job's directory is
unchanged afterwards (checksums), no temporary checkpoint name was read, and
the project's own compare command, named in the spec, accepts the combined
result against the uninterrupted one. What "the same result" means stays
with the project.

**Storage.** Each job keeps its own checkpoints, where a shared directory
kept one set, so a chain of N jobs holds up to N sets. A driver should keep
only its newest checkpoint in its `ck/`. SimLaunch never deletes checkpoints
by itself, and neither does a job: whoever runs the jobs deletes them.
`simlaunch clean <run> --old-checkpoints` lists the checkpoints of every job
but the newest, with sizes, and deletes them after confirmation. The
clusters' scratch purges apply to these files as to any others: fetch what
must be kept.

**Disk usage.** Each job measures itself when it ends: its exit trap runs
`du` on its own directory and on its `ck/`, and appends the two numbers to
`diskusage.toml` beside `simwatch.toml`. A job killed before its trap is measured
by its successor, as with the read-only step. The measurement walks one job's
files only, and runs under a time limit (60 s); when it does not finish, the
entry says `unknown` and the job still ends. `simlaunch usage <study>` adds
up the recorded numbers per run, per job and per site. It reads only these
small files and never walks a tree, so it answers at once, and `clean` shows
the same numbers. `simlaunch usage --measure` walks the trees for entries
that are `unknown` or for a job still running, and is the only slow path.

SimWatch shows a run while it runs, when the running job's size is not known
yet, so it is not where disk usage is asked for. It gets what is known at no
cost: each job's last status update, the one that marks it finished or
failed, also writes a `diskusage` key with the run's recorded total. During a
chain SimWatch therefore shows the size of the jobs that have ended, and
after the run its full size.

**Combining.** Reading a run as one series is a later step.
`[combine] cmd = "…"` names a project script that reads the job directories in
order and writes a new `combined-<n>/`; `simlaunch combine <run>` runs it on
the site, or on the laptop after a fetch. Each combine writes a new directory,
so its output is immutable too.

**Opting out.** `mutable_restarts = true` keeps today's behaviour for a driver
that is not converted yet: one shared checkpoint directory passed as a single
argument, appended CSVs, no read-only step, and requeue under the same job ID
with `--open-mode=append`. `simlaunch submit` prints a warning for such a
spec. TreeGeneralizedHarmonic's three checkpointing drivers use it until
they are converted, all three together, in that repository.

## A session with the tool

The S1 sweep from start to finish, as it would have gone on 2026-11-15 with
Nibi down:

```bash
# the snapshot, from the XCTS worktree: finds and copies the six siblings
simlaunch snapshot ~/src/jl/XCTS-harmonic --study s1

# copy, instantiate, fetch, precompile on tri-login (checks ssh -O check first)
simlaunch prepare s1 --site trillium --spec jobs/s1-sweep.toml

# generate, show, submit; marks six SimWatch runs queued
simlaunch submit s1 jobs/s1-sweep.toml --site trillium

# one table across sites
simlaunch status s1

# copy results into .claude/data/s1/trillium/
simlaunch fetch s1
```

Moving the same study to Nibi when its nodes return is `prepare`, `submit`
and `fetch` again with `--site nibi`, using the spec's `[site.nibi]` table;
Nibi resolves and precompiles its own environment. Running it on the laptop
is `--site local`. `simlaunch submit --dry-run` prints the generated script and
the queue it chose without submitting, which is also how a new profile is
checked.

The Julia entry points stay the projects' own scripts: `test/octant_runs.jl`,
`examples/harmonic_single.jl`, `Pkg.test`. The tool never wraps or parses
them; it only decides where and how they run.

## Implementation

Julia (decided 2026-11-15), as a package with only standard-library dependencies:
`TOML` and `Dates`.

- The trickiest input is `Project.toml` and `Manifest.toml`: `[sources]`
  paths relative to the project, developed packages, manifest format versions,
  pins. The tool reads both files with `TOML`, following each path package's
  own `[sources]`. It does not use `Pkg.dependencies()`, which needs an
  instantiated environment and makes every command load `Pkg`. A package that
  only the manifest names by path (`Pkg.develop` without a `[sources]` entry)
  is refused, since a site gets no manifest and could not find it.
- Julia's backtick commands run `ssh`, `rsync` and `sbatch` without a shell,
  which removes a class of quoting bugs. `Base.shell_escape` covers the one
  place that still needs quoting: the command string for the remote shell.
- Installed as a Pkg app (`[apps]`, experimental in Julia 1.12), `simlaunch`
  is a command in `~/.julia/bin` with its own environment, separate from the
  projects it runs.
- Startup cost matters little: the tool runs a few times per study, not in a
  loop. It is to be measured with `Pkg` loaded. Status polling stays with
  SimWatch.
- Batch scripts are generated as text from templates kept beside the profiles,
  and tested by snapshot tests of the generated script for each site profile.

Rust would be the choice for a single fast binary used by people without
Julia, or called from SimWatch; neither applies. Bash is what the current
scripts use, and the reason they are hard to keep right: no data structures,
no TOML parser, and quoting through two shells.

## Migrating the existing scripts

Each script moves only when a run of it is due anyway, and its replacement is
checked against one run of the old one. Nothing that is running changes:
running jobs keep their scripts and directories, as SimWatch's rules already
require.

| Script | Becomes | Note |
| --- | --- | --- |
| TreeGH `.claude/orchestration/symmetry-run.sh` | a job spec per job kind (`suite1`, `suite4`, `hole:<section>`) | its `PART`, `TLIM` and `~` conventions become spec fields |
| TreeGH `ci/full-suite-symmetry.sh` | `simlaunch submit` of a suite spec on a `git archive` snapshot, then its `collect` step unchanged | each commit becomes a study of its own and compiles once; the fixed tree and its one cache slot go away. Posting the status stays a separate, asked-for step |
| TreeGH `bench/symmetry_mpi_gpu_env.sh` | the `mpi` and `cuda` environments, built by `prepare` per site | the HPC-X, Open MPI and mpi_abi_wrapper recipes move into the profiles |
| TreeGH `bench/symmetry_mpi_gpu.sh`, `_breakdown.sh`, `_steps.sh` | job specs with `ranks` and `mpi` | their comparisons stay as they are |
| XCTS `copy-to-symmetry.sh`, `launch.sh`, `run.sh` | `snapshot`, and a spec per task (`test`, `single`, `binary`, `adaptive`) | its tracked `Manifest.toml` stays for the laptop and CI; each site resolves its own |
| Scratch scripts of single studies (the S1 sweep, the harm-h1 to h3 batches) | specs under `jobs/` | written new for each study, as now, but a few lines long |
| The three skills | short pointers to the profiles, plus what is not a fact about a job (MFA, who to ask, cluster etiquette) | the profiles become the place a changed cluster fact is fixed |

The other packages' scripts move the same way:

| Script | Becomes | Note |
| --- | --- | --- |
| TreeAMR `bench/symmetry_*.sh` (11) | specs with variants, placement and MPI recipes | `symmetry_nested.sh`, `_mpi.sh` and `_affinity.sh` are the hardest cases, and the ones to try first |
| TreeAMR `bench/scan.sh`, `mpiscan.sh` | unchanged | laptop scans; their cluster versions become `threads` and `ranks` lists |
| TreeGRRMHD `ci/full-suite-symmetry.sh` | as TreeGeneralizedHarmonic's, its queue picked from the suite's time | its results already go to `full-suite/TreeGRRMHD/<sha>/` |
| TreeWaveOLDG `bin/symmetry/*.sh` (10) | specs; each script's `setup` becomes `prepare` | run lists move from environment variables into `[[run]]` tables, or stay as `vars` |
| The copies of `simwatch.sh` (TreeAMR, TreeGeneralizedHarmonic, TreeWaveOLDG, scratch copies) | one copy, carried by the tool | each project keeps its own until its last old script is retired |

SimLaunch does not convert drivers. A conversion is a change in the driver's
own package, reviewed and tested there, and whether a restarted run
reproduces an uninterrupted one is that package's property. SimLaunch states
the contract and checks it with `simlaunch check-restart`.
TreeGeneralizedHarmonic's checkpointing drivers, `test/octant_runs.jl`,
`test/binary_runs.jl` and `test/hole_runs.jl`, are converted together, as one
task in that repository that milestone 3 waits on. Until then they run with
`mutable_restarts = true`. Converting one means a `restart_from=`
argument beside `checkpoint=`, checkpoints written under a temporary name and
renamed, its CSVs started fresh in the job directory, and a
combine script that joins a chain's CSVs into the form `test/octant_study.jl`
and the other study scripts read. The packages without checkpoints today need
nothing: a run without `checkpoints = true` is one job in one directory.

`CLAUDE.md`'s command lines for the long runs stay as they are: they name the
Julia command, which the tool does not change.

## Non-goals

The tool decides where and how a command runs, and nothing about what it
computes. Explicitly out of scope:

- **A workflow engine.** No dependency graphs between runs, no
  parameter-sweep language, no retries by policy. A list of runs per job
  covers every study so far; a chain of restarts is the only dependency, and a
  threads list is the only expansion.
- **A daemon or a database.** State is the files on each site
  (`snapshot.toml`, the generated scripts, SimWatch's status files) and the
  cache on the laptop. A lost laptop cache costs a new snapshot, not a lost
  run.
- **Anything on the cluster that must be installed or kept running.**
  Generated scripts are plain bash and readable on their own.
- **Wrapping the Julia drivers.** Options such as `checkpoint=` and
  `walltime=` are passed through under the names the spec's `[restart]` table
  gives them; the drivers keep parsing their own arguments.
- **Pushing, tagging or posting.** The tool never runs `git push`, `gh` or a
  commit-status post. Those stay explicit, asked-for steps.
- **Hiding the cluster.** `--dry-run` shows every script, and a job can always
  be submitted by hand from the study's `jobs/` directory.

## Plan and open questions

Four milestones, each done when a real study has run through it on every
site it claims. The day counts are working time and exclude waits for queues
and for clusters that are down.

1. **One study, two sites.** Profiles for `local` and Trillium; snapshots with
   path sources and provenance; prepare on a login node; submit with SimWatch
   and `--dry-run`; per-site spec tables and the resource check. Done when
   step S1's sweep runs from one spec on `local` and on Trillium. About two
   days.

   Done on 2026-11-15: all six runs on Trillium (job 2865234), and on
   `local` the one run that fits into the laptop's 36 GB. Not implemented:
   the memory part of the resource check, and `--snapshot-pins`.
2. **The other sites and the device environments.** Profiles for Symmetry,
   Nibi and Trillium's GPUs; the remote precompile job and its lock; the
   `cuda` environment; the report of version differences between sites. Done
   when S1's sweep also runs on Nibi, a TreeGH octant smoke row runs on a
   Symmetry H200 and a Trillium H100, and a TreeWaveOLDG sequential job with
   a thread scan runs on Symmetry. About three days, most of it testing each
   site.

   Implemented on 2026-11-16, with a profile for Fir and the per-study depot
   in addition. Nibi's compute nodes and Symmetry's CPU nodes were down, so
   two of the runs went elsewhere:

   | Run | Site | Job | Result |
   | --- | --- | --- | --- |
   | S1's sweep | Fir (for Nibi) | 4362202 | six runs, `M_irr` identical to Trillium's |
   | Octant smoke row | Trillium, one H100 | 1342940 | finished |
   | Octant smoke row | Symmetry, one H200 | 599434 | finished, same values; precompile job 599432 |
   | TreeWaveOLDG thread scan, pinned | Trillium (for Symmetry) | 2869575 | 1 to 192 threads, `rhs` 40 times faster |

   Open: S1's sweep on Nibi, and the thread scan on Symmetry's CPU nodes,
   when they are back. Not yet seen on a cluster: a version report that
   lists differences, and a precompile lock that is held or stale.
3. **Queue rules, status, fetch, restarts.** SimLaunch delivers the restart
   contract and `simlaunch check-restart`. Converting TreeGeneralizedHarmonic's
   three checkpointing drivers is a separate task in that repository, done
   and tested there; this milestone waits on it and cannot finish before it.
   Done when `check-restart` passes for the converted drivers, a
   checkpointed GPU row survives a pre-emption on `h200preq` with the
   pre-empted job's directory unchanged (checksums before and after), a
   two-job chain runs on Trillium, its results land in `.claude/data` readable
   by the existing study scripts, and TreeAMR's nested benchmark runs as two
   variants with NUMA placement and two MPI recipes, on one node and on two.
   About three days.
4. **Migration.** The tables above, one script at a time, each when a run of
   it is due. Done when `symmetry-run.sh` and XCTS's three scripts are retired
   and the skills point at the profiles.

**Open questions for Erik:**

- [x] **Language.** Julia.
- [x] **Pins by default.** Snapshots keep GitHub pins as pins, so runs match
  CI, and warn when a local checkout differs from its pin.
- [x] **Where specs live.** In each project's `jobs/`, committed with the
  study.
- [x] **Symmetry's suite tree.** One compile per commit: each commit is a
  study of its own, and the fixed tree goes away.
- [x] **Converting the drivers.** `octant_runs.jl`, `binary_runs.jl` and
  `hole_runs.jl` are converted together, as a task in TreeGeneralizedHarmonic
  and not by SimLaunch, which delivers the contract and `check-restart`.
  Milestone 3 waits on that task.
- [x] **Different versions on different sites.** Accepted. Each site resolves
  its own manifests; the tool reports the differences and does not prevent
  them.
- [x] **Old checkpoints.** Deleted by whoever runs the jobs, with
  `clean --old-checkpoints`; never by SimLaunch or a job on its own.
- [x] **Suites without `Pkg.test`.** Accepted on every site: a suite job runs
  `test/runtests.jl` in a prepared environment.
- [x] **Disk usage in SimWatch.** `simlaunch usage` is where it is asked
  for. SimWatch gets a `diskusage` key with what is known when a job ends,
  not a live measurement.
