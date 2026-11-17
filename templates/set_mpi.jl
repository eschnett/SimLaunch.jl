# Part of a SimLaunch study. Run as
#     julia --project=<environment> set_mpi.jl jll
#     julia --project=<environment> set_mpi.jl MPIABI_jll        (or another binary that MPIPreferences knows)
#     julia --project=<environment> set_mpi.jl system [<preferences as TOML>]
# Chooses the MPI binary of the environment (its LocalPreferences.toml) and
# installs what that choice needs. For the site's MPI, its modules must be
# loaded; the preferences are the keywords of MPIPreferences.use_system_binary.

using Pkg
using TOML
using MPIPreferences

if ARGS[1] == "jll"
    MPIPreferences.use_jll_binary(; export_prefs = false, force = true)
elseif endswith(ARGS[1], "_jll")
    MPIPreferences.use_jll_binary(ARGS[1]; export_prefs = false, force = true)
elseif ARGS[1] == "system"
    prefs = length(ARGS) > 1 ? TOML.parse(ARGS[2]) : Dict{String,Any}()
    MPIPreferences.use_system_binary(; export_prefs = false, force = true,
                                     (Symbol(k) => v for (k, v) in prefs)...)
else
    error("set_mpi.jl: the binary is \"jll\", a name that ends in \"_jll\", or \"system\", not ", repr(ARGS[1]))
end
Pkg.instantiate()
println("MPI of ", Base.active_project(), ": ", ARGS[1])
