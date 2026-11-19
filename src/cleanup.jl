# What there is and how old it is: `list`; and removing it: `delete`
# (PLAN.md, "Submit, status, fetch and restarts").

"An age such as `14d`, `12h` or `2w`."
function parse_age(text)
    m = match(r"^(\d+)([hdw])$", text)
    m === nothing && fail("an age is a number and h, d or w, such as 14d: $(repr(text))")
    n = parse(Int, m[1])
    return m[2] == "h" ? Hour(n) : m[2] == "d" ? Day(n) : Week(n)
end

"A time that a file gives, as UTC: SimWatch's `updated`, or a `date -u` line."
function utc_time(text)
    t = strip(strip(text), '"')
    length(t) >= 19 || return nothing
    return tryparse(DateTime, t[1:19])
end

"A snapshot's `created`, which is the laptop's local time, as UTC."
function created_utc(snap)
    t = tryparse(DateTime, get(snap, "created", ""))
    t === nothing && return nothing
    offset = round(now() - now(UTC), Minute)
    return t - offset
end

"""
The project of a snapshot as a name: the repository's, also for a worktree
of it under `.claude/worktrees/`, with the commit when it was in git.
"""
function project_label(snap)
    rel = joinpath("src", get(snap, "project", "?"))
    for p in get(snap, "package", [])
        # the package that holds the project: the project itself, or a package it is a subproject of
        rel == p["dest"] || startswith(rel, p["dest"] * "/") || continue
        path = p["path"] * rel[length(p["dest"])+1:end]
        m = match(r"^(.*)/\.claude/worktrees/[^/]+(/.*)?$", path)
        name = m === nothing ? basename(path) : basename(m[1]) * something(m[2], "")
        return get(p, "git", false) && haskey(p, "sha") ? string(name, "@", p["sha"][1:7]) : name
    end
    return chopprefix(rel, "src/")
end

"The sites that the studies on the laptop were prepared on, by the records `prepare` keeps."
function laptop_sites()
    root = joinpath(cache_root(), ".sites")
    isdir(root) || return String[]
    names = String[]
    for study in readdir(root), name in readdir(joinpath(root, study))
        isdir(joinpath(root, study, name)) && push!(names, name)
    end
    return sort!(unique!(names))
end

"The studies on the laptop: name => the record of its snapshot."
function laptop_studies()
    root = cache_root()
    isdir(root) || return Dict{String,Dict{String,Any}}()
    out = Dict{String,Dict{String,Any}}()
    for d in readdir(root)
        f = joinpath(root, d, "snapshot.toml")
        isfile(f) && (out[d] = try TOML.parsefile(f) catch; Dict{String,Any}("study" => d) end)
    end
    return out
end

