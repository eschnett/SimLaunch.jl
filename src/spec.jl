# Job specs: what to run (the same on every site) and what it needs (a table
# per site), resolved against a site profile into a Job.

struct Run
    label::String
    cmd::Vector{String}               # script and arguments, or Julia options
    threads::Int                      # per rank
    julia_args::Vector{String}
    vars::Dict{String,String}
    variant::String                   # which version of the study's packages
    env::String                       # "default", or kinds of ENV_KINDS joined by '+'
    envdir::String                    # the run's environment, relative to the study's directory
    ranks::Int                        # MPI ranks; 0: started without a launcher
    nodes::Int
    placement::String                 # "" or "numa"
    domains::Int                      # NUMA domains a placed rank is bound to; 0: its share of the node's
    mpi::String                       # a recipe of the site's profile, or ""
    prefix::Vector{String}            # words put before the Julia command, each quoted
    launcher_args::Vector{String}     # further arguments of the MPI launcher, after the recipe's
end

"The restart contract: the names of the driver's arguments, and how its checkpoints are told apart."
struct Restart
    from::String                      # argument that names an earlier job's checkpoints; "": not passed
    to::String                        # argument that names this job's own
    walltime::String                  # argument that gives the seconds the driver may run; "": not passed
    margin::Int                       # seconds of the time limit kept back
    continue_code::Union{Int,Nothing} # the driver's exit code when it stopped at the walltime
    temporary::Vector{String}         # names of checkpoints that are still being written
    compare::Vector{String}           # the project's script that compares two results, for check-restart
end

struct Job
    name::String
    study::String
    site::Site
    project::String                   # relative to the study's src/
    time::Union{Int,Nothing}          # seconds
    nodes::Int
    gpus::Int                         # 0: a CPU job
    cores::Int                        # of one node of the allocation
    tasks::Int                        # tasks per node in the batch header: the most ranks a run starts there
    mode::Symbol                      # :sequential or :parallel
    blas_threads::Int
    pin::Bool
    queue::Union{Queue,Nothing}
    node::String                      # a named node, or ""
    sbatch_args::Vector{String}
    checkpoints::Bool
    mutable::Bool                     # mutable_restarts: one shared directory, as before the contract
    restart::Union{Restart,Nothing}
    after::String                     # a shell command run after the last run, or ""
    combine::Vector{String}           # the project's combine script and its arguments
    runs::Vector{Run}
end

# Keys that may depend on the site: read from [site.<name>], with the top
# level as the default.
const SITE_KEYS = ["time", "resources", "mode", "threads", "pin", "env", "blas_threads",
                   "julia_args", "vars", "queue", "node", "sbatch_args", "mpi", "placement", "domains_per_rank", "prefix", "launcher_args"]
const TOP_KEYS = ["name", "project", "site", "checkpoints", "mutable_restarts", "restart", "after", "combine", "run"]
const RUN_KEYS = ["label", "cmd", "threads", "julia_args", "vars", "variant", "env", "ranks", "nodes",
                  "placement", "domains_per_rank", "mpi", "prefix", "launcher_args"]
const RESTART_KEYS = ["from", "to", "walltime", "margin", "continue_code", "temporary", "compare"]

"""
The kinds an environment can be made of, joined by `+` in a spec: the
packages each adds, and the Julia code that fetches what a package downloads
at first use. `test` adds the project's test dependencies instead.
"""
const ENV_KINDS = Dict("cuda" => (packages = ["CUDA"], warm = "using CUDA; CUDA.versioninfo()"),
                       "metal" => (packages = ["Metal"], warm = "using Metal; Metal.versioninfo()"),
                       "mpi" => (packages = ["MPI", "MPIPreferences"], warm = "using MPI"),
                       "test" => (packages = String[], warm = ""))

"The kinds of an environment, without \"default\"."
env_kinds(env) = filter(!=("default"), split(env, '+'))

"""
A run's environment, relative to the study's directory. Without kinds it is
the project itself, in its variant; with kinds it is written by `prepare`.
`own` is the study's own project, `recipe` the run's MPI recipe.
"""
function env_dir(project, env, own; variant = "default", recipe = "")
    kinds = env_kinds(env)
    if isempty(kinds)
        return variant == "default" ? joinpath("src", project) : joinpath("variants", variant, "src", project)
    end
    name = "$variant-" * join(kinds, '+') * (isempty(recipe) ? "" : "-$recipe")
    project == own || (name *= "-" * replace(project, r"[^A-Za-z0-9_.-]" => "-"))
    return joinpath("envs", name)
