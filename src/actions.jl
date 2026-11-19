# prepare and submit: what the tool does on a site.

stamp() = Dates.format(now(), dateformat"yyyymmdd-HHMMSS")

prepared_file(site::Site, study, arch) = joinpath(study_depot(site, study, arch), "prepared")

"A combination's line in the study's `prepared` file on a site."
function combo_line(c::Combo)
    own = c.envdir == joinpath("src", c.project)                       # the project itself, as the snapshot holds it
    fields = [own ? c.project : c.envdir, c.args, c.gpu ? "gpu" : "", c.target]
    while length(fields) > 1 && isempty(fields[end])
        pop!(fields)
    end
    return join(fields, '\t')
end

"""
A combination's line in the `prepared` file: `combo_line` and the Julia
build it was compiled with, such as `julia 1.14.0-beta1`. A juliaup channel
moves on to new builds, and a cache of an older one is no use to the new.
"""
prepared_line(c::Combo, build) = combo_line(c) * "\tjulia " * build

"Bash text that is the version of the combination's Julia on the site, as `julia --version` says it."
julia_build_text(site::Site, c::Combo; bin = "\"\$JULIA\"") =
    "\$($(julia_text(site, c.mpi, c.julia; bin)) --version 2>/dev/null | sed 's/^julia version //')"

"Bash text that is the combination's line in the `prepared` file, written on the site."
prepared_line_text(site::Site, c::Combo) = "\"\$(printf '%s\\tjulia %s' $(q(combo_line(c))) \"$(julia_build_text(site, c))\")\""

"The lines the `prepared` file needs for the combinations: their Julia builds are asked of the site, each binary once."
function prepared_lines(site::Site, cs)
    isempty(cs) && return String[]
    texts = [julia_text(site, c.mpi, c.julia; bin = shpath(site.julia_bin)) for c in cs]
    commands = unique(texts)
    loads = join(["module load $(q(m)); " for m in site.modules])
    out = readsite(site, loads * join(["echo \"$(julia_build_text(site, c; bin = shpath(site.julia_bin)))\""
                                       for c in cs[[findfirst(==(t), texts) for t in commands]]], "; ") * "; true")
    builds = Dict(zip(commands, split(out, '\n')))
    return [prepared_line(c, strip(get(builds, t, ""))) for (c, t) in zip(cs, texts)]
end

function combo_text(c::Combo)
    return string(c.envdir, isempty(c.args) ? "" : " with $(c.args)", c.gpu ? " on a GPU node" : "")
end

"The jobs the given spec files mean on a site."
function load_jobs(study, site::Site, specs; kw...)
    snap = load_snapshot(study)
    return map(specs) do file
        job = resolve(load_spec(file), site; study, project = snap["project"], variants = study_variants(snap), file,
                      note = get(snap, "note", ""), kw...)
        isdir(joinpath(cache_root(), study, "src", job.project)) ||
            fail("$file: study $study has no project at src/$(job.project). `project` is relative to the study's own project, ",
                 "src/$(snap["project"]) (until 2026-11-18 it was relative to src/): \"coupled\" for a subproject, ",
                 "\"../HexCGSEM\" for a sibling, and none for the study's own")
        job
    end
end

