# The command line.

# Exit codes. A script that posts a status tells "the runs did not all finish"
# from "simlaunch could not tell", such as a site that cannot be reached.
"The jobs have ended, and not every run has finished: `wait`, `submit --wait`, `check-restart`."
const NOT_FINISHED = 1
"An error: the command could not do or find out what it was asked."
const ERROR = 2
"`wait --once`: a job of the spec is queued or running."
const ACTIVE = 3

const USAGE = """
    simlaunch: run Julia projects locally and on clusters

    Usage:
      simlaunch snapshot <project> --study <study> [--rev <commit>] [--variant <name>=<directory>]...
          Copy the project and the packages it takes by path, as the study <study>.
          --rev copies them as a commit of the project's repository holds them, not the working tree.
          A variant is another version of the project, for comparisons in one job.
      simlaunch prepare <study> --site <site> [--spec <spec.toml>]...
          Copy the study to the site, instantiate and precompile it there.
      simlaunch submit <study> <spec.toml> --site <site> [--queue <queue>] [--run <label>]...
                       [--chain <n>] [--wait [--poll <seconds>]] [--dry-run]
          Generate the batch script and submit it. --dry-run only prints it.
          --wait then waits as `simlaunch wait` does.
          --run submits only the named runs, for a site that cannot hold them all.
          --chain queues <n> jobs of a spec with checkpoints, one after another.
      simlaunch resubmit <study> <spec.toml> --site <site> [--queue <queue>] [--run <label>]... [--chain <n>]
                         [--wait [--poll <seconds>]]
          Submit the next job of a run with checkpoints.
      simlaunch wait <study> <spec.toml> --site <site> [--run <label>]... [--poll <seconds> | --once]
          Wait until no job of the spec is queued or running; fails unless every run has finished.
          --once looks once and does not wait; its exit code is $ACTIVE while a job is queued or running.
      simlaunch status <study>... [--site <site>]
          One table of the studies' runs on the sites they are prepared on.
      simlaunch fetch <study> [--site <site>] [--run <run>]... [--with-checkpoints]
                      [--max-size <size>] [--to <directory>]
          Copy results to simlaunch-data/<study>/<site>/ in the study's project, or to <directory>.
      simlaunch usage <study> [--site <site>] [--measure]
          What the study's runs hold on disk, as each job recorded it.
      simlaunch clean <study> --site <site> [--old-checkpoints [--run <run>]...] [--yes]
          List what would be deleted on the site, and delete it after confirmation.
      simlaunch cancel <study> <spec.toml> --site <site> [--message <text>] [--poll <seconds>]
          Cancel the spec's jobs and mark its runs that have not ended as cancelled, for SimWatch.
      simlaunch combine <study> <spec.toml> --site <site> [--run <label>]...
          Run the spec's [combine] script over each run's job directories.
      simlaunch after <study> <spec.toml> --site <site> [--run <label>]... [--checkout]
          Run the spec's [after] command again over the runs' newest job directories.
          --checkout takes PROJECT from the project as it is here now, not from the snapshot.
      simlaunch check-restart <study> <spec.toml> --site <site> [--run <label>]...
          Test the spec's driver against the restart contract, with real jobs.
      simlaunch sites
          List the site profiles and the files they come from.
      simlaunch studies
          List the studies in the cache.
      simlaunch version
          The version of SimLaunch, and its commit when it runs from a git checkout.

    Exit codes: 0 when the command did what it was asked; $NOT_FINISHED when the jobs have ended
    and not every run has finished (wait, submit --wait, check-restart); $ERROR for an error,
    such as a site that cannot be reached.

    A spec is a TOML file, or a Julia file (.jl) whose last expression is the spec.
    Snapshots are kept in ~/.cache/simlaunch (or \$SIMLAUNCH_CACHE).
    Your own site profiles are in ~/.config/simlaunch/sites (or \$SIMLAUNCH_SITES);
    they come before the ones of the package. SITES.md describes them.
    """

"Split arguments into positional ones and options. `flags` take no value; `multi` may repeat."
function parse_args(args, valued, flags = String[]; multi = String[])
    positional = String[]
    options = Dict{String,Any}()
    i = 1
    while i <= length(args)
        arg = args[i]
        if startswith(arg, "--")
            name, value = occursin('=', arg) ? split(arg[3:end], '='; limit = 2) : (arg[3:end], nothing)
            if name in flags
                value === nothing || fail("--$name takes no value")
                options[name] = true
            elseif name in valued
                if value === nothing
                    i < length(args) || fail("--$name needs a value")
                    value = args[i += 1]
                end
                if name in multi
                    push!(get!(options, name, String[]), String(value))
                else
                    haskey(options, name) && fail("--$name is given twice")
                    options[name] = String(value)
                end
            else
                fail("unknown option --$name")
            end
        else
            push!(positional, arg)
        end
        i += 1
    end
    return positional, options