end

"Where a variant's version of the project is, relative to the study's directory."
variant_project(project, variant) =
    variant == "default" ? joinpath("src", project) : joinpath("variants", variant, "src", project)

# Fields of the design that are not implemented.
const LATER_KEYS = Dict("julia" => 4)

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

"A project script and its arguments, from a table's `cmd`-like key."
function script_words(table, key, where)
    cmd = get(table, key, nothing)
    cmd isa AbstractString && !isempty(strip(cmd)) || fail("$where needs `$key`, a script of the project and its arguments")
    return Base.shell_split(cmd)
end

function read_restart(spec, file, checkpoints, mutable)
    table = get(spec, "restart", nothing)
    if !checkpoints
        table === nothing || fail("$file: a [restart] table needs `checkpoints = true`")
        return nothing
    end
    table isa AbstractDict || fail("$file: `checkpoints = true` needs a [restart] table that names the driver's arguments")
    check_keys(table, RESTART_KEYS, "$file, [restart]")
    name(key) = (v = get(table, key, ""); v isa AbstractString && occursin(r"^[A-Za-z0-9_.-]*$", v) ||
                 fail("$file, [restart]: `$key` is the name of an argument of the driver"); String(v))
    to = name("to")
    isempty(to) && fail("$file, [restart]: `to` must name the argument for a job's own checkpoint directory")
    from = name("from")
    mutable && !isempty(from) &&
        fail("$file: with `mutable_restarts = true` the driver gets one directory, as `to`; remove `from`")
    !mutable && isempty(from) &&
        fail("$file, [restart]: `from` must name the argument for an earlier job's checkpoints ",
             "(or set `mutable_restarts = true` for a driver that is not converted yet)")
    code = get(table, "continue_code", nothing)
    code === nothing || (code isa Integer && 1 <= code <= 125) ||
        fail("$file, [restart]: `continue_code` is an exit code from 1 to 125")
    temporary = string_list(get(table, "temporary", ["*.tmp", "*.tmp.*", ".*"]), "$file, [restart]: `temporary`")
    all(t -> occursin(r"^[A-Za-z0-9_.*?-]+$", t), temporary) ||
        fail("$file, [restart]: `temporary` holds file name patterns of letters, digits, '.', '_', '-', '*' and '?'")
    compare = haskey(table, "compare") ? script_words(table, "compare", "$file, [restart]") : String[]
    return Restart(from, to, name("walltime"), parse_time(get(table, "margin", "0:05:00")), code, temporary, compare)
end

