# The batch script of a job: plain bash, readable and runnable on its own.

study_code(site::Site, study) = joinpath(site.code, study)
study_scratch(site::Site, study) = joinpath(site.scratch, study)

"""
The study's own Julia depot on a site, for one architecture of the site's
profile. Its `compiled` directory holds the study's precompiled caches for
the nodes of that architecture, so that neither another study's prepare nor
a node of another architecture can change what a job loads; packages,
artifacts and registries are links into the site's depot.
"""
study_depot(site::Site, study, arch) = joinpath(study_code(site, study), "depot-" * arch)
log_file(job::Job, jobid) = joinpath(study_scratch(job.site, job.study), "logs", "$(job.name)-$jobid.out")

"`gpus` times a memory size such as \"64G\"."
function scale_mem(mem, gpus)
    m = match(r"^(\d+)([KMGT]?)$", mem)
    m === nothing && fail("cannot read the memory size $(repr(mem)); use a number and K, M, G or T")
    return string(parse(Int, m[1]) * gpus, m[2])
end

"""
The `#SBATCH` lines of a job on a Slurm site, on its kind of node `type`:
`gpus` GPUs, or `nodes` CPU nodes for `gpus = 0`, with `tasks` tasks on each
node. `queue` is `nothing` where the site chooses the partition.
"""
function sbatch_header(io::IO, site::Site, type::NodeType; queue, gpus, time, name, output, nodes = 1, tasks = 1,
                       node = "", extra = String[], requeue = false)
    site.account === nothing || println(io, "#SBATCH --account=$(site.account)")
    queue === nothing || println(io, "#SBATCH --partition=$(queue)")
    println(io, "#SBATCH --nodes=$nodes")
    several = nodes > 1 || tasks > 1
    println(io, several ? "#SBATCH --ntasks-per-node=$tasks" : "#SBATCH --ntasks=1")
    if gpus > 0
        g = type.gpus
        println(io, "#SBATCH ", replace(g.request, "%d" => string(gpus)))
        g.request_cores && println(io, "#SBATCH --cpus-per-task=$(gpus * g.cores ÷ tasks)")
        g.mem === nothing || println(io, "#SBATCH --mem=$(scale_mem(g.mem, gpus))")
    else
        (several || !type.whole) && println(io, "#SBATCH --cpus-per-task=$(type.cores ÷ tasks)")
    end
    for line in type.header
        println(io, "#SBATCH $line")
    end
    isempty(node) || println(io, "#SBATCH --nodelist=$node")
    println(io, "#SBATCH --time=$(time_string(time))")
    println(io, "#SBATCH --job-name=$name")
    println(io, "#SBATCH --output=$output")
    if requeue
        println(io, "#SBATCH --requeue")
        println(io, "#SBATCH --open-mode=append")
    else
        println(io, "#SBATCH --no-requeue")
    end
    for line in extra
        println(io, "#SBATCH $line")
    end
    return
end

"""
The Julia binary of a run or a combination, as bash text: its MPI recipe's;
for a Julia version, the binary the profile names for it, or else juliaup's
channel of `bin`; else `bin`, the site's own.
"""
function julia_text(site::Site, recipe, julia = ""; bin = "\"\$JULIA\"")
    rec = isempty(recipe) ? nothing : site.mpi[recipe]
    rec === nothing || rec.julia_bin === nothing || return shpath(rec.julia_bin)
    isempty(julia) && return bin
    haskey(site.julia_versions, julia) && return shpath(site.julia_versions[julia])
    return "$bin +$julia"                              # juliaup's channel
end

"Bash lines that load a recipe's modules and export its variables."
function recipe_setup(io::IO, site::Site, recipe; indent = "")
    isempty(recipe) && return
    rec = site.mpi[recipe]
    if !isempty(rec.modules)
        # `module` reads unset variables
        println(io, indent, "set +u; module load ", join(q.(rec.modules), " "), "; set -u")
    end
    for (k, v) in sort!(collect(rec.env))
        println(io, indent, "export $k=$(q(v))")
    end
    return
