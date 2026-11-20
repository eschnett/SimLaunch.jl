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
    header::Vector{String}            # further batch options of a job in this queue
    min_gpus::Union{Int,Nothing}      # a queue for whole GPU nodes takes no smaller job
end

"How MPI runs are set up and launched on a site."
struct MPIRecipe
    name::String
    binary::String                    # "jll": MPICH_jll; another binary of MPIPreferences, such as "MPIABI_jll"; "system": the site's MPI
    launcher::String                  # "srun", or "mpiexec": the binary's own
    launcher_args::Vector{String}
    multi_node::Bool
    implementation::String            # "openmpi" or "mpich" (Hydra's mpiexec), or "": how an mpiexec is told its nodes
    modules::Vector{String}
    julia_bin::Union{String,Nothing}  # a Julia that can load the site's MPI
    preferences::Dict{String,Any}     # for MPIPreferences.use_system_binary
    env::Dict{String,String}
    unset::Vector{String}             # its keys that still hold a placeholder: not usable until they are set
end

"What a GPU job is given on a kind of GPU node, per GPU."
struct GPUs
    request::String                   # the batch option; %d is the number of GPUs
    cores::Int                        # per GPU
    request_cores::Bool               # false: the site hands them out with the GPU
    mem::Union{String,Nothing}        # per GPU, such as "64G"; nothing: not asked for
    max::Union{Int,Nothing}           # per job
end

"""
One kind of node of a site: its shape, its architecture and its queues. A
job runs on one kind. A CPU kind has `cores`; a GPU kind has `gpus`, and a
GPU job gets cores and memory per GPU.
"""
struct NodeType
    name::String
    cores::Int                        # per node, for a CPU kind; 0 for a GPU kind
    numa::Int                         # NUMA domains per node
    whole::Bool                       # a job gets whole nodes without asking for cores
    header::Vector{String}            # further batch options of a job on these nodes
    gpus::Union{GPUs,Nothing}         # nothing: a CPU kind
    arch::String                      # a key of the site's `archs`
    queues::Vector{Queue}             # in the order of preference; empty: the site chooses the partition
    max_time::Union{Int,Nothing}      # seconds, where the site chooses the partition
end

isgpu(t::NodeType) = t.gpus !== nothing

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
    types::Vector{NodeType}           # its kinds of node, in the order of preference; the laptop has one
    mpi::Dict{String,MPIRecipe}
    mpi_default::Union{String,Nothing} # the recipe of a run that names none
    julia_bin::String
    julia_versions::Dict{String,String} # a run's Julia version => its binary, for one that is not juliaup's channel
    depot::String                     # the site's own Julia depot: packages, artifacts, registries
    modules::Vector{String}
    archs::Dict{String,String}        # architectures: name => JULIA_CPU_TARGET; "": the node's own CPU
    login_arch::String                # the login node's
    precompile_tasks::Union{Int,Nothing}
    precompile_time::Int              # seconds, for a precompile job on a compute node
    compute_internet::Bool
    registry_update::Bool
    env::Dict{String,String}          # exported in every job
end

islocal(site::Site) = site.host === nothing

const SITE_TABLES = ["name", "connect", "paths", "slurm", "julia", "env", "mpi", "arch"]

"""
The architectures of a profile: `[arch]` gives each a name and its
`JULIA_CPU_TARGET` (`"native"`: the node's own CPU); each kind of node names
one as `arch`, and the login node as `[julia] login_arch`. Nodes with the
same architecture share their compiled caches; a job sees no others. Without
`[arch]` a site has one architecture, `default`. A login node that names
none has its own, `login`, and compiles nothing that a job uses; on a site
without Slurm the login node is where jobs run.
"""
function read_archs(conf, file; slurm::Bool)
    julia = get(conf, "julia", Dict{String,Any}())
    for key in ("precompile_on", "cpu_target")
        haskey(julia, key) &&
            fail("$file, [julia]: `$key` is gone; name the site's architectures in [arch], and give each kind of node's as `arch`")
    end
    haskey(julia, "arch") && slurm &&
        fail("$file, [julia]: `arch` is gone; each kind of node in [[slurm.nodes]] names its architecture (SITES.md)")
    if !haskey(conf, "arch")
        haskey(julia, "login_arch") && fail("$file, [julia]: `login_arch` names an architecture, but the profile has no [arch] table")
        return Dict("default" => ""), "default"
    end
    archs = Dict{String,String}()
    for (name, target) in conf["arch"]
        checkname("$file: an architecture's name", name)
        target isa AbstractString && occursin(r"^[A-Za-z0-9_.,;()+-]+$", target) ||
            fail("$file, [arch]: `$name` is a JULIA_CPU_TARGET such as \"znver2;znver4,clone_all\", or \"native\"")
        archs[name] = target == "native" ? "" : target
    end
    login = get(julia, "login_arch", nothing)
    if login === nothing
        slurm || fail("$file: a site without Slurm compiles where it runs; give its architecture as `login_arch` in [julia]")
        login = "login"
        get!(archs, "login", "")
    end
    haskey(archs, login) || fail("$file, [julia]: no architecture $(repr(login)) in [arch]; it has ", join(sort!(collect(keys(archs))), ", "))
    return archs, login
