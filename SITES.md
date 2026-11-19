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
  - [`[slurm.gpu]`](#slurmgpu)
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

[slurm]
node = { cores = 64 }
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
| `partition` | `true` | `false`: the site chooses the partition; no `--partition` is written |
| `max_time` | none | The longest job, for a site without `queues` |
| `node` | | The CPU nodes; see below. A site needs `node`, `gpu` or both |
| `queues` | none | The CPU jobs' [queues](#queues), in the order of preference |

`node`:

| Key | Default | Meaning |
|-----|---------|---------|
| `cores` | required | Cores of a node |
| `numa` | 1 | NUMA domains of a node, for `placement = "numa"` |
| `whole` | `false` | `true`: a job gets whole nodes without asking for cores |
| `header` | none | Further batch options of every CPU job, such as `["--exclusive", "--mem=0"]` |

Other keys of `node`, such as `mem`, are notes: SimLaunch does not read them.

### `[slurm.gpu]`

| Key | Default | Meaning |
|-----|---------|---------|
| `request` | required | The batch option for GPUs, with `%d` for their number: `"--gres=gpu:h200:%d"` |
| `cores` | required | Cores per GPU |
| `request_cores` | `true` | `false`: the site hands out the cores with the GPU; none are asked for |
| `mem` | none | Memory per GPU, such as `"64G"`; without it none is asked for |
| `max` | none | The most GPUs of a job |
| `arch` | | The GPU nodes' architecture, where the profile has an `[arch]` table |
| `queues` | none | The GPU jobs' [queues](#queues), in the order of preference |

### Queues

A queue is a table in the list `queues`. A job takes the first that fits,
or the one it names.

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
| `on_request` | `false` | Taken only by a job that names it |
| `arch` | the site's | Its nodes' architecture, where it is not that of the site's other nodes |
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

`[julia] arch` names the CPU nodes' architecture, `[slurm.gpu] arch` the
GPU nodes', and `[julia] login_arch` the login node's. Without `login_arch`
the login node has an architecture of its own, and `prepare` compiles in a
job on a compute node. Without `[arch]` the site has one architecture, and
the login node compiles for all nodes. A target does not start with
`generic`.

### `[julia]`

| Key | Default | Meaning |
|-----|---------|---------|
| `bin` | `"julia"` | The Julia of the site. May start with `~/` |
| `versions` | none | A table: a Julia version, as a spec's `julia` names it, and the binary that runs it, such as `"1.14" = "~/julia-1.14.0-beta1/bin/julia"`. A version that is not here runs as juliaup's channel, `<bin> +1.14`, so `bin` must be juliaup's launcher for it |
| `depot` | `"~/.julia"` | The site's shared depot: packages, artifacts, registries. Compiled caches are the study's own |
| `modules` | none | Environment modules that every job loads |
| `arch`, `login_arch` | | See [`[arch]`](#arch) |
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
| `modules` | none | Environment modules for a run with this recipe |
| `julia` | `[julia] bin` | A Julia that can load the site's MPI |
| `env` | none | Variables exported for a run with this recipe |
| `preferences` | none | A table: the keywords of `MPIPreferences.use_system_binary`, such as `library_names`, `mpiexec` and `abi` |

### `[env]`

Variables exported in every job on the site.
