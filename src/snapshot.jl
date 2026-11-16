# Source snapshots: a copy of a project and every package it takes by path,
# written once and never changed.

const DEFAULT_EXCLUDES = [".git", "Manifest*.toml", "*~", ".#*", "#*#", ".DS_Store",
                          "out/", "*.jls", ".claude/data/", ".claude/worktrees/"]

"The Julia files of `templates/` that every study carries in its `tools/`."
const TOOLS = ["check_precompiled.jl", "make_env.jl", "set_mpi.jl", "mpiexec.jl"]

struct SourcePackage
    name::String
    path::String                      # on the laptop
end

struct Pin
    name::String
    owner::String                     # the package whose Project.toml names it
    owner_dir::String
    rev::Union{String,Nothing}
end

function read_project(dir)
    file = joinpath(dir, "Project.toml")
    isfile(file) || fail("no Project.toml in $dir")
    return TOML.parsefile(file)
end

"""
The project and every package it takes by path, following the packages' own
path sources; and the packages pinned to a URL.
"""
function collect_packages(project_dir)
    packages = SourcePackage[]
    pins = Pin[]
    seen = Set{String}()
    todo = [(get(read_project(project_dir), "name", basename(project_dir)), project_dir)]
    while !isempty(todo)
        name, dir = popfirst!(todo)
        dir in seen && continue
        push!(seen, dir)
        push!(packages, SourcePackage(name, dir))
        for (dep, source) in get(read_project(dir), "sources", Dict{String,Any}())
            if haskey(source, "path")
                path = source["path"]
                isabspath(path) &&
                    fail("$name takes $dep by the absolute path $path, which would still point at this machine on a site; use a relative path")
                full = joinpath(dir, path)
                isdir(full) || fail("$name takes $dep from $full, which does not exist")
                push!(todo, (dep, realpath(full)))
            elseif haskey(source, "url")
                push!(pins, Pin(dep, name, dir, get(source, "rev", nothing)))
            end
        end
    end
    check_manifest_paths(project_dir, seen)
    return packages, pins
end

"""
A package developed with `Pkg.develop` is named by path in the manifest only.
Manifests are not copied, so a site could not find it: refuse.
"""
function check_manifest_paths(project_dir, known)
    for file in readdir(project_dir; join = true)
        occursin(r"^Manifest(-v[\d.]+)?\.toml$", basename(file)) || continue
        manifest = TOML.parsefile(file)
        for (dep, entries) in get(manifest, "deps", Dict{String,Any}())
            for entry in entries
                haskey(entry, "path") || continue
                full = joinpath(project_dir, entry["path"])
                isdir(full) && realpath(full) in known && continue
                fail("$(basename(file)) takes $dep from the path $(entry["path"]), but Project.toml has no [sources] entry for it. ",
                     "Manifests are not copied to a site; add `$dep = {path = \"$(entry["path"])\"}` to [sources].")
            end
        end
    end
    return
end

"The deepest directory that holds every package directory below it."
function common_root(dirs)
    parts = [splitpath(dirname(d)) for d in dirs]
    n = minimum(length, parts)
    k = 0
    while k < n && all(p -> p[k + 1] == parts[1][k + 1], parts)
        k += 1
    end
    return joinpath(parts[1][1:k]...)
end

function git(dir, args...)
    try
        return readchomp(pipeline(`git -C $dir $args`; stderr = devnull))
    catch
        return nothing
    end
end

"Where a tree came from: branch, commit, and whether it has uncommitted changes."
function provenance(dir)
    sha = git(dir, "rev-parse", "HEAD")
    sha === nothing && return (; git = false, branch = "", sha = "", dirty = false, status = "", diff = "")
    branch = something(git(dir, "rev-parse", "--abbrev-ref", "HEAD"), "")
    status = something(git(dir, "status", "--porcelain", "--", "."), "")
    diff = isempty(status) ? "" : something(git(dir, "diff", "HEAD", "--", "."), "")
    return (; git = true, branch, sha, dirty = !isempty(status), status, diff)
end

"Warn about pinned packages whose checkout beside their owner differs from the pin."
function warn_pins(pins)
    for pin in pins
        for candidate in (pin.name, pin.name * ".jl")
            dir = joinpath(dirname(pin.owner_dir), candidate)
            isdir(dir) || continue
            prov = provenance(dir)
            prov.git || continue
            pinned = pin.rev === nothing ? nothing : git(dir, "rev-parse", "--verify", "--quiet", pin.rev * "^{commit}")
            why = prov.dirty ? "has uncommitted changes" :
                  pin.rev === nothing ? nothing :
                  pinned === nothing ? "does not know the pinned revision $(pin.rev)" :
                  pinned != prov.sha ? "is at $(prov.sha[1:10]), not at the pinned $(pin.rev)" : nothing
            why === nothing ||
                @warn "$(pin.owner) pins $(pin.name) to a URL, and the checkout at $dir $why. The snapshot uses the pin, as CI does; the checkout is not copied."
            break
        end
    end
    return
