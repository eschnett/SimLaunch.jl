# Job specs: what to run (the same on every site) and what it needs (a table
# per site), resolved against a site profile into a Job.

struct Run
    label::String
    cmd::Vector{String}               # script and arguments, or Julia options
    threads::Int
    julia_args::Vector{String}
    vars::Dict{String,String}
end

struct Job
    name::String
    study::String
    site::Site
    project::String                   # relative to the study's src/
    time::Union{Int,Nothing}          # seconds
    nodes::Int
    gpus::Int                         # 0: a CPU job
    cores::Int                        # of the allocation
    env::String                       # "default", or a kind of ENV_KINDS
    envdir::String                    # the runs' environment, relative to the study's directory
    mode::Symbol                      # :sequential or :parallel
    blas_threads::Int
    pin::Bool
    queue::Union{Queue,Nothing}
    runs::Vector{Run}
end

# Keys that may depend on the site: read from [site.<name>], with the top
# level as the default.
const SITE_KEYS = ["time", "resources", "mode", "threads", "pin", "env", "blas_threads",
                   "julia_args", "vars", "queue"]
const TOP_KEYS = ["name", "project", "site", "checkpoints", "run"]
const RUN_KEYS = ["label", "cmd", "threads", "julia_args", "vars"]

"""
The environments `prepare` can write beside the project: the packages they
add, and the Julia code that fetches what a package downloads at first use.
"""
const ENV_KINDS = Dict("cuda" => (packages = ["CUDA"], warm = "using CUDA; CUDA.versioninfo()"),
                       "metal" => (packages = ["Metal"], warm = "using Metal; Metal.versioninfo()"))

"A job's environment, relative to the study's directory. `own` is the study's own project."
function env_dir(project, env, own)
    env == "default" && return joinpath("src", project)
    return joinpath("envs", project == own ? "default-$env" : "default-$env-" * replace(project, r"[^A-Za-z0-9_.-]" => "-"))
end

# Fields of the design that later milestones implement.
const LATER_KEYS = Dict("variant" => 3, "ranks" => 3, "nodes" => 3, "placement" => 3, "mpi" => 3,
                        "julia" => 2, "after" => 3, "restart" => 3, "combine" => 3,
                        "mutable_restarts" => 3, "sbatch_args" => 3, "prefix" => 3, "node" => 3)

function check_keys(table, allowed, where)
    for key in keys(table)
        key in allowed && continue
        haskey(LATER_KEYS, key) &&
            fail("$where: `$key` is not implemented yet (milestone $(LATER_KEYS[key]))")
        fail("$where: unknown key `$key`")
    end
    return
end

time_string(seconds) = string(seconds ÷ 3600, ":", lpad(seconds % 3600 ÷ 60, 2, '0'), ":", lpad(seconds % 60, 2, '0'))

function string_list(value, where)
    value isa AbstractVector && all(v -> v isa AbstractString, value) ||
        fail("$where must be a list of strings")
    return collect(String, value)
end

function var_table(value, where)
    value isa AbstractDict || fail("$where must be a table")
    for key in keys(value)
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", key) || fail("$where: $(repr(key)) is not a variable name")
    end
    return Dict{String,String}(k => string(v) for (k, v) in value)
end

