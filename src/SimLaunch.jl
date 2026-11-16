"""
SimLaunch: a run tool for local and cluster jobs. See `PLAN.md` for the
design. The tool runs on the laptop; on a site it leaves plain files.
"""
module SimLaunch

using Dates
using TOML

const PKGROOT = dirname(@__DIR__)
const VERSION_STRING = "0.1.0"

"An error the user can fix; printed without a stack trace."
struct UserError <: Exception
    msg::String
end
fail(msg...) = throw(UserError(string(msg...)))

"Where snapshots are kept on the laptop."
cache_root() = get(ENV, "SIMLAUNCH_CACHE", joinpath(homedir(), ".cache", "simlaunch"))

"Where the site profiles are."
sites_dir() = get(ENV, "SIMLAUNCH_SITES", joinpath(PKGROOT, "sites"))

const NAME_RE = r"^[A-Za-z0-9][A-Za-z0-9_.-]*$"

"Names become directory names and go into shell scripts: keep them plain."
function checkname(what, name)
    name isa AbstractString && occursin(NAME_RE, name) ||
        fail("$what must consist of letters, digits, '_', '.' and '-', and start with a letter or digit: $(repr(name))")
    return String(name)
end

"Seconds in a Slurm time limit: `[D-]HH:MM:SS`, `MM:SS` or `MM`."
function parse_time(str)
    str isa AbstractString || fail("a time limit must be a string such as \"3:00:00\": $(repr(str))")
    m = match(r"^(?:(\d+)-)?(\d+)(?::(\d+))?(?::(\d+))?$", str)
    m === nothing && fail("cannot read the time limit $(repr(str)); use [D-]HH:MM:SS, MM:SS or MM")
    days = m[1] === nothing ? 0 : parse(Int, m[1])
    parts = [parse(Int, p) for p in (m[2], m[3], m[4]) if p !== nothing]
    if m[1] !== nothing
        # D-HH[:MM[:SS]]
        h, mi, s = (parts..., 0, 0)[1:3]
    elseif length(parts) == 3
        h, mi, s = parts
    elseif length(parts) == 2
        h, mi, s = 0, parts[1], parts[2]
    else
        h, mi, s = 0, parts[1], 0
    end
    return ((days * 24 + h) * 60 + mi) * 60 + s
end

include("sites.jl")
include("snapshot.jl")
include("spec.jl")
include("generate.jl")
include("actions.jl")
include("manage.jl")
include("restart.jl")
include("cli.jl")

end # module SimLaunch