end

"""
Copy a project and its path packages into `tmp/<prefix>/src`, keeping their
relative positions. Returns the project's path there, the packages' records
and the pins.
"""
function copy_packages(project, tmp, prefix)
    packages, pins = collect_packages(project)
    warn_pins(pins)
    # a package inside another one is copied with it
    packages = [p for p in packages
                if !any(o -> o.path != p.path && startswith(p.path, o.path * "/"), packages)]
    root = common_root([p.path for p in packages])
    records = Dict{String,Any}[]
    for p in packages
        rel = relpath(p.path, root)
        dest = joinpath(prefix, "src", rel)
        target = joinpath(tmp, dest)
        mkpath(target)
        excludes = ["--exclude=$e" for e in DEFAULT_EXCLUDES]
        ignore = joinpath(p.path, ".simlaunchignore")
        isfile(ignore) && push!(excludes, "--exclude-from=$ignore")
        run(`rsync -a $excludes $(p.path * "/") $(target * "/")`)
        prov = provenance(p.path)
        record = Dict{String,Any}("name" => p.name, "path" => p.path, "dest" => dest, "git" => prov.git)
        if prov.git
            record["branch"], record["sha"], record["dirty"] = prov.branch, prov.sha, prov.dirty
            if prov.dirty
                stem = joinpath("provenance", isempty(prefix) ? p.name : replace(prefix, "/" => "-") * "-" * p.name)
                write(joinpath(tmp, stem * ".status"), prov.status * "\n")
                write(joinpath(tmp, stem * ".diff"), prov.diff * "\n")
                record["diff"] = stem * ".diff"
            end
        end
        push!(records, record)
    end
    return relpath(project, root), records, pins
end

"""
    snapshot(project; study, variants = [])

Copy the project at `project` and its path packages into the cache as the
study `study`. `variants` are pairs `name => directory`: further versions of
the project, for comparisons inside one job. Returns the snapshot's
directory.
"""
function snapshot(project::AbstractString; study::AbstractString, variants = Pair{String,String}[])
    checkname("a study name", study)
    project = abspath(expanduser(project))
    isdir(project) || fail("no such directory: $project")
    project = realpath(project)
    dest = joinpath(cache_root(), study)
    ispath(dest) && fail("study $(repr(study)) exists already ($dest). A changed source makes a new study: choose another name, or remove the old one.")
    for (name, dir) in variants
        checkname("a variant's name", name)
        name == "default" && fail("\"default\" is the study's own version; choose another name for the variant")
        isdir(expanduser(dir)) || fail("variant $name: no such directory: $dir")
    end
    allunique(first.(variants)) || fail("two variants have the same name")

    tmp = dest * ".tmp"
    rm(tmp; recursive = true, force = true)
    mkpath(joinpath(tmp, "provenance"))
    try
        rel, records, pins = copy_packages(project, tmp, "")
        variant_records = Dict{String,Any}[]
        for (name, dir) in variants
            vrel, vrecords, _ = copy_packages(realpath(abspath(expanduser(dir))), tmp, joinpath("variants", name))
            vrel == rel ||
                fail("variant $name: its project is at $vrel beside its packages, the study's at $rel; a variant is another version of the same project")
            push!(variant_records, Dict{String,Any}("name" => name, "package" => vrecords))
        end
        tools = mkpath(joinpath(tmp, "tools"))
        for tool in TOOLS
            cp(joinpath(PKGROOT, "templates", tool), joinpath(tools, tool))
        end
        meta = Dict{String,Any}("study" => study,
                                "created" => Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"),
                                "simlaunch" => VERSION_STRING,
                                "project" => rel,
                                "pins" => [Dict{String,Any}("name" => pin.name, "owner" => pin.owner,
                                                            "rev" => something(pin.rev, ""))
                                           for pin in pins],
                                "package" => records,
                                "variant" => variant_records)
        open(joinpath(tmp, "snapshot.toml"), "w") do io
            TOML.print(io, meta; sorted = true)
        end
        mv(tmp, dest)
    catch
        rm(tmp; recursive = true, force = true)
        rethrow()
    end
    return dest
end

"The names of a study's variants, with \"default\" for its own version."
study_variants(snap) = ["default"; [v["name"] for v in get(snap, "variant", [])]]

"The directory on the laptop that the study's project was copied from."
function project_home(snap)
    for p in snap["package"]
        p["dest"] == joinpath("src", snap["project"]) && return p["path"]
    end
    fail("the snapshot of study $(snap["study"]) does not record where its project came from")
end

"The record of a study's snapshot."
function load_snapshot(study::AbstractString)
    checkname("a study name", study)
    file = joinpath(cache_root(), study, "snapshot.toml")
    isfile(file) || fail("no study $(repr(study)) in $(cache_root()); make it with `simlaunch snapshot <project> --study $study`")
    return TOML.parsefile(file)
end