"""
    resolve(spec, site; study, project, queue = nothing)

Turn the parsed spec into the job it means on `site`. `project` is the
study's own project, the default for the spec's `project`. `only_runs` keeps
the runs with these labels, for a site that cannot hold them all. Refuses a
job the site cannot hold.
"""
function resolve(spec::AbstractDict, site::Site; study, project, queue = nothing, only_runs = String[],
                 file = "the spec")
    check_keys(spec, [TOP_KEYS; SITE_KEYS; "site"], file)
    name = checkname("the spec's name", get(spec, "name", nothing))

    # which sites, and this site's table
    sites = get(spec, "site", Dict{String,Any}())
    if sites isa AbstractString
        sites == site.name || fail("$file is written for site $sites only, not for $(site.name)")
        table = Dict{String,Any}()
    else
        sites isa AbstractDict || fail("$file: `site` is a site's name or the tables [site.<name>]")
        table = get(sites, site.name, Dict{String,Any}())
        check_keys(table, SITE_KEYS, "$file, [site.$(site.name)]")
    end
    setting(key, default) = get(table, key, get(spec, key, default))

    get(spec, "checkpoints", false) == false ||
        fail("$file: `checkpoints = true` is not implemented yet (milestone 3)")
    env = setting("env", "default")
    env == "default" || haskey(ENV_KINDS, env) ||
        fail("$file: no environment `$env`; the environments are \"default\", ",
             join(repr.(sort!(collect(keys(ENV_KINDS)))), ", "), " (others come with milestone 3)")

    # resources: nodes, or GPUs
    resources = setting("resources", Dict{String,Any}("nodes" => 1))
    resources isa AbstractDict || fail("$file: `resources` must be a table such as { nodes = 1 } or { gpus = 1 }")
    for key in keys(resources)
        key in ("nodes", "gpus") || fail("$file: `resources.$key` is not implemented yet; only `nodes` and `gpus`")
    end
    gpus = get(resources, "gpus", 0)
    gpus isa Integer && gpus >= 0 || fail("$file: `resources.gpus` must be a number of GPUs")
    gpus > 0 && haskey(resources, "nodes") && resources["nodes"] != 1 &&
        fail("$file: `resources` names nodes or GPUs, not both")
    nodes = get(resources, "nodes", 1)
    nodes isa Integer && nodes >= 1 || fail("$file: `resources.nodes` must be a positive integer")
    nodes == 1 || fail("$file: jobs on several nodes need the MPI recipes, which are not implemented yet (milestone 3)")
    if gpus > 0
        g = site.gpu
        g === nothing && fail("$file asks for GPUs, but site $(site.name) has none in its profile")
        g.max !== nothing && gpus > g.max &&
            fail("$file asks for $gpus GPUs, but a job on $(site.name) gets at most $(g.max)")
        cores = gpus * g.cores
    else
        site.cores > 0 || fail("site $(site.name) runs GPU jobs only; give `resources = { gpus = 1 }` in [site.$(site.name)]")
        cores = site.cores
    end
    what = gpus > 0 ? "the $gpus GPU$(gpus == 1 ? "" : "s") of this job on $(site.name) come$(gpus == 1 ? "s" : "") with" :
                      "a node of $(site.name) has"

    mode = setting("mode", "sequential")
    mode in ("sequential", "parallel") || fail("$file: `mode` is \"sequential\" or \"parallel\", not $(repr(mode))")
    mode = Symbol(mode)
    pin = setting("pin", false)
    pin isa Bool || fail("$file: `pin` is true or false")
    pin && mode === :parallel && fail("$file: pinned runs side by side need placement, which is not implemented yet (milestone 3)")
    pin && !site.slurm && fail("$file: `pin = true` needs a Slurm site; $(site.name) cannot pin threads")
    pin && gpus > 0 && fail("$file: `pin = true` is for CPU jobs")
    blas_threads = setting("blas_threads", 1)
    blas_threads isa Integer && blas_threads >= 1 || fail("$file: `blas_threads` must be a positive integer")

    # time and queue
    time = setting("time", nothing)
    time === nothing && site.slurm &&
        fail("$file gives no `time` for site $(site.name); add it to [site.$(site.name)]")
    seconds = time === nothing ? nothing : parse_time(time)
    chosen = nothing
    if site.slurm && !site.partition
        something(queue, setting("queue", nothing), Some(nothing)) === nothing ||
            fail("site $(site.name) chooses the partition itself; give no queue")
        site.max_time !== nothing && seconds > site.max_time &&
            fail("$file asks for $(time_string(seconds)), but $(site.name) allows at most $(time_string(site.max_time))")
    elseif site.slurm
        queues = gpus > 0 ? site.gpu.queues : site.queues
        default = gpus > 0 ? site.gpu.default_queue : site.default_queue
        queue_name = something(queue, setting("queue", nothing), default, Some(nothing))
        queue_name === nothing && fail("site $(site.name) has no default queue; give one with --queue")
        i = findfirst(qu -> qu.partition == queue_name, queues)
        i === nothing && fail("site $(site.name) has no queue $(repr(queue_name)) for $(gpus > 0 ? "GPU" : "CPU") jobs; its queues: ",
                              join([qu.partition for qu in queues], ", "))
        chosen = queues[i]
        chosen.max_gpus !== nothing && gpus > chosen.max_gpus &&
            fail("$file asks for $gpus GPUs, but queue $(chosen.partition) on $(site.name) allows at most $(chosen.max_gpus)")
        chosen.max_time !== nothing && seconds > chosen.max_time &&
            fail("$file asks for $(time_string(seconds)), but queue $(chosen.partition) on $(site.name) allows at most $(time_string(chosen.max_time))")
        chosen.min_time !== nothing && seconds < chosen.min_time &&
            fail("$file asks for $(time_string(seconds)), but queue $(chosen.partition) on $(site.name) takes no less than $(time_string(chosen.min_time))")
        chosen.max_nodes !== nothing && nodes > chosen.max_nodes &&
            fail("$file asks for $nodes nodes, but queue $(chosen.partition) on $(site.name) allows at most $(chosen.max_nodes)")
    end

    # runs
    run_tables = get(spec, "run", nothing)
    run_tables isa AbstractVector && !isempty(run_tables) || fail("$file has no [[run]] tables")
    job_args = string_list(setting("julia_args", String[]), "$file: `julia_args`")
    job_vars = var_table(setting("vars", Dict{String,Any}()), "$file: `vars`")
    # a threads list is a scan: one run per count
    nruns = sum(r -> get(r, "threads", nothing) isa AbstractVector ? length(r["threads"]) : 1, run_tables)
    default_threads = setting("threads", mode === :parallel ? max(1, cores ÷ nruns) : cores)
    runs = Run[]
    for (k, r) in enumerate(run_tables)
        where = "$file, run $k"
        check_keys(r, RUN_KEYS, where)
        label = checkname("$where: its label", get(r, "label", nothing))
        cmd = get(r, "cmd", nothing)
        cmd isa AbstractString && !isempty(strip(cmd)) || fail("$where ($label) has no `cmd`")
        words = Base.shell_split(cmd)
        args = haskey(r, "julia_args") ? string_list(r["julia_args"], "$where: `julia_args`") : job_args
        vars = merge(job_vars, var_table(get(r, "vars", Dict{String,Any}()), "$where: `vars`"))
        threads = get(r, "threads", default_threads)
        scan = threads isa AbstractVector
        for t in (scan ? threads : [threads])
            t isa Integer && t >= 1 || fail("$where ($label): `threads` must be a positive integer or a list of them")
            push!(runs, Run(scan ? "$label-t$t" : label, words, t, args, vars))
        end
    end
    allunique(r.label for r in runs) || fail("$file: two runs have the same label")
    if !isempty(only_runs)
        for label in only_runs
            any(r -> r.label == label, runs) ||
                fail("$file has no run $(repr(label)); its runs: ", join([r.label for r in runs], ", "))
        end
        filter!(r -> r.label in only_runs, runs)
    end

    # does the allocation hold it?
    for r in runs
        r.threads <= cores ||
            fail("$file: run $(r.label) asks for $(r.threads) threads, but $what $cores cores")
    end
    if mode === :parallel
        total = sum(r.threads for r in runs)
        total <= cores ||
            fail("$file: $(length(runs)) runs side by side ask for $total threads, but $what $cores cores; ",
                 "lower `threads` or use `mode = \"sequential\"` in [site.$(site.name)]")
    end

    own = project
    project = get(spec, "project", project)
    project isa AbstractString && !isabspath(project) && !occursin("..", project) ||
        fail("$file: `project` is a path relative to the study's src/")
    return Job(name, study, site, project, seconds, nodes, gpus, cores, env, env_dir(project, env, own),
               mode, blas_threads, pin, chosen, runs)
end

function load_spec(file::AbstractString)
    isfile(file) || fail("no such spec: $file")
    try
        return TOML.parsefile(file)
    catch err
        err isa TOML.ParserError || rethrow()
        fail("$file: ", sprint(showerror, err))
    end
end

"""
What `prepare` makes and `submit` asks for: an environment, precompiled with
these Julia flags on this kind of node.
"""
struct Combo
    project::String                   # relative to the study's src/
    env::String
    envdir::String                    # relative to the study's directory
    args::String                      # the Julia flags, joined
    gpu::Bool                         # for the GPU nodes of a site that precompiles on compute nodes
end

"The combinations a job needs."
combos(job::Job) = unique!([Combo(job.project, job.env, job.envdir, join(r.julia_args, " "), job.gpus > 0)
                            for r in job.runs])
