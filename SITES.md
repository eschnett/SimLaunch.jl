# SimLaunch: site profiles

A site is a machine that runs jobs: the laptop, or a cluster. A site profile
is a TOML file that describes one, `<name>.toml`. This is the reference for
every key. [`README.md`](README.md) has an introduction and
[`SPEC.md`](SPEC.md) the job specs that name a site.

- [Where profiles are](#where-profiles-are)
- [Using a profile that comes with SimLaunch](#using-a-profile-that-comes-with-simlaunch)
- [A profile on top of another](#a-profile-on-top-of-another)
- [A profile for a new cluster](#a-profile-for-a-new-cluster)
- [Keys](#keys)
  - [`[connect]`](#connect)
  - [`[paths]`](#paths)
  - [`[slurm]`](#slurm)
  - [Kinds of node: `[[slurm.nodes]]`](#kinds-of-node-slurmnodes)
  - [Queues](#queues)
  - [`[arch]`](#arch)
  - [`[julia]`](#julia)
  - [`[mpi]`](#mpi)
  - [`[env]`](#env)

## Where profiles are

SimLaunch looks for `<name>.toml` in two directories, in this order:

1. your own: `~/.config/simlaunch/sites/`, or the directory that the
   environment variable `SIMLAUNCH_SITES` names;
2. the ones that come with SimLaunch: `sites/` in the installed package.

The first file found is the site's profile. Do not edit the files in the
package: an update replaces them.

`simlaunch sites` lists the sites and the file each one comes from.

## Using a profile that comes with SimLaunch

| Profile | Site |
|---------|------|
| `local` | this machine; a job is a background process. Works as it is |
| `trillium`, `trillium-gpu` | Trillium (Alliance / SciNet), its CPU and its GPU cluster |
| `nibi` | Nibi (Alliance / SHARCNET) |
| `fir` | Fir (Alliance / SFU) |

A cluster's profile describes the cluster, not you. What only you know is
written there as a placeholder, a string in `<...>`: the directories for
your studies and your Slurm account. SimLaunch refuses the site until they
are set, and names them. Set them in a profile of your own with the same
name, `~/.config/simlaunch/sites/trillium.toml`:

```toml
base = "trillium"                   # everything else comes from SimLaunch's profile

[paths]
code = "/home/USER/simlaunch/studies"
scratch = "/scratch/USER/simlaunch/studies"

[slurm]
account = "def-NAME"
```

The profiles expect that `ssh <host>` reaches the cluster without a
prompt, with `<host>` as in `[connect]`. On a cluster that asks for a second
factor, that is a master connection which you open yourself
(`ControlMaster` in `~/.ssh/config`). Change `[connect]` in your profile if
your host has another name.

The clusters' own MPI (the recipe `mpiabi`) needs two things that you build
once on the cluster, so it has placeholders too: a Julia that can load the
cluster's libraries, and
[mpi_abi_wrapper](https://github.com/eschnett/mpi_abi_wrapper) built
against the cluster's Open MPI. Until then the default recipe of
Trillium, Nibi and Fir is `jll`, which needs neither and is several times
slower between nodes. Trillium's GPU profile has no `jll` recipe: its
default is `mpiabi`, so a run with ranks there needs it set up. A run that
asks for `mpiabi` before it is set up is refused. To set it up, add to your
profile:

```toml
[mpi]
default = "mpiabi"

[mpi.mpiabi]
julia = "~/julia-1.13.4-trillium/bin/julia"
[mpi.mpiabi.preferences]
library_names = ["/home/USER/openmpi-4.1.5-mpi-abi/lib64/libmpi_abi.so"]
mpiexec = "/home/USER/openmpi-4.1.5-mpi-abi/bin/mpiexec"
```

## A profile on top of another

A profile with the key `base` holds only what differs from the profile it
names. Tables are merged key by key; any other value, a list of queues
included, replaces the base's.

The base is looked up like any profile, except that files already in use
are skipped. So your `trillium.toml` with `base = "trillium"` builds on
SimLaunch's, and your `trillium-big.toml` with `base = "trillium"` builds on
yours.

## A profile for a new cluster

Write `~/.config/simlaunch/sites/<name>.toml` without `base`. The smallest
profile of a Slurm cluster:

```toml
[connect]
host = "mycluster"                  # as in ~/.ssh/config

[paths]
code = "/home/me/simlaunch/studies"
scratch = "/scratch/me/simlaunch/studies"

[[slurm.nodes]]
name = "cpu"
cores = 64
queues = [{ partition = "batch", max_time = "24:00:00" }]

[julia]
bin = "~/.juliaup/bin/julia"
```

Then try it in this order: `simlaunch submit … --site <name> --dry-run` and
read the script; `simlaunch prepare`; one short job. The profiles in the
package's `sites/` are examples with comments on why each entry is there.

## Keys

The top level has `name` (optional; it must be the file's name), `base`, and
the tables below. An unknown table is refused.

### `[connect]`

Without this table the site is this machine.

| Key | Default | Meaning |
|-----|---------|---------|
| `host` | required | The host as `ssh` and `rsync` know it |
| `via` | none | A second login node, reached from `host` with `ssh`, where commands run. Files still go to `host` |
| `check` | none | A local command that tells whether the site can be reached without a new login. SimLaunch runs it first and stops if it fails |
| `hint` | none | What to do when `check` fails; added to the message |

### `[paths]`

| Key | Meaning |
|-----|---------|
| `code` | Where the studies' sources go: `<code>/<study>/`. May be read-only in jobs |
| `scratch` | Where the studies' output goes: `<scratch>/<study>/`. Jobs write here |

Both are required, and absolute on a remote site. A local site's may start
with `~`.

### `[slurm]`

Without this table a job is a background process on the site, and the
site's cores are counted when SimLaunch runs.

| Key | Default | Meaning |
|-----|---------|---------|
| `account` | none | `--account` of every job |
| `export_env` | `true` | `false`: `sbatch` hands the job nothing of the submitting shell's environment, so the script sets everything itself |
| `nodes` | required | The site's [kinds of node](#kinds-of-node-slurmnodes) |

### Kinds of node: `[[slurm.nodes]]`

A cluster has one or more kinds of node, each a table `[[slurm.nodes]]`
with its shape, its architecture and its queues. A job runs on one kind. The
order counts: the first CPU kind takes a CPU job, and the first GPU kind a
GPU job, unless the job names another with `node_type` in its spec. The
other kinds are used only when named, such as a single large-memory node or
an older generation that is best avoided.

```toml
[[slurm.nodes]]                     # the default for CPU jobs
name = "amd"
cores = 64
numa = 8
header = ["--exclusive"]
arch = "amd"
queues = [{ partition = "amdq", max_time = "24:00:00" }]

[[slurm.nodes]]                     # only for a spec with `node_type = "intel"`
name = "intel"
cores = 40
numa = 2
header = ["--exclusive"]
arch = "intel"
queues = [{ partition = "defq", max_time = "24:00:00" }]

[[slurm.nodes]]                     # the default for GPU jobs
name = "h200"
gpus = { request = "--gres=gpu:h200:%d", cores = 8, mem = "64G", max = 8 }
arch = "h200"
queues = [{ partition = "h200q", max_time = "24:00:00" }]
```

| Key | Default | Meaning |
|-----|---------|---------|
| `name` | required | The kind's name, as a spec's `node_type` gives it |
| `cores` | required for CPU nodes | Cores of a node |
| `numa` | 1 | NUMA domains of a node, for `placement = "numa"` |
| `whole` | `false` | `true`: a job gets whole nodes without asking for cores |
| `mem` | none | A note: SimLaunch does not read it |
| `gpus` | none | Makes the kind GPU nodes; see below. A GPU kind has no `cores`, `numa`, `whole` or `mem` of its own |
| `header` | none | Further batch options of every job on these nodes, such as `["--exclusive", "--mem=0"]` |
| `arch` | | Its [architecture](#arch), where the profile has an `[arch]` table |
| `queues` | none | Its [queues](#queues), in the order of preference |
| `max_time` | none | The longest job, for a kind without `queues`: the site's submit filter chooses the partition, and no `--partition` is written |

`gpus`:

| Key | Default | Meaning |
|-----|---------|---------|
| `request` | required | The batch option for GPUs, with `%d` for their number: `"--gres=gpu:h200:%d"` |
| `cores` | required | Cores per GPU |
| `request_cores` | `true` | `false`: the site hands out the cores with the GPU; none are asked for |
| `mem` | none | Memory per GPU, such as `"64G"`; without it none is asked for |
| `max` | none | The most GPUs of a job |

A queue belongs to one kind of node, and `--queue` names a queue of the
job's kind. A partition that holds nodes of two kinds is listed with each,
with a `header` such as `--exclude=cn112` that keeps a job on its own kind.

`[[slurm.nodes]]` is a list, so a profile on top of another replaces all of
its kinds of node when it gives any.

Until 2026-11-19 a profile had one kind of CPU node in `[slurm] node` with
its `queues`, and one kind of GPU node in `[slurm.gpu]`; a queue could name
its own `arch` and be marked `on_request`. Such a profile is refused with a
message.

### Queues

A queue is a table in the list `queues` of a kind of node. A job takes the
first that fits, or the one it names.

| Key | Default | Meaning |
|-----|---------|---------|
| `partition` | required | The Slurm partition |
| `min_time`, `max_time` | none | The shortest and the longest job |
| `max_nodes` | none | The most nodes of a job |
| `min_gpus`, `max_gpus` | none | The fewest and the most GPUs of a job |
| `one_at_a_time` | `false` | The site refuses a user's second job here; SimLaunch looks first, and sends no chain here |
| `preempt` | `false` | Its jobs can be stopped at any time: only for a job with `checkpoints = true` |
| `prefer` | `false` | A job with checkpoints takes this queue first |
| `chain` | `true` | `false`: not for a chain of jobs |
| `header` | none | Further batch options of a job in this queue |

### `[arch]`

Nodes with different CPUs cannot share compiled Julia code. `[arch]` names
the site's architectures, each with its `JULIA_CPU_TARGET`; `"native"` means
the node's own CPU. A study has one depot of compiled caches per
architecture.

```toml
[arch]
amd = "znver2"                      # two CPU generations share Zen 2 code
h200 = "native"
```

Each kind of node names its architecture as `arch`, and `[julia]
login_arch` names the login node's. Several kinds can share one. Without
`login_arch` the login node has an architecture of its own, and `prepare`
compiles in a job on a node of each kind. Without `[arch]` the site has one
architecture, and the login node compiles for all nodes. A site without
`[slurm]`, such as the laptop, gives its architecture as `login_arch`,
since its jobs run where it compiles. A target does not start with
`generic`.

### `[julia]`

| Key | Default | Meaning |
|-----|---------|---------|
| `bin` | `"julia"` | The Julia of the site. May start with `~/` |
| `versions` | none | A table: a Julia version, as a spec's `julia` names it, and the binary that runs it, such as `"1.14" = "~/julia-1.14.0-beta1/bin/julia"`. A version that is not here runs as juliaup's channel, `<bin> +1.14`, so `bin` must be juliaup's launcher for it |
| `depot` | `"~/.julia"` | The site's shared depot: packages, artifacts, registries. Compiled caches are the study's own |
| `modules` | none | Environment modules that every job loads |
| `login_arch` | | See [`[arch]`](#arch) |
| `precompile_tasks` | Julia's | Parallel precompilation tasks on a shared login node |
| `precompile_time` | `"0:30:00"` | Time limit of a precompile job on a compute node |
| `compute_internet` | `true` | `false`: compute nodes have no network, so `prepare` fetches everything and jobs run offline |
| `registry_update` | `true` | `false`: `prepare` does not update the registry |

### `[mpi]`

`default` names the recipe of a run that asks for ranks and names none.
Each recipe is a table `[mpi.<name>]`:

| Key | Default | Meaning |
|-----|---------|---------|
| `binary` | the recipe's name | `"jll"`: MPICH_jll. A binary that MPIPreferences knows, such as `"MPIABI_jll"`. `"system"`: the site's own MPI |
| `launcher` | `"srun"` | `"srun"`, or `"mpiexec"`: the binary's own |
| `launcher_args` | none | Arguments of the launcher, such as `["--mpi=pmix"]` |
| `multi_node` | `true` under `srun` | Whether the recipe can start ranks on several nodes |
| `implementation` | from `binary` | `"openmpi"` (Open MPI, HPC-X) or `"mpich"` (MPICH, Intel MPI, MVAPICH: Hydra's `mpiexec`). It says how an `mpiexec` is told the run's nodes and ranks per node. Known for `"jll"`, `"MPICH_jll"` and `"OpenMPI_jll"`; a recipe with `launcher = "mpiexec"` and `multi_node = true` needs it otherwise |
| `modules` | none | Environment modules for a run with this recipe |
| `julia` | `[julia] bin` | A Julia that can load the site's MPI |
| `env` | none | Variables exported for a run with this recipe |
| `preferences` | none | A table: the keywords of `MPIPreferences.use_system_binary`, such as `library_names`, `mpiexec` and `abi` |

### `[env]`

Variables exported in every job on the site.
