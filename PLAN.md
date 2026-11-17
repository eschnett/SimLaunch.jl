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

A profile has six tables. `[connect]` says how to reach the site and how to
check first; `[paths]` where code and output go; `[slurm]` the account and the
queue rules; `[julia]` which Julia, which modules and where to precompile;
`[mpi.<recipe>]` how MPI runs are set up and started; `[env]` what every job
exports. Trillium's CPU profile, abbreviated:

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
queues = [                             # in the order of preference
  { partition = "debug",   max_time = "1:00:00",  max_nodes = 4, one_at_a_time = true },
  { partition = "compute", min_time = "0:15:00", max_time = "24:00:00" },
]

[julia]
bin = "~/.juliaup/bin/julia"
modules = []                           # a pure Julia job needs none
# no [arch] table: one architecture, so the login node compiles for the compute nodes
compute_internet = false               # prepare fetches everything; jobs run offline

[mpi.system]                           # Open MPI 4.1.5 through mpi_abi_wrapper
julia = "~/claude/julia-1.13.4-trillium/bin/julia"   # setrpaths-patched: juliaup's cannot load it
modules = ["StdEnv/2023"]
launcher = "srun"
launcher_args = ["--mpi=pmix"]
[mpi.system.preferences]               # the keywords of MPIPreferences.use_system_binary
library_names = ["/home/eschnett/claude/openmpi-4.1.5-mpi-abi/lib64/libmpi_abi.so"]
abi = "MPIABI"

[env]
JULIA_PKG_OFFLINE = "true"
```

The other profiles differ where the table above says they do. Symmetry's
names two architectures, neither of them the login node's, which makes
`prepare` submit a short precompile job for each, and per-partition rules: `amddebugq` up to an hour, `amdq` beyond,
`h200preq` only for runs that checkpoint (`preempt = true`), and `h200debugq`
never chained (`chain = false`).
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
queues = [
  { partition = "h200debugq", max_time = "1:00:00",  max_gpus = 2, chain = false },
  { partition = "h200q",      max_time = "24:00:00" },
  { partition = "h200preq",   max_time = "24:00:00", preempt = true },
]
```

