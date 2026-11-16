# Source snapshots: a copy of a project and every package it takes by path,
# written once and never changed.

const DEFAULT_EXCLUDES = [".git", "Manifest*.toml", "*~", ".#*", "#*#", ".DS_Store",
                          "out/", "*.jls", ".claude/data/"]

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
    snapshot(project; study)

Copy the project at `project` and its path packages into the cache as the
study `study`. Returns the snapshot's directory.
"""
function snapshot(project::AbstractString; study::AbstractString)
    checkname("a study name", study)
    project = abspath(expanduser(project))
    isdir(project) || fail("no such directory: $project")
    project = realpath(project)
    dest = joinpath(cache_root(), study)
    ispath(dest) && fail("study $(repr(study)) exists already ($dest). A changed source makes a new study: choose another name, or remove the old one.")

    packages, pins = collect_packages(project)
    warn_pins(pins)
    # a package inside another one is copied with it
    packages = [p for p in packages
                if !any(o -> o.path != p.path && startswith(p.path, o.path * "/"), packages)]
    root = common_root([p.path for p in packages])

    tmp = dest * ".tmp"
    rm(tmp; recursive = true, force = true)
    mkpath(joinpath(tmp, "provenance"))
    try
        records = Dict{String,Any}[]
        for p in packages
            rel = relpath(p.path, root)
            target = joinpath(tmp, "src", rel)
            mkpath(target)
            excludes = ["--exclude=$e" for e in DEFAULT_EXCLUDES]
            ignore = joinpath(p.path, ".simlaunchignore")
            isfile(ignore) && push!(excludes, "--exclude-from=$ignore")
            run(`rsync -a $excludes $(p.path * "/") $(target * "/")`)
            prov = provenance(p.path)
            record = Dict{String,Any}("name" => p.name, "path" => p.path, "dest" => joinpath("src", rel),
                                      "git" => prov.git)
            if prov.git
                record["branch"], record["sha"], record["dirty"] = prov.branch, prov.sha, prov.dirty
                if prov.dirty
                    write(joinpath(tmp, "provenance", p.name * ".status"), prov.status * "\n")
                    write(joinpath(tmp, "provenance", p.name * ".diff"), prov.diff * "\n")
                    record["diff"] = joinpath("provenance", p.name * ".diff")
                end
            end
            push!(records, record)
        end
        cp(joinpath(PKGROOT, "templates", "check_precompiled.jl"),
           joinpath(mkpath(joinpath(tmp, "tools")), "check_precompiled.jl"))
        meta = Dict{String,Any}("study" => study,
                                "created" => Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"),
                                "simlaunch" => VERSION_STRING,
                                "project" => relpath(project, root),
                                "pins" => [Dict{String,Any}("name" => pin.name, "owner" => pin.owner,
                                                            "rev" => something(pin.rev, ""))
                                           for pin in pins],
                                "package" => records)
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

"The record of a study's snapshot."
function load_snapshot(study::AbstractString)
    checkname("a study name", study)
    file = joinpath(cache_root(), study, "snapshot.toml")
    isfile(file) || fail("no study $(repr(study)) in $(cache_root()); make it with `simlaunch snapshot <project> --study $study`")
    return TOML.parsefile(file)
end
