# Part of a SimLaunch study. Run as
#     julia make_env.jl <project directory> <environment directory> [--test] <package>...
# Writes an environment that holds the project, everything the project
# depends on, and the named packages (CUDA, for example), then instantiates
# it. With --test it also holds the project's test dependencies, those of
# its test/Project.toml with their [compat] bounds, so that a suite or a
# benchmark runs without Pkg.test. The project's own Project.toml is not
# changed: CI must not install a device package.

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
test_compat = Dict{String,Any}()
if with_test
    test_dir = joinpath(project_dir, "test")
    test_file = joinpath(test_dir, "Project.toml")
    if isfile(test_file)
        test_project = TOML.parsefile(test_file)
        merge!(deps, get(test_project, "deps", Dict{String,Any}()))
        test_compat = get(test_project, "compat", Dict{String,Any}())
        collect!(test_dir)
    else
        # the older form: [extras] and the test target of the project itself
        extras = get(project, "extras", Dict{String,Any}())
        for name in get(get(project, "targets", Dict{String,Any}()), "test", String[])
            haskey(extras, name) && (deps[name] = extras[name])
        end
    end
end
bounded(table) = filter(((name, _),) -> name == "julia" || haskey(deps, name), table)
compat = bounded(get(project, "compat", Dict{String,Any}()))
# The test project's bounds hold too, as under Pkg.test. Where both name a
# package, the environment takes the test project's bound, and the project,
# a path package here, brings its own: the resolver honours both. A project
# that is not a package has nothing that brings its bound.
is_package = haskey(project, "name") && haskey(project, "uuid")
for (name, bound) in bounded(test_compat)
    is_package || get(compat, name, bound) == bound ||
        error("$name has the bound $(repr(compat[name])) in $project_dir/Project.toml and $(repr(bound)) in test/Project.toml; " *
              "a project that is not a package can have only one")
    compat[name] = bound
end

mkpath(env_dir)
open(joinpath(env_dir, "Project.toml"), "w") do io
    println(io, "# Written by SimLaunch: ", project_dir, " and ", isempty(extra) ? "nothing else" : join(extra, ", "), ".")
    TOML.print(io, Dict{String,Any}("deps" => deps, "sources" => sources, "compat" => compat); sorted = true)
end

Pkg.activate(env_dir)
isempty(extra) || Pkg.add(extra)
Pkg.instantiate()
println("environment ", env_dir, ": ", length(deps) + length(extra), " packages")