"""
The start of a prepare script: paths and what every Julia call there needs.
`arch` is the architecture of the node the script runs on: what it compiles
goes into that architecture's depot.
"""
function prepare_preamble(io::IO, site::Site, study, arch)
    print(io, """
          set -euo pipefail

          CODE=$(shpath(study_code(site, study)))
          SCRATCH=$(shpath(study_scratch(site, study)))
          JULIA=$(shpath(site.julia_bin))
          DEPOT=$(shpath(study_depot(site, study, arch)))
          SITE_DEPOT=$(shpath(site.depot))

          # The study's own depot for the architecture $arch: its compiled caches
          # are its own, so neither another study's prepare nor a node of another
          # architecture can change what a job loads. What is installed once and
          # never changes is shared with the site's depot.
          mkdir -p "\$DEPOT/compiled"
          for d in packages artifacts registries clones scratchspaces; do
              mkdir -p "\$SITE_DEPOT/\$d"
              [ -e "\$DEPOT/\$d" ] || ln -s "\$SITE_DEPOT/\$d" "\$DEPOT/\$d"
          done
          export JULIA_DEPOT_PATH="\$DEPOT:"       # then Julia's own depots; not ~/.julia

          unset JULIA_LOAD_PATH JULIA_PROJECT JULIA_CPU_TARGET   # a combination sets its own target
          export JULIA_PKG_PRECOMPILE_AUTO=0
          """)
    site.precompile_tasks === nothing || println(io, "export JULIA_NUM_PRECOMPILE_TASKS=$(site.precompile_tasks)")
    for m in site.modules
        println(io, "module load $(q(m))")
    end
    return
end

"Bash text that precompiles one combination, checks it and records it."
function precompile_block(io::IO, site::Site, c::Combo; instantiate::Bool)
    flags = isempty(c.args) ? "" : c.args * " "
    julia = "$(julia_text(site, c.mpi, c.julia)) $(flags)--startup-file=no --project=\"\$CODE\"/$(q(c.envdir))"
    println(io)
    println(io, "echo ", q("=== precompile $(combo_text(c)) ==="))
    println(io, "(")                                   # a recipe's modules and variables stay in here
    recipe_setup(io, site, c.mpi)
    isempty(c.target) || println(io, "export JULIA_CPU_TARGET=$(q(c.target))")
    println(io, "$julia -e 'using Pkg; $(instantiate ? "Pkg.instantiate(); " : "")Pkg.precompile()'")
    # what a package downloads at first use is fetched now, where there is a network
    for kind in env_kinds(c.env)
        isempty(ENV_KINDS[kind].warm) || println(io, "$julia -e $(q(ENV_KINDS[kind].warm))")
    end
    println(io, "$julia \"\$CODE\"/tools/check_precompiled.jl")
    println(io, ")")
    println(io, "line=$(prepared_line_text(site, c))")
    println(io, "grep -qxF \"\$line\" \"\$DEPOT/prepared\" 2>/dev/null || printf '%s\\n' \"\$line\" >> \"\$DEPOT/prepared\"")
    return
end

