# Part of a SimLaunch study. Run as `julia [flags] --project=<project> check_precompiled.jl`:
# exits with 1 unless the project and its direct dependencies are precompiled
# for this Julia and these flags. A job runs it before its first run, since a
# stale cache on a read-only depot means a silent compile in every run.

using TOML

project = TOML.parsefile(Base.active_project())
names = collect(keys(get(project, "deps", Dict{String,Any}())))
haskey(project, "name") && haskey(project, "uuid") && push!(names, project["name"])

missing_packages = String[]
for name in sort!(names)
    pkg = Base.identify_package(name)
    if pkg === nothing
        push!(missing_packages, name * " (not installed)")
    elseif !Base.in_sysimage(pkg) && !Base.isprecompiled(pkg)
        push!(missing_packages, name)
    end
end

if isempty(missing_packages)
    println("precompiled: ", length(names), " packages of ", Base.active_project())
else
    println(stderr, "not precompiled for julia ", VERSION, " with these flags: ", join(missing_packages, ", "))
    println(stderr, "run `simlaunch prepare` for this study, site and spec")
    exit(1)
end