"""
What a site holds of each study, in one call: the top of its snapshot, the
sizes in its code directory, its `prepared` files, its runs' SimWatch
status and recorded disk usage, and whether a local job of it is alive.
"""
function site_holdings(s::Site)
    script = """
        if cd $(q(s.code)) 2>/dev/null; then
            for d in */; do st=\${d%/}; [ -f "\$st/snapshot.toml" ] || continue
                echo "### top \$st"; awk '/^\\[/ { exit } { print }' "\$st/snapshot.toml"
                echo "### sizes \$st"; du -sk "\$st"/* 2>/dev/null
                echo "### prepared \$st"
                for f in "\$st"/prepared "\$st"/depot-*/prepared; do [ -f "\$f" ] && date -u -r "\$f" +%Y-%m-%dT%H:%M:%SZ; done
            done
        fi
        if cd $(q(s.scratch)) 2>/dev/null; then
            for d in */; do st=\${d%/}
                echo "### scratch \$st"
                for r in "\$st"/*/; do r=\${r%/}; [ -f "\$r/simwatch.toml" ] || continue
                    echo "### run \$r"; awk '/^\\[/ { exit } /^(status|updated) = / { print }' "\$r/simwatch.toml"
                    if [ -f "\$r/diskusage.toml" ]; then echo "### usage \$r"; cat "\$r/diskusage.toml"; fi
                done
                for f in "\$st"/logs/*.pid; do
                    if [ -f "\$f" ] && kill -0 "\$(cat "\$f")" 2>/dev/null; then echo "### live \$st"; fi
                done
            done
        fi
        $(s.slurm ? "echo '### queue'; squeue -h -u \"\$(id -un)\" -o '%j' 2>/dev/null" : "")
        true
        """
    holdings = Dict{String,Dict{Symbol,Any}}()
    hold(st) = get!(() -> Dict{Symbol,Any}(:top => Dict{String,Any}(), :sizes => Pair{String,Int}[],
                                           :prepared => DateTime[], :runs => Dict{String,Any}[], :live => 0,
                                           :code => false, :scratch => false), holdings, st)
    queue = String[]
    for (head, body) in sections(readsite(s, script))
        kind, what = (split(head, ' '; limit = 2)..., "")[1:2]
        if kind == "queue"
            append!(queue, split(body, '\n'; keepempty = false))
            continue
        end
        st = String(first(split(what, '/')))
        h = hold(st)
        if kind == "top"
            h[:code] = true
            h[:top] = try TOML.parse(body) catch; Dict{String,Any}() end
        elseif kind == "sizes"
            for l in split(body, '\n'; keepempty = false)
                kb, path = split(l, '\t'; limit = 2)
                push!(h[:sizes], basename(path) => parse(Int, kb))
            end
        elseif kind == "prepared"
            append!(h[:prepared], filter(!isnothing, utc_time.(split(body, '\n'; keepempty = false))))
        elseif kind == "scratch"
            h[:scratch] = true
        elseif kind == "run"
            t = try TOML.parse(replace(body, r"^updated = (\d.*)$"m => s"updated = \"\1\"")) catch; Dict{String,Any}() end
            push!(h[:runs], Dict{String,Any}("run" => what, "status" => get(t, "status", "?"),
                                             "updated" => utc_time(string(get(t, "updated", "")))))
        elseif kind == "usage"
            isempty(h[:runs]) || (h[:runs][end]["usage"] = usage_entries(body))
        elseif kind == "live"
            h[:live] += 1
        end
    end
    # a job belongs to the study whose name, with a dash, is the longest start of the job's name
    for job in queue
        owners = [st for st in keys(holdings) if startswith(job, st * "-")]
        isempty(owners) || (holdings[argmax(length, owners)][:live] += 1)
    end
    return holdings
end

"The sites to look at: those named, or every site a study on the laptop was prepared on, each place once."
function inventory_sites(names)
    sites = Site[]
    for name in (isempty(names) ? laptop_sites() : names)
        s = try load_site(name) catch e; e isa UserError || rethrow(); isempty(names) ? continue : rethrow() end
        any(o -> o.host == s.host && o.code == s.code && o.scratch == s.scratch, sites) || push!(sites, s)
    end
    return sites
end

"""
    inventory(; sites = []) -> rows

One row per study and site, and one per study that is only on the laptop:
what `list` shows and `delete --older-than` chooses from. A site that cannot
be reached is a row with `error` set.
"""
function inventory(; sites = String[])
    laptop = laptop_studies()
    rows = NamedTuple[]
    seen = Set{String}()
    for s in inventory_sites(sites)
        holdings = try
            check_connection(s)
            site_holdings(s)
        catch e
            e isa UserError || rethrow()
            push!(rows, inventory_row("", s.name, Dict{String,Any}(), nothing; error = e.msg))
            continue
        end
        for (st, h) in holdings
            push!(seen, st)
            push!(rows, inventory_row(st, s.name, get(laptop, st, h[:top]), h))
        end
    end
    for (st, snap) in laptop
        st in seen || !isempty(sites) || push!(rows, inventory_row(st, "", snap, nothing))
    end
    return sort!(rows; by = r -> (r.live > 0, something(r.last, DateTime(0)), r.study, r.site))
end