end

"Seconds between two looks at the queue: `--poll`, or 20 on a cluster and 2 on this machine."
function poll_seconds(options)
    haskey(options, "poll") || return islocal(load_site(need(options, "site"))) ? 2 : 20
    seconds = tryparse(Float64, options["poll"])
    seconds !== nothing && seconds > 0 || fail("--poll takes a number of seconds")
    return seconds
end

function need(options, name)
    haskey(options, name) || fail("--$name is required")
    return options[name]
end

"""
The version of SimLaunch, and the commit when it runs from a git checkout of
its own, as a development copy does; an installed copy has no `.git`.
"""
function version_text()
    text = "SimLaunch $VERSION_STRING"
    top = git(PKGROOT, "rev-parse", "--show-toplevel")
    top !== nothing && realpath(top) == realpath(PKGROOT) || return text
    prov = provenance(PKGROOT)
    return string(text, ", from the checkout $PKGROOT at ", prov.sha[1:10], prov.dirty ? ", with uncommitted changes" : "")
end

function command(args)
    isempty(args) && (print(USAGE); return 0)
    cmd, rest = args[1], args[2:end]
    if cmd in ("help", "--help", "-h")
        print(USAGE)
    elseif cmd == "snapshot"
        pos, opt = parse_args(rest, ["study", "rev", "variant"]; multi = ["variant"])
        length(pos) == 1 || fail("usage: simlaunch snapshot <project> --study <study> [--rev <commit>] [--variant <name>=<directory>]...")
        variants = map(get(opt, "variant", String[])) do v
            occursin('=', v) || fail("--variant takes <name>=<directory>: $(repr(v))")
            name, dir = split(v, '='; limit = 2)
            String(name) => String(dir)
        end
        dest = snapshot(pos[1]; study = need(opt, "study"), rev = get(opt, "rev", nothing), variants)
        snap = load_snapshot(opt["study"])
        println("study $(opt["study"]): $(length(snap["package"])) packages in $dest")
        for p in snap["package"]
            state = !p["git"] ? "not in git" :
                    haskey(p, "rev") ? string(p["sha"][1:10], ", the commit ", p["rev"]) :
                    string(p["sha"][1:10], " ", p["branch"], p["dirty"] ? ", with uncommitted changes" : "")
            println("  $(rpad(p["name"], 28)) $state")
        end
        for v in get(snap, "variant", [])
            println("  variant $(v["name"]): ", join([p["name"] for p in v["package"]], ", "))
        end
    elseif cmd == "prepare"
        pos, opt = parse_args(rest, ["site", "spec"]; multi = ["spec"])
        length(pos) == 1 || fail("usage: simlaunch prepare <study> --site <site> [--spec <spec.toml>]...")
        prepare(pos[1]; site = need(opt, "site"), specs = get(opt, "spec", String[]))
    elseif cmd in ("submit", "resubmit")
        pos, opt = parse_args(rest, ["site", "queue", "run", "chain", "poll"], cmd == "submit" ? ["dry-run", "wait"] : ["wait"]; multi = ["run"])
        length(pos) == 2 ||
            fail("usage: simlaunch $cmd <study> <spec.toml> --site <site> [--queue <queue>] [--run <label>]... [--chain <n>] ",
                 "[--wait [--poll <seconds>]]", cmd == "submit" ? " [--dry-run]" : "")
        chain = tryparse(Int, get(opt, "chain", "1"))
        chain === nothing && fail("--chain takes a number of jobs")
        kw = (; site = need(opt, "site"), queue = get(opt, "queue", nothing), only_runs = get(opt, "run", String[]), chain)
        dry = get(opt, "dry-run", false)
        dry && haskey(opt, "wait") && fail("--wait and --dry-run exclude each other")
        cmd == "submit" ? submit(pos[1], pos[2]; kw..., dry_run = dry) : resubmit(pos[1], pos[2]; kw...)
        if haskey(opt, "wait")
            wait_spec(pos[1], pos[2]; site = kw.site, only_runs = kw.only_runs, poll = poll_seconds(opt)) || return NOT_FINISHED
        end
    elseif cmd == "wait"
        pos, opt = parse_args(rest, ["site", "run", "poll"], ["once"]; multi = ["run"])
        length(pos) == 2 || fail("usage: simlaunch wait <study> <spec.toml> --site <site> [--run <label>]... [--poll <seconds> | --once]")
        once = haskey(opt, "once")
        once && haskey(opt, "poll") && fail("--once and --poll exclude each other")
        ended = wait_spec(pos[1], pos[2]; site = need(opt, "site"), only_runs = get(opt, "run", String[]),
                          poll = once ? 0 : poll_seconds(opt), once)
        ended === nothing && return ACTIVE
        ended || return NOT_FINISHED
    elseif cmd == "status"
        pos, opt = parse_args(rest, ["site"])
        isempty(pos) && fail("usage: simlaunch status <study>... [--site <site>]")
        status(pos; site = get(opt, "site", nothing))
    elseif cmd == "fetch"
        pos, opt = parse_args(rest, ["site", "run", "max-size", "to"], ["with-checkpoints"]; multi = ["run"])
        length(pos) == 1 || fail("usage: simlaunch fetch <study> [--site <site>] [--run <run>]... [--with-checkpoints] [--max-size <size>] [--to <directory>]")
        fetch(pos[1]; site = get(opt, "site", nothing), runs = get(opt, "run", String[]),
              with_checkpoints = get(opt, "with-checkpoints", false), max_size = get(opt, "max-size", "100M"),
              to = get(opt, "to", nothing))
    elseif cmd == "usage"
        pos, opt = parse_args(rest, ["site"], ["measure"])
        length(pos) == 1 || fail("usage: simlaunch usage <study> [--site <site>] [--measure]")
        usage(pos[1]; site = get(opt, "site", nothing), measure = get(opt, "measure", false))
    elseif cmd == "clean"
        pos, opt = parse_args(rest, ["site", "run"], ["old-checkpoints", "yes"]; multi = ["run"])
        length(pos) == 1 || fail("usage: simlaunch clean <study> --site <site> [--old-checkpoints [--run <run>]...] [--yes]")
        clean(pos[1]; site = need(opt, "site"), old_checkpoints = get(opt, "old-checkpoints", false),
              runs = get(opt, "run", String[]), yes = get(opt, "yes", false))
    elseif cmd == "cancel"
        pos, opt = parse_args(rest, ["site", "message", "poll"])
        length(pos) == 2 || fail("usage: simlaunch cancel <study> <spec.toml> --site <site> [--message <text>] [--poll <seconds>]")
        cancel(pos[1], pos[2]; site = need(opt, "site"), message = get(opt, "message", ""), poll = poll_seconds(opt))
    elseif cmd == "combine"
        pos, opt = parse_args(rest, ["site", "run"]; multi = ["run"])
        length(pos) == 2 || fail("usage: simlaunch combine <study> <spec.toml> --site <site> [--run <label>]...")
        combine(pos[1], pos[2]; site = need(opt, "site"), only_runs = get(opt, "run", String[]))
    elseif cmd == "after"
        pos, opt = parse_args(rest, ["site", "run"], ["checkout"]; multi = ["run"])
        length(pos) == 2 || fail("usage: simlaunch after <study> <spec.toml> --site <site> [--run <label>]... [--checkout]")
        after(pos[1], pos[2]; site = need(opt, "site"), only_runs = get(opt, "run", String[]),
              checkout = get(opt, "checkout", false))
    elseif cmd == "check-restart"
        pos, opt = parse_args(rest, ["site", "run"]; multi = ["run"])
        length(pos) == 2 || fail("usage: simlaunch check-restart <study> <spec.toml> --site <site> [--run <label>]...")
        check_restart(pos[1], pos[2]; site = need(opt, "site"), only_runs = get(opt, "run", String[])) || return NOT_FINISHED
    elseif cmd == "sites"
        for name in known_sites()
            found = read_profile(name)
            println(rpad(name, 16), join(found[2], ", on top of "))
        end
    elseif cmd in ("version", "--version")
        isempty(rest) || fail("usage: simlaunch version")
        println(version_text())
    elseif cmd == "studies"
        isdir(cache_root()) && foreach(println, sort!(filter(d -> isfile(joinpath(cache_root(), d, "snapshot.toml")),
                                                             readdir(cache_root()))))
    else
        fail("unknown command $(repr(cmd)); try `simlaunch help`")
    end
    return 0
end

function (@main)(args)
    try
        return command(args)
    catch err
        # the reader of the output has gone, as in `simlaunch sites | head -1`
        err isa Base.IOError && err.code == Base.UV_EPIPE && return 0
        err isa InterruptException && rethrow()
        if err isa UserError
            println(stderr, "simlaunch: ", err.msg)
        else
            # a defect of simlaunch, or something it did not foresee: the whole story, and still an error
            print(stderr, "simlaunch: ")
            showerror(stderr, err, catch_backtrace())
            println(stderr)
        end
        return ERROR
    end
end
