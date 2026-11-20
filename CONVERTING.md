# SimLaunch: converting a project's launch scripts

How a hand-written batch script becomes a job spec. Written for someone, or
an agent, working in the project that owns the script, such as the batch
scripts in TreeAMR's `bench/`. [`SPEC.md`](SPEC.md) is the reference for every key.

- [Before you start](#before-you-start)
- [The steps](#the-steps)
- [What becomes what](#what-becomes-what)
- [What does not carry over](#what-does-not-carry-over)
- [Checking the conversion](#checking-the-conversion)
- [In CI](#in-ci)

## Before you start

- A script moves when a run of it is due anyway, not all at once. Running
  jobs keep their scripts.
- The Julia entry points stay as they are. SimLaunch decides where and how
  `bench/nested.jl` runs; it does not wrap or change it.
- Specs live in the project, in `jobs/`, committed with it.
- What has run on a cluster so far is short: see "What has run where" in
  [`PLAN.md`](PLAN.md#what-has-run-where). MPI launchers, NUMA placement and jobs on
  several nodes have run on two clusters only, with a toy program. The first
  real script that needs one of them, or another site, is its first test:
  read the generated script (`--dry-run`) with care, and expect to fix the
  site's profile.

## The steps

1. **Read the script for what it does, in four parts**: what it sets up
   (environments, precompilation), what it asks the queue for, which
   commands it runs, and what it does with their output.
2. **Write the spec**, `jobs/<name>.toml`: the commands become `[[run]]`
   tables, the queue's part a `[site.<name>]` table. Where the runs are a
   product of versions, sizes and rounds, write `jobs/<name>.jl` instead:
   see "A spec in Julia" in `SPEC.md`.
3. **Take a snapshot** of the project:
   `simlaunch snapshot . --study <study> --note "<what it is for>"`, with
   `--variant <name>=<directory>` for each further version the script
   compares. The note is how a study is recognised later, in
   `simlaunch list` and in SimWatch, after the session that made it is gone:
   always give one. A fix to the project afterwards, even to one script,
   is a new snapshot under a new name: never edit the copy on a site,
   which `prepare` and `submit` then refuse.
4. **Look at the result without a cluster**:
   `simlaunch submit <study> jobs/<name>.toml --site <site> --dry-run`
   prints the queue it chose and the whole batch script. Compare it with
   the old script line by line: header, modules, variables, launcher.
5. **Try it on the laptop** where the hardware allows: add a `[site.local]`
   table with small sizes, then `prepare`, `submit --wait` with
   `--site local`.
6. **Prepare and submit on the cluster**, once against one run of the old
   script.
7. **When the results are in**, run `simlaunch list` and propose to Erik
   what of your studies can go: their compiled caches (`delete --caches`),
   old checkpoints, or whole studies. `delete` asks before it deletes, and
   only Erik answers: never pass `--yes`.

## What becomes what

| In the script | In SimLaunch |
| --- | --- |
| `#SBATCH --partition`, `--time`, `--nodes`, `--gres`, `--mem`, `--exclusive`, `--account` | `time` and `resources` in the site table. The partition is chosen by rule, or `queue`; a partition of another kind of node than the site's default (Symmetry's Intel nodes, cn112) needs `node_type` too. Cores, memory, account and `--exclusive` come from the site's profile |
| Any other `#SBATCH` line | `sbatch_args` |
| `--nodelist` | `node` |
| `--exclude`, `--constraint` | `sbatch_args = ["--exclude=cn099"]`. A profile can exclude a node for every job of a queue |
| A line that records the node and `lscpu`'s model | nothing: every job directory has a `simlaunch-job.toml` with them |
| A setup stage: `Pkg.instantiate`, `Pkg.precompile`, building environments | `simlaunch prepare`, once per study and site. Nothing of it stays in the job |
| An environment that copies `test/Project.toml` with the package's path made absolute | `env = "test"` |
| `Pkg.add("CUDA")` into a scratch environment | `env = "cuda"`, or `"test+cuda"` |
| `MPIPreferences.use_jll_binary()` / `use_system_binary()`, `module load` of an MPI | nothing for the site's own MPI: it is the default recipe of a run with `ranks`. `mpi = "<recipe>"` for another one of the site's profile |
| `srun --mpi=pmi2 --ntasks=R …`, `mpiexec -n R …` | `ranks = R` and the recipe's launcher |
| A rank script with `numactl --cpunodebind=$d --membind=$d`, one domain a rank or several | `placement = "numa"`: a rank gets its share of the domains. `domains_per_rank = 1` for one domain a rank at any number of ranks |
| `JULIA_EXCLUSIVE=1` with `srun --cpu-bind=none` | `pin = true` |
| `-t N`, `OPENBLAS_NUM_THREADS` | `threads`, `blas_threads` |
| A loop over thread counts | `threads = [1, 8, 64]` in one run |
| A loop over anything else (sizes, shapes, versions) | one `[[run]]` per iteration, written out; for more than a few, a spec in Julia that builds the list |
| `VAR=value julia …`, `export VAR` | `vars`, for the job or for one run |
| `mpiexec --mca io romio321`, `-x VAR` | `vars = { OMPI_MCA_io = "romio321" }`: a run's `vars` reach every rank. `launcher_args` for an option that has no variable |
| `--check-bounds=yes` and other Julia options | `julia_args` |
| `julia +1.13`, another Julia version | `julia = "1.13"` |
| `perf stat …`, `taskset …` before `julia` | `prefix` |
| A baseline checkout beside the new one (`TREEAMR_BASE`) | a variant: `snapshot --variant base=<directory>`, then `variant = "base"` in a run |
| `$OUT/<stem>.tsv`, one output file per run | each run's `output.log`, in its own job directory; files the script writes land there too |
| A table printed at the end (`awk` over the outputs) | `[after] cmd`. `simlaunch after` prints it again later; a corrected script runs on the laptop over what `simlaunch fetch` brought back |
| The project's copy of `simwatch.sh`, stages | nothing: every run has a SimWatch file, written by the job |
| `rsync` of the checkout to the cluster, a fixed tree there | `snapshot` and `prepare` |
| `--requeue`, `--open-mode=append`, a resume-from-checkpoint option | `checkpoints = true` and `[restart]`; see "Restarts" in `SPEC.md` |
| `scp` of the results back | `simlaunch fetch` |

## What does not carry over

Each of these needs a decision in the project, not a key in the spec.

- **Rounds with a rotating order.** A script that runs every configuration
  several times, the versions in another order each round, has no
  counterpart: runs execute in the order of the spec. Write the rounds out
  as runs (`base-8x8-r1`, `new-8x8-r1`, `new-8x8-r2`, `base-8x8-r2`), or
  let a spec in Julia build them in that order.
- **A working directory inside the checkout.** A run starts in its own job
  directory, never in the source tree, which is read-only on some sites. A
  script that reads files relative to its working directory must find them
  from `@__DIR__` instead.
- **Output in a place the script chooses.** A run writes into its job
  directory. A script that takes `out=<dir>` gets a relative path there.
- **Stages chosen by a variable** (`TREEAMR_NESTED_STAGES="setup smoke"`).
  Setup is `prepare`. The other stages are specs of their own, or runs
  picked with `submit --run`.
- **A smoke mode at a tiny size.** A second spec, or a `[site.local]` table
  with small sizes in `vars`.
- **Runs that share their cores unevenly**, or a pinned run beside another.
  Parallel runs share the cores by their `threads`, unpinned.
- **Anything decided while the job runs**: a run that depends on another
  run's result, retries. SimLaunch has no such logic by design.

If a script needs something that fits none of these, `sbatch_args`,
`prefix` and `launcher_args` pass text through as written. Say so in the project's notes: a
second script with the same need is the reason to add a key.

## Checking the conversion

- `--dry-run` on every site the spec names. It needs no connection.
- On the laptop, `simlaunch submit … --site local --wait` returns 0 only
  when every run has finished.
- On a cluster, compare the first job's output with a run of the old
  script: the same numbers for a simulation, times within the usual scatter
  for a benchmark. Then retire the script.
- For a driver with checkpoints, `simlaunch check-restart` with a short
  spec.

## In CI

A spec can run in the project's GitHub CI on the runner itself, as
`--site local`, so that it does not rot between cluster runs. Give it a
`[site.local]` table with a size that takes seconds.

```yaml
- uses: julia-actions/setup-julia@v2
  with:
    version: '1'
- name: Install SimLaunch
  run: |
    julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/eschnett/SimLaunch.jl")'
    echo "$HOME/.julia/bin" >> "$GITHUB_PATH"
- name: Run the job spec
  run: |
    simlaunch snapshot . --study ci
    simlaunch prepare ci --site local --spec jobs/smoke.toml
    simlaunch submit ci jobs/smoke.toml --site local --wait
```

`--wait` prints each run's status as it changes and the end of the output
of a run that did not finish, and fails the step unless every run has
finished. This checks the spec and the command it names, not the cluster's
part: queues, modules and launchers are only exercised there. For the
project's test suite itself, `Pkg.test` in CI stays the simpler way.
