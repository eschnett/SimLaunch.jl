# Site profiles, and running commands on a site.

struct Queue
    partition::String
    min_time::Union{Int,Nothing}      # seconds
    max_time::Union{Int,Nothing}      # seconds
    max_nodes::Union{Int,Nothing}
    max_gpus::Union{Int,Nothing}
    one_at_a_time::Bool               # a second job of the same user is refused
    preempt::Bool                     # its jobs can be stopped at any time: only for jobs with checkpoints
    prefer::Bool                      # a pre-emptible queue that a job with checkpoints takes first
    chain::Bool                       # false: not for a chain of jobs
end

"How MPI runs are set up and launched on a site."
struct MPIRecipe
    name::String
    binary::String                    # "jll": MPICH_jll; "system": the site's MPI
    launcher::String                  # "srun", or "mpiexec": the binary's own
    launcher_args::Vector{String}
    multi_node::Bool
    modules::Vector{String}
    julia_bin::Union{String,Nothing}  # a Julia that can load the site's MPI
    preferences::Dict{String,Any}     # for MPIPreferences.use_system_binary
    env::Dict{String,String}
end

"What a GPU job is given on a site, per GPU."
struct GPUs
    request::String                   # the batch option; %d is the number of GPUs
    cores::Int                        # per GPU
    request_cores::Bool               # false: the site hands them out with the GPU
    mem::Union{String,Nothing}        # per GPU, such as "64G"; nothing: not asked for
    max::Union{Int,Nothing}           # per job
    queues::Vector{Queue}             # in the order of preference
    precompile_on::Union{String,Nothing}   # where the site's GPU nodes differ from its CPU nodes
    cpu_target::Union{String,Nothing}      # JULIA_CPU_TARGET on the GPU nodes
end

struct Site
    name::String
    host::Union{String,Nothing}       # nothing: this machine
    via::Union{String,Nothing}        # a second login node, reached from `host`, where commands run
    check::Union{String,Nothing}      # command that tells whether the site is reachable
    hint::String
    code::String                      # root of the studies' sources
    scratch::String                   # root of the studies' output
    slurm::Bool
    account::Union{String,Nothing}
    export_env::Bool
    partition::Bool                   # false: the site's submit filter chooses the partition
    max_time::Union{Int,Nothing}      # seconds, for a site without partitions
    cores::Int                        # per CPU node; 0: the site has no CPU nodes
    numa::Int                         # NUMA domains per CPU node
    whole_node::Bool                  # a job gets whole nodes without asking for cores
    node_header::Vector{String}       # further batch options of a CPU job
    queues::Vector{Queue}             # in the order of preference
    gpu::Union{GPUs,Nothing}
    mpi::Dict{String,MPIRecipe}
    julia_bin::String
    depot::String                     # the site's own Julia depot: packages, artifacts, registries
    modules::Vector{String}
    precompile_on::String
    precompile_tasks::Union{Int,Nothing}
    cpu_target::Union{String,Nothing} # JULIA_CPU_TARGET: one cache for a site whose nodes are several CPU types
    precompile_time::Int              # seconds, for a precompile job on a compute node
    compute_internet::Bool
    registry_update::Bool
    env::Dict{String,String}          # exported in every job
end

islocal(site::Site) = site.host === nothing

const SITE_TABLES = ["name", "connect", "paths", "slurm", "julia", "env", "mpi"]