"""
    resolve(spec, site; study, project, queue = nothing)

Turn the parsed spec into the job it means on `site`. `project` is the
study's own project, the default for the spec's `project`. `only_runs` keeps
the runs with these labels, for a site that cannot hold them all. `variants`
are the study's; `busy` the partitions that hold a job of this user already;
`chain` the number of jobs submitted at once. Refuses a job the site cannot
hold.
"""
function resolve(spec::AbstractDict, site::Site; study, project, queue = nothing, only_runs = String[],
                 file = "the spec", variants = ["default"], busy = Set{String}(), chain = 1)
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

    checkpoints = get(spec, "checkpoints", false)
    checkpoints isa Bool || fail("$file: `checkpoints` is true or false")
    mutable = get(spec, "mutable_restarts", false)
    mutable isa Bool || fail("$file: `mutable_restarts` is true or false")
    mutable && !checkpoints && fail("$file: `mutable_restarts = true` needs `checkpoints = true`")
    restart = read_restart(spec, file, checkpoints, mutable)
    chain isa Integer && chain >= 1 || fail("--chain takes a positive number of jobs")
    chain > 1 && !checkpoints && fail("$file: a chain of jobs needs `checkpoints = true`")
    chain > 1 && !site.slurm && fail("site $(site.name) has no queue to hold a chain of jobs")

    # resources: nodes, or GPUs
    resources = setting("resources", Dict{String,Any}("nodes" => 1))
    resources isa AbstractDict || fail("$file: `resources` must be a table such as { nodes = 1 } or { gpus = 1 }")
    for key in keys(resources)
        key in ("nodes", "gpus") || fail("$file: `resources.$key` is unknown; only `nodes` and `gpus`")
    end
    gpus = get(resources, "gpus", 0)
    gpus isa Integer && gpus >= 0 || fail("$file: `resources.gpus` must be a number of GPUs")
    gpus > 0 && haskey(resources, "nodes") && resources["nodes"] != 1 &&
        fail("$file: `resources` names nodes or GPUs, not both")
    nodes = get(resources, "nodes", 1)
    nodes isa Integer && nodes >= 1 || fail("$file: `resources.nodes` must be a positive integer")
    nodes > 1 && !site.slurm && fail("$file asks for $nodes nodes, but site $(site.name) is one machine")
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
    pin && mode === :parallel && fail("$file: `pin = true` is for runs one after another; pinned runs side by side would share their cores")
    pin && !site.slurm && fail("$file: `pin = true` needs a Slurm site; $(site.name) cannot pin threads")
    pin && gpus > 0 && fail("$file: `pin = true` is for CPU jobs")
    blas_threads = setting("blas_threads", 1)
    blas_threads isa Integer && blas_threads >= 1 || fail("$file: `blas_threads` must be a positive integer")
    node = setting("node", "")
    node isa AbstractString && occursin(r"^[A-Za-z0-9_.,\[\]-]*$", node) || fail("$file: `node` is a node's name")
    isempty(node) || site.slurm || fail("$file: `node` needs a Slurm site")
    sbatch_args = string_list(setting("sbatch_args", String[]), "$file: `sbatch_args`")
    isempty(sbatch_args) || site.slurm || fail("$file: `sbatch_args` needs a Slurm site")
    any(a -> occursin('\n', a), sbatch_args) && fail("$file: an entry of `sbatch_args` is one line")
    after = get(get(spec, "after", Dict{String,Any}()), "cmd", "")
    haskey(spec, "after") && (after isa AbstractString && !isempty(strip(after)) ||
                              fail("$file: [after] needs `cmd`, a shell command"))
    combine = haskey(spec, "combine") ? script_words(spec["combine"], "cmd", "$file, [combine]") : String[]

    # time and queue
    time = setting("time", nothing)
    time === nothing && site.slurm &&
        fail("$file gives no `time` for site $(site.name); add it to [site.$(site.name)]")
    seconds = time === nothing ? nothing : parse_time(time)
    restart !== nothing && seconds !== nothing && !isempty(restart.walltime) && restart.margin >= seconds &&
        fail("$file: the margin of $(time_string(restart.margin)) in [restart] leaves nothing of the job's $(time_string(seconds))")
    chosen = nothing
    if site.slurm && !site.partition
        something(queue, setting("queue", nothing), Some(nothing)) === nothing ||
            fail("site $(site.name) chooses the partition itself; give no queue")
        site.max_time !== nothing && seconds > site.max_time &&
            fail("$file asks for $(time_string(seconds)), but $(site.name) allows at most $(time_string(site.max_time))")
    elseif site.slurm
        asks = "$file asks for $(time_string(seconds)) on " *
               (gpus > 0 ? "$gpus GPU$(gpus == 1 ? "" : "s")" : "$nodes node$(nodes == 1 ? "" : "s")")
        chosen = choose_queue(site, gpus > 0 ? site.gpu.queues : site.queues;
                              name = something(queue, setting("queue", nothing), Some(nothing)), what = asks, busy,
                              seconds, nodes, gpus, checkpoints, chain)
    end

    # runs
    run_tables = get(spec, "run", nothing)
    run_tables isa AbstractVector && !isempty(run_tables) || fail("$file has no [[run]] tables")
    own = project
    project = get(spec, "project", project)
    project isa AbstractString && !isabspath(project) && !occursin("..", project) ||
        fail("$file: `project` is a path relative to the study's src/")
    job_args = string_list(setting("julia_args", String[]), "$file: `julia_args`")
    job_vars = var_table(setting("vars", Dict{String,Any}()), "$file: `vars`")
    # a threads list is a scan: one run per count
    nruns = sum(r -> get(r, "threads", nothing) isa AbstractVector ? length(r["threads"]) : 1, run_tables)
    runs = Run[]
    labels = String[]                                  # of every run, also those `only_runs` leaves out
    for (k, r) in enumerate(run_tables)
        where = "$file, run $k"
        check_keys(r, RUN_KEYS, where)
        label = checkname("$where: its label", get(r, "label", nothing))
        where = "$where ($label)"
        # A run that `only_runs` leaves out is not checked: it may be written for another site, with a recipe
        # or a placement this one does not have.
        counts = get(r, "threads", get(table, "threads", get(spec, "threads", nothing)))
        names = counts isa AbstractVector ? ["$label-t$t" for t in counts] : [label]
        append!(labels, names)
        isempty(only_runs) || any(in(only_runs), names) || continue
        cmd = get(r, "cmd", nothing)
        cmd isa AbstractString && !isempty(strip(cmd)) || fail("$where has no `cmd`")
        words = Base.shell_split(cmd)
        args = haskey(r, "julia_args") ? string_list(r["julia_args"], "$where: `julia_args`") : job_args
        vars = merge(job_vars, var_table(get(r, "vars", Dict{String,Any}()), "$where: `vars`"))
        prefix = get(r, "prefix", setting("prefix", String[]))
        prefix isa AbstractString || prefix isa AbstractVector && all(w -> w isa AbstractString, prefix) ||
            fail("$where: `prefix` is the words put before the Julia command, as a string or a list of strings")
        prefix = prefix isa AbstractString ? Base.shell_split(prefix) : collect(String, prefix)

        variant = get(r, "variant", "default")
        variant in variants ||
            fail("$where: study $study has no variant $(repr(variant)); its variants: ", join(variants, ", "),
                 ". A variant is added when the snapshot is taken: `simlaunch snapshot … --variant $variant=<path>`")
        env = get(r, "env", setting("env", "default"))
        env isa AbstractString || fail("$where: `env` is a string such as \"cuda\" or \"test+mpi\"")
        for kind in env_kinds(env)
            haskey(ENV_KINDS, kind) ||
                fail("$where: no environment `$kind`; the kinds are ", join(repr.(sort!(collect(keys(ENV_KINDS)))), ", "),
                     ", joined by '+', or \"default\"")
        end

        # MPI: ranks, the nodes they are spread over, the recipe, the placement
        ranks = get(r, "ranks", 0)
        ranks isa Integer && ranks >= 0 || fail("$where: `ranks` must be a number of MPI ranks")
        run_nodes = get(r, "nodes", ranks > 0 ? nodes : 1)
        run_nodes isa Integer && 1 <= run_nodes <= nodes ||
            fail("$where: `nodes` must be between 1 and the job's $nodes node$(nodes == 1 ? "" : "s")")
        recipe = get(r, "mpi", setting("mpi", ""))
        recipe isa AbstractString || fail("$where: `mpi` names a recipe of the site's profile")
        # the site's default: for a run with ranks that names no recipe, and for `mpi = "default"`
        if recipe == "default" || (ranks > 0 && isempty(recipe))
            site.mpi_default === nothing &&
                fail("$where: ", recipe == "default" ? "`mpi = \"default\"`" : "a run with `ranks`", " needs `mpi`, a recipe of $(site.name), ",
                     "whose profile names no default: ",
                     isempty(site.mpi) ? "it has no recipes" : "it has " * join(sort!(collect(keys(site.mpi))), ", "))
            recipe = site.mpi_default
        end
        if ranks > 0
            mode === :parallel && fail("$where: runs with `ranks` run one after another; use `mode = \"sequential\"`")
            ranks % run_nodes == 0 || fail("$where: $ranks ranks do not divide evenly over $run_nodes nodes")
        else
            run_nodes == 1 || fail("$where: `nodes` is for a run with `ranks`")
        end
        if !isempty(recipe)
            haskey(site.mpi, recipe) ||
                fail("$where: site $(site.name) has no MPI recipe $(repr(recipe)); its recipes: ",
                     isempty(site.mpi) ? "none" : join(sort!(collect(keys(site.mpi))), ", "))
            rec = site.mpi[recipe]
            isempty(rec.unset) ||
                fail("$where: the MPI recipe $recipe of $(site.name) leaves these to you: ", join(sort(rec.unset), ", "),
                     ". Set them in ", joinpath(user_sites_dir(), site.name * ".toml"), " (see SITES.md), or name another recipe")
            run_nodes > 1 && !rec.multi_node &&
                fail("$where: the MPI recipe $recipe of $(site.name) starts its ranks on one node only")
            rec.launcher == "srun" && gpus > 0 &&
                fail("$where: the MPI recipe $recipe of $(site.name) starts its ranks with srun, which a GPU job's ",
                     "allocation here is not set up for; use a recipe with `launcher = \"mpiexec\"`")
            "mpi" in env_kinds(env) || (env = join([env_kinds(env); "mpi"], '+'))
        elseif "mpi" in env_kinds(env)
            fail("$where: the environment `mpi` needs `mpi`, the recipe that says which MPI it is built for")
        end
        placement = get(r, "placement", setting("placement", ""))
        placement in ("", "numa") || fail("$where: `placement` is \"numa\", not $(repr(placement))")
        if placement == "numa"
            gpus > 0 && fail("$where: `placement = \"numa\"` is for CPU jobs")
            site.numa > 1 || fail("$where: the profile of $(site.name) names no NUMA domains (`numa` in its node table)")
            rpn = max(ranks, 1) ÷ run_nodes
            rpn <= site.numa ||
                fail("$where: $rpn ranks on a node do not fit its $(site.numa) NUMA domains, at least one domain a rank")
            # the job's `domains_per_rank` is for its runs that are placed; a run's own needs a placement
            domains = get(r, "domains_per_rank", setting("domains_per_rank", 0))
            if haskey(r, "domains_per_rank") || domains != 0
                domains isa Integer && domains >= 1 || fail("$where: `domains_per_rank` must be a positive integer")
                rpn * domains <= site.numa ||
                    fail("$where: $rpn rank$(rpn == 1 ? "" : "s") on a node with $domains NUMA domains each ",
                         "do not fit its $(site.numa) domains")
            else
                site.numa % rpn == 0 ||
                    fail("$where: $rpn ranks on a node cannot share its $(site.numa) NUMA domains evenly; ",
                         "`placement = \"numa\"` gives every rank the same number of domains. ",
                         "`domains_per_rank` names a smaller number")
            end
        else
            haskey(r, "domains_per_rank") && fail("$where: `domains_per_rank` is for a run with `placement = \"numa\"`")
            domains = 0
        end
        # the launcher's own arguments: the job's are for its runs with ranks, a run's own need ranks
        haskey(r, "launcher_args") && ranks == 0 && fail("$where: `launcher_args` is for a run with `ranks`")
        launcher_args = ranks == 0 ? String[] :
                        string_list(get(r, "launcher_args", setting("launcher_args", String[])), "$where: `launcher_args`")
        pin && (ranks > 0 || placement != "") &&
            fail("$where: `pin = true` binds threads to the cores from 0 on, which a run with `ranks` or `placement` must not; ",
                 "such a run is bound by its placement")

        # threads: per rank
        rpn = max(ranks, 1) ÷ run_nodes
        # a rank has its share of the node, and so of its NUMA domains; a placed run has the cores of the
        # domains it is bound to: those it names, or else its share, or one domain without ranks
        share = placement != "numa" ? max(1, cores ÷ rpn) :
                domains > 0 ? max(1, domains * (cores ÷ site.numa)) :
                ranks == 0 ? max(1, cores ÷ site.numa) : max(1, cores ÷ rpn)
        default_threads = get(table, "threads", get(spec, "threads",
                              ranks > 0 || placement == "numa" ? share : mode === :parallel ? max(1, cores ÷ nruns) : cores))
        threads = get(r, "threads", default_threads)
        scan = threads isa AbstractVector
        for t in (scan ? threads : [threads])
            t isa Integer && t >= 1 || fail("$where: `threads` must be a positive integer or a list of them")
            rpn * t <= cores ||
                fail("$file: run $label asks for $(rpn == 1 ? "" : "$rpn ranks of ")$t threads, but $what $cores cores")
            domains > 0 && t > share &&
                fail("$file: run $label asks for $t threads, but the $domains NUMA domain$(domains == 1 ? "" : "s") ",
                     "it is bound to $(domains == 1 ? "has" : "have") $share cores")
            push!(runs, Run(scan ? "$label-t$t" : label, words, t, args, vars, variant, env,
                            env_dir(project, env, own; variant, recipe), ranks, run_nodes, placement, domains, recipe,
                            prefix, launcher_args))
        end
    end
    allunique(labels) || fail("$file: two runs have the same label")
    if !isempty(only_runs)
        for label in only_runs
            label in labels || fail("$file has no run $(repr(label)); its runs: ", join(labels, ", "))
        end
        filter!(r -> r.label in only_runs, runs)
    end

    # does the allocation hold the runs side by side?
    if mode === :parallel
        total = sum(r.threads for r in runs)
        total <= cores ||
            fail("$file: $(length(runs)) runs side by side ask for $total threads, but $what $cores cores; ",
                 "lower `threads` or use `mode = \"sequential\"` in [site.$(site.name)]")
    end
    tasks = maximum(r -> max(r.ranks, 1) ÷ r.nodes, runs)

    return Job(name, study, site, project, seconds, nodes, gpus, cores, tasks, mode, blas_threads, pin, chosen,
               node, sbatch_args, checkpoints, mutable, restart, after, combine, runs)
