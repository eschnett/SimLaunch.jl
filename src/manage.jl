# What happens after a job is submitted: status, fetch, usage, clean, combine.

"The sites a study has been prepared on, by the copies of their manifests on the laptop."
function study_sites(study; site = nothing)
    load_snapshot(study)
    site === nothing || return [load_site(site)]
    dir = manifest_store(study)
    names = isdir(dir) ? filter(n -> isfile(joinpath(sites_dir(), n * ".toml")), readdir(dir)) : String[]
    isempty(names) && fail("study $study is not prepared on any site; give --site")
    return load_site.(names)
end

"A site's answer as sections: the text after each line `### <name>`."
function sections(text)
    out = Pair{String,String}[]
    name, buf = nothing, IOBuffer()
    for line in eachline(IOBuffer(text))
        if startswith(line, "### ")
            name === nothing || push!(out, name => String(take!(buf)))
            name = line[5:end]
        elseif name !== nothing
            println(buf, line)
        end
    end
    name === nothing || push!(out, name => String(take!(buf)))
    return out
end

"The files `<run>/<file>` of a study on a site, by run."
function run_files(site::Site, study, file)
    scratch = study_scratch(site, study)
    text = readsite(site, "cd $(q(scratch)) 2>/dev/null || exit 0; for d in */; do d=\${d%/}; " *
                          "[ -f \"\$d/$file\" ] || continue; echo \"### \$d\"; cat \"\$d/$file\"; done; true")
    return sections(text)
end

kb_string(kb) = kb >= 1024^2 ? string(round(kb / 1024^2; digits = 1), " GiB") :
                kb >= 1024 ? string(round(kb / 1024; digits = 1), " MiB") : "$kb KiB"

"""
    status(studies; site = nothing)

One table of the studies' runs on every site they are prepared on, from the
runs' SimWatch files. A run whose job the queue no longer knows is `lost`.
Returns the rows.
"""
function status(studies; site = nothing, io::IO = stdout)
    rows = NamedTuple[]
    for study in studies, s in study_sites(study; site)
        check_connection(s)
        known = Set(first.(queued_jobs(s)))
        for (run, text) in run_files(s, study, "simwatch.toml")
            t = try TOML.parse(text) catch; Dict{String,Any}("status" => "unreadable") end
            state = get(t, "status", "?")
            job = string(get(get(t, "slurm", Dict{String,Any}()), "job_id", ""))
            s.slurm && state in ("queued", "running") && !isempty(job) && job ∉ known && (state = "lost")
            push!(rows, (; study, site = s.name, run, status = state, job, updated = string(get(t, "updated", "")),
                         message = get(t, "message", "")))
        end
        println(io, "live: simwatch ", islocal(s) ? study_scratch(s, study) : "$(s.host):$(study_scratch(s, study))")
    end
    if isempty(rows)
        println(io, "no runs")
        return rows
    end
    width(col) = maximum(length(string(getfield(r, col))) for r in rows)
    for r in rows
        println(io, rpad(r.study, width(:study)), "  ", rpad(r.site, width(:site)), "  ", rpad(r.run, width(:run)), "  ",
                rpad(r.status, 8), "  ", rpad(r.job, width(:job)), "  ", r.message)
    end
    return rows
end

"""
    fetch(study; site = nothing, runs = [], with_checkpoints = false, max_size = "100M", to = nothing)

Copy the study's results from its sites to `.claude/data/<study>/<site>/` in
the project the study came from (or to `to`). Checkpoints and files above
`max_size` stay on the site. Returns the directories written.
"""
function fetch(study::AbstractString; site = nothing, runs = String[], with_checkpoints::Bool = false,
               max_size = "100M", to = nothing, io::IO = stdout)
    snap = load_snapshot(study)
    root = to === nothing ? joinpath(project_home(snap), ".claude", "data", study) : abspath(expanduser(to))
    to === nothing && !isdir(project_home(snap)) &&
        fail("the project of study $study was at $(project_home(snap)), which is gone; give --to <directory>")
    occursin(r"^\d+[KMG]?$", max_size) || fail("--max-size is a number and K, M or G: $(repr(max_size))")
    dests = String[]
    for s in study_sites(study; site)
        check_connection(s)
        scratch = study_scratch(s, study)
        dest = joinpath(root, s.name)
        mkpath(dest)
        # copies are for reading: files stay read-only, directories are writable so that a later fetch can add to them
        options = ["-a", "--chmod=Du+w", "--max-size=$max_size", "--exclude=*.tmp.*", "--exclude=.simlaunch-job*",
                   "--exclude=*.pid", "--exclude=*.next"]
        with_checkpoints || push!(options, "--exclude=ck/")
        sources = isempty(runs) ? [scratch * "/"] : [joinpath(scratch, checkname("a run's name", r)) for r in runs]
        for src in sources
            success(pipeline(`rsync $options $(rsync_target(s, src)) $(dest * "/")`; stdout = devnull, stderr)) ||
                fail("fetching $src from $(s.name) failed (rsync's message is above)")
        end
        # what the results were made from
        cp(joinpath(cache_root(), study, "snapshot.toml"), joinpath(dest, "snapshot.toml"); force = true)
        store = joinpath(manifest_store(study), s.name)
        if isdir(store)
            for f in readdir(store)
                cp(joinpath(store, f), joinpath(mkpath(joinpath(dest, "manifests")), f); force = true)
            end
        end
        println(io, "$(s.name): fetched into $dest",
                with_checkpoints ? "" : " (checkpoints and files above $max_size stay on the site)")
        push!(dests, dest)
    end
    return dests
