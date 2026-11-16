# Site profiles, and running commands on a site.

struct Queue
    partition::String
    min_time::Union{Int,Nothing}      # seconds
    max_time::Union{Int,Nothing}      # seconds
    max_nodes::Union{Int,Nothing}
end

struct Site
    name::String
    host::Union{String,Nothing}       # nothing: this machine
    check::Union{String,Nothing}      # command that tells whether the site is reachable
    hint::String
    code::String                      # root of the studies' sources
    scratch::String                   # root of the studies' output
    slurm::Bool
    account::Union{String,Nothing}
    export_env::Bool
    cores::Int                        # per node
    whole_node::Bool
    queues::Vector{Queue}
    default_queue::Union{String,Nothing}
    julia_bin::String
    modules::Vector{String}
    precompile_on::String
    precompile_tasks::Union{Int,Nothing}
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
    cores, whole = Sys.CPU_THREADS, false
    if slurm !== nothing
        node = get(slurm, "node", nothing)
        node === nothing && fail("$file: [slurm] needs a node table with its cores")
        cores, whole = node["cores"], get(node, "whole", false)
        for q in get(slurm, "queues", [])
            min_time = haskey(q, "min_time") ? parse_time(q["min_time"]) : nothing
            max_time = haskey(q, "max_time") ? parse_time(q["max_time"]) : nothing
            push!(queues, Queue(q["partition"], min_time, max_time, get(q, "max_nodes", nothing)))
        end
    end

    julia = get(conf, "julia", Dict{String,Any}())
    env = Dict{String,String}(k => string(v) for (k, v) in get(conf, "env", Dict{String,Any}()))
    return Site(name, host,
                connect === nothing ? nothing : get(connect, "check", nothing),
                connect === nothing ? "" : get(connect, "hint", ""),
                code, scratch,
                slurm !== nothing,
                slurm === nothing ? nothing : get(slurm, "account", nothing),
                slurm === nothing ? true : get(slurm, "export_env", true),
                cores, whole, queues,
                slurm === nothing ? nothing : get(slurm, "default_queue", nothing),
                get(julia, "bin", "julia"),
                collect(String, get(julia, "modules", String[])),
                get(julia, "precompile_on", "login"),
                get(julia, "precompile_tasks", nothing),
                get(julia, "registry_update", true),
                env)
end

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
    return `ssh $(site.host) $("bash -lc " * q(script))`
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