function load_site(name::AbstractString)
    checkname("a site name", name)
    file = joinpath(sites_dir(), name * ".toml")
    isfile(file) || fail("no profile for site $(repr(name)) ($file); known sites: ", join(known_sites(), ", "))
    conf = TOML.parsefile(file)
    for key in keys(conf)
        key in SITE_TABLES || fail("$file: unknown key $(repr(key))")
    end
    get(conf, "name", name) == name || fail("$file: its name is $(repr(conf["name"])), not $(repr(name))")

    connect = get(conf, "connect", nothing)
    host = connect === nothing ? nothing : connect["host"]
    paths = get(conf, "paths", nothing)
    paths === nothing && fail("$file: no [paths] table")
    code, scratch = paths["code"], paths["scratch"]
    if host === nothing
        code, scratch = abspath(expanduser(code)), abspath(expanduser(scratch))
    else
        isabspath(code) && isabspath(scratch) || fail("$file: the paths of a remote site must be absolute")
    end

    slurm = get(conf, "slurm", nothing)
    queues = Queue[]
    cores, numa, whole, header, gpu = Sys.CPU_THREADS, 1, false, String[], nothing
    if slurm !== nothing
        node = get(slurm, "node", nothing)
        g = get(slurm, "gpu", nothing)
        node === nothing && g === nothing && fail("$file: [slurm] needs a node table, a gpu table or both")
        cores = 0
        if node !== nothing
            cores, numa, whole = node["cores"], get(node, "numa", 1), get(node, "whole", false)
            header = collect(String, get(node, "header", String[]))
        end
        haskey(slurm, "default_queue") &&
            fail("$file: `default_queue` is gone; list the queues in the order of preference")
        queues = read_queues(get(slurm, "queues", []))
        if g !== nothing
            occursin("%d", g["request"]) || fail("$file: [slurm.gpu] request needs a %d for the number of GPUs")
            gpu = GPUs(g["request"], g["cores"], get(g, "request_cores", true), get(g, "mem", nothing),
                       get(g, "max", nothing), read_queues(get(g, "queues", [])), get(g, "precompile_on", nothing),
                       get(g, "cpu_target", nothing))
            haskey(g, "default_queue") &&
                fail("$file: `default_queue` is gone; list the queues in the order of preference")
        end
    end

    julia = get(conf, "julia", Dict{String,Any}())
    env = Dict{String,String}(k => string(v) for (k, v) in get(conf, "env", Dict{String,Any}()))
    return Site(name, host,
                connect === nothing ? nothing : get(connect, "via", nothing),
                connect === nothing ? nothing : get(connect, "check", nothing),
                connect === nothing ? "" : get(connect, "hint", ""),
                code, scratch,
                slurm !== nothing,
                slurm === nothing ? nothing : get(slurm, "account", nothing),
                slurm === nothing ? true : get(slurm, "export_env", true),
                slurm === nothing ? false : get(slurm, "partition", true),
                slurm !== nothing && haskey(slurm, "max_time") ? parse_time(slurm["max_time"]) : nothing,
                cores, numa, whole, header, queues, gpu,
                read_recipes(get(conf, "mpi", Dict{String,Any}()), file),
                get(julia, "bin", "julia"),
                get(julia, "depot", "~/.julia"),
                collect(String, get(julia, "modules", String[])),
                get(julia, "precompile_on", "login"),
                get(julia, "precompile_tasks", nothing),
                get(julia, "cpu_target", nothing),
                parse_time(get(julia, "precompile_time", "0:30:00")),
                get(julia, "compute_internet", true),
                get(julia, "registry_update", true),
                env)
end

function read_queues(tables)
    return [Queue(q["partition"],
                  haskey(q, "min_time") ? parse_time(q["min_time"]) : nothing,
                  haskey(q, "max_time") ? parse_time(q["max_time"]) : nothing,
                  get(q, "max_nodes", nothing), get(q, "max_gpus", nothing),
                  get(q, "one_at_a_time", false), get(q, "preempt", false), get(q, "prefer", false),
                  get(q, "chain", true))
            for q in tables]
end

function read_recipes(tables, file)
    recipes = Dict{String,MPIRecipe}()
    for (name, t) in tables
        checkname("$file: an MPI recipe's name", name)
        binary = get(t, "binary", name)
        binary in ("jll", "system") ||
            fail("$file, [mpi.$name]: `binary` is \"jll\" or \"system\", not $(repr(binary))")
        launcher = get(t, "launcher", "srun")
        launcher in ("srun", "mpiexec") ||
            fail("$file, [mpi.$name]: `launcher` is \"srun\" or \"mpiexec\", not $(repr(launcher))")
        recipes[name] = MPIRecipe(name, binary, launcher, collect(String, get(t, "launcher_args", String[])),
                                  get(t, "multi_node", launcher == "srun"),
                                  collect(String, get(t, "modules", String[])), get(t, "julia", nothing),
                                  Dict{String,Any}(get(t, "preferences", Dict{String,Any}())),
                                  Dict{String,String}(k => string(v) for (k, v) in get(t, "env", Dict{String,Any}())))
    end
    return recipes
end

"""
Why a job does not fit into a queue, or `nothing` if it fits. `busy` holds
the partitions that have a job of this user already.
"""
function queue_misfit(qu::Queue; seconds, nodes, gpus, checkpoints, chain, busy)
    qu.max_gpus !== nothing && gpus > qu.max_gpus && return "allows at most $(qu.max_gpus) GPUs"
    qu.max_time !== nothing && seconds > qu.max_time && return "allows at most $(time_string(qu.max_time))"
    qu.min_time !== nothing && seconds < qu.min_time && return "takes no less than $(time_string(qu.min_time))"
    qu.max_nodes !== nothing && nodes > qu.max_nodes && return "allows at most $(qu.max_nodes) nodes"
    qu.preempt && !checkpoints && return "is pre-emptible: only for a job with `checkpoints = true`"
    qu.chain || !checkpoints || return "is not for a chain of jobs, which a job with checkpoints is"
    qu.one_at_a_time && chain > 1 && return "takes one job at a time, not a chain"
    qu.one_at_a_time && qu.partition in busy && return "takes one job at a time, and one is there already"
    return nothing
end