end

"""
    load_spec(file) -> Dict

A spec, as TOML gives it. `file` is a TOML file, or a Julia file (`.jl`)
whose value is the spec: nothing after this function can tell the two apart.
"""
function load_spec(file::AbstractString)
    isfile(file) || fail("no such spec: $file")
    endswith(file, ".jl") && return TOML.parse(spec_toml(file))
    try
        return TOML.parsefile(file)
    catch err
        err isa TOML.ParserError || rethrow()
        fail("$file: ", sprint(showerror, err))
    end
end

"""
    spec_toml(file) -> String

The spec as TOML text: the file itself, or for a Julia file what it
evaluates to. A Julia spec is evaluated in a module of its own, with Julia's
standard library and nothing of the study; its last expression is the spec,
written with named tuples or dictionaries where TOML has tables and with
tuples or arrays where it has lists.
"""
function spec_toml(file::AbstractString)
    endswith(file, ".jl") || return read(file, String)
    # the standard library can be loaded, also where the tool runs with a load path of its own
    stdlib = "@stdlib" in LOAD_PATH
    stdlib || push!(LOAD_PATH, "@stdlib")
    value = try
        Base.include(Module(:Spec), abspath(file))
    catch err
        err isa LoadError && (err = err.error)
        fail("$file: ", sprint(showerror, err))
    finally
        stdlib || filter!(!=("@stdlib"), LOAD_PATH)
    end
    value isa Union{NamedTuple,AbstractDict} ||
        fail("$file: its last expression is the spec, a named tuple or a dictionary; it is a $(typeof(value))")
    text = sprint(io -> TOML.print(io, spec_value(value, file, "the spec")))
    return "# What $(basename(file)) evaluated to.\n\n" * text