end

"What the jobs of one run hold: the entries of its `diskusage.toml`."
function usage_entries(text)
    t = try TOML.parse(text) catch; Dict{String,Any}() end
    deleted = Dict{String,Int}()
    for d in get(t, "deleted", [])
        deleted[d["dir"]] = get(deleted, d["dir"], 0) + d["checkpoints_kb"]
    end
    entries = NamedTuple[]
    for j in get(t, "job", [])
        kb, ck = j["kb"], j["checkpoints_kb"]
        gone = get(deleted, j["dir"], 0)
        push!(entries, (; dir = j["dir"], kb = kb isa Integer ? kb - gone : nothing,
                        ck = ck isa Integer ? ck - gone : nothing))
    end
    return entries
end

"""
    usage(study; site = nothing, measure = false)

What the study's runs hold on disk, from the numbers each job recorded when
it ended. Reads only those small files; `measure` walks the directories of
the jobs that have no number, which is slow. Returns the rows.
"""
function usage(study::AbstractString; site = nothing, measure::Bool = false, io::IO = stdout)
    rows = NamedTuple[]
    for s in study_sites(study; site)
        check_connection(s)
        scratch = study_scratch(s, study)
        recorded = Dict(run => usage_entries(text) for (run, text) in run_files(s, study, "diskusage.toml"))
        listing = readsite(s, "cd $(q(scratch)) 2>/dev/null || exit 0; for d in */; do d=\${d%/}; " *
                              "for j in \"\$d\"/[0-9][0-9][0-9]-* \"\$d\"/mutable; do [ -d \"\$j\" ] && echo \"\$j\"; done; done; true")
        for path in split(listing, '\n'; keepempty = false)
            run, dir = split(path, '/')
            e = findfirst(x -> x.dir == dir, get(recorded, run, NamedTuple[]))
            kb, ck = e === nothing ? (nothing, nothing) : (recorded[run][e].kb, recorded[run][e].ck)
            if kb === nothing && measure
                out = split(readsite(s, "cd $(q(scratch)) && du -sk $(q(path)) | cut -f1; " *
                                        "if [ -d $(q(path))/ck ]; then du -sk $(q(path))/ck | cut -f1; else echo 0; fi"))
                kb, ck = parse(Int, out[1]), parse(Int, out[2])
            end
            push!(rows, (; site = s.name, run = String(run), dir = String(dir), kb, ck))
        end
    end
    if isempty(rows)
        println(io, "no jobs")
        return rows
    end
    wrun, wdir = maximum(length(r.run) for r in rows), maximum(length(r.dir) for r in rows)
    show(kb) = kb === nothing ? "not measured" : kb_string(kb)
    for s in unique(r.site for r in rows)
        mine = filter(r -> r.site == s, rows)
        println(io, s, ":")
        for r in mine
            println(io, "  ", rpad(r.run, wrun), "  ", rpad(r.dir, wdir), "  ", lpad(show(r.kb), 12),
                    r.ck === nothing || r.ck == 0 ? "" : "   checkpoints $(show(r.ck))")
        end
        known = [r.kb for r in mine if r.kb !== nothing]
        unknown = count(r -> r.kb === nothing, mine)
        println(io, "  total ", kb_string(sum(known; init = 0)),
                unknown == 0 ? "" : ", without $unknown job$(unknown == 1 ? "" : "s") still running or not measured (`--measure` walks them)")
    end
    return rows
end

"Ask for a yes; `yes = true` answers it."
function confirm(question; yes::Bool, io::IO, input::IO)
    yes && return true
    print(io, question, " [y/N] ")
    return lowercase(strip(readline(input))) in ("y", "yes")
end