end

const SLURM_KEYS = ["account", "export_env", "nodes"]
const NODE_KEYS = ["name", "cores", "numa", "mem", "whole", "header", "gpus", "arch", "queues", "max_time"]
const GPU_KEYS = ["request", "cores", "request_cores", "mem", "max"]

"""
The kinds of node of a Slurm site, `[[slurm.nodes]]`, in the order of
preference: the first CPU kind takes a CPU job that names none, the first
GPU kind a GPU job.
"""
function read_node_types(slurm, archs, file; named::Bool)
    old = [k for k in ("node", "gpu", "queues", "partition", "max_time", "default_queue") if haskey(slurm, k)]
    isempty(old) ||
        fail("$file, [slurm]: ", join("`" .* old .* "`", ", "), " belong to the form of a profile before 2026-11-19. ",
             "A site now lists its kinds of node as [[slurm.nodes]] tables, each with its shape, `arch` and queues (SITES.md)")
    for key in keys(slurm)
        key in SLURM_KEYS || fail("$file, [slurm]: unknown key `$key`")
    end
    tables = get(slurm, "nodes", nothing)
    tables isa AbstractVector && !isempty(tables) && all(t -> t isa AbstractDict, tables) ||
        fail("$file: [slurm] needs its kinds of node, as [[slurm.nodes]] tables")
    types = map(tables) do t
        name = checkname("$file: the name of a kind of node in [[slurm.nodes]]", get(t, "name", nothing))
        where = "$file, node type $name"
        for key in keys(t)
            key in NODE_KEYS || fail("$where: unknown key `$key`")
        end
        arch = get(t, "arch", nothing)
        if !named
            arch === nothing || fail("$where: `arch` names an architecture, but the profile has no [arch] table")
            arch = "default"
        else
            arch isa AbstractString && haskey(archs, arch) && arch != "login" ||
                fail("$where: `arch` must name one of the architectures in [arch]: ", join(sort!(filter(!=("login"), collect(keys(archs)))), ", "))
        end
        g = get(t, "gpus", nothing)
        gpus = nothing
        if g === nothing
            haskey(t, "cores") || fail("$where: a kind of CPU node gives its `cores`, a kind of GPU node its `gpus`")
            cores = t["cores"]
            cores isa Integer && cores >= 1 || fail("$where: `cores` is a positive number")
        else
            for key in ("cores", "numa", "whole", "mem")
                haskey(t, key) && fail("$where: a kind of GPU node gives its `$key` per GPU, in `gpus`, or not at all")
            end
            g isa AbstractDict || fail("$where: `gpus` is a table such as { request = \"--gpus=%d\", cores = 8 }")
            for key in keys(g)
                key in GPU_KEYS || fail("$where, gpus: unknown key `$key`")
            end
            haskey(g, "request") && occursin("%d", g["request"]) || fail("$where: `gpus.request` needs a %d for the number of GPUs")
            haskey(g, "cores") || fail("$where: `gpus.cores` gives the cores per GPU")
            gpus = GPUs(g["request"], g["cores"], get(g, "request_cores", true), get(g, "mem", nothing), get(g, "max", nothing))
            cores = 0
        end
        queues = read_queues(get(t, "queues", []), "$where, ")
        haskey(t, "max_time") && !isempty(queues) &&
            fail("$where: `max_time` is for nodes without queues, where the site chooses the partition; a queue gives its own")
        NodeType(name, cores, get(t, "numa", 1), get(t, "whole", false), collect(String, get(t, "header", String[])), gpus, arch,
                 queues, haskey(t, "max_time") ? parse_time(t["max_time"]) : nothing)
    end
    allunique(t -> t.name, types) || fail("$file: two kinds of node in [[slurm.nodes]] have the same name")
    return types