function inventory_row(study, site, snap, h; error = "")
    created = created_utc(snap)
    times = DateTime[t for t in [created] if t !== nothing]
    counts = Dict{String,Int}()
    caches = ck = out = 0
    unmeasured = 0
    live = 0
    if h !== nothing
        append!(times, h[:prepared])
        for r in h[:runs]
            counts[r["status"]] = get(counts, r["status"], 0) + 1
            r["updated"] === nothing || push!(times, r["updated"])
            haskey(r, "usage") || (unmeasured += 1)       # a run from before jobs recorded their size
            for e in get(r, "usage", [])
                e.kb === nothing ? (unmeasured += 1) : (out += e.kb - something(e.ck, 0))
                ck += something(e.ck, 0)
            end
        end
        for (name, kb) in h[:sizes]
            (name == "depot" || startswith(name, "depot-")) && (caches += kb)    # `depot`: one for all, until 2026-11-17
        end
        live = h[:live]
    end
    return (; study, site, project = isempty(snap) ? "?" : project_label(snap), created,
            last = isempty(times) ? nothing : maximum(times), live, counts,
            caches, ck, out, unmeasured, onsite = h !== nothing && (h[:code] || h[:scratch]),
            note = get(snap, "note", ""), session = get(snap, "session", ""), error)
end

function age_string(t)
    t === nothing && return "?"
    m = Dates.value(round(now(UTC) - t, Minute))
    return m < 60 ? "$(m)m" : m < 48 * 60 ? "$(m ÷ 60)h" : "$(m ÷ (24 * 60))d"
end

function runs_string(counts)
    isempty(counts) && return "-"
    order = ["running", "queued", "stopped", "finished", "failed", "cancelled", "lost"]
    keys_ = sort!(collect(keys(counts)); by = k -> something(findfirst(==(k), order), length(order) + 1))
    return join(("$(counts[k]) $k" for k in keys_), ", ")
end

"""
    list(; sites = [], older_than = nothing)

Print one table of every study, oldest activity first: on each site, and
on the laptop alone. Returns the rows.
"""
function list(; sites = String[], older_than = nothing, io::IO = stdout)
    rows = inventory(; sites)
    if older_than !== nothing
        cutoff = now(UTC) - parse_age(older_than)
        filter!(r -> !isempty(r.error) || r.live == 0 && r.last !== nothing && r.last < cutoff, rows)
    end
    errors = filter(r -> !isempty(r.error), rows)
    table = filter(r -> isempty(r.error), rows)
    if isempty(table)
        println(io, "no studies")
    else
        cells = map(table) do r
            [r.study, isempty(r.site) ? "laptop" : r.site, r.project,
             r.created === nothing ? "?" : Dates.format(r.created + round(now() - now(UTC), Minute), "yyyy-mm-dd"),
             r.live > 0 ? "live, $(r.live) job$(r.live == 1 ? "" : "s")" : age_string(r.last),
             runs_string(r.counts),
             isempty(r.site) ? "" : kb_string(r.caches), isempty(r.site) ? "" : kb_string(r.ck),
             isempty(r.site) ? "" : kb_string(r.out) * (r.unmeasured > 0 ? "+" : ""),
             first(r.session, 8), r.note]
        end
        head = ["study", "site", "project", "created", "last", "runs", "caches", "checkpoints", "output", "session", "note"]
        widths = [maximum(length, [head[i]; [c[i] for c in cells]]) for i in eachindex(head)]
        line(c) = rstrip(join((i in (7, 8, 9) ? lpad(c[i], widths[i]) : rpad(c[i], widths[i]) for i in eachindex(c)), "  "))
        println(io, line(head))
        foreach(c -> println(io, line(c)), cells)
        any(r -> r.unmeasured > 0, table) && println(io, "output+: some jobs are running or were not measured (`usage --measure`)")
    end
    for r in errors
        println(io, "$(r.site): not looked at: $(r.error)")
    end
    return rows
end

const DELETE_LEVELS = (:all, :caches, :old_checkpoints, :checkpoints, :large)