"""
The bash script that makes a study runnable on a site, run on its login
node: it instantiates every environment and, on a site whose login node is
the compute nodes' CPU, precompiles too.
"""
function prepare_script(site::Site, study, needed)
    io = IOBuffer()
    print(io, """
          #!/bin/bash
          # Generated by SimLaunch $VERSION_STRING: prepare study $study on site $(site.name).
          # Instantiates on this node, and precompiles what its CPU fits; a job needs no network afterwards.

          """)
    prepare_preamble(io, site, study, site.login_arch)
    print(io, """

          mkdir -p "\$SCRATCH/logs" "\$CODE/jobs"
          exec > >(tee -a "\$SCRATCH/prepare.log") 2>&1
          echo "=== prepare $study on $(site.name), host \$(hostname -s), \$(date) ==="
          """)
    site.registry_update && print(io, """

                                  "\$JULIA" --startup-file=no -e 'using Pkg; Pkg.Registry.update()'
                                  """)
    # every Julia version the specs name runs here, before anything is written
    for v in unique!(filter(!isempty, [c.julia for c in needed]))
        println(io, "$(julia_text(site, "", v)) --version >/dev/null 2>&1 || { echo \"Julia $v does not run on $(site.name): ",
                haskey(site.julia_versions, v) ? "check [julia.versions] in its profile" :
                "add it with \\`juliaup add $v\\`, or name its binary in [julia.versions] of the profile", "\" >&2; exit 1; }")
    end
    for c in unique(c -> c.envdir, needed)
        julia = julia_text(site, c.mpi, c.julia)
        kinds = env_kinds(c.env)
        println(io)
        if c.envdir == variant_project(c.project, c.variant)
            println(io, "echo ", q("=== instantiate $(c.envdir) ==="))
            println(io, "$julia --startup-file=no --project=\"\$CODE\"/$(q(c.envdir)) -e 'using Pkg; Pkg.instantiate()'")
            continue
        end
        packages = unique!(String[p for k in kinds for p in ENV_KINDS[k].packages])
        # An environment whose caches a compute node compiled is left as it is: writing it again makes
        # this node compile MPIPreferences anew, and the caches that were built on it are then stale.
        users = [u for u in needed if u.envdir == c.envdir]
        done = all(u -> precompile_where(site, u.arch) == "compute", users)
        if done
            tests = join(["grep -qxF $(prepared_line_text(site, u)) $(shpath(prepared_file(site, study, u.arch))) 2>/dev/null"
                          for u in users], " && ")
            println(io, "if $tests; then")
            println(io, "echo ", q("=== environment $(c.envdir): compiled on a compute node already, left as it is ==="))
            println(io, "else")
        end
        "test" in kinds && pushfirst!(packages, "--test")
        what = [isempty(kinds) ? String[] : [join(kinds, ", ")]; isempty(c.julia) ? String[] : ["Julia $(c.julia)"]]
        println(io, "echo ", q("=== environment $(c.envdir): $(c.project)$(c.variant == "default" ? "" : " ($(c.variant))") and $(join(what, ", ")) ==="))
        println(io, "(")
        recipe_setup(io, site, c.mpi)
        println(io, "$julia --startup-file=no \"\$CODE\"/tools/make_env.jl \"\$CODE\"/$(q(variant_project(c.project, c.variant))) ",
                "\"\$CODE\"/$(q(c.envdir)) $(join(q.(packages), " "))")
        if !isempty(c.mpi)
            rec = site.mpi[c.mpi]
            prefs = isempty(rec.preferences) ? "" : " " * q(sprint(io -> TOML.print(io, rec.preferences; sorted = true)))
            println(io, "$julia --startup-file=no --project=\"\$CODE\"/$(q(c.envdir)) \"\$CODE\"/tools/set_mpi.jl $(rec.binary)$prefs")
        end
        println(io, ")")
        done && println(io, "fi")
    end
    for c in needed
        precompile_where(site, c.arch) == "login" && precompile_block(io, site, c; instantiate = false)
    end
    println(io)
    println(io, "echo \"=== done on the login node, \$(date) ===\"")
    return String(take!(io))
end

"""
The precompile lock of a study's depot for one architecture: it is that depot
a precompile job writes, so the lock is the depot's, and another study or
another architecture is not kept waiting.
"""
lock_dir(site::Site, study, arch) = joinpath(study_depot(site, study, arch), "precompile.lock")
precompile_log(site::Site, study, jobid) = joinpath(study_scratch(site, study), "logs", "precompile-$jobid.out")