end

"The files that hold a profile of this name, the user's first."
site_files(name) = [f for f in (joinpath(d, name * ".toml") for d in sites_dirs()) if isfile(f)]

"Put the tables of `over` on top of `under`: a table is merged key by key, anything else replaces."
function merge_tables!(under::AbstractDict, over::AbstractDict)
    for (k, v) in over
        if v isa AbstractDict && get(under, k, nothing) isa AbstractDict
            merge_tables!(under[k], v)
        else
            under[k] = v
        end
    end
    return under
end

"""
The tables of a profile, and the files they come from. The first file of
that name counts: the user's, else the package's. A profile that names a
`base` holds only what differs from that profile; the base is looked up in
the same way, leaving out the files that are in use already, so that a
user's `trillium.toml` can build on the package's.
"""
function read_profile(name, used = String[])
    files = filter(!in(used), site_files(name))
    isempty(files) && return nothing
    file = files[1]
    conf = TOML.parsefile(file)
    base = pop!(conf, "base", nothing)
    base === nothing && return conf, [file]
    base isa AbstractString && occursin(NAME_RE, base) || fail("$file: `base` names another profile, not $(repr(base))")
    under = read_profile(base, [used; file])
    under === nothing && fail("$file: no profile for its base $(repr(base)); known sites: ", join(known_sites(), ", "))
    delete!(under[1], "name")
    return merge_tables!(under[1], conf), [file; under[2]]
end

"""
The keys of a profile that still hold a placeholder, a string `<...>`: what
the package's profile of a public cluster cannot know, such as the account.
"""
function placeholders(value, key = "")
    value isa AbstractDict &&
        return reduce(vcat, [placeholders(v, isempty(key) ? k : "$key.$k") for (k, v) in value]; init = String[])
    value isa AbstractVector && return reduce(vcat, [placeholders(v, key) for v in value]; init = String[])
    return value isa AbstractString && occursin(r"^<.*>$", value) ? ["`$key` ($(value[2:end-1]))"] : String[]
end

function load_site(name::AbstractString)
    checkname("a site name", name)
    found = read_profile(name)
    found === nothing &&
        fail("no profile for site $(repr(name)) in ", join(sites_dirs(), " or "), "; known sites: ", join(known_sites(), ", "))
    conf, files = found
    file = files[1]
    # an MPI recipe's are reported when a run asks for the recipe
    unset = placeholders(Dict{String,Any}(k => v for (k, v) in conf if k != "mpi"))
    if !isempty(unset)
        own = joinpath(user_sites_dir(), name * ".toml")
        fail("site $name: its profile leaves these to you: ", join(sort!(unset), ", "), ". Set them in $own",
             own in files ? "" : ", a file that starts with `base = $(repr(name))` (see SITES.md)")
    end
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
    archs, login_arch = read_archs(conf, file; slurm = slurm !== nothing)
    # the laptop: one kind of node, this machine, which compiles for itself
    types = slurm === nothing ?
            [NodeType("local", Sys.CPU_THREADS, 1, false, String[], nothing, login_arch, Queue[], nothing)] :
            read_node_types(slurm, archs, file; named = haskey(conf, "arch"))

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
                types,
                read_recipes(get(conf, "mpi", Dict{String,Any}()), file)...,
                get(julia, "bin", "julia"),
                julia_versions(get(julia, "versions", Dict{String,Any}()), file),
                get(julia, "depot", "~/.julia"),
                collect(String, get(julia, "modules", String[])),
                archs, login_arch,
                get(julia, "precompile_tasks", nothing),
                parse_time(get(julia, "precompile_time", "0:30:00")),
                get(julia, "compute_internet", true),
                get(julia, "registry_update", true),
                env)
end

"The table `[julia.versions]`: a Julia version, as a run names it, and the binary that runs it."
function julia_versions(table, file)
    table isa AbstractDict && all(v -> v isa AbstractString, values(table)) ||
        fail("$file: [julia.versions] names a binary for each version, such as \"1.14\" = \"~/julia-1.14/bin/julia\"")
    for v in keys(table)
        occursin(JULIA_VERSION_RE, v) || fail("$file: [julia.versions]: $(repr(v)) is not a Julia version or a juliaup channel")
    end
    return Dict{String,String}(k => v for (k, v) in table)
end

const QUEUE_KEYS = ["partition", "min_time", "max_time", "max_nodes", "max_gpus", "one_at_a_time", "preempt", "prefer",
                    "chain", "header", "min_gpus"]