"""
Bash text: each checkpoint directory of the study's runs, as `<path>\\t<KiB>`.
With `keep_newest`, not each run's newest, and not a mutable run's one.
"""
function checkpoint_listing(s::Site, study, keep_newest)
    newest = keep_newest ? "for j in \"\$d\"/[0-9][0-9][0-9]-*; do [ -d \"\$j/ck\" ] && last=\$j; done; " : ""
    return "cd $(q(study_scratch(s, study))) 2>/dev/null || exit 0; for d in */; do d=\${d%/}; last=; $newest" *
           "for j in \"\$d\"/[0-9][0-9][0-9]-*$(keep_newest ? "" : " \"\$d\"/mutable"); do if [ -d \"\$j/ck\" ] && [ \"\$j\" != \"\$last\" ]; then " *
           "printf '%s\\t%s\\n' \"\$j\" \"\$(du -sk \"\$j/ck\" | cut -f1)\"; fi; done; done; true"
end

"Bash text that deletes a file or directory below `dir`, restoring write permission only for the deletion."
function delete_below(path; recursive = false)
    parent = dirname(path)
    return "p=$(q(parent)); w=1; [ -w \"\$p\" ] || { w=0; chmod u+w \"\$p\"; }; " *
           (recursive ? "chmod -R u+w $(q(path)) && rm -rf $(q(path))" : "rm -f $(q(path))") *
           "; [ \$w = 1 ] || chmod a-w \"\$p\""
end

"Bash text that records in a run's `diskusage.toml` what was deleted from one of its job directories."
record_deleted(run, dir, key, kb) =
    "printf '[[deleted]]\\ndir = \"%s\"\\n$key = %s\\n\\n' $(q(dir)) $kb >> $(q(run))/diskusage.toml"

"""
What `delete` would do on one site for one study: a list of items, each
with what it is, its size in KiB and the bash text that deletes it there.
"""
function delete_items(s::Site, study, level; runs = String[], max_size = "100M")
    code, scratch = study_code(s, study), study_scratch(s, study)
    items = NamedTuple[]
    if level === :all
        sizes = split(readsite(s, "for d in $(q(code)) $(q(scratch)); do if [ -d \"\$d\" ]; then du -sk \"\$d\" | cut -f1; else echo -; fi; done"))
        for (dir, what, kb) in ((code, "sources, environments and compiled caches", sizes[1]),
                                (scratch, "output of every run, with its checkpoints", sizes[2]))
            kb == "-" && continue
            push!(items, (; what = "$what  $dir", kb = parse(Int, kb), script = "chmod -R u+w $(q(dir)) && rm -rf $(q(dir))"))
        end
        return items
    end
    if level === :caches
        text = readsite(s, "cd $(q(code)) 2>/dev/null || exit 0; for d in depot depot-*; do [ -d \"\$d\" ] && du -sk \"\$d\"; done; true")
        for l in split(text, '\n'; keepempty = false)
            kb, name = split(l, '\t'; limit = 2)
            dir = joinpath(code, name)
            push!(items, (; what = "compiled caches  $dir", kb = parse(Int, kb), script = "chmod -R u+w $(q(dir)) && rm -rf $(q(dir))"))
        end
        return items
    end
    chosen = nothing
    if !isempty(runs)
        chosen, missing = chosen_runs(s, study, runs)
        isempty(missing) || fail("study $study has no run $(join(repr.(missing), " or ")) on $(s.name): ",
                                 "a run is named `<spec>-<label>`, or by its label")
    end
    if level in (:old_checkpoints, :checkpoints)
        text = readsite(s, checkpoint_listing(s, study, level === :old_checkpoints))
        for l in split(text, '\n'; keepempty = false)
            path, kb = split(l, '\t')
            run, dir = split(path, '/')
            chosen === nothing || run in chosen || continue
            full = joinpath(scratch, path, "ck")
            push!(items, (; what = "checkpoints  $(path)/ck", kb = parse(Int, kb),
                          script = "cd $(q(scratch)) && " * delete_below(full; recursive = true) * " && " *
                                   record_deleted(run, dir, "checkpoints_kb", kb)))
        end
        return items
    end
    # :large: the files that `fetch` leaves on the site, other than checkpoints
    m = match(r"^(\d+)([KMG]?)$", max_size)
    m === nothing && fail("--max-size is a number and K, M or G: $(repr(max_size))")
    limit = parse(Int, m[1]) * (m[2] == "G" ? 1024^2 : m[2] == "M" ? 1024 : 1)
    text = readsite(s, "cd $(q(scratch)) 2>/dev/null || exit 0; find . -type f -size +$(limit)k ! -path '*/ck/*' -exec du -k {} + ; true")
    for l in split(text, '\n'; keepempty = false)
        kb, path = split(l, '\t'; limit = 2)
        path = chopprefix(path, "./")
        parts = split(path, '/')
        chosen === nothing || parts[1] in chosen || continue
        full = joinpath(scratch, path)
        record = length(parts) >= 3 && occursin(r"^(\d{3}-|mutable$)", parts[2]) ?
                 " && cd $(q(scratch)) && " * record_deleted(parts[1], parts[2], "kb", kb) : ""
        push!(items, (; what = "file  $path", kb = parse(Int, kb), script = delete_below(full) * record))
    end
    return items
end

"""
    delete(studies; sites = [], level = :all, runs = [], max_size = "100M", older_than = nothing, yes = false)

List what would be deleted of the studies, site by site, and delete it after
one confirmation. `level` is `:all` (the whole study), `:caches` (the
compiled caches), `:old_checkpoints` (each run's but its newest),
`:checkpoints` (every checkpoint) or `:large` (files above `max_size`
outside the checkpoints). Without `sites`, every site the study is on, and
for `:all` the snapshot on the laptop too. `older_than`, such as `"30d"`,
takes the studies that `list` shows as older, in place of names. Refuses on a
site where a job of the study is queued or running. Returns whether it
deleted.
"""
function delete(studies = String[]; sites = String[], level::Symbol = :all, runs = String[], max_size = "100M",
                older_than = nothing, yes::Bool = false, io::IO = stdout, input::IO = stdin)
    level in DELETE_LEVELS || fail("unknown level $level")
    isempty(runs) || level in (:old_checkpoints, :checkpoints, :large) ||
        fail("--run chooses runs for --old-checkpoints, --checkpoints and --large only")
    isempty(studies) != (older_than === nothing) || fail("give studies, or --older-than, not both and not neither")
    foreach(st -> checkname("a study name", st), studies)
    rows = inventory(; sites)
    for r in rows
        isempty(r.error) || fail("site $(r.site) cannot be reached, so nothing is deleted: $(r.error)")
    end
    if older_than !== nothing
        cutoff = now(UTC) - parse_age(older_than)
        studies = unique(r.study for r in rows if r.live == 0 && r.last !== nothing && r.last < cutoff)
        isempty(studies) && (println(io, "no study is older than $older_than"); return false)
    end
    laptop = laptop_studies()
    for st in studies
        any(r -> r.study == st && r.onsite, rows) || isempty(sites) && haskey(laptop, st) ||
            fail("no study $(repr(st)) on ", isempty(sites) ? "any site or the laptop" : join(sites, " or "))
    end
    live = [r for r in rows if r.study in studies && r.live > 0]
    isempty(live) || fail("jobs are queued or running for ", join(("$(r.study) on $(r.site)" for r in live), ", "),
                          "; nothing is deleted")

    plan = Tuple{String,Site,Vector{NamedTuple}}[]     # study, site, items
    for st in studies, r in rows
        r.study == st && r.onsite || continue
        s = load_site(r.site)
        items = delete_items(s, st, level; runs, max_size)
        isempty(items) || push!(plan, (st, s, items))
    end
    whole = level === :all && isempty(sites)
    snapshots = whole ? [st for st in studies if haskey(laptop, st)] : String[]
    if isempty(plan) && isempty(snapshots)
        println(io, "nothing to delete")
        return false
    end
    total = 0
    for (st, s, items) in plan
        println(io, "study $st on $(s.name):")
        w = maximum(i -> length(i.what), items)
        for i in items
            println(io, "  ", rpad(i.what, w), "  ", lpad(kb_string(i.kb), 10))
            total += i.kb
        end
    end
    for st in snapshots
        println(io, "study $st on the laptop: its snapshot  ", joinpath(cache_root(), st))
    end
    println(io, "total ", kb_string(total))
    level === :large && println(io, "`fetch` does not copy files above $max_size: unless they are kept elsewhere, they are lost")
    level === :caches && println(io, "`prepare` compiles them again before another job of these studies")
    confirm("delete all this? It cannot be restored."; yes, io, input) || (println(io, "nothing deleted"); return false)
    for (st, s, items) in plan
        for i in items
            runsite(s, i.script)
        end
        level === :all && rm(joinpath(manifest_store(st), s.name); recursive = true, force = true)
        println(io, "deleted ", level === :all ? "study $st" : "$(length(items)) item$(length(items) == 1 ? "" : "s") of study $st",
                " on $(s.name)")
    end
    for st in snapshots
        rm(joinpath(cache_root(), st); recursive = true)
        rm(manifest_store(st); recursive = true, force = true)
        println(io, "deleted the snapshot of study $st")
    end
    return true
end
