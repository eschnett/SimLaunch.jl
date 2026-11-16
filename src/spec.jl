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
    env == "default" || fail("$file: the environment `$env` is not implemented yet (milestone 2); only \"default\"")

    # resources
    resources = setting("resources", Dict{String,Any}("nodes" => 1))
    resources isa AbstractDict || fail("$file: `resources` must be a table such as { nodes = 1 }")
    for key in keys(resources)
        key == "gpus" && fail("$file: GPU jobs are not implemented yet (milestone 2)")
        key == "nodes" || fail("$file: `resources.$key` is not implemented yet; only `nodes`")
    end
    nodes = get(resources, "nodes", 1)
    nodes isa Integer && nodes >= 1 || fail("$file: `resources.nodes` must be a positive integer")
    nodes == 1 || fail("$file: jobs on several nodes need the MPI recipes, which are not implemented yet (milestone 3)")
    cores = site.cores

    mode = setting("mode", "sequential")
    mode in ("sequential", "parallel") || fail("$file: `mode` is \"sequential\" or \"parallel\", not $(repr(mode))")
    mode = Symbol(mode)
    pin = setting("pin", false)
    pin isa Bool || fail("$file: `pin` is true or false")
    pin && mode === :parallel && fail("$file: pinned runs side by side need placement, which is not implemented yet (milestone 3)")
    pin && !site.slurm && fail("$file: `pin = true` needs a Slurm site; $(site.name) cannot pin threads")
    blas_threads = setting("blas_threads", 1)
    blas_threads isa Integer && blas_threads >= 1 || fail("$file: `blas_threads` must be a positive integer")

    # time and queue
    time = setting("time", nothing)
    time === nothing && site.slurm &&
        fail("$file gives no `time` for site $(site.name); add it to [site.$(site.name)]")
    seconds = time === nothing ? nothing : parse_time(time)
    chosen = nothing
    if site.slurm
        queue_name = something(queue, setting("queue", nothing), site.default_queue, Some(nothing))
        queue_name === nothing && fail("site $(site.name) has no default queue; give one with --queue")
        i = findfirst(qu -> qu.partition == queue_name, site.queues)
        i === nothing && fail("site $(site.name) has no queue $(repr(queue_name)); its queues: ",
                              join([qu.partition for qu in site.queues], ", "))
        chosen = site.queues[i]
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
            fail("$file: run $(r.label) asks for $(r.threads) threads, but a node of $(site.name) has $cores cores")
    end
    if mode === :parallel
        total = sum(r.threads for r in runs)
        total <= cores ||
            fail("$file: $(length(runs)) runs side by side ask for $total threads, but a node of $(site.name) has $cores cores; ",
                 "lower `threads` or use `mode = \"sequential\"` in [site.$(site.name)]")
    end

    project = get(spec, "project", project)
    project isa AbstractString && !isabspath(project) && !occursin("..", project) ||
        fail("$file: `project` is a path relative to the study's src/")
    return Job(name, study, site, project, seconds, nodes, mode, blas_threads, pin, chosen, runs)
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

"The combinations of project and Julia flags a job needs precompiled."
combos(job::Job) = unique!([(job.project, join(r.julia_args, " ")) for r in job.runs])