function read_queues(tables, where)
    tables isa AbstractVector && all(q -> q isa AbstractDict && haskey(q, "partition"), tables) ||
        fail("$(where)`queues` is a list of tables, each with its `partition`")
    return map(tables) do q
        for key in keys(q)
            key in ("arch", "on_request") &&
                fail("$(where)queue $(q["partition"]): `$key` is gone; a queue whose nodes differ is a kind of node of its own in [[slurm.nodes]]")
            key in QUEUE_KEYS || fail("$(where)queue $(q["partition"]): unknown key `$key`")
        end
        Queue(q["partition"],
              haskey(q, "min_time") ? parse_time(q["min_time"]) : nothing,
              haskey(q, "max_time") ? parse_time(q["max_time"]) : nothing,
              get(q, "max_nodes", nothing), get(q, "max_gpus", nothing),
              get(q, "one_at_a_time", false), get(q, "preempt", false), get(q, "prefer", false),
              get(q, "chain", true),
              collect(String, get(q, "header", String[])), get(q, "min_gpus", nothing))
    end
end

"The MPI implementation of a binary, where its name says it."
const MPI_IMPLEMENTATIONS = Dict("jll" => "mpich", "MPICH_jll" => "mpich", "OpenMPI_jll" => "openmpi")

"""
The MPI recipes of a profile, `[mpi.<name>]`, and its default: `default` in
`[mpi]` names the recipe of a run that asks for ranks and names none.
"""
function read_recipes(tables, file)
    recipes = Dict{String,MPIRecipe}()
    for (name, t) in tables
        name == "default" && continue
        checkname("$file: an MPI recipe's name", name)
        t isa AbstractDict || fail("$file, [mpi]: `$name` is not a recipe; a recipe is a table [mpi.$name]")
        binary = get(t, "binary", name)
        binary isa AbstractString && (binary in ("jll", "system") || occursin(r"^[A-Za-z0-9]+_jll$", binary)) ||
            fail("$file, [mpi.$name]: `binary` is \"jll\", a binary of MPIPreferences such as \"MPIABI_jll\", or \"system\", ",
                 "not $(repr(binary))")
        launcher = get(t, "launcher", "srun")
        launcher in ("srun", "mpiexec") ||
            fail("$file, [mpi.$name]: `launcher` is \"srun\" or \"mpiexec\", not $(repr(launcher))")
        multi_node = get(t, "multi_node", launcher == "srun")
        # an mpiexec on several nodes is told which nodes, and how many ranks on each, in its own words
        implementation = get(t, "implementation", get(MPI_IMPLEMENTATIONS, binary, ""))
        implementation in ("", "openmpi", "mpich") ||
            fail("$file, [mpi.$name]: `implementation` is \"openmpi\" or \"mpich\", not $(repr(implementation))")
        launcher == "mpiexec" && multi_node && isempty(implementation) &&
            fail("$file, [mpi.$name]: an mpiexec that starts ranks on several nodes needs `implementation`: ",
                 "\"openmpi\" (Open MPI, HPC-X) or \"mpich\" (MPICH, Intel MPI, MVAPICH: Hydra's mpiexec)")
        recipes[name] = MPIRecipe(name, binary, launcher, collect(String, get(t, "launcher_args", String[])),
                                  multi_node, implementation,
                                  collect(String, get(t, "modules", String[])), get(t, "julia", nothing),
                                  Dict{String,Any}(get(t, "preferences", Dict{String,Any}())),
                                  Dict{String,String}(k => string(v) for (k, v) in get(t, "env", Dict{String,Any}())),
                                  placeholders(t, "mpi.$name"))
    end
    default = get(tables, "default", nothing)
    default === nothing || (default isa AbstractString && haskey(recipes, default)) ||
        fail("$file, [mpi]: `default` names one of the recipes: ", join(sort!(collect(keys(recipes))), ", "))
    return recipes, default
end

