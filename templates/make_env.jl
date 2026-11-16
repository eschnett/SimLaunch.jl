# Part of a SimLaunch study. Run as
#     julia make_env.jl <project directory> <environment directory> [--test] <package>...
# Writes an environment that holds the project, everything the project
# depends on, and the named packages (CUDA, for example), then instantiates
# it. With --test it also holds the project's test dependencies, those of
# its test/Project.toml, so that a suite or a benchmark runs without Pkg.test. The project's own Project.toml is not changed: CI must not install a
# device package.

using Pkg
using TOML

project_dir, env_dir = abspath(ARGS[1]), abspath(ARGS[2])
with_test = "--test" in ARGS[3:end]
extra = filter(!=("--test"), ARGS[3:end])

deps = Dict{String,Any}()
sources = Dict{String,Any}()

# The path packages, followed through their own [sources]: a package found
# through the environment is not the active project, so its relative paths
# are written here as absolute ones.
function collect!(dir, seen = Set{String}(); file = joinpath(dir, "Project.toml"))
    file in seen && return
    push!(seen, file)
    project = TOML.parsefile(file)
    uuids = merge(get(project, "deps", Dict{String,Any}()), get(project, "weakdeps", Dict{String,Any}()),
                  get(project, "extras", Dict{String,Any}()))
    for (name, source) in get(project, "sources", Dict{String,Any}())
        haskey(uuids, name) || continue
        if haskey(source, "path")
            path = normpath(joinpath(dir, source["path"]))
            deps[name] = uuids[name]
            sources[name] = Dict{String,Any}("path" => path)
            collect!(path, seen)
        elseif !haskey(sources, name) && haskey(get(project, "deps", Dict{String,Any}()), name)
            deps[name] = uuids[name]
            sources[name] = source
        end
    end
    return
end

project = TOML.parsefile(joinpath(project_dir, "Project.toml"))
merge!(deps, get(project, "deps", Dict{String,Any}()))
collect!(project_dir)
if haskey(project, "name") && haskey(project, "uuid")
    deps[project["name"]] = project["uuid"]
    sources[project["name"]] = Dict{String,Any}("path" => project_dir)
end
if with_test
    test_dir = joinpath(project_dir, "test")
    test_file = joinpath(test_dir, "Project.toml")
    if isfile(test_file)
        merge!(deps, get(TOML.parsefile(test_file), "deps", Dict{String,Any}()))
        collect!(test_dir)
    else
        # the older form: [extras] and the test target of the project itself
        extras = get(project, "extras", Dict{String,Any}())
        for name in get(get(project, "targets", Dict{String,Any}()), "test", String[])
            haskey(extras, name) && (deps[name] = extras[name])
        end
    end
end
compat = filter(((name, _),) -> name == "julia" || haskey(deps, name), get(project, "compat", Dict{String,Any}()))

mkpath(env_dir)
open(joinpath(env_dir, "Project.toml"), "w") do io
    println(io, "# Written by SimLaunch: ", project_dir, " and ", isempty(extra) ? "nothing else" : join(extra, ", "), ".")
    TOML.print(io, Dict{String,Any}("deps" => deps, "sources" => sources, "compat" => compat); sorted = true)
end

Pkg.activate(env_dir)
isempty(extra) || Pkg.add(extra)
Pkg.instantiate()
println("environment ", env_dir, ": ", length(deps) + length(extra), " packages")