"""
The batch script that precompiles `group`, combinations for one
architecture, on a compute node that has it: on the kind of node the jobs
will use, in the first of its queues that fits. Its exit trap gives the
depot's precompile lock back.
"""
function precompile_script(site::Site, study, group)
    gpu, arch = first(group).gpu, first(group).arch
    type = type_named(site, first(group).type)
    io = IOBuffer()
    println(io, "#!/bin/bash")
    queue = nothing
    if !isempty(type.queues)
        queue = choose_queue(site, type; what = "the precompile job asks for $(time_string(site.precompile_time))",
                             seconds = site.precompile_time, nodes = 1, gpus = gpu ? 1 : 0, checkpoints = false, chain = 1)
    end
    sbatch_header(io, site, type; queue = queue === nothing ? nothing : queue.partition, gpus = gpu ? 1 : 0,
                  time = site.precompile_time, name = "$study-precompile", output = precompile_log(site, study, "%j"),
                  extra = queue === nothing ? String[] : queue.header)
    print(io, """

          # Generated by SimLaunch $VERSION_STRING: precompile study $study on a $(gpu ? "GPU" : "CPU") node of $(site.name), architecture $arch.
          # The login node has another architecture, so this node compiles its own caches.

          """)
    prepare_preamble(io, site, study, arch)
    print(io, """
          LOCK=$(shpath(lock_dir(site, study, arch)))

          # give the lock back, if it is still this job's
          unlock() {
              if [ "\$(cat "\$LOCK/jobid" 2>/dev/null)" = "\$SLURM_JOB_ID" ]; then rm -rf "\$LOCK"; fi
          }
          trap unlock EXIT

          echo "=== precompile $study on $(site.name), job \$SLURM_JOB_ID, host \$(hostname -s), \$(date) ==="
          lscpu 2>/dev/null | grep -m1 'Model name' || true
          """)
    for c in group
        precompile_block(io, site, c; instantiate = site.compute_internet)
    end
    println(io)
    println(io, "echo \"=== precompiled, \$(date) ===\"")
    return String(take!(io))
end

"The Slurm state of a job on the site; empty once the queue no longer knows it."
job_state(site::Site, jobid) =
    strip(readsite(site, "squeue -h -j $(q(jobid)) -o %T 2>/dev/null | head -n 1 || true"))

"Wait until the queue no longer knows the job, printing each new state."
function wait_job(site::Site, jobid; what = "job", poll = 20, io::IO = stdout)
    last = ""
    while true
        state = job_state(site, jobid)
        isempty(state) && return
        state == last || println(io, "$what $jobid on $(site.name): ", lowercase(state))
        last = state
        sleep(poll)
    end
end

"""
Take the precompile lock of a study's depot for one architecture: a
directory, since `mkdir` is atomic, that
holds the ID of the precompile job. Waits for a job that holds it; a lock
whose job the queue no longer knows is stale and is taken over.
"""
function acquire_lock(site::Site, study, arch; poll = 20, io::IO = stdout)
    lock = q(lock_dir(site, study, arch))
    while true
        out = strip(readsite(site, "mkdir -p $(q(study_depot(site, study, arch))) && if mkdir $lock 2>/dev/null; then echo acquired; " *
                                   "elif [ -f $lock/jobid ]; then cat $lock/jobid; " *
                                   "elif [ -n \"\$(find $lock -maxdepth 0 -mmin +2 2>/dev/null)\" ]; then echo stale; " *
                                   "else echo starting; fi"))
        out == "acquired" && return
        out == "starting" &&
            fail("another `simlaunch prepare` is submitting a precompile job for study $study on $(site.name) just now; ",
                 "try again in a minute. If none is running, remove $(lock_dir(site, study, arch)) there.")
        if out != "stale"
            if !isempty(job_state(site, out))
                println(io, "precompile job $out compiles study $study for $arch on $(site.name) already; waiting for it")
                wait_job(site, out; what = "precompile job", poll, io)
                sleep(2)                           # its exit trap removes the lock
                continue
            end
            println(io, "the precompile lock of study $study for $arch on $(site.name) names job $out, which has ended: taking it over")
        end
        runsite(site, "rm -rf $lock")
    end
end

release_lock(site::Site, study, arch) = runsite(site, "rm -rf " * q(lock_dir(site, study, arch)))