"""
Why a job does not fit into a queue, or `nothing` if it fits. `busy` holds
the partitions that have a job of this user already.
"""
function queue_misfit(qu::Queue; seconds, nodes, gpus, checkpoints, chain, busy)
    qu.max_gpus !== nothing && gpus > qu.max_gpus && return "allows at most $(qu.max_gpus) GPUs"
    qu.min_gpus !== nothing && gpus < qu.min_gpus && return "takes no fewer than $(qu.min_gpus) GPUs, a whole node"
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
function choose_queue(site::Site, type::NodeType; name = nothing, what, busy = Set{String}(),
                      seconds, nodes, gpus, checkpoints, chain)
    kw = (; seconds, nodes, gpus, checkpoints, chain)
    queues = type.queues
    kind = length(site.types) == 1 ? "" : " for its $(type.name) nodes"
    if name !== nothing
        i = findfirst(qu -> qu.partition == name, queues)
        if i === nothing
            other = [t for t in site.types if any(qu -> qu.partition == name, t.queues)]
            hint = isempty(other) ? "" :
                   isgpu(first(other)) == isgpu(type) ? ". $name is a queue of its $(first(other).name) nodes: give `node_type = $(repr(first(other).name))`" :
                   ". $name is a queue of its $(first(other).name) nodes, which are $(isgpu(first(other)) ? "GPU" : "CPU") nodes"
            fail("site $(site.name) has no queue $(repr(name))$kind; its queues: ", join([qu.partition for qu in queues], ", "), hint)
        end
        why = queue_misfit(queues[i]; busy, kw...)
        why === nothing || fail("$what, but queue $name on $(site.name) $why")
        return queues[i]
    end
    isempty(queues) && fail("site $(site.name) has no queues$kind in its profile")
    order = checkpoints ? [filter(qu -> qu.prefer, queues); filter(qu -> !qu.prefer, queues)] : queues
    reasons = String[]
    for qu in order
        why = queue_misfit(qu; busy, kw...)
        why === nothing && return qu
        push!(reasons, "$(qu.partition) $why")
    end
    fail("$what, which no queue of $(site.name)$kind takes: ", join(reasons, "; "))
end

"""
The kind of node of a job: the one named, or else the site's first kind for
CPU jobs or for GPU jobs.
"""
function node_type(site::Site, name; gpus::Bool, where = "the spec")
    if name === nothing
        i = findfirst(t -> isgpu(t) == gpus, site.types)
        i === nothing && fail(gpus ? "$where asks for GPUs, but site $(site.name) has none in its profile" :
                                     "site $(site.name) runs GPU jobs only; give `resources = { gpus = 1 }` in [site.$(site.name)]")
        return site.types[i]
    end
    name isa AbstractString || fail("$where: `node_type` names a kind of node of the site")
    i = findfirst(t -> t.name == name, site.types)
    i === nothing && fail("$where: site $(site.name) has no kind of node $(repr(name)); it has ",
                          join([t.name for t in site.types], ", "))
    t = site.types[i]
    isgpu(t) == gpus ||
        fail("$where: the $name nodes of $(site.name) are ", isgpu(t) ? "GPU nodes; give `resources = { gpus = 1 }`" :
                                                                         "CPU nodes, without GPUs")
    return t
end
"A kind of node of the site, by its name."
type_named(site::Site, name::AbstractString) = site.types[findfirst(t -> t.name == name, site.types)]

"All queues of a site, of every kind of node."
all_queues(site::Site) = Queue[qu for t in site.types for qu in t.queues]

"""
Where code for an architecture is precompiled: \"login\" if the login node
has it, else \"compute\", in a job on a node that has it.
"""
precompile_where(site::Site, arch::AbstractString) = arch == site.login_arch ? "login" : "compute"

known_sites() = sort!(unique!([splitext(f)[1] for d in sites_dirs() if isdir(d) for f in readdir(d) if endswith(f, ".toml")]))

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

"""
The files of the local directory `src` whose contents differ from those under `dst` on the site, and
those missing there: `(; differ, missing)`, as paths relative to both. Only the entries of `src`
other than `exclude` are looked at, and on the site only what they hold: files there alone are left
aside.
"""
function tree_differences(site::Site, src, dst; exclude = String[])
    tops = filter(∉(exclude), readdir(src))
    isempty(tops) && return (; differ = String[], missing = String[])
    # POSIX cksum gives the same sums on macOS and Linux; an rsync dry run with -c did not on every macOS
    sums(dir) = "cd $(q(dir)) 2>/dev/null && find $(join(q.(tops), " ")) -type f -exec cksum {} + 2>/dev/null; true"
    table(text) = Dict(m[2] => m[1] for m in (match(r"^(\d+ \d+) (.*)$", l) for l in split(text, '\n'))
                       if m !== nothing)
    here, there = table(read(`bash -c $(sums(src))`, String)), table(readsite(site, sums(dst)))
    differ = sort!([p for (p, s) in here if haskey(there, p) && there[p] != s])
    missing = sort!([p for p in keys(here) if !haskey(there, p)])
    return (; differ, missing)
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
