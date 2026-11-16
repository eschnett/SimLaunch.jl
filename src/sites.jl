# Site profiles, and running commands on a site.

struct Queue
    partition::String
    min_time::Union{Int,Nothing}      # seconds
    max_time::Union{Int,Nothing}      # seconds
    max_nodes::Union{Int,Nothing}
    max_gpus::Union{Int,Nothing}
end

"What a GPU job is given on a site, per GPU."
struct GPUs
    request::String                   # the batch option; %d is the number of GPUs
    cores::Int                        # per GPU
    request_cores::Bool               # false: the site hands them out with the GPU
    mem::Union{String,Nothing}        # per GPU, such as "64G"; nothing: not asked for
    max::Union{Int,Nothing}           # per job
    queues::Vector{Queue}
    default_queue::Union{String,Nothing}
    precompile_on::Union{String,Nothing}   # where the site's GPU nodes differ from its CPU nodes
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
    whole_node::Bool                  # a job gets whole nodes without asking for cores
    node_header::Vector{String}       # further batch options of a CPU job
    queues::Vector{Queue}
    default_queue::Union{String,Nothing}
    gpu::Union{GPUs,Nothing}
    julia_bin::String
    modules::Vector{String}
    precompile_on::String
    precompile_tasks::Union{Int,Nothing}
    precompile_time::Int              # seconds, for a precompile job on a compute node
    compute_internet::Bool
    registry_update::Bool
    env::Dict{String,String}          # exported in every job
end

islocal(site::Site) = site.host === nothing

const SITE_TABLES = ["name", "connect", "paths", "slurm", "julia", "env"]

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
    cores, whole, header, gpu = Sys.CPU_THREADS, false, String[], nothing
    if slurm !== nothing
        node = get(slurm, "node", nothing)
        g = get(slurm, "gpu", nothing)
        node === nothing && g === nothing && fail("$file: [slurm] needs a node table, a gpu table or both")
        cores = 0
        if node !== nothing
            cores, whole = node["cores"], get(node, "whole", false)
            header = collect(String, get(node, "header", String[]))
        end
        queues = read_queues(get(slurm, "queues", []))
        if g !== nothing
            occursin("%d", g["request"]) || fail("$file: [slurm.gpu] request needs a %d for the number of GPUs")
            gpu = GPUs(g["request"], g["cores"], get(g, "request_cores", true), get(g, "mem", nothing),
                       get(g, "max", nothing), read_queues(get(g, "queues", [])), get(g, "default_queue", nothing),
                       get(g, "precompile_on", nothing))
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
                cores, whole, header, queues,
                slurm === nothing ? nothing : get(slurm, "default_queue", nothing),
                gpu,
                get(julia, "bin", "julia"),
                collect(String, get(julia, "modules", String[])),
                get(julia, "precompile_on", "login"),
                get(julia, "precompile_tasks", nothing),
                parse_time(get(julia, "precompile_time", "0:30:00")),
                get(julia, "compute_internet", true),
                get(julia, "registry_update", true),
                env)
end

function read_queues(tables)
    return [Queue(q["partition"],
                  haskey(q, "min_time") ? parse_time(q["min_time"]) : nothing,
                  haskey(q, "max_time") ? parse_time(q["max_time"]) : nothing,
                  get(q, "max_nodes", nothing), get(q, "max_gpus", nothing))
            for q in tables]
end

"Where a combination for CPU or GPU nodes is precompiled: \"login\" or \"compute\"."
precompile_where(site::Site, gpu::Bool) =
    gpu && site.gpu !== nothing ? something(site.gpu.precompile_on, site.precompile_on) : site.precompile_on

known_sites() = sort!([splitext(f)[1] for f in readdir(sites_dir()) if endswith(f, ".toml")])

# Shell text

"Quote a string for bash."
q(s) = Base.shell_escape(string(s))

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
    run(`rsync -a $(src * "/") $(rsync_target(site, dst * "/"))`)
    return
end

"Copy one local file to the path `dst` on the site."
function push_file(site::Site, src, dst)
    runsite(site, "mkdir -p " * q(dirname(dst)))
    run(`rsync -a $src $(rsync_target(site, dst))`)
    return
end

"Copy the file `src` on the site to the local path `dst`; false if the site has no such file."
function pull_file(site::Site, src, dst)
    mkpath(dirname(dst))
    return success(pipeline(`rsync -a $(rsync_target(site, src)) $dst`; stdout = devnull, stderr = devnull))
end