"Precompile `needed` in jobs on the compute nodes, one job per architecture and kind of node."
function precompile_on_compute(site::Site, study, needed; poll = 20, io::IO = stdout)
    code = study_code(site, study)
    for (arch, gpu) in unique!([(c.arch, c.gpu) for c in needed])
        precompile_where(site, arch) == "compute" || continue
        mine = [c for c in needed if c.arch == arch && c.gpu == gpu]
        lines = prepared_lines(site, mine)
        missing_combos() = (have = prepared(site, study, arch); [c for (c, l) in zip(mine, lines) if l ∉ have])
        isempty(missing_combos()) && continue
        acquire_lock(site, study, arch; poll, io)
        group = missing_combos()                   # the job that held the lock may have made them
        if isempty(group)
            release_lock(site, study, arch)
            continue
        end
        jobid = try
            name = "precompile-$(stamp())$(gpu ? "-gpu" : "").sh"
            remote = joinpath(code, "jobs", name)
            mktempdir() do dir
                write(joinpath(dir, name), precompile_script(site, study, group))
                push_file(site, joinpath(dir, name), remote)
            end
            out = readsite(site, "sbatch --parsable $(site.export_env ? "" : "--export=NONE ")" * q(remote))
            id = String(first(split(strip(out), ';')))
            occursin(r"^\d+$", id) || fail("sbatch did not return a job ID: $(repr(out))")
            runsite(site, "echo $(q(id)) > " * q(joinpath(lock_dir(site, study, arch), "jobid")))
            id
        catch
            release_lock(site, study, arch)
            rethrow()
        end
        log = precompile_log(site, study, jobid)
        println(io, "precompile job $jobid on a $(gpu ? "GPU" : "CPU") node of $(site.name), architecture $arch; log in $log")
        println(io, "(this can be interrupted; `simlaunch prepare` run again finds the job and continues)")
        t0 = time()
        wait_job(site, jobid; what = "precompile job", poll, io)
        seconds = round(Int, time() - t0)
        left = missing_combos()
        # the login node can see a file that a compute node wrote a minute late (NFS)
        for attempt in 1:12
            isempty(left) && break
            sleep(min(poll, 5))
            left = missing_combos()
        end
        if !isempty(left)
            print(readsite(site, "tail -n 30 " * q(log) * " 2>/dev/null || true"))
            fail("precompile job $jobid on $(site.name) did not finish $(join(combo_text.(left), ", ")); its log is $log")
        end
        # the last state printed above is "running": say that it ended, and how
        println(io, "precompile job $jobid on $(site.name): finished, $(seconds ÷ 60):$(lpad(seconds % 60, 2, '0')) after it was submitted")
    end
    return
end

# Resolved versions: each site writes its own manifests. The tool keeps a
# copy of each on the laptop and reports what differs between sites.

manifest_store(study) = joinpath(cache_root(), ".sites", study)
manifest_copy(study, site_name, envdir) =
    joinpath(manifest_store(study), site_name, replace(envdir, "/" => "--") * ".toml")

"The versions a manifest resolved, by package name; `julia` is the Julia version."
function manifest_versions(file)
    manifest = TOML.parsefile(file)
    versions = Dict{String,String}("julia" => string(get(manifest, "julia_version", "?")))
    for (name, entries) in get(manifest, "deps", Dict{String,Any}())
        entry = first(entries)
        if haskey(entry, "path")
            versions[name] = "the study's sources"
        elseif haskey(entry, "version")
            versions[name] = entry["version"]
        elseif haskey(entry, "repo-rev")
            versions[name] = string(entry["repo-rev"], " ", first(get(entry, "git-tree-sha1", ""), 10))
        end
    end
    return versions
end

"Fetch the manifests this site resolved, and print what differs from the study's other prepared sites."
function report_versions(io::IO, site::Site, study, needed)
    for envdir in unique!([c.envdir for c in needed])
        mine = manifest_copy(study, site.name, envdir)
        pull_file(site, joinpath(study_code(site, study), envdir, "Manifest.toml"), mine) || continue
        here = manifest_versions(mine)
        for other in sort!(filter(d -> d != site.name && isfile(manifest_copy(study, d, envdir)),
                                  readdir(manifest_store(study))))
            there = manifest_versions(manifest_copy(study, other, envdir))
            names = sort!([n for n in union(keys(here), keys(there)) if get(here, n, "absent") != get(there, n, "absent")])
            if isempty(names)
                println(io, "$envdir: $(site.name) and $other resolved the same versions")
            else
                println(io, "$envdir: $(length(names)) packages differ between $(site.name) and $other:")
                for n in names
                    println(io, "  $(rpad(n, 28)) $(rpad(get(here, n, "absent"), 22)) $other: $(get(there, n, "absent"))")
                end
            end
        end
    end
    return