end

"The command of one run, as bash text: its launcher, its placement and its Julia command."
function run_command(job::Job, r::Run)
    site = job.site
    julia = julia_text(site, r.mpi, r.julia)
    envdir = "\"\$CODE\"/" * q(r.envdir)
    # A step under srun has its own shape. Without the job's SLURM_CPUS_PER_TASK, srun does not warn that a
    # step with fewer and wider tasks "may never run" (Slurm 21.08: it runs the same).
    srun = r.ranks > 0 ? site.mpi[r.mpi].launcher == "srun" : job.pin
    words = String[]
    if srun || !isempty(r.vars)
        push!(words, "env")
        srun && push!(words, "-u", "SLURM_CPUS_PER_TASK")
        append!(words, ["$k=$(q(v))" for (k, v) in sort!(collect(r.vars))])
    end
    if r.ranks > 0
        rec = site.mpi[r.mpi]
        if rec.launcher == "srun"
            push!(words, "srun")
            append!(words, q.(rec.launcher_args), q.(r.launcher_args))
            # else the other ranks of one that died wait in MPI until the time limit
            push!(words, "--kill-on-bad-exit=1", "--nodes=$(r.nodes)", "--ntasks=$(r.ranks)",
                  "--cpus-per-task=$(job.cores * r.nodes ÷ r.ranks)", "--cpu-bind=none")
        else
            # the binary's own mpiexec, found through MPI.jl
            push!(words, julia, "--startup-file=no", "--project=$envdir", "\"\$TOOLS\"/mpiexec.jl")
            append!(words, q.(rec.launcher_args), q.(r.launcher_args))
            if rec.multi_node && job.nodes > 1
                # the run's nodes, the job's first, and as many ranks on each: left to itself, an mpiexec fills
                # each node's Slurm slots in turn, as many as the run with the most ranks on a node needs
                rpn = r.ranks ÷ r.nodes
                if rec.implementation == "openmpi"
                    push!(words, "--host", "\"\$(node_list $(r.nodes) :$rpn)\"")
                else
                    push!(words, "-ppn", string(rpn), "-hosts", "\"\$(node_list $(r.nodes))\"")
                end
            end
            push!(words, "-n", string(r.ranks))
            # srun gives every rank the job's environment. An mpiexec need not, on another node: the run's
            # variables are set again on the rank's side
            isempty(r.vars) || append!(words, ["env"; ["$k=$(q(v))" for (k, v) in sort!(collect(r.vars))]])
        end
    elseif job.pin
        push!(words, "srun")
        (job.nodes > 1 || job.tasks > 1) && push!(words, "--nodes=1", "--ntasks=1", "--cpus-per-task=$(job.cores)")
        push!(words, "--cpu-bind=none")
    end
    if r.placement == "numa"
        # rank i of the R on its node gets the D/R NUMA domains from i·D/R on: their cores and their memory.
        # With `domains_per_rank = k` it gets k, from ⌊i·D/R⌋ on. A run without ranks gets domain 0, or k from 0 on. D is counted on the node (`numactl -H` starts with
        # "available: 8 nodes (0-7)"): a partition can mix node types, and the profile's number is only what
        # `submit` checks against
        rpn = max(r.ranks, 1) ÷ r.nodes
        # which rank on its node this is: srun says so; under an mpiexec the batch step's SLURM_LOCALID (0) is
        # inherited and says nothing, and Open MPI or Hydra do (PMI_RANK counts over all nodes)
        id = srun && r.ranks > 0 ? "\${SLURM_LOCALID:-0}" :
             r.ranks > 0 ? "\${OMPI_COMM_WORLD_LOCAL_RANK:-\${MPI_LOCALRANKID:-0}}" : "0"
        width = r.domains > 0 ? string(r.domains) : r.ranks > 0 ? "\$(( n / $rpn ))" : "1"
        misfit = r.domains > 0 ?
                 "if [ \"\${n:-0}\" -lt $(rpn * r.domains) ]; then " *
                 "echo \"placement: \$(hostname -s) has \${n:-no} NUMA domains, too few for " *
                 "$rpn rank$(rpn == 1 ? "" : "s") with $(r.domains) each\" >&2; exit 1; fi; " :
                 "if [ \"\${n:-0}\" -lt $rpn ] || [ \$(( n % $rpn )) != 0 ]; then " *
                 "echo \"placement: \$(hostname -s) has \${n:-no} NUMA domains, " *
                 "which $rpn rank$(rpn == 1 ? "" : "s") cannot share evenly\" >&2; exit 1; fi; "
        first = r.domains > 0 ? "\$(( l * n / $rpn ))" : "\$(( l * w ))"
        bind = "l=$id; n=; read -r _ n _ < <(numactl -H 2>/dev/null); " * misfit *
               "w=$width; d=$first; if [ \$w -gt 1 ]; then d=\$d-\$(( d + w - 1 )); fi; " *
               "exec numactl --cpunodebind=\$d --membind=\$d \"\$@\""
        push!(words, "bash", "-c", q(bind), "numa")
    end
    append!(words, q.(r.prefix))
    push!(words, julia, "-t", job.pin ? "$(r.threads),0" : string(r.threads))
    append!(words, q.(r.julia_args))
    push!(words, "--project=$envdir")
    if startswith(r.cmd[1], "-")
        append!(words, q.(r.cmd))                      # Julia options, such as -e
    else
        push!(words, "\"\$PROJECT\"/" * q(r.cmd[1]))   # a script of the project
        append!(words, q.(r.cmd[2:end]))
    end
    job.checkpoints && push!(words, "\${RESTART_ARGS[@]+\"\${RESTART_ARGS[@]}\"}")
    return join(words, " ")
