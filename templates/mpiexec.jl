# Part of a SimLaunch study. Run as
#     julia --project=<environment> mpiexec.jl <arguments of mpiexec>...
# Starts the launcher of the MPI binary the environment is set up for
# (MPICH_jll's, or the site's), with the environment that binary needs.

using MPI

launcher = MPI.mpiexec()
process = run(ignorestatus(`$launcher $ARGS`))
exit(process.exitcode)