end

"""
    prepare(study; site, specs = [])

Copy the study to the site, instantiate it there, and precompile it: for
what the given specs need, or without specs for the project itself with the
default flags. Returns the combinations it prepared.
"""
function prepare(study::AbstractString; site::AbstractString, specs = String[], only_runs = String[], poll = 20,
                 io::IO = stdout)
    s = load_site(site)
    snap = load_snapshot(study)
    isempty(only_runs) || length(specs) == 1 || fail("`--run` names runs of one spec: give exactly one `--spec`")
    needed = Combo[]
    for job in load_jobs(study, s, specs; only_runs)
        append!(needed, combos(job))
    end
    if isempty(specs)
        project = snap["project"]
        t = first(s.types)                                       # the site's first kind of node
        push!(needed, Combo(project, "default", "default", env_dir(project, "default", project), "", isgpu(t), "",
                            t.arch, s.archs[t.arch], "", t.name))
    end
    unique!(needed)
    check_connection(s)

    code = study_code(s, study)
    println(io, "copying study $study to $(s.name):$code")
    push_tree(s, joinpath(cache_root(), study), code)
    script = prepare_script(s, study, needed)
    name = "prepare-$(stamp()).sh"
    mktempdir() do dir
        write(joinpath(dir, name), script)
        push_file(s, joinpath(dir, name), joinpath(code, "jobs", name))
        for tool in TOOLS                                         # also for a study snapshotted before the tool had them
            push_file(s, joinpath(PKGROOT, "templates", tool), joinpath(code, "tools", tool))
        end
    end
    println(io, "preparing on $(s.name); log in $(joinpath(study_scratch(s, study), "prepare.log"))")
    ok = success(pipeline(sitecmd(s, "bash " * q(joinpath(code, "jobs", name))); stdout = io, stderr))
    ok || fail("prepare failed on $(s.name); see the output above")
    s.slurm && precompile_on_compute(s, study, needed; poll, io)
    report_versions(io, s, study, needed)
    println(io, "study $study is prepared on $(s.name)")
    return needed
end

"The combinations prepared on the site so far, for the nodes of one architecture."
function prepared(site::Site, study, arch)
    # listing the directory first makes an NFS client look again
    out = readsite(site, "ls " * q(dirname(prepared_file(site, study, arch))) * " > /dev/null 2>&1; cat " *
                         q(prepared_file(site, study, arch)) * " 2>/dev/null || true")
    return Set(split(out, '\n'; keepempty = false))
end

function describe(io::IO, job::Job)
    println(io, "study $(job.study), spec $(job.name), site $(job.site.name)")
    length(job.site.types) == 1 || println(io, "node type: $(job.type.name)")
    job.queue === nothing || println(io, "queue: $(job.queue.partition)")
    job.nodes > 1 && println(io, "nodes: $(job.nodes)")
    job.gpus > 0 && println(io, "GPUs: $(job.gpus), with $(job.cores) cores")
    println(io, "time: ", job.time === nothing ? "no limit" : time_string(job.time))
    job.checkpoints && println(io, "checkpoints: ", job.mutable ? "one shared directory (mutable_restarts)" :
                                                    "a chain of jobs, one directory each")
    println(io, "runs ($(job.mode)):")
    width = maximum(r -> length(r.label), job.runs; init = 0)
    for r in job.runs
        shape = r.ranks > 0 ? "$(lpad(r.ranks, 3)) ranks × $(lpad(r.threads, 3)) threads" : "$(lpad(r.threads, 4)) threads"
        notes = [r.envdir == joinpath("src", job.project) ? "" : r.envdir, r.placement]
        println(io, "  $(rpad(r.label, width)) $shape   ", join(r.cmd, " "),
                all(isempty, notes) ? "" : "   [" * join(filter(!isempty, notes), ", ") * "]")
    end
    return