"""
    clean(study; site, old_checkpoints = false, runs = [], yes = false)

List what the study holds on the site, and delete it after confirmation: the
whole study there, or with `old_checkpoints` the checkpoints of every job but
each run's newest. Nothing is deleted while a job of the study is queued or
running. Needs no snapshot on the laptop, only the study on the site. Returns
whether it deleted.
"""
function clean(study::AbstractString; site::AbstractString, old_checkpoints::Bool = false, runs = String[],
               yes::Bool = false, io::IO = stdout, input::IO = stdin)
    s = load_site(site)
    checkname("a study name", study)     # the snapshot on the laptop is not needed, and may be gone
    check_connection(s)
    code, scratch = study_code(s, study), study_scratch(s, study)
    there = readsite(s, "for d in $(q(code)) $(q(scratch)); do [ -d \"\$d\" ] && echo \"\$d\"; done; true")
    isempty(strip(there)) && fail("no study $(repr(study)) on $(s.name): neither $code nor $scratch exists")
    names = [name for (_, name) in queued_jobs(s) if startswith(name, "$study-")]
    isempty(names) || fail("jobs of study $study are queued or running on $(s.name) ($(join(unique(names), ", "))); nothing is deleted")
    if !s.slurm
        alive = readsite(s, "for f in $(q(scratch))/logs/*.pid; do [ -f \"\$f\" ] && kill -0 \"\$(cat \"\$f\")\" 2>/dev/null && echo \"\$f\"; done; true")
        isempty(strip(alive)) || fail("jobs of study $study are running on $(s.name); nothing is deleted")
    end

    if old_checkpoints
        # per run: the ck/ of every job directory but the newest that has one
        text = readsite(s, "cd $(q(scratch)) 2>/dev/null || exit 0; for d in */; do d=\${d%/}; last=; " *
                           "for j in \"\$d\"/[0-9][0-9][0-9]-*; do [ -d \"\$j/ck\" ] && last=\$j; done; " *
                           "for j in \"\$d\"/[0-9][0-9][0-9]-*; do if [ -d \"\$j/ck\" ] && [ \"\$j\" != \"\$last\" ]; then " *
                           "printf '%s\\t%s\\n' \"\$j\" \"\$(du -sk \"\$j/ck\" | cut -f1)\"; fi; done; done; true")
        found = [(String(a), parse(Int, b)) for (a, b) in (split(l, '\t') for l in split(text, '\n'; keepempty = false))]
        isempty(runs) || filter!(f -> first(split(f[1], '/')) in runs, found)
        if isempty(found)
            println(io, "no old checkpoints of study $study on $(s.name)")
            return false
        end
        println(io, "old checkpoints of study $study on $(s.name) (each run's newest stay):")
        for (path, kb) in found
            println(io, "  ", rpad(path * "/ck", 40), lpad(kb_string(kb), 12))
        end
        println(io, "  total ", kb_string(sum(last, found)))
        confirm("delete these checkpoints? They cannot be restored."; yes, io, input) || (println(io, "nothing deleted"); return false)
        for (path, kb) in found
            run, dir = split(path, '/')
            # the job's directory stays read-only; the deletion is recorded beside the sizes
            runsite(s, "cd $(q(scratch)) && chmod u+w $(q(path)) && chmod -R u+w $(q(path))/ck && rm -rf $(q(path))/ck && " *
                       "chmod a-w $(q(path)) && printf '[[deleted]]\\ndir = \"%s\"\\ncheckpoints_kb = %s\\n\\n' $(q(dir)) $kb >> $(q(run))/diskusage.toml")
        end
        println(io, "deleted $(length(found)) checkpoint directories")
        return true
    end

    sizes = split(readsite(s, "for d in $(q(code)) $(q(scratch)); do if [ -d \"\$d\" ]; then du -sk \"\$d\" | cut -f1; else echo 0; fi; done"))
    println(io, "study $study on $(s.name):")
    println(io, "  sources, environments and compiled caches  ", rpad(code, 50), lpad(kb_string(parse(Int, sizes[1])), 12))
    println(io, "  output of every run, with its checkpoints  ", rpad(scratch, 50), lpad(kb_string(parse(Int, sizes[2])), 12))
    confirm("delete both directories? They cannot be restored."; yes, io, input) || (println(io, "nothing deleted"); return false)
    for dir in (code, scratch)
        runsite(s, "if [ -d $(q(dir)) ]; then chmod -R u+w $(q(dir)) && rm -rf $(q(dir)); fi")
    end
    rm(joinpath(manifest_store(study), s.name); recursive = true, force = true)
    snapshot = joinpath(cache_root(), study)
    println(io, "deleted study $study on $(s.name)", isdir(snapshot) ? "; its snapshot on the laptop stays ($snapshot)" : "")
    return true
end

