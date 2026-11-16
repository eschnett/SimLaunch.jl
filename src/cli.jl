# The command line.

const USAGE = """
    simlaunch: run Julia projects locally and on clusters

    Usage:
      simlaunch snapshot <project> --study <study>
          Copy the project and the packages it takes by path, as the study <study>.
      simlaunch prepare <study> --site <site> [--spec <spec.toml>]...
          Copy the study to the site, instantiate and precompile it there.
      simlaunch submit <study> <spec.toml> --site <site> [--queue <queue>] [--run <label>]... [--dry-run]
          Generate the batch script and submit it. --dry-run only prints it.
          --run submits only the named runs, for a site that cannot hold them all.
      simlaunch sites
          List the site profiles.
      simlaunch studies
          List the studies in the cache.

    Snapshots are kept in ~/.cache/simlaunch (or \$SIMLAUNCH_CACHE).
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

function need(options, name)
    haskey(options, name) || fail("--$name is required")
    return options[name]
end

function command(args)
    isempty(args) && (print(USAGE); return 0)
    cmd, rest = args[1], args[2:end]
    if cmd in ("help", "--help", "-h")
        print(USAGE)
    elseif cmd == "snapshot"
        pos, opt = parse_args(rest, ["study"])
        length(pos) == 1 || fail("usage: simlaunch snapshot <project> --study <study>")
        dest = snapshot(pos[1]; study = need(opt, "study"))
        snap = load_snapshot(opt["study"])
        println("study $(opt["study"]): $(length(snap["package"])) packages in $dest")
        for p in snap["package"]
            state = !p["git"] ? "not in git" :
                    string(p["sha"][1:10], " ", p["branch"], p["dirty"] ? ", with uncommitted changes" : "")
            println("  $(rpad(p["name"], 28)) $state")
        end
    elseif cmd == "prepare"
        pos, opt = parse_args(rest, ["site", "spec"]; multi = ["spec"])
        length(pos) == 1 || fail("usage: simlaunch prepare <study> --site <site> [--spec <spec.toml>]...")
        prepare(pos[1]; site = need(opt, "site"), specs = get(opt, "spec", String[]))
    elseif cmd == "submit"
        pos, opt = parse_args(rest, ["site", "queue", "run"], ["dry-run"]; multi = ["run"])
        length(pos) == 2 ||
            fail("usage: simlaunch submit <study> <spec.toml> --site <site> [--queue <queue>] [--run <label>]... [--dry-run]")
        submit(pos[1], pos[2]; site = need(opt, "site"), queue = get(opt, "queue", nothing),
               only_runs = get(opt, "run", String[]), dry_run = get(opt, "dry-run", false))
    elseif cmd == "sites"
        foreach(println, known_sites())
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
        err isa UserError || rethrow()
        println(stderr, "simlaunch: ", err.msg)
        return 1
    end
end