end

"The user's jobs in the site's queue: pairs of job ID and job name."
function queued_jobs(site::Site)
    site.slurm || return Pair{String,String}[]
    out = readsite(site, "squeue -h -u \"\$(id -un)\" -o '%i %j' 2>/dev/null || true")
    return [String(a) => String(b) for (a, b) in (split(l; limit = 2) for l in split(out, '\n'; keepempty = false))]
end

"The partitions among `queues` that take one job at a time and hold one of the user's already."
function busy_queues(site::Site, queues)
    names = [qu.partition for qu in queues if qu.one_at_a_time]
    isempty(names) && return Set{String}()
    out = readsite(site, "for p in $(join(q.(names), " ")); do " *
                         "if [ -n \"\$(squeue -h -u \"\$(id -un)\" -p \"\$p\" -o %i 2>/dev/null | head -n 1)\" ]; then echo \"\$p\"; fi; done")
    return Set{String}(split(out, '\n'; keepempty = false))
end

"The jobs of a spec that are queued or running on the site."
function active_jobs(site::Site, study, name)
    if site.slurm
        return [id for (id, jobname) in queued_jobs(site) if jobname == "$study-$name"]
    end
    logs = joinpath(study_scratch(site, study), "logs")
    out = readsite(site, "for f in $(q(logs))/$(q(name))-*.pid; do [ -f \"\$f\" ] || continue; " *
                         "if kill -0 \"\$(cat \"\$f\")\" 2>/dev/null; then b=\${f##*/$(name)-}; echo \"\${b%.pid}\"; fi; done; true")
    return collect(String, split(out, '\n'; keepempty = false))
end

"Stop a job: `scancel`, or a signal to the local job's script."
function cancel_job(site::Site, study, name, jobid)
    if site.slurm
        runsite(site, "scancel $(q(jobid))")
    else
        pidfile = joinpath(study_scratch(site, study), "logs", "$name-$jobid.pid")
        runsite(site, "kill -TERM \"\$(cat $(q(pidfile)))\" 2>/dev/null || true")
    end
    return
end

"Wait until the given job of a spec has ended."
function wait_ended(site::Site, study, name, jobid; poll = 20, timeout = Inf)
    t0 = time()
    while jobid in active_jobs(site, study, name)
        time() - t0 > timeout && fail("job $jobid on $(site.name) did not end within $(round(Int, timeout)) s")
        sleep(poll)
    end
    return
end

"""
    submit(study, spec; site, queue = nothing, only_runs = [], dry_run = false, chain = 1)

Generate the job's batch script and submit it. With `dry_run` it is only
printed. `only_runs` submits just the runs with these labels. `chain`
submits that many jobs of a spec with checkpoints, each after the one before
has ended. Returns the job ID (the first of a chain), or `nothing` for a dry
run.
"""
function submit(study::AbstractString, spec::AbstractString; site::AbstractString, queue = nothing,
                only_runs = String[], dry_run::Bool = false, chain::Integer = 1, io::IO = stdout)
    s = load_site(site)
    if dry_run
        job = only(load_jobs(study, s, [spec]; queue, only_runs, chain))
        describe(io, job)
        job.queue !== nothing && job.queue.one_at_a_time &&
            println(io, "(queue $(job.queue.partition) takes one job at a time; `submit` checks that it is free and else takes the next queue)")
        println(io, "--- the batch script ---")
        print(io, generate(job))
        return nothing
    end

    check_connection(s)
    busy = isempty(all_queues(s)) ? Set{String}() : busy_queues(s, all_queues(s))
    job = only(load_jobs(study, s, [spec]; queue, only_runs, chain, busy))
    return submit_job(job, spec; chain, io)
