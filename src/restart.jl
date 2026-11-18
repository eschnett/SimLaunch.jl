# Restart chains: `resubmit`, and `check-restart`, which tests a driver
# against the restart contract (PLAN.md, "Immutable outputs and restarts").

"The same job with other runs, and with fields replaced."
function with_runs(job::Job, runs; kw...)
    return Job((f === :runs ? runs : get(kw, f, getfield(job, f)) for f in fieldnames(Job))...)
end

relabel(r::Run, label; kw...) =
    Run((f === :label ? label : get(kw, f, getfield(r, f)) for f in fieldnames(Run))...)

"""
    resubmit(study, spec; site, chain = 1, only_runs = [])

Submit the next job of a run with checkpoints: it continues from the newest
complete checkpoint of the earlier jobs, in a directory of its own.
"""
function resubmit(study::AbstractString, spec::AbstractString; site::AbstractString, kw...)
    s = load_site(site)
    job = only(load_jobs(study, s, [spec]; only_runs = get(kw, :only_runs, String[])))
    job.checkpoints || fail("$spec has no checkpoints: there is nothing to continue. `simlaunch submit` runs it again, in a new directory.")
    check_connection(s)
    scratch = study_scratch(s, study)
    started = strip(readsite(s, "cd $(q(scratch)) 2>/dev/null || exit 0; ls -d " *
                                join(["$(q("$(job.name)-$(r.label)"))/[0-9m]*" for r in job.runs], " ") *
                                " 2>/dev/null | head -n 1"))
    isempty(started) && fail("no job of spec $(job.name) has run on $(s.name) yet; start it with `simlaunch submit`")
    return submit(study, spec; site, kw...)
end

"The status in a run's SimWatch file on the site; empty if there is none."
function run_status(site::Site, study, run)
    text = readsite(site, "cat " * q(joinpath(study_scratch(site, study), run, "simwatch.toml")) * " 2>/dev/null || true")
    t = try TOML.parse(text) catch; Dict{String,Any}() end
    return get(t, "status", "")
end