end

"A value of a Julia spec, as TOML holds it. `where` names it in a message."
function spec_value(value, file, where)
    if value isa NamedTuple
        return Dict{String,Any}(string(k) => spec_value(v, file, "$where.$k") for (k, v) in pairs(value))
    elseif value isa AbstractDict
        all(k -> k isa Union{AbstractString,Symbol}, keys(value)) || fail("$file: the keys of $where are strings or symbols")
        return Dict{String,Any}(string(k) => spec_value(v, file, "$where.$k") for (k, v) in value)
    elseif value isa Union{Tuple,AbstractArray}
        # a comprehension over two ranges is a matrix: its entries in order
        return Any[spec_value(v, file, "$where[$k]") for (k, v) in enumerate(vec(collect(Any, value)))]
    elseif value isa Bool || value isa AbstractString
        return value
    elseif value isa Integer
        return Int64(value)
    elseif value isa AbstractFloat
        return Float64(value)
    end
    fail("$file: $where is a $(typeof(value)); a spec holds strings, numbers, true or false, lists and tables")
end

"""
What `prepare` makes and `submit` asks for: an environment, precompiled with
these Julia flags on this kind of node.
"""
struct Combo
    project::String                   # relative to the study's src/
    variant::String
    env::String
    envdir::String                    # relative to the study's directory
    args::String                      # the Julia flags, joined
    gpu::Bool                         # for the GPU nodes of a site that precompiles on compute nodes
    mpi::String                       # the MPI recipe the environment is built for, or ""
    arch::String                      # the architecture of the nodes it runs on: which depot holds its caches
    target::String                    # that architecture's JULIA_CPU_TARGET, or ""
end

"The architecture of the nodes a job runs on."
job_arch(job::Job) = queue_arch(job.site, job.queue, job.gpus > 0)

"The combinations a job needs."
combos(job::Job) = unique!([Combo(job.project, r.variant, r.env, r.envdir, join(r.julia_args, " "), job.gpus > 0, r.mpi,
                                  job_arch(job), job.site.archs[job_arch(job)])
                            for r in job.runs])