end

"Submit a resolved job. `spec` is the file it came from, kept beside the script."
function submit_job(job::Job, spec; chain::Integer = 1, successor::Bool = true, io::IO = stdout)
    s, study = job.site, job.study
    have = prepared(s, study, job_arch(job))
    cs = combos(job)
    for (combo, line) in zip(cs, prepared_lines(s, cs))
        line in have && continue
        fail("study $study is not prepared on $(s.name) for $(combo_text(combo))",
             "; run `simlaunch prepare $study --site $(s.name) --spec $spec`")
    end
    if job.checkpoints
        active = active_jobs(s, study, job.name)
        isempty(active) ||
            fail("job $(join(active, ", ")) of spec $(job.name) is queued or running on $(s.name). A run with checkpoints ",
                 "has one job at a time: wait for it, or cancel it. (`--chain N` queues N jobs at once.)")
        job.mutable &&
            @warn "$(job.name): mutable_restarts = true. Its jobs share one directory and append to earlier output; nothing is made read-only."
    end

    code, scratch = study_code(s, study), study_scratch(s, study)
    # The script's name holds the second, and on the laptop so does the job's ID: a second job of the spec in
    # the same second would take the first one's script, log and process file. It waits for the next second.
    taken(base) = strip(readsite(s, "[ -e $(q(joinpath(code, "jobs", base * ".sh"))) ] && echo taken; true")) == "taken"
    when = stamp()
    while taken("$(job.name)-$when")
        sleep(0.25)
        when = stamp()
    end
    base = "$(job.name)-$when"
    remote = joinpath(code, "jobs", base * ".sh")
    mktempdir() do dir
        write(joinpath(dir, base * ".sh"), generate(job; script = remote, successor))
        push_file(s, joinpath(dir, base * ".sh"), remote)
        # the spec as it was read: for a Julia spec what it evaluated to, and the file beside it
        write(joinpath(dir, base * ".toml"), spec_toml(spec))
        push_file(s, joinpath(dir, base * ".toml"), joinpath(code, "jobs", base * ".toml"))
        endswith(spec, ".jl") && push_file(s, spec, joinpath(code, "jobs", base * ".jl"))
    end
    runsite(s, "mkdir -p " * q(joinpath(scratch, "logs")))
    ids = String[]
    if s.slurm
        export_flag = s.export_env ? "" : "--export=NONE "
        for k in 1:chain
            after = k == 1 ? "" : "--dependency=afterany:$(ids[end]) "
            out = readsite(s, "sbatch --parsable $export_flag$after" * q(remote))
            id = String(first(split(strip(out), ';')))
            occursin(r"^\d+$", id) || fail("sbatch did not return a job ID: $(repr(out))")
            push!(ids, id)
        end
        runsite(s, "bash " * q(remote) * " --queued " * q(ids[1]) * " " * q(join(ids[2:end], ", ")))
    else
        push!(ids, "L" * when)
        runsite(s, "bash " * q(remote) * " --queued " * q(ids[1]))
        log = log_file(job, ids[1])
        # returns once the job has written its process ID, by which it is known to be running
        pidfile = joinpath(scratch, "logs", "$(job.name)-$(ids[1]).pid")
        runsite(s, "SIMLAUNCH_JOB_ID=$(q(ids[1])) nohup bash $(q(remote)) > $(q(log)) 2>&1 < /dev/null & " *
                   "for k in \$(seq 100); do [ -f $(q(pidfile)) ] && break; sleep 0.1; done")
    end
    describe(io, job)
    println(io, length(ids) == 1 ? "submitted as job $(ids[1])" : "submitted as a chain of jobs $(join(ids, ", "))",
            "; script $remote")
    println(io, "log: ", log_file(job, ids[1]))
    println(io, "watch with: simwatch ", islocal(s) ? scratch : "$(s.host):$scratch")
    return ids[1]
end