An MPI recipe names the binary (`jll`: MPICH_jll; `system`: the site's MPI),
the launcher (`srun` with its arguments, or `mpiexec`: the binary's own,
found through MPI.jl), the modules and variables its runs need, a Julia that
can load the site's MPI where juliaup's cannot, and whether its ranks can be
spread over several nodes. Symmetry has three: `jll` (MPICH_jll under
`srun --mpi=pmi2`), `jll-fork` (MPICH_jll's `mpiexec` with Hydra forking the
ranks, for one node and for GPU jobs) and `system` (HPC-X).

**Architectures.** A site's nodes are not one CPU type, and a compiled cache
is for one. A profile names its architectures in `[arch]`, each with its
`JULIA_CPU_TARGET` (`"native"` for the node's own CPU), and says which one
the CPU nodes (`[julia] arch`), the GPU nodes (`[slurm.gpu] arch`) and the
login node (`[julia] login_arch`) have:

```toml
[arch]
amd = "znver2"                         # Symmetry's EPYC 7532 and 7543 nodes
zen4c = "native"                       # cn112, an EPYC 8534P, through largememq
h200 = "native"                        # its H200 nodes: Sapphire Rapids

[julia]
arch = "amd"

[slurm.gpu]
arch = "h200"
```

- A study has one depot of compiled caches per architecture, and a job sees
  only its own (see "The study's depot").
- `prepare` compiles on the login node for the nodes that share its
  architecture, and in a job on a node of the kind for the others. Fir's
  login and CPU nodes are both Zen 5 (`login_arch = "zen5"`) and its GPU
  nodes Zen 4. A login node that names no architecture has its own,
  `login`: Symmetry's is Intel, and none of its nodes is.
- A profile without `[arch]` has one architecture, `default`, as Trillium's
  two sites, whose login nodes are their compute nodes' CPU.
- An architecture need not be one CPU model. Code for a named CPU runs on
  every CPU with that CPU's features, so neighbouring generations of one
  vendor can share one: Zen 2 code serves Zen 3; Sapphire Rapids code
  should serve Granite Rapids. What a newer node loses that way is not
  measured, so Nibi and Fir keep an architecture per node type for now.
- A queue can hold another kind of node than the site's others, and then
  names its own architecture: `{ partition = "largememq", on_request =
  true, arch = "zen4c" }`. A precompile job for an architecture runs in a
  queue whose nodes have it. `on_request` keeps the queue out of the choice
  by rule: only a job that names it gets it. A queue's `header` adds batch
  options to every job in it.
- Symmetry's AMD partitions list cn112, which is another machine: Zen 4c
  with AVX-512, 384 GB and fewer NUMA domains, where the others are Zen 2
  and Zen 3 with 256 GB and 8 domains. The profile keeps every job in them
  off cn112 (`header = ["--exclude=cn112"]`) and describes `largememq`,
  which holds only cn112, for the jobs that want it. The AMD architecture
  is then Zen 2 code alone. Partitions without cn112 would be the simpler
  fix; that is the site's to make.
- A target does not start with `generic`. A node that cannot run the code
  must refuse the cache, and its job then stops at its precompile check; a
  `generic` part runs everywhere, slowly and without a word.

The reason, found by TreeAMR on Symmetry on 2026-11-17: there was one depot
per study, the AMD nodes compiled into it with
`generic;znver2,clone_all;znver4,clone_all`, and the H200 nodes with their
own CPU. Julia loads any cache that the host can run, whatever
`JULIA_CPU_TARGET` says, which only decides what is built. So the H200
precompile job (601141) found FastPower's cache from the AMD job (601139)
valid through its `generic` part, built nothing, and the H200 jobs ran
x86-64 code without FMA.

Trillium's GPU cluster is a Slurm cluster of its own with its own login node,
so it is a site of its own, `trillium-gpu`. Its `[connect]` table has
`host = "trillium"` for files, since both clusters see the same file systems,
and `via = "trig-login01"` for commands, which run there through the first
connection. Its directories are not the CPU cluster's, since the two prepare
for different CPUs.

A known trap of a site is to become data the generator acts on, for example
`exclusive_breaks_threaded_subprocess = true` on Symmetry, so a test-suite
job is written without `JULIA_EXCLUSIVE`. None is implemented yet: the first
suite job brings the first.

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
  depot-<architecture>/     the study's compiled caches, one depot per architecture
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
   Where a site's nodes are several CPU types under one partition, as
   Symmetry's AMD nodes, their architecture's target makes one cache serve
   them all (`JULIA_CPU_TARGET`, set for the precompile job and for every
   job).
4. **Precompile for each architecture**, once for every combination of
   environment, Julia version and Julia flags the specs name, since
   `--check-bounds=yes` has its own cache. On Trillium, on the login node of
   the matching cluster. On Symmetry and Nibi, whose login nodes have an
   architecture of their own, `prepare` submits a short precompile
   job on the target partition, on the node type of the job that will use it.
   `prepare` can be interrupted while that job waits in the queue; run again,
   it finds the job and continues. An environment that a compute node has
   compiled is not written again by a later `prepare`: the login node would
   compile MPIPreferences anew, and the compute node's caches of MPI would
   be stale (Symmetry, job 600484, which stopped at its check with "not
   precompiled").

**The study's depot.** Every study has Julia depots of its own on each site,
one per architecture of the site's profile,
`<code root>/<study>/depot-<architecture>/`. A job runs with
`JULIA_DEPOT_PATH="<depot>:"`: the study's depot for its nodes'
architecture, then the depots that come with Julia, and not `~/.julia` nor
another architecture's. What the login node compiles for itself while it
writes the environments goes into the login node's depot. Its `compiled/` directory holds the study's
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

**The precompile lock.** Two of the tool's jobs never precompile into one
depot at once. The lock is a directory in the study's depot for the
architecture, `depot-<architecture>/precompile.lock`, made by `prepare` over
ssh (`mkdir` is atomic), holding the precompile job's ID and removed by that
job's exit trap; a lock whose job `squeue` no longer knows is stale and is
taken over. It is held from before the job is submitted, so also while the
job waits in the queue. Another study, or the same study's jobs for another
architecture, are not kept waiting: the lock was one per site while all
studies shared a depot, and a job that waited 14 minutes in `h200debugq`
then held up every other `prepare` on Symmetry. What a precompile job
fetches into the site's own depot (packages, artifacts) is not locked, as
it never was against the login node's part of a `prepare`. The lock binds only what the tool submits. A hand-written script
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
env = "default"                     # or "cuda", "test", "test+cuda", … built by prepare

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

**A spec in Julia.** A spec file that ends in `.jl` is evaluated, and the
value of its last expression is the spec, as named tuples or dictionaries.
`load_spec` turns it into what a TOML file gives, and nothing after it
knows the difference. The need is TreeAMR's: its `nested-gpu` spec was 241
lines of `[[run]]` tables that differ in version, GPUs, MPI, path and
round. A key for a product of runs was considered and rejected: it needs
substitution and quoting, then exclusions, then conditions and variables,
which is a language. Julia is one already, and data, not text put into a
TOML string, needs no quoting. The file is evaluated in a module of its
own with the standard library only, must give the same spec each time, and
`submit` keeps what it evaluated to, as TOML, beside the batch script.

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
expands into a scan, `threads = [1, 8, 16, 32, 64]`), `julia_args`
(`["--check-bounds=yes"]`), `ranks`, `nodes`, `placement`, `mpi`, `prefix`,
and `vars` for environment variables a script reads, such as TreeWaveOLDG's
`TREEWAVEOLDG_RUNS`. A run's `julia` (a juliaup channel such as `"+1.13"`)
is not implemented. An `[after]` table names one shell command run inside
the job after the last run, for a table such as TreeAMR's `mpitable.awk`. It
runs in the study's output directory, with `PROJECT` and
`SIMLAUNCH_JOBDIRS` (this job's directories) exported, and its output goes
to the job's log. `simlaunch after <study> <spec>` runs the command again
on the login node over each run's newest job directory, for a table that
was wrong or is wanted again. Its `--checkout` takes `PROJECT` from a
read-only copy of the project as it is on the laptop now, kept in the
study's output directory, and the log says so: the study's snapshot, which
is what the jobs ran, is not touched.

**Environments.** `env` names kinds joined by `+`: `cuda` and `metal` add
the device package, `test` the project's test dependencies, `mpi` MPI.jl set
to the run's recipe. A run with `mpi` gets the `mpi` kind by itself, and an
environment of its own per recipe, `envs/<variant>-<kinds>-<recipe>/`.

**Placement.** `pin = true` is `JULIA_EXCLUSIVE=1` with
`srun --cpu-bind=none` and `-t N,0`. `placement = "numa"` binds rank i of
the R on its node to NUMA domain i·D/R with `numactl --cpunodebind
--membind`; a run without ranks gets domain 0. D is counted on the node
when the run starts (`numactl -H`), and a node with fewer domains than
ranks ends the run at once. The profile's count (8 on Symmetry's EPYC 7543
nodes and on Trillium, 6 on Nibi) is what `submit` checks and what the
default of `threads` comes from. The reason is Symmetry's cn112 (EPYC
8534P), which has fewer than the profile's 8: TreeAMR's nested benchmark
landed there on 2026-11-17, rank 1 asked `numactl` for domain 4 and
exited, and the other ranks waited in MPI for 35 minutes. Ranks under
`srun` are therefore also started with `--kill-on-bad-exit=1`. The two exclude
each other: `JULIA_EXCLUSIVE` binds threads to the cores from 0 on, whatever
`numactl` allows, so a run with `ranks` or `placement` is not pinned.
`node = "cn095"` fixes the node for a benchmark, `sbatch_args =
["--exclude=cn112"]` keeps a job off one, and every job directory records
its host and `lscpu`'s model in `simlaunch-job.toml`, which `fetch` copies
with the results.

**MPI.** `mpi` names a recipe in the site profile, and `ranks` the number of
ranks; `threads` is then per rank. Runs of one job may use different recipes
and rank counts, which is how TreeAMR compares MPICH_jll with HPC-X at 1 to
8 ranks. The batch header asks for as many tasks per node as the largest run
starts there. A run's `nodes` spreads its ranks over that many of the job's
nodes; `resources.nodes` above 1 restricts the queue choice to queues that
allow it (on Symmetry `amdq`, since `amddebugq` takes one node). A recipe
that starts its ranks with `srun` is refused in a GPU job, whose allocation
is one task; such a job uses a recipe with the binary's own `mpiexec`.

**The default recipe.** A profile's `[mpi]` table names a default, and a run
with `ranks` that names no recipe gets it, so a spec without `mpi` runs on
every site. The default is the standard MPI ABI everywhere (MPI.jl's
`abi = "MPIABI"`): on a cluster the site's own MPI through mpi_abi_wrapper,
which has the site's interconnect and, where the site's MPI has it, CUDA; on
the laptop MPIABI_jll, since there is no site MPI to wrap. One ABI means one
way MPI.jl is built on every site, and the wrapper costs nothing measurable
(ping-pong on Trillium, Nibi and Fir: the same as Open MPI loaded directly).
A recipe's `binary` is `"system"` with the keywords of
`MPIPreferences.use_system_binary` as its `preferences`, `"jll"` for
MPICH_jll, or the name of another binary MPIPreferences knows.

| Site | Default recipe | Wraps | Launcher | Other recipes |
| --- | --- | --- | --- | --- |
| `local` | `abi` | MPIABI_jll (MPICH 5) | its `mpiexec` | `jll` |
| Symmetry | `system` | HPC-X's Open MPI 4.1.7, CUDA-aware | `mpiexec` | `hpcx` (the same MPI without the wrapper), `jll`, `jll-fork` |
| Trillium | `system` | Open MPI 4.1.5 of StdEnv/2023 | `srun --mpi=pmix` | `jll` |
| Trillium GPU | `system` | the same, built with CUDA | `mpiexec` | |
| Nibi | `system` | Open MPI 4.1.5 of StdEnv/2023 | `srun --mpi=pmix` | `jll` |
| Fir | `system` | Open MPI 4.1.5 of StdEnv/2023 | `srun --mpi=pmix` | `jll` |

On the Alliance sites the recipe names a copy of Julia patched with
`setrpaths.sh`, since juliaup's cannot load libraries of the site's software
stack. Nibi's and Fir's GPU jobs have no recipe with an `mpiexec` yet.

The defaults ran on 2026-11-17 with a toy study whose spec names no recipe:
a ring exchange and a reduction over four ranks, and in a GPU job two ranks
on one GPU that exchange host buffers and then device buffers.

| Site | Job | Result |
| --- | --- | --- |
| `local` | L20261117-135044 | 4 ranks, MPIABI_jll |
| Symmetry, AMD node | 601884 on cn107 | 4 ranks, the wrapper around HPC-X |
| Symmetry, H200 | 601886 on cn113 | host and device buffers |
| Trillium | 2878504 on tri0518 | 4 ranks, the wrapper around Open MPI 4.1.5 |
| Trillium GPU, H100 | 1355034 on trig0001 | host and device buffers |
| Nibi | 27652961 on c249 | 4 ranks; precompile job 27652919 |
| Fir | not run | its login node could not read Julia's library that day (a Lustre error) |

What these runs found:

- **Device buffers need the UCX that knows GPU memory.** On Trillium GPU
  the first job (1355026) passed with host buffers and crashed in UCX with
  device buffers. Loading `cuda/12.9` beside `StdEnv/2023` swaps that UCX
  in, under the same Open MPI and the same wrapper; the recipe names both.
- **MPI.jl's `has_cuda()` says false through the wrapper** on both GPU
  sites, although device buffers work: the wrapper does not pass Open MPI's
  own query on. A code that asks before it hands MPI a device buffer needs
  `JULIA_MPI_HAS_CUDA=true`; no recipe sets it yet.
- **A precompile job that waited held the site's lock.** Symmetry's GPU
  precompile job waited 14 minutes in `h200debugq` behind the group's
  limit, and every other `prepare` on Symmetry waited with it. The lock is
  now one per study and architecture (see "The precompile lock").

**MPI with GPUs** ran on Symmetry on 2026-11-16 (job 601126, cn111, two
H200s): a toy study, two ranks with one GPU each, exchanging a small and a
32 MiB message and checking what arrives.

| Run | MPI | Buffers handed to MPI | Result |
|-----|-----|-----------------------|--------|
| `fork-staged` | MPICH_jll, `jll-fork` | host copies | ok |
| `hpcx-staged` | HPC-X, `system` | host copies | ok |
| `hpcx-direct-nopool` | HPC-X, `system` | device, `JULIA_CUDA_MEMORY_POOL=none` | ok |
| `hpcx-direct` | HPC-X, `system` | device, CUDA.jl's default pool | ok |

A spec asks for it with `resources = { gpus = 2 }`, `env = "cuda"`, and
`mpi` and `ranks = 2` in a run; a rank chooses its GPU itself
(`CUDA.device!(rank % ndevices)`), since both ranks see both. Each rank had
all 16 cores of the job: a recipe's `launcher_args` now go to an `mpiexec`
too, and HPC-X's are `--bind-to none`, without which Open MPI binds a rank
and all its threads to one core. What is left open:

- `JULIA_CUDA_MEMORY_POOL=none` is what MPI.jl's "Known issues" ask for with
  a CUDA-aware MPI (CUDA.jl's allocator against the library's `cuIpc*`
  calls; the symptoms are `cuIpcGetMemHandle failed` or a segmentation
  fault in `gdr_pin_buffer`). The toy run did not need it. It is not in the
  recipe: a run that hands device buffers to MPI sets it in its `vars` if
  it meets those symptoms.
- The HPC-X module puts its own CUDA 12 libraries on the library path, and
  CUDA.jl, with its own 13.4 runtime, then warns that `libcusparse.so.12`
  and `libnvJitLink.so.12` "were loaded from a system path". The runs
  finished all the same. Using the site's toolkit throughout
  (`CUDA.set_runtime_version!(local_toolkit = true)`, a step of `prepare`
  as `set_mpi.jl` is for MPI, with a key in the recipe) is the answer if a
  real code trips over the mixture; it is not implemented.

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
env = "test"                        # the benchmark needs the test dependencies

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

Both runs execute the study's own `bench/nested.jl`, each in its variant's
environment, so they differ in the package only.

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

**Queue choice.** The tool picks the first queue in the profile's order that
fits the spec: its time, its nodes or GPUs, and three rules a queue can
carry. `one_at_a_time`: skipped while the user has a job there, which
`submit` asks the site; `preempt`: only for a job with checkpoints;
`prefer`: taken first by a job with checkpoints (`h200preq`, since `h200q`
is often full; not `amdpreq`); `chain = false`: not for a job with
checkpoints; `on_request`: never chosen, only named (`largememq`). The
result:

| Site | Fits in 1 h | Longer | GPU, no checkpoints | GPU with checkpoints |
| --- | --- | --- | --- | --- |
| Symmetry | `amddebugq` | `amdq` | `h200q` (`h200debugq` once, never chained) | `h200preq` |
| Nibi | chosen by the submit filter | same | same | same |
| Trillium | `debug` if no other debug job | `compute` | `compute` (H100) | `compute` |

`--queue` overrides the choice; the tool then still checks the spec against
that queue's limits and refuses with the limit it breaks. When no queue
fits, the refusal lists each queue with its reason.

## Submit, status, fetch and restarts

**Submit** copies the generated script into the study's `jobs/`, submits it
from the right login node (`trig-login01` for Trillium's GPUs), and marks
every run's SimWatch directory queued with the job ID before returning. A
study's runs are therefore visible in SimWatch from the moment they exist.

**Status** reads SimWatch's files: `simlaunch status <study>…` prints one
table of the runs on every site the study is prepared on, with each run's
status, job and message. A run that says queued or running while the queue
no longer knows its job is shown as `lost`. It reads the files itself, in
one ssh call per site, and does not run `simwatch --print`, which would need
SimWatch installed on every site. Erik's own view stays
`simwatch <site>:<dir>`, which the tool prints at submission and with the
table.

**Cancel.** `simlaunch cancel <study> <spec>` cancels the spec's jobs and
marks every run that has not ended as `cancelled` in its SimWatch file,
with `--message` as the reason. SimWatch 1.5.0 has that state: final, grey,
hidden with the finished runs. A plain `scancel` cannot say it: a job
cancelled while it waits writes nothing, its runs stay `queued`, and
SimWatch shows them as lost. The command marks the runs through the batch
script (`<script> --cancelled <message>`), cancels the jobs, including a
successor that a stopped job submitted, and marks again what a job wrote
while it ended. A finished or failed run stays as it is.

A job that is told to stop without the command says what it can tell.
Without checkpoints: `failed`, "killed at the time limit", within a minute
of the limit, and `cancelled` otherwise, also for the runs that had not
started. With checkpoints a run is `stopped`, as before, since a later job
can continue it; only the command makes it `cancelled`, and a job whose run
is marked submits no successor.

Ran on Symmetry on 2026-11-17 with a toy study: the command on a running
job (602617) and on a job waiting in the queue (602618) left both runs
`cancelled` with the message given, and a plain `scancel` of a running job
(602619) left its running run "cancelled in 001-602619 on cn103" and the run
that had not started "cancelled before this run finished".

**Wait.** `simlaunch wait <study> <spec>` watches until no job of the spec
is queued or running, printing each run's status as it changes, and exits
with 0 only when every run has finished; `submit --wait` is `submit` followed
by it. It covers a chain, also a successor that a stopped job submits. It
asks the queue over ssh and reads the runs' SimWatch files, since Slurm's
own state does not tell a job whose run failed from one that finished. It
holds no session open: interrupted, it is started again. This is also how a
spec runs in a project's CI, as `--site local`.

**Fetch** copies a run's results back to
`.claude/data/<study>/<site>/<run>/` in the project the study came from:
logs, CSVs, `records.csv`, `simwatch.toml`, plots, `snapshot.toml` and the
site's resolved manifests. The site is part of the path, so the same spec run
on two sites never lands in one directory. Checkpoints (`ck/`) stay on the
cluster unless `--with-checkpoints` is given, and so do files above
`--max-size` (100 MB by default). The copied files are read-only, as on the
site; their directories are writable, so that a later fetch can add to them.
`--to` names another directory, and `--run` single runs. The
analysis scripts that read `.claude/data` (`test/aligned_study.jl`,
`test/harmonic_spin_study.jl` and the rest) read a run's directory as they
do now.

A run with checkpoints comes back as its job directories, unchanged, with its
`combined-<n>/` directories beside them. An analysis script that wants one
series reads a combined directory.

**Restart chains.** A run with `checkpoints = true` is a chain of jobs, each
in a directory of its own;
[Immutable outputs and restarts](#immutable-outputs-and-restarts) has the
layout and the rules. `simlaunch resubmit <study> <spec>` submits the next
job of the chain, and `--chain N` submits N jobs with
`--dependency=afterany`, which suits Trillium's and Nibi's 24 h limits. A
job of a chain whose runs have all finished ends at once. A run with
checkpoints has one job at a time: `submit` refuses a second while one is
queued or running.

**Cleanup.** `simlaunch clean <study> --site <site>` lists what it would
delete there (the study's sources and caches, and its output, with sizes) and
deletes only after confirmation, first restoring write permission on the job
directories it made read-only. It refuses while a job of the study is queued
or running. The snapshot on the laptop stays, and is not needed: a study
whose snapshot is gone can still be removed from a site. Nothing is ever deleted automatically: step H1's checkpoints alone
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
  diskusage.toml         what each ended job holds (exempt)
  001-2864584/           the first job: its logs, CSVs, plots, ck/
  002-2864611/           a restart: reads 001-2864584/ck/, writes only here
  combined-1/            written by a combine step, never by a job
<scratch root>/<study>/logs/
  <spec>-2864584.out     Slurm's own log of one job ID, for all its runs
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
  submits its successor from its SIGTERM handler, before it stops its runs,
  within the 30 s grace. The successor is submitted with
  `--dependency=afterany:` and the job's own ID, so it cannot start, and
  cannot make this directory read-only, while this job still writes. A node
  failure ends the chain, and
  `simlaunch resubmit` or a pending `--chain` successor continues it.
- Slurm cannot tell a job why it is stopped: pre-emption, the time limit
  and `scancel` all arrive as SIGTERM. The handler therefore submits a
  successor only on a queue the profile marks `preempt`, only more than a
  minute before the time limit, only when no job of the same name is pending
  already, and not while the file `<scratch root>/<study>/STOP` exists. To
  stop such a chain for good, create that file and then cancel the job.
- Slurm's `--output` goes to `logs/<spec>-<jobid>.out` in the study's output
  directory, since a job can hold several runs and Slurm cannot write into a
  directory that does not exist yet. With unique job IDs it, too, is written
  by one job only.
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

The arguments are passed as `<name>=<value>` after the run's own. The first
job gets only `to`. A driver writes its CSVs and records into its working
directory, which is the job directory, so a restart starts new files rather
than extending old ones. `margin` (5 minutes by default) is the part of the
time limit kept back from `walltime`. `continue_code` is the driver's exit
code when it stopped at its walltime (3 for TreeGeneralizedHarmonic's
drivers): the run is then `stopped`, not failed, and the next job continues
it. A run that an earlier job finished is not run again.

`from` is not always the predecessor's `ck/`: a job killed before its first
checkpoint leaves none. The script passes the `ck/` of the newest job
directory that holds a complete checkpoint, and no `from` when there is none.
The tool cannot tell a complete checkpoint from a partial one by itself, so
the driver must write each checkpoint under a temporary name and rename it
when it is whole; the tool then ignores temporary names (`*.tmp`, `*.tmp.*`
and names that start with a dot, or the patterns in `[restart] temporary`).
This is a requirement on the driver that the tool can test but not enforce.

**Checking a driver.** `simlaunch check-restart <study> <spec>` runs the
spec's runs twice on one site, under new labels: once in one job, and once
with the first job stopped after its first complete checkpoint and continued
by further jobs. It passes when the stopped job's directory is unchanged
afterwards (file list and checksums), the second job started from the first
one's checkpoint, and the project's own compare script, `[restart] compare`,
accepts the chain's job directories against the uninterrupted one. The
comparison runs as a job, in the prepared environment, with the directories
as its last arguments. What "the same result" means stays with the project.
That a restart never reads a temporary name cannot be observed from outside;
the check reports whether the stopped job left one, since only then was the
restart exposed to it.

**Storage.** Each job keeps its own checkpoints, where a shared directory
kept one set, so a chain of N jobs holds up to N sets. A driver should keep
only its newest checkpoint in its `ck/`. SimLaunch never deletes checkpoints
by itself, and neither does a job: whoever runs the jobs deletes them.
`simlaunch clean <study> --site <site> --old-checkpoints` lists the
checkpoints of every job but each run's newest, with sizes, and deletes them
after confirmation; the deletion is recorded in the run's `diskusage.toml`. The
clusters' scratch purges apply to these files as to any others: fetch what
must be kept.

**Disk usage.** Each job measures itself when it ends: its exit trap runs
`du` on its own directory and on its `ck/`, and appends the two numbers to
`diskusage.toml` beside `simwatch.toml`. A job killed before its trap is measured
by its successor, as with the read-only step. The measurement walks one job's
files only, and runs under a time limit (60 s); when it does not finish, the
entry says `unknown` and the job still ends. `simlaunch usage <study>` adds
up the recorded numbers per run, per job and per site. It reads only these
small files and never walks a tree, so it answers at once.
`simlaunch usage --measure` walks the trees for entries that are `unknown`
or for a job still running, and is the only slow path. `clean` measures
what it is about to delete.

SimWatch shows a run while it runs, when the running job's size is not known
yet, so it is not where disk usage is asked for. It gets what is known at no
cost: each job's last status update, the one that marks it finished or
failed, also writes a `[diskusage]` table with the run's recorded total. During a
chain SimWatch therefore shows the size of the jobs that have ended, and
after the run its full size.

**Combining.** Reading a run as one series is a later step.
`[combine] cmd = "…"` names a project script that reads the job directories in
order and writes a new `combined-<n>/`; `simlaunch combine <study> <spec>`
runs it on the site's login node, with the job directories as its last
arguments and the new directory as its working directory. It runs with a
depot of its own in front of the study's depot for the login node's
architecture, so what it compiles goes there and the study's caches stay
untouched. Each combine writes a
new directory, so its output is immutable too. Running it on the laptop
after a fetch is not implemented.

**Opting out.** `mutable_restarts = true` keeps today's behaviour for a driver
that is not converted yet: one shared directory for all jobs of a run
(`<run>/mutable/`), its `ck/` passed as the single argument `to`, appended
CSVs, no read-only step, and requeue under the same job ID with
`--open-mode=append`. `simlaunch submit` prints a warning for such a
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
   | Octant smoke row | Fir, one H100 (fc10605) | 4409948 | finished, the same values as on Symmetry; precompile job 4409134 on a GPU node |
   | The same scan | Symmetry, cn102 (EPYC 7543) | 599475 | 1 to 64 threads, `rhs` 0.375 s to 0.020 s at 32; precompile job 599473 |
   | S1's sweep | Nibi, c143 | 27514859 | six runs in 27 minutes, `M_irr` identical to Trillium's and Fir's in all twelve digits; precompile job 27514148 on c151 |

   Nibi's nodes came back later that day, and the sweep ran there too,
   which completes this milestone. Seen on Symmetry and on Nibi: a version
   report that lists a difference (ForwardDiff 1.5.0 there, 1.4.8 on
   Trillium and Fir). Not yet seen on a cluster: a precompile lock
   that is held or stale.
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

   Implemented on 2026-11-16, and tested on the laptop only:

   | Part | Tested by |
   | --- | --- |
   | Queue choice by rule | the profiles of Trillium and Symmetry, without a queue |
   | A chain of three jobs with `--chain`, stopped at the walltime | a real driver under stand-ins for `sbatch`, `squeue` and `scancel` |
   | A stopped job on a pre-emptible queue submits its successor | the same, with SIGTERM to the job |
   | `check-restart`, passing and failing | real local jobs, a toy driver that follows the contract |
   | `status`, `fetch`, `usage`, `clean`, `combine` | the same runs |
   | Variants, test dependencies, MPI ranks under MPICH_jll's `mpiexec` | a run on the laptop, 2 and 3 ranks, by hand |
   | `srun` launchers, `numactl` placement, several nodes, the site's MPI | the generated scripts only (`test/reference/symmetry-nested.sh`) |

   Run on Symmetry's AMD nodes on 2026-11-16, with a toy project (a
   counting driver that follows the restart contract, and an MPI hello that
   prints each rank's host and cores):

   | Run | Jobs | Result |
   | --- | --- | --- |
   | A chain of three jobs, `--chain 3`, `amddebugq` | 599478 to 599480 | the first stopped at its walltime after step 59, the second continued at 60 and finished, the third had nothing left to do |
   | `check-restart`, `amddebugq` | 599490, 599493, 599494, 599496 | passed: the stopped job's directory unchanged, the comparison accepted |
   | A job stopped on `amdpreq` (with `scancel`, as a pre-emption stops it) | 599500, 599502 | the stopped job submitted its successor from the compute node; that continued at step 17 and finished |
   | MPI on one node: 8 ranks × 8 threads for two variants, 2 ranks, under `srun --mpi=pmi2`; HPC-X's `mpiexec`; MPICH_jll's `mpiexec` | 599489, 599497 | every rank on its own NUMA domain, each variant its own version |
   | MPI on two nodes, `amdq`: 16 and 8 ranks under `srun`, 8 under HPC-X | 599491, 599498 | the ranks split evenly over cn095 and cn096, each on its domain |
   | `wait`, `status`, `usage`, `fetch` | the same | as on the laptop |

   Run on Trillium's CPU nodes on the same day, with the same toy project,
   prepared on the login node, both jobs in `debug`:

   | Run | Job | Result |
   | --- | --- | --- |
   | MPI on one node: 8 ranks × 24 threads for two variants under MPICH_jll and `srun --mpi=pmi2`; 8 × 24 and 2 × 4 under the system's Open MPI (mpi_abi_wrapper, the patched Julia, `srun --mpi=pmix`) | 2871423 on tri0494 | every rank on its own NUMA domain of 24 cores, each variant its own version |
   | MPI on two nodes: 16 × 24 under both recipes, 8 × 24 and 2 × 4 under the system's | 2871446 on tri0079 and tri0655 | the ranks split evenly over the nodes, each on its domain |

   Nothing had to be changed for Trillium. `srun` warns as on Symmetry when
   a step's `--cpus-per-task` exceeds the job's.

   TreeAMR's nested benchmark, on the same day: `bench/nested.jl` at
   `N = 16` for two variants, both `main` at bdb023f, so the two columns
   test the mechanism and the scatter, not a change
   ([`examples/treeamr-nested.toml`](examples/treeamr-nested.toml)). One
   node, job 599512 on cn099 (EPYC 7543), 7 minutes, precompile job 599510;
   the minimum time of a fill, in seconds:

   | Ranks × threads | `base` | `new` | Difference |
   | --- | --- | --- | --- |
   | 1 × 1 | 0.6008 | 0.6014 | 0.1 % |
   | 2 × 1 | 0.4632 | 0.4604 | −0.6 % |
   | 4 × 1 | 0.2367 | 0.2364 | −0.1 % |
   | 8 × 8, MPICH_jll under `srun` | 0.0566 | 0.0579 | 2.2 % |
   | 8 × 8, HPC-X | | 0.0439 | 24 % faster than MPICH_jll |

   Two nodes, 16 ranks × 8 threads, 8 ranks on each node
   ([`examples/treeamr-nested-2nodes.toml`](examples/treeamr-nested-2nodes.toml)):
   job 599511 on cn087 and cn099, `amdq`, 2 minutes:

   | Ranks × threads | `base` | `new` | Difference |
   | --- | --- | --- | --- |
   | 16 × 8, MPICH_jll under `srun` | 0.0433 | 0.0444 | 2.6 % |
   | 16 × 8, HPC-X | | 0.0298 | 33 % faster than MPICH_jll |

   What these runs found and fixed:

   - **A cache from one AMD generation is rejected on another.** The first
     precompile job ran on cn112 (EPYC 8534P) and the jobs on EPYC 7532
     nodes, which stopped at their precompile check (599483, 599484). A
     profile now names a target, exported as `JULIA_CPU_TARGET` where
     the caches are compiled and where they are used; the marker of what is
     prepared records it. Symmetry's was
     `generic;znver2,clone_all;znver4,clone_all`. It is `znver2` since
     the profiles name architectures and the AMD queues keep off cn112.
   - **A file written on a compute node shows on the login node late.**
     `prepare` found no marker right after precompile job 599476 had ended.
     It now looks again for up to a minute.
   - **Under an `mpiexec`, `SLURM_LOCALID` is the batch step's.** All ranks
     were bound to domain 0. The placement now reads the rank from Open MPI
     or Hydra there, and from `srun` only under `srun`.

   `srun` warned that a step's `--cpus-per-task` exceeds the job's ("may
   never run") when a run has fewer ranks than the job's largest; the step
   ran. A step is now started without the job's `SLURM_CPUS_PER_TASK`
   (`env -u`), which removes the warning and changes nothing else: probe
   job 601766 on cn083, which also saw `--kill-on-bad-exit=1` end three
   sleeping ranks at once and the placement give each of 8 ranks its own
   domain. Known and left: under HPC-X's `mpiexec` Julia writes terminal title sequences into the
   output.

   Open of the done-when list: `check-restart` for the converted drivers,
   a checkpointed GPU row on `h200preq`, and a chain on Trillium with its
   results read by the study scripts. A real pre-emption has not happened yet, only its signal. Not implemented: a run's `julia` channel, the
   memory part of the resource check, `--snapshot-pins`, `combine` on the
   laptop, and the removal of a snapshot from the laptop by `clean`.
4. **Migration.** The tables above, one script at a time, each when a run of
   it is due. Done when `symmetry-run.sh` and XCTS's three scripts are retired
   and the skills point at the profiles.

   TreeAMR's nine scripts were converted first and ran on Symmetry. What
   that found, on 2026-11-17:

   - Done: a spec in Julia in place of a key for a product of runs; the
     NUMA domains counted on the node; `--kill-on-bad-exit=1`; the host and
     CPU model in every job directory; `simlaunch after`; `node` and
     `sbatch_args` described as the way to choose or avoid nodes.
   - `prepare` waits for its precompile jobs, but its last line was "precompile
     job … running", which read afterwards as if it had left the job
     behind. It now prints how each job ended and a closing line.
   - Compiled caches of two CPU types in one depot: see "Architectures" in
     "Site profiles". A study now has a depot per architecture. Ran on
     Symmetry on 2026-11-17 with a toy study:

     | Nodes | Jobs | What the job loaded |
     | --- | --- | --- |
     | AMD, cn083 (EPYC 7532) | precompile 601812, job 601814 | from `depot-amd` only; caches built for `znver2` and `znver4`, no `generic` |
     | H200, cn113 (Xeon Platinum 8452Y) | precompile 601816, job 601817 | from `depot-h200` only; caches built for `sapphirerapids`, with AVX-512 |

     The login node's depot holds MPIPreferences and Preferences only.
     Eight packages are in both jobs' depots, each compiled for its own
     nodes. The AMD job also ran 8 and 2 MPI ranks under `srun`, each rank
     on its own NUMA domain and without the `--cpus-per-task` warning.
     The AMD target was `znver2;znver4,clone_all` in these jobs. It is
     `znver2` since cn112 is kept out of the AMD queues, and that ran the
     same day: precompile job 601842 and job 601843, both with
     `--exclude=cn112`, on cn107 (EPYC 7543, Zen 3), which loaded caches
     built for `znver2` from `depot-amd`. `largememq` has not run: cn112
     was busy, and a precompile job waiting there would then have held the
     site's precompile lock against every other `prepare`. Not seen yet: a Zen 2
     node loading what a Zen 3 node compiled; a job on cn111, whose Xeon Gold 6442Y must accept what
     cn113 compiled; if it does not, the job stops at its precompile check.
   - Open, each to be designed:
     - a `depot` root in a profile's `[paths]`, since home is small on most
       sites and compiled caches need not live there;
     - a new study derived from one on the site, with its manifests and
       caches copied, so that a one-line fix does not compile everything
       again. One depot shared by all studies stays ruled out (see "The
       study's depot"), and so does changing a study's sources in place:
       its finished runs point at them;
     - a smoke run of every run of a spec on `local` before `submit`, which
       needs a convention for a tiny size;
     - the same recipe names on every site (`jll`, `system`), with the
       launcher for a GPU job chosen by the tool;
     - MPI recipes for the GPU jobs of Nibi and Fir, whose `system` recipe
       starts its ranks with `srun`.

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