"""
    combine(study, spec; site, only_runs = [])

Run the spec's `[combine]` script for each run: it gets the run's job
directories, oldest first, as its last arguments and writes into a new
directory `combined-<n>/` of the run, which is then made read-only. Runs on
the site's login node, with a depot of its own in front of the study's, so
that the study's caches stay untouched. Returns the directories written.
"""
function combine(study::AbstractString, spec::AbstractString; site::AbstractString, only_runs = String[], io::IO = stdout)
    s = load_site(site)
    job = only(load_jobs(study, s, [spec]; only_runs))
    isempty(job.combine) && fail("$spec has no [combine] table")
    check_connection(s)
    code, scratch = study_code(s, study), study_scratch(s, study)
    written = String[]
    for r in job.runs
        run = "$(job.name)-$(r.label)"
        script = """
            set -eu
            cd $(q(joinpath(scratch, run)))
            dirs=()
            for d in [0-9][0-9][0-9]-*; do [ -d "\$d" ] && dirs+=("\$PWD/\$d"); done
            [ \${#dirs[@]} -gt 0 ] || { echo "run $run has no job directories" >&2; exit 1; }
            n=1; while [ -e "combined-\$n" ]; do n=\$((n + 1)); done
            mkdir "combined-\$n"; cd "combined-\$n"
            export JULIA_DEPOT_PATH=$(shpath(joinpath(scratch, "combine-depot"))):$(shpath(study_depot(s, study))):
            unset JULIA_LOAD_PATH JULIA_PROJECT JULIA_CPU_TARGET
            $(shpath(s.julia_bin)) --startup-file=no --project=$(shpath(joinpath(code, r.envdir))) $(shpath(joinpath(code, "src", job.project, job.combine[1]))) $(join(q.(job.combine[2:end]), " ")) "\${dirs[@]}" > combine.log 2>&1 || { cat combine.log >&2; exit 1; }
            cd ..; chmod -R a-w "combined-\$n"; echo "\$PWD/combined-\$n"
            """
        out = strip(readsite(s, script))
        println(io, "$run: combined into $out")
        push!(written, out)
    end
    return written
end

"""
    wait_spec(study, spec; site, only_runs = [], poll = 20) -> Bool

Wait until no job of the spec is queued or running on the site, printing each
run's status as it changes, and return whether every run has finished. This
covers a chain of jobs, also a successor that a stopped job submits itself.
It only watches: interrupted, it can be started again, and the jobs are not
affected. A run that is not finished gets the end of its output printed.
"""
function wait_spec(study::AbstractString, spec::AbstractString; site::AbstractString, only_runs = String[],
                   poll = 20, io::IO = stdout)
    s = load_site(site)
    job = only(load_jobs(study, s, [spec]; only_runs))
    check_connection(s)
    scratch = study_scratch(s, study)
    runs = ["$(job.name)-$(r.label)" for r in job.runs]
    function states()
        files = Dict(run_files(s, study, "simwatch.toml"))
        return map(runs) do run
            t = try TOML.parse(get(files, run, "")) catch; Dict{String,Any}() end
            (; run, status = get(t, "status", "not submitted"), message = get(t, "message", ""))
        end
    end
    seen = Dict{String,String}()
    report(now) = for st in now
        get(seen, st.run, "") == st.status && continue
        seen[st.run] = st.status
        println(io, rpad(st.run, maximum(length, runs)), "  ", rpad(st.status, 8), "  ", st.message)
    end
    while true
        active = active_jobs(s, study, job.name)
        report(states())
        isempty(active) && break
        sleep(poll)
    end
    final = states()
    report(final)
    all(st -> st.status == "not submitted", final) &&
        fail("no job of spec $(job.name) has been submitted on $(s.name); start it with `simlaunch submit`")
    ok = true
    for st in final
        st.status == "finished" && continue
        ok = false
        why = st.status in ("queued", "running") ? "its job has ended without saying so" :
              st.status == "stopped" ? "no job is left to continue it; `simlaunch resubmit` submits one" : st.message
        println(io, "\n$(st.run) has not finished ($(st.status)): $why")
        tail = readsite(s, "cd $(q(joinpath(scratch, st.run))) 2>/dev/null || exit 0; " *
                           "d=\$(ls -d [0-9][0-9][0-9]-* mutable 2>/dev/null | tail -n 1); " *
                           "if [ -s \"\$d/output.log\" ]; then echo \"--- the end of \$d/output.log ---\"; tail -n 20 \"\$d/output.log\"; " *
                           "else id=\$(cut -d' ' -f1 .simlaunch-job 2>/dev/null); echo \"--- the run wrote nothing; the start of its job's log ---\"; " *
                           "head -n 12 ../logs/$(job.name)-\$id.out 2>/dev/null; fi; true")
        print(io, tail)
    end
    println(io, ok ? "all $(length(runs)) run$(length(runs) == 1 ? " has" : "s have") finished" :
                     "not all runs have finished; job logs are in $(joinpath(scratch, "logs"))")
    return ok
end