end

"A string as a TOML value, quoted and escaped; nothing for an empty one."
toml_value(text) = isempty(text) ? "" : chopprefix(chomp(sprint(TOML.print, Dict("x" => text))), "x = ")

"""
    generate(job; script = "") -> String

The job's batch script. On a Slurm site it is submitted with `sbatch`; on the
local site it runs under `bash` with `SIMLAUNCH_JOB_ID` set. Called as
`script --queued JOBID` it marks the job's runs queued for SimWatch.
`script` is where the script will be on the site, for a job that submits its
successor; `successor = false` keeps a pre-empted job from doing so.
"""
function generate(job::Job; script = "", successor = true)
    site = job.site
    code, scratch = study_code(site, job.study), study_scratch(site, job.study)
    isempty(script) && (script = joinpath(code, "jobs", job.name * ".sh"))
    io = IOBuffer()
    println(io, "#!/bin/bash")
    site.slurm && sbatch_header(io, site, job.type; queue = job.queue === nothing ? nothing : job.queue.partition,
                                gpus = job.gpus, time = job.time, name = "$(job.study)-$(job.name)",
                                output = log_file(job, "%j"), nodes = job.nodes, tasks = job.tasks,
                                node = job.node, requeue = job.mutable,
                                extra = [job.queue === nothing ? String[] : job.queue.header; job.sbatch_args])
    print(io, """

          # Generated by SimLaunch $VERSION_STRING: study $(job.study), spec $(job.name), site $(site.name).
          # $(length(job.runs)) runs, $(job.mode). Plain bash; nothing else is needed to run it.

          set -u

          STUDY=$(q(job.study))
          SPEC=$(q(job.name))
          DESCRIPTION=$(q(toml_value(job.description)))        # for SimWatch, as a TOML string; empty: none
          SITE=$(q(site.name))
          CODE=$(shpath(code))
          PROJECT=$(shpath(joinpath(code, "src", job.project)))
          TOOLS=$(shpath(joinpath(code, "tools")))
          DEPOT=$(shpath(study_depot(site, job.study, job_arch(job))))      # the study's compiled caches, for this architecture
          SCRATCH=$(shpath(scratch))
          JULIA=$(shpath(site.julia_bin))
          USE_SLURM=$(site.slurm ? 1 : 0)
          TIME_LIMIT=$(something(job.time, ""))        # seconds; empty: none
          NODES=$(job.nodes)
          GPUS=$(job.gpus)
          LABELS=($(join(q.(r.label for r in job.runs), " ")))
          THREADS=($(join((r.threads for r in job.runs), " ")))
          RANKS=($(join((r.ranks for r in job.runs), " ")))
          JOBDIRS=()
          SKIP=()
          PIDS=()
          TERMINATED=
          CHECKPOINTS=$(job.checkpoints ? 1 : 0)        # 1: the runs continue from the checkpoints of earlier jobs
          MUTABLE=$(job.mutable ? 1 : 0)            # 1: one shared directory for all jobs of a run
          CONTINUE_CODE=$(job.restart === nothing ? "" : something(job.restart.continue_code, ""))        # the driver's exit code when it stops at its walltime
          """)
    job.checkpoints || println(io, "SUCCESSOR=0")
    if job.checkpoints
        rs = job.restart
        auto = successor && site.slurm && !job.mutable && job.queue !== nothing && job.queue.preempt
        print(io, """
              RESTART_TO=$(q(rs.to))                # the driver's arguments: its own checkpoints,
              RESTART_FROM=$(q(rs.from))              # an earlier job's,
              RESTART_WALLTIME=$(q(rs.walltime))          # and the seconds it may run
              MARGIN=$(rs.margin)                   # seconds of the time limit kept back
              TEMPORARY=($(join(q.(rs.temporary), " ")))   # checkpoints that are still being written
              SUCCESSOR=$(auto ? 1 : 0)                 # 1: a job stopped before its time limit submits the next one
              SCRIPT=$(shpath(script))
              SBATCH_EXPORT=$(site.export_env ? "" : "--export=NONE")
              """)
    end
    println(io)
    print(io, read(joinpath(PKGROOT, "templates", "job_helpers.sh"), String))
    print(io, """

          # Called by `simlaunch submit` after the job is queued.
          if [ "\${1:-}" = --queued ]; then
              JOBID=\$2
              for i in "\${!LABELS[@]}"; do sw_queued "\$i" "\${3:-}"; done
              exit 0
          fi

          # Called by `simlaunch cancel`: the runs that have not ended are marked cancelled.
          if [ "\${1:-}" = --cancelled ]; then
              for i in "\${!LABELS[@]}"; do sw_cancel "\$i" "\${2:-cancelled}"; done
              exit 0
          fi

          JOBID=\${SLURM_JOB_ID:-\${SIMLAUNCH_JOB_ID:-}}
          if [ -z "\$JOBID" ]; then
              echo "no job ID: submit with sbatch, or set SIMLAUNCH_JOB_ID" >&2
              exit 2
          fi
          SW_T0=\$(date +%s)
          SW_STARTED=\$(sw_now)
          # without Slurm, this is how the job is stopped: kill \$(cat <file>)
          if [ "\$USE_SLURM" = 0 ]; then echo \$\$ > "\$SCRATCH/logs/\$SPEC-\$JOBID.pid"; fi

          # The environment. Everything is set here; nothing is taken from the
          # submitting shell.
          """)
    for m in site.modules
        println(io, "module load $(q(m))")
    end
    println(io, "unset JULIA_LOAD_PATH JULIA_PROJECT JULIA_CPU_TARGET   # set below where the caches were compiled for a target")
    println(io, "export JULIA_DEPOT_PATH=\"\$DEPOT:\"         # the study's depot, then Julia's own; not ~/.julia")
    println(io, "export OPENBLAS_NUM_THREADS=$(job.blas_threads)")
    println(io, "export JULIA_PKG_PRECOMPILE_AUTO=0")
    for (k, v) in sort!(collect(site.env))
        println(io, "export $k=$(q(v))")
    end
    target = site.archs[job_arch(job)]
    isempty(target) || println(io, "export JULIA_CPU_TARGET=$(q(target))     # as the caches were compiled")
    job.pin && println(io, "export JULIA_EXCLUSIVE=1")
    print(io, """

          echo "SimLaunch job \$JOBID: study \$STUDY, spec \$SPEC, site \$SITE, host \$(hostname -s), \$(date)"
          lscpu 2>/dev/null | grep -m1 'Model name' || sysctl -n machdep.cpu.brand_string 2>/dev/null || true$(job.gpus > 0 ? "\nnvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true" : "")
          """)
    job.checkpoints && print(io, """

                             # A run that an earlier job has finished is not run again.
                             left=0
                             for i in "\${!LABELS[@]}"; do
                                 SKIP[\$i]=0
                                 if run_finished "\$i"; then
                                     SKIP[\$i]=1
                                     echo "run \${LABELS[\$i]} has finished already"
                                 else
                                     left=\$((left + 1))
                                 fi
                             done
                             if [ "\$left" = 0 ]; then echo "nothing is left to do"; exit 0; fi
                             """)
    print(io, """

          trap finish EXIT
          trap on_term TERM INT

          # Every run gets a new directory of its own for this job.
          for i in "\${!LABELS[@]}"; do
              if [ "\${SKIP[\$i]:-0}" = 1 ]; then continue; fi
              JOBDIRS[\$i]=\$(new_job_dir "\$i")
              mkdir -p "\${JOBDIRS[\$i]}" || exit 1
          """)
    job.checkpoints && !job.mutable &&
        println(io, "    seal_earlier \"\$i\"               # what earlier jobs wrote can only be read")
    print(io, """
          done

          # The environment must be precompiled for this Julia and these flags:
          # a job compiles nothing.
          """)
    for (recipe, args, envdir, julia) in unique!([(r.mpi, r.julia_args, r.envdir, r.julia) for r in job.runs])
        check = join([julia_text(site, recipe, julia), q.(args)..., "--startup-file=no", "--project=\"\$CODE\"/$(q(envdir))",
                      "\"\$TOOLS\"/check_precompiled.jl", "||", "exit", "3"], " ")
        if isempty(recipe) || isempty(site.mpi[recipe].modules)
            println(io, check)
        else
            println(io, "(")
            recipe_setup(io, site, recipe; indent = "    ")
            println(io, "    ", replace(check, " || exit 3" => ""))
            println(io, ") || exit 3")
        end
    end
    println(io)
    println(io, "# The runs. Each starts in its own job directory, with its output in output.log.")
    for (k, r) in enumerate(job.runs)
        println(io, "run_$(k - 1)() {   # $(r.label)")
        recipe_setup(io, site, r.mpi; indent = "    ")
        println(io, "    exec ", run_command(job, r))
        println(io, "}")
    end
    after = isempty(job.after) ? "" : """

        # After the last run: the spec's [after] command, in the study's output directory.
        ( cd "\$SCRATCH" && export STUDY SPEC PROJECT SCRATCH JOBID SIMLAUNCH_JOBDIRS="\${JOBDIRS[*]}" &&
          bash -c $(q(job.after)) ) || echo "the [after] command failed with exit code \$?"
        """
    if job.mode === :parallel
        print(io, """

              # All runs side by side.
              for i in "\${!LABELS[@]}"; do
                  if [ "\${SKIP[\$i]:-0}" = 1 ]; then continue; fi
                  ( run_one "\$i" ) &
                  PIDS+=(\$!)
              done
              wait_runs
              rc=\$?
              """)
    else
        print(io, """

              # One run after another.
              rc=0
              for i in "\${!LABELS[@]}"; do
                  if [ "\${SKIP[\$i]:-0}" = 1 ]; then continue; fi
                  if [ -n "\$TERMINATED" ]; then rc=143; break; fi
                  ( run_one "\$i" ) &
                  PIDS=(\$!)
                  wait_runs || rc=1
              done
              """)
    end
    print(io, after)
    println(io, "exit \$rc")
    return String(take!(io))
end