"""
The queue for a job: the named one, checked against its limits, or else the
first in the profile's order that fits. A job with checkpoints takes a
queue marked `prefer` first.
"""
function choose_queue(site::Site, queues; name = nothing, what, busy = Set{String}(),
                      seconds, nodes, gpus, checkpoints, chain)
    kw = (; seconds, nodes, gpus, checkpoints, chain)
    kind = gpus > 0 ? "GPU" : "CPU"
    if name !== nothing
        i = findfirst(qu -> qu.partition == name, queues)
        i === nothing && fail("site $(site.name) has no queue $(repr(name)) for $kind jobs; its queues: ",
                              join([qu.partition for qu in queues], ", "))
        why = queue_misfit(queues[i]; busy, kw...)
        why === nothing || fail("$what, but queue $name on $(site.name) $why")
        return queues[i]
    end
    isempty(queues) && fail("site $(site.name) has no queues for $kind jobs in its profile")
    order = checkpoints ? [filter(qu -> qu.prefer, queues); filter(qu -> !qu.prefer, queues)] : queues
    reasons = String[]
    for qu in order
        why = queue_misfit(qu; busy, kw...)
        why === nothing && return qu
        push!(reasons, "$(qu.partition) $why")
    end
    fail("$what, which no queue of $(site.name) takes: ", join(reasons, "; "))
end

"Where a combination for CPU or GPU nodes is precompiled: \"login\" or \"compute\"."
precompile_where(site::Site, gpu::Bool) =
    gpu && site.gpu !== nothing ? something(site.gpu.precompile_on, site.precompile_on) : site.precompile_on

"`JULIA_CPU_TARGET` for the site's CPU or GPU nodes; empty: Julia's default, the node's own CPU."
cpu_target(site::Site, gpu::Bool) = something(gpu && site.gpu !== nothing ? site.gpu.cpu_target : site.cpu_target, "")

known_sites() = sort!([splitext(f)[1] for f in readdir(sites_dir()) if endswith(f, ".toml")])

# Shell text

"""
Quote a string for bash. Everything but plain words is put in single quotes,
also what `Base.shell_escape` leaves bare: a `*` or a `~` that bash would
expand.
"""
function q(s)
    s = string(s)
    occursin(r"^[A-Za-z0-9_@%+=:,./-]+$", s) && return s
    return "'" * replace(s, "'" => "'\\''") * "'"
end

"A path as bash text; a leading `~/` becomes `\$HOME/`, which also works where `~` does not expand."
shpath(p) = startswith(p, "~/") ? "\"\$HOME\"/" * q(p[3:end]) : q(p)

# Running commands on a site

"The command that runs the bash text `script` on the site, in a login shell if it is remote."
function sitecmd(site::Site, script::AbstractString)
    islocal(site) && return `bash -c $script`
    # ssh joins its arguments and hands them to the remote shell
    remote = "bash -lc " * q(script)
    site.via === nothing || (remote = "ssh " * q(site.via) * " " * q(remote))
    return `ssh $(site.host) $remote`
end

"Run bash text on the site; a failure is reported without a stack trace."
function runsite(site::Site, script)
    success(pipeline(sitecmd(site, script); stdout, stderr)) ||
        fail("on $(site.name), this command failed (its message is above): $script")
    return
end

"Run bash text on the site and return what it prints."
function readsite(site::Site, script)
    out = IOBuffer()
    success(pipeline(sitecmd(site, script); stdout = out, stderr)) ||
        fail("on $(site.name), this command failed (its message is above): $script")
    return String(take!(out))
end

"Stop unless the site can be reached without a new login."
function check_connection(site::Site)
    site.check === nothing && return
    ok = success(pipeline(`bash -c $(site.check)`; stdout = devnull, stderr = devnull))
    ok || fail("site $(site.name) is not reachable (`$(site.check)` failed)",
               isempty(site.hint) ? "" : "; " * site.hint)
    return
end

rsync_target(site::Site, path) = islocal(site) ? path : "$(site.host):$path"

"Copy the contents of the local directory `src` into `dst` on the site. Nothing is deleted there."
function push_tree(site::Site, src, dst)
    runsite(site, "mkdir -p " * q(dst))
    success(pipeline(`rsync -a $(src * "/") $(rsync_target(site, dst * "/"))`; stdout, stderr)) ||
        fail("copying $src to $(site.name):$dst failed (rsync's message is above); try again")
    return
end

"Copy one local file to the path `dst` on the site."
function push_file(site::Site, src, dst)
    runsite(site, "mkdir -p " * q(dirname(dst)))
    success(pipeline(`rsync -a $src $(rsync_target(site, dst))`; stdout, stderr)) ||
        fail("copying $src to $(site.name):$dst failed (rsync's message is above); try again")
    return
end

"Copy the file `src` on the site to the local path `dst`; false if the site has no such file."
function pull_file(site::Site, src, dst)
    mkpath(dirname(dst))
    return success(pipeline(`rsync -a $(rsync_target(site, src)) $dst`; stdout = devnull, stderr = devnull))
end