"""
    check_restart(study, spec; site, only_runs = [], poll = 20)

Test the spec's driver against the restart contract, with real jobs on the
site. Each run is done twice under new labels: once in one job, and once
with its first job stopped after its first complete checkpoint and continued
by a second job. The check passes when

- the stopped job's directory is the same afterwards, file by file,
- the second job started from the first one's checkpoint, and
- the project's compare script (`[restart] compare`) accepts the pieces
  against the uninterrupted run. It is run in a job, as
  `<script> <its arguments> <the uninterrupted job's directory> <the chain's directories>`.

The spec should be short: three or four jobs wait in the queue one after
another. Returns whether the check passed.
"""
function check_restart(study::AbstractString, spec::AbstractString; site::AbstractString, only_runs = String[],
                       poll = 20, io::IO = stdout)
    s = load_site(site)
    check_connection(s)
    busy = s.slurm && s.partition ? busy_queues(s, [s.queues; s.gpu === nothing ? Queue[] : s.gpu.queues]) : Set{String}()
    base = only(load_jobs(study, s, [spec]; only_runs, busy))
    base.checkpoints && !base.mutable ||
        fail("$spec: check-restart is for a spec with `checkpoints = true` and without `mutable_restarts`")
    rs = base.restart
    isempty(rs.compare) &&
        fail("$spec: [restart] needs `compare`, a script of the project that tells whether a chain's results ",
             "are those of the uninterrupted run; what \"the same\" means stays with the project")
    scratch = study_scratch(s, study)
    k = stamp()
    whole = with_runs(base, [relabel(r, "$(r.label)-whole-$k") for r in base.runs])
    cut = with_runs(base, [relabel(r, "$(r.label)-cut-$k") for r in base.runs])
    rundir(job, r) = joinpath(scratch, "$(job.name)-$(r.label)")
    statuses(job) = [run_status(s, study, "$(job.name)-$(r.label)") for r in job.runs]
    step(text) = println(io, "check-restart: ", text)
    ok = true
    problem(text) = (ok = false; println(io, "check-restart: FAILED: ", text))

    # 1. uninterrupted
    id = submit_job(whole, spec; successor = false, io = devnull)
    step("job $id runs $(length(whole.runs)) run$(length(whole.runs) == 1 ? "" : "s") without interruption")
    wait_ended(s, study, base.name, id; poll)
    all(==("finished"), statuses(whole)) ||
        fail("the uninterrupted run did not finish in one job (", join(statuses(whole), ", "),
             "); see $(log_file(whole, id)). Make the spec short enough for one job.")

    # 2. the same, stopped after the first complete checkpoint
    id1 = submit_job(cut, spec; successor = false, io = devnull)
    step("job $id1 runs them again, to be stopped after the first checkpoint")
    complete = join(["! -name $(q(t))" for t in rs.temporary], " ")
    probe = "n=0; for d in " * join([q(rundir(cut, r)) for r in cut.runs], " ") * "; do " *
            "if [ -n \"\$(find \"\$d\"/001-*/ck -mindepth 1 -maxdepth 1 $complete 2>/dev/null | head -n 1)\" ]; then n=\$((n + 1)); fi; done; echo \$n"
    while true
        have = parse(Int, strip(readsite(s, probe)))
        have == length(cut.runs) && break
        id1 in active_jobs(s, study, base.name) ||
            fail("job $id1 ended before $(length(cut.runs) == 1 ? "its run" : "all its runs") had a complete checkpoint ",
                 "($have of $(length(cut.runs))): the driver wrote none, or under a temporary name only, or the run is too short. ",
                 "See $(log_file(cut, id1)).")
        sleep(poll)
    end
    cancel_job(s, study, base.name, id1)
    wait_ended(s, study, base.name, id1; poll)
    sleep(2)                                           # its exit trap
    all(==("finished"), statuses(cut)) &&
        fail("job $id1 finished before it could be stopped: the run is too short to test a restart")
    sums = "cd $(q(scratch)) && for d in " * join([q(basename(rundir(cut, r))) for r in cut.runs], " ") * "; do " *
           "find \"\$d\"/001-* | LC_ALL=C sort; find \"\$d\"/001-* -type f -exec cksum {} + | LC_ALL=C sort -k3; done"
    before = readsite(s, sums)
    leftovers = strip(readsite(s, "cd $(q(scratch)) && find " * join([q(basename(rundir(cut, r))) * "/001-*/ck" for r in cut.runs], " ") *
                                  " -mindepth 1 -maxdepth 1 \\( " * join(["-name $(q(t))" for t in rs.temporary], " -o ") * " \\) 2>/dev/null | wc -l"))
    step("job $id1 stopped; its directory holds $(count(==('\n'), before) ÷ 2) files, $leftovers of them unfinished checkpoints")

    # 3. continue until the runs have finished
    ids = [id1]
    for attempt in 1:5
        id2 = submit_job(cut, spec; successor = false, io = devnull)
        push!(ids, id2)
        step("job $id2 continues")
        wait_ended(s, study, base.name, id2; poll)
        all(==("finished"), statuses(cut)) && break
        any(==("failed"), statuses(cut)) &&
            fail("the continued run failed in job $id2; see $(log_file(cut, id2))")
        attempt == 5 && fail("the continued run has not finished after 5 more jobs")
    end
    after = readsite(s, sums)
    before == after ? step("the stopped job's directory is unchanged") :
                      problem("the stopped job's directory changed after it had ended; a job writes into its own directory only")
    log = readsite(s, "cat " * q(log_file(cut, ids[2])) * " 2>/dev/null || true")
    for r in cut.runs
        occursin("run $(r.label): continues from", log) ||
            problem("run $(r.label) did not start from the stopped job's checkpoint")
    end
    leftovers == "0" && step("note: the stopped job left no unfinished checkpoint, so that a restart ignores them was not tested")

    # 4. the project's own comparison, in a job
    dirs(job, r) = split(readsite(s, "ls -d $(q(rundir(job, r)))/[0-9][0-9][0-9]-*"), '\n'; keepempty = false)
    compare = with_runs(base, [relabel(r, "$(r.label)-compare-$k"; cmd = [rs.compare; dirs(whole, w); dirs(cut, c)],
                                       ranks = 0, nodes = 1, placement = "", prefix = String[], launcher_args = String[])
                               for (r, w, c) in zip(base.runs, whole.runs, cut.runs)];
                        checkpoints = false, restart = nothing, after = "", tasks = 1, nodes = 1)
    idc = submit_job(compare, spec; io = devnull)
    step("job $idc compares the results with $(first(rs.compare))")
    wait_ended(s, study, base.name, idc; poll)
    for (r, st) in zip(compare.runs, statuses(compare))
        st == "finished" ||
            problem("the comparison of $(r.label) ended as $(repr(st)); its output is in $(joinpath(scratch, "$(base.name)-$(r.label)"))")
    end
    println(io, ok ? "check-restart: passed" : "check-restart: failed")
    return ok
end
