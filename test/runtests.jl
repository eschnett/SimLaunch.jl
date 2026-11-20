using SimLaunch
using SimLaunch: UserError, parse_time, load_site, load_spec, load_snapshot, resolve, generate, snapshot,
                 prepare, submit, study_scratch, study_code, combos, combo_line, lock_dir, manifest_versions,
                 resubmit, status, fetch, usage, combine, check_restart, wait_spec, after, cancel
using Test
using TOML

# A toy project with a sibling package taken by path, in a git repository
# with an uncommitted change.
function make_project(root)
    toy, dep = joinpath(root, "Toy"), joinpath(root, "ToyDep")
    mkpath(joinpath(toy, "src")); mkpath(joinpath(toy, "examples")); mkpath(joinpath(dep, "src"))
    write(joinpath(dep, "Project.toml"), """
          name = "ToyDep"
          uuid = "11111111-1111-4111-8111-111111111111"
          version = "0.1.0"
          """)
    write(joinpath(dep, "src", "ToyDep.jl"), "module ToyDep\ntwice(x) = 2x\nend\n")
    write(joinpath(toy, "Project.toml"), """
          name = "Toy"
          uuid = "22222222-2222-4222-8222-222222222222"
          version = "0.1.0"

          [deps]
          ToyDep = "11111111-1111-4111-8111-111111111111"

          [sources]
          ToyDep = {path = "../ToyDep"}
          """)
    write(joinpath(toy, "src", "Toy.jl"), "module Toy\nusing ToyDep\nanswer(x) = ToyDep.twice(x) + 1\nend\n")
    write(joinpath(toy, "examples", "hello.jl"), """
          using Toy
          n = parse(Int, split(ARGS[1], "=")[2])
          println("answer = ", Toy.answer(n), ", threads = ", Threads.nthreads(), ", var = ", get(ENV, "TOYVAR", ""))
          write("result.csv", "n,answer\\n\$n,\$(Toy.answer(n))\\n")
          length(ARGS) > 1 && ARGS[2] == "fail" && exit(7)
          length(ARGS) > 1 && ARGS[2] == "sleep" && sleep(600)
          """)
    # a driver that follows the restart contract: it counts, and checkpoints after every step
    write(joinpath(toy, "examples", "count.jl"), """
          using Toy
          opts = Dict(String.(split(a, "=")) for a in ARGS)
          steps, delay = parse(Int, opts["steps"]), parse(Float64, get(opts, "delay", "0.3"))
          ck, from = get(opts, "checkpoint", nothing), get(opts, "restart_from", nothing)
          walltime = parse(Float64, get(opts, "walltime", "Inf"))
          t0 = time()
          first, total = 1, 0
          if from !== nothing
              done = maximum(parse(Int, f[6:end]) for f in readdir(from) if startswith(f, "step-") && !endswith(f, ".tmp"))
              first, total = done + 1, parse(Int, read(joinpath(from, "step-\$done"), String))
          end
          open("count.csv", "w") do io
              println(io, "step,total")
              for k in first:steps
                  sleep(delay)
                  global total += Toy.answer(k)
                  println(io, k, ",", total); flush(io)
                  if ck !== nothing                     # written under a temporary name, then renamed
                      write(joinpath(ck, "step-\$k.tmp"), string(total))
                      mv(joinpath(ck, "step-\$k.tmp"), joinpath(ck, "step-\$k"))
                      rm(joinpath(ck, "step-\$(k - 1)"); force = true)
                  end
                  time() - t0 > walltime && k < steps && exit(3)
              end
          end
          """)
    # the project's own comparison: the pieces of a chain against one uninterrupted job
    write(joinpath(toy, "examples", "compare.jl"), """
          rows(dir) = Dict(parse(Int, a) => parse(Int, b) for (a, b) in split.(readlines(joinpath(dir, "count.csv"))[2:end], ","))
          whole, pieces = rows(ARGS[1]), merge(rows.(ARGS[2:end])...)
          println("whole: ", length(whole), " steps; chain: ", length(pieces), " steps in ", length(ARGS) - 1, " jobs")
          whole == pieces || exit(1)
          """)
    write(joinpath(toy, "examples", "combine.jl"), """
          open("combined.csv", "w") do io
              for dir in ARGS, line in readlines(joinpath(dir, "count.csv"))[2:end]
                  println(io, line)
              end
          end
          """)
    write(joinpath(toy, "Manifest.toml"), "# must not be copied\n")
    write(joinpath(toy, "backup.jl~"), "")
    run(`git -C $toy init -q`)
    run(`git -C $toy add -A`)
    run(`git -C $toy -c user.name=test -c user.email=test@example.org commit -q -m init`)
    open(io -> println(io, "# an uncommitted change"), joinpath(toy, "src", "Toy.jl"), "a")
    return toy
end

spec_text(runs; top = "", locals = "mode = \"sequential\"") = """
    name = "hello"
    $top

    [site.local]
    $locals

    [site.trillium]
    time = "3:00:00"
    resources = { nodes = 1 }
    mode = "parallel"
    threads = 32

    $runs
    """

const RUNS = """
    [[run]]
    label = "n3"
    cmd = "examples/hello.jl n=3"
    vars = { TOYVAR = "a b" }

    [[run]]
    label = "n5"
    cmd = "examples/hello.jl n=5"
    julia_args = ["--check-bounds=yes"]
    """

"Wait until the job's runs have all ended; returns their SimWatch tables."
function wait_for(scratch, names; timeout = 120)
    t0 = time()
    while time() - t0 < timeout
        tables = [try TOML.parsefile(joinpath(scratch, n, "simwatch.toml")) catch; nothing end for n in names]
        all(t -> t !== nothing && t["status"] in ("finished", "failed", "cancelled"), tables) && return tables
        sleep(0.5)
    end
    error("the runs did not end within $timeout s")
end

@testset "SimLaunch" begin
    root = mktempdir()
    toy = make_project(joinpath(root, "work"))
    sites = mkpath(joinpath(root, "sites"))
    write(joinpath(sites, "local.toml"), """
          name = "local"
          [paths]
          code = "$(joinpath(root, "site", "code"))"
          scratch = "$(joinpath(root, "site", "scratch"))"
          [julia]
          bin = "$(joinpath(Sys.BINDIR, "julia"))"
          depot = "$(joinpath(root, "depot"))"
          registry_update = false
          [julia.versions]                 # a made-up version that this Julia stands in for
          "9.9" = "$(joinpath(Sys.BINDIR, "julia"))"
          [mpi]
          default = "mpiabi"
          [mpi.mpiabi]
          binary = "MPIABI_jll"
          launcher = "mpiexec"
          """)
    # a cluster that does not exist, and the package's profiles with a user's part filled in
    cp(joinpath(@__DIR__, "sites", "kepler.toml"), joinpath(sites, "kepler.toml"))
    for name in ("trillium", "trillium-gpu", "nibi", "fir")
        write(joinpath(sites, "$name.toml"), """
              base = "$name"
              [paths]
              code = "/home/user/studies"
              scratch = "/scratch/user/studies"
              [slurm]
              account = "def-user"
              [mpi]
              default = "mpiabi"
              [mpi.mpiabi]
              julia = "~/julia-$name/bin/julia"
              [mpi.mpiabi.preferences]
              library_names = ["/home/user/openmpi-mpi-abi/lib64/libmpi_abi.so"]
              mpiexec = "/home/user/openmpi-mpi-abi/bin/mpiexec"
              """)
    end
    # a Slurm site on this machine, with the stand-ins of test/fakeslurm for sbatch and squeue
    write(joinpath(sites, "cluster.toml"), """
          name = "cluster"
          [paths]
          code = "$(joinpath(root, "cluster", "code"))"
          scratch = "$(joinpath(root, "cluster", "scratch"))"
          [[slurm.nodes]]
          name = "cpu"
          cores = 4
          header = ["--exclusive"]
          arch = "cpu"
          queues = [{ partition = "cpuq", max_time = "1:00:00" }, { partition = "preq", max_time = "1:00:00", preempt = true, prefer = true }]
          [[slurm.nodes]]
          name = "gpu"
          gpus = { request = "--gres=gpu:%d", cores = 2, mem = "8G", max = 2 }
          arch = "gpu"
          queues = [{ partition = "gpuq", max_time = "1:00:00", max_gpus = 1 }]
          [julia]
          bin = "$(joinpath(Sys.BINDIR, "julia"))"
          depot = "$(joinpath(root, "depot"))"
          registry_update = false
          [arch]                           # two kinds of node, and a login node that is neither
          cpu = "native"
          gpu = "native"
          """)
    # an environment kind that needs no network: the project and a standard library
    SimLaunch.ENV_KINDS["dates"] = (packages = ["Dates"], warm = "using Dates; println(\"warm: \", Dates.today())")
    spec(text) = (f = tempname(root) * ".toml"; write(f, text); f)

    withenv("SIMLAUNCH_CACHE" => joinpath(root, "cache"), "SIMLAUNCH_SITES" => sites,
            "FAKESLURM" => joinpath(root, "fakeslurm"),
            "PATH" => joinpath(@__DIR__, "fakeslurm") * ":" * ENV["PATH"]) do
        @testset "time limits" begin
            @test parse_time("3:00:00") == 10800
            @test parse_time("1-00:00:00") == 86400
            @test parse_time("90") == 5400
            @test parse_time("10:30") == 630
            @test_throws UserError parse_time("soon")
        end

        @testset "version" begin
            @test SimLaunch.VERSION_STRING == string(pkgversion(SimLaunch))         # from Project.toml, not a copy
            text = SimLaunch.version_text()
            @test startswith(text, "SimLaunch $(pkgversion(SimLaunch))")
            # a git checkout of the package, as here and in CI, also names its commit
            isdir(joinpath(pkgdir(SimLaunch), ".git")) &&
                @test occursin(r"from the checkout .* at [0-9a-f]{10}", text)
            @test_throws "usage: simlaunch version" SimLaunch.command(["version", "x"])
        end

        @testset "snapshot" begin
            @test_throws "one line" snapshot(toy; study = "toy", note = "a\nb")
            dest = snapshot(toy; study = "toy", note = "the toy study \"T\"")
            @test isfile(joinpath(dest, "src", "Toy", "src", "Toy.jl"))
            @test isfile(joinpath(dest, "src", "ToyDep", "src", "ToyDep.jl"))     # relative position kept
            @test !ispath(joinpath(dest, "src", "Toy", "Manifest.toml"))          # manifests are not copied
            @test !ispath(joinpath(dest, "src", "Toy", "backup.jl~"))
            @test !ispath(joinpath(dest, "src", "Toy", ".git"))
            snap = load_snapshot("toy")
            @test snap["project"] == "Toy"
            @test snap["note"] == "the toy study \"T\"" && snap["session"] == get(ENV, "CLAUDE_CODE_SESSION_ID", "")
            pkgs = Dict(p["name"] => p for p in snap["package"])
            @test pkgs["Toy"]["dirty"] && length(pkgs["Toy"]["sha"]) == 40
            @test occursin("an uncommitted change", read(joinpath(dest, pkgs["Toy"]["diff"]), String))
            @test !pkgs["ToyDep"]["git"]
            @test_throws UserError snapshot(toy; study = "toy")                    # a study is never rewritten
            @test_throws UserError snapshot(toy; study = "bad name")
        end

        @testset "snapshot of a commit" begin
            # the commit, not the working tree: not its uncommitted change, nor an untracked file
            write(joinpath(toy, "untracked.jl"), "")
            dest = snapshot(toy; study = "toy-rev", rev = "HEAD")
            rm(joinpath(toy, "untracked.jl"))
            @test !occursin("an uncommitted change", read(joinpath(dest, "src", "Toy", "src", "Toy.jl"), String))
            @test !ispath(joinpath(dest, "src", "Toy", "untracked.jl"))
            @test !ispath(joinpath(dest, "src", "Toy", "Manifest.toml")) && !ispath(joinpath(dest, "src", "Toy", "backup.jl~"))
            @test isfile(joinpath(dest, "src", "ToyDep", "src", "ToyDep.jl"))    # outside the repository: its working tree
            pkgs = Dict(p["name"] => p for p in load_snapshot("toy-rev")["package"])
            @test pkgs["Toy"]["sha"] == readchomp(`git -C $toy rev-parse HEAD`) && pkgs["Toy"]["rev"] == "HEAD"
            @test !pkgs["Toy"]["dirty"] && !haskey(pkgs["Toy"], "diff") && pkgs["Toy"]["path"] == realpath(toy)
            @test !haskey(pkgs["ToyDep"], "rev")
            @test_throws "has no commit" snapshot(toy; study = "toy-rev2", rev = "nope")
            @test_throws "is not in one" snapshot(joinpath(dirname(toy), "ToyDep"); study = "toy-rev2", rev = "HEAD")
            @test !ispath(joinpath(ENV["SIMLAUNCH_CACHE"], "toy-rev2"))
            # a path package of the repository that the working tree no longer has is copied from the commit
            repo = mkpath(joinpath(root, "repo"))
            outer, inner = mkpath(joinpath(repo, "Outer", "src")), mkpath(joinpath(repo, "Outer", "lib", "Inner", "src"))
            write(joinpath(repo, "Outer", "Project.toml"), """
                  name = "Outer"
                  uuid = "44444444-4444-4444-8444-444444444444"
                  [deps]
                  Inner = "55555555-5555-4555-8555-555555555555"
                  [sources]
                  Inner = {path = "lib/Inner"}
                  """)
            write(joinpath(outer, "Outer.jl"), "module Outer end\n")
            write(joinpath(dirname(inner), "Project.toml"), "name = \"Inner\"\nuuid = \"55555555-5555-4555-8555-555555555555\"\n")
            write(joinpath(inner, "Inner.jl"), "module Inner end\n")
            run(`git -C $repo init -q`); run(`git -C $repo add -A`)
            run(`git -C $repo -c user.name=test -c user.email=test@example.org commit -q -m init`)
            rm(joinpath(repo, "Outer", "lib"); recursive = true)
            @test_throws "does not exist" snapshot(joinpath(repo, "Outer"); study = "outer")
            out = mktemp() do path, io
                redirect_stdout(io) do
                    @test SimLaunch.command(["snapshot", joinpath(repo, "Outer"), "--study", "outer", "--rev", "HEAD"]) == 0
                end
                close(io); read(path, String)
            end
            dest = joinpath(ENV["SIMLAUNCH_CACHE"], "outer")
            @test isfile(joinpath(dest, "src", "Outer", "lib", "Inner", "src", "Inner.jl"))
            @test occursin(r"Outer\s+[0-9a-f]{10}, the commit HEAD", out)
        end

        @testset "specs" begin
            trillium, loc = load_site("trillium"), load_site("local")
            job(text, site; kw...) = resolve(load_spec(spec(text)), site; study = "toy", project = "Toy", kw...)
            j = job(spec_text(RUNS), trillium)
            @test j.mode === :parallel && j.time == 10800 && j.queue.partition == "compute"
            @test [r.threads for r in j.runs] == [32, 32]
            @test j.runs[2].julia_args == ["--check-bounds=yes"]
            j = job(spec_text(RUNS), loc)
            @test j.mode === :sequential && j.time === nothing && j.queue === nothing
            @test all(r -> r.threads == Sys.CPU_THREADS, j.runs)                  # sequential: all the cores
            # parallel default: the cores divided by the runs
            j = job(spec_text(RUNS; locals = "mode = \"parallel\""), loc)
            @test all(r -> r.threads == max(1, Sys.CPU_THREADS ÷ 2), j.runs)
            # a threads list is a scan
            j = job(spec_text("[[run]]\nlabel = \"s\"\ncmd = \"examples/hello.jl n=1\"\nthreads = [1, 2]\n"), loc)
            @test [r.label for r in j.runs] == ["s-t1", "s-t2"] && [r.threads for r in j.runs] == [1, 2]
            # only some of the runs
            @test [r.label for r in job(spec_text(RUNS), loc; only_runs = ["n5"]).runs] == ["n5"]
            @test_throws "no run" job(spec_text(RUNS), loc; only_runs = ["n7"])
            # a scan's label names all its runs; on a node too small for some of its counts, those are left out
            scans = "[[run]]\nlabel = \"s\"\ncmd = \"examples/hello.jl n=1\"\nthreads = [1, 96, 500]\n\n" *
                    "[[run]]\nlabel = \"one\"\ncmd = \"examples/hello.jl n=1\"\nthreads = 1\n"
            j = job(spec_text(scans), trillium)
            @test [r.label for r in j.runs] == ["s-t1", "s-t96", "one"]
            @test startswith(only(j.left_out), "s-t500 asks for 500 threads, but ") && endswith(only(j.left_out), " 192 cores")
            out = IOBuffer()
            SimLaunch.describe(out, j)
            @test occursin("left out on trillium, spec hello: run s-t500 asks for 500 threads", String(take!(out)))
            @test [r.label for r in job(spec_text(scans), trillium; only_runs = ["s"]).runs] == ["s-t1", "s-t96"]
            j = job(spec_text(scans), trillium; only_runs = ["s-t96", "one"])
            @test [r.label for r in j.runs] == ["s-t96", "one"] && isempty(j.left_out)
            @test_throws "run s-t500 asks for 500 threads" job(spec_text(scans), trillium; only_runs = ["s-t500"])
            @test_throws "none of the runs of scan s fit" job(spec_text(replace(scans, "[1, 96, 500]" => "[400, 500]")), trillium)
            @test_throws "run one asks for 500 threads" job(spec_text(replace(scans, "threads = 1\n" => "threads = 500\n")), trillium)
            # a run's Julia version: juliaup's channel, or the binary the profile names for it
            versions = """
                       [[run]]
                       label = "new"
                       cmd = "examples/hello.jl n=1"

                       [[run]]
                       label = "floor"
                       cmd = "examples/hello.jl n=1"
                       julia = "1.13"
                       env = "test"

                       [[run]]
                       label = "site"
                       cmd = "examples/hello.jl n=1"
                       julia = ""
                       """
            j = job(spec_text(versions; top = "julia = \"+1.14\""), trillium)
            @test [r.julia for r in j.runs] == ["1.14", "1.13", ""]
            @test [r.envdir for r in j.runs] == ["envs/default-julia1.14", "envs/default-test-julia1.13", "src/Toy"]
            @test [c.julia for c in SimLaunch.combos(j)] == ["1.14", "1.13", ""]
            script = generate(j)
            @test occursin("\"\$JULIA\" +1.14 -t 32", script) && occursin("\"\$JULIA\" +1.13 -t 32", script)
            @test occursin("\"\$JULIA\" +1.14 --startup-file=no --project=\"\$CODE\"/envs/default-julia1.14 \"\$TOOLS\"/check_precompiled.jl", script)
            script = generate(job(spec_text(versions; top = "julia = \"9.9\""), loc))
            @test occursin("$(SimLaunch.shpath(joinpath(Sys.BINDIR, "julia"))) -t", script) && !occursin("+9.9", script)
            @test_throws "is a Julia version" job(spec_text(RUNS; top = "julia = \"1 14\""), loc)
            # a spec's description, else the study's note, for SimWatch
            @test job(spec_text(RUNS), loc; note = "the study").description == "the study"
            @test job(spec_text(RUNS; top = "description = \"weak scaling\""), loc; note = "the study").description == "weak scaling"
            @test_throws "one line of text" job(spec_text(RUNS; top = "description = \"\"\"a\nb\"\"\""), loc)
            # `project` is relative to the study's own project, whatever the folder of its checkout was called
            sub = job(spec_text(RUNS; top = "project = \"coupled\"\nenv = \"test\""), loc)
            @test sub.project == "Toy/coupled" && all(r -> r.envdir == "envs/default-test-coupled", sub.runs)
            sib = job(spec_text(RUNS; top = "project = \"../ToyDep\"\nenv = \"cuda\""), loc)
            @test sib.project == "ToyDep" && all(r -> r.envdir == "envs/default-cuda-ToyDep", sib.runs)
            @test job(spec_text(RUNS), loc).project == "Toy"
            @test_throws "leads out of the study's packages" job(spec_text(RUNS; top = "project = \"..\""), loc)
            @test_throws "leads out of the study's packages" job(spec_text(RUNS; top = "project = \"../..\""), loc)
            @test_throws "has no project at src/Toy/Toy" SimLaunch.load_jobs("toy", loc, [spec(spec_text(RUNS; top = "project = \"Toy\""))])
            @test only(SimLaunch.load_jobs("toy", loc, [spec(spec_text(RUNS; top = "project = \"../ToyDep\""))])).project == "ToyDep"
            # Julia flags reach the prepare script quoted, as they reach the job
            c = only(combos(job(spec_text("[[run]]\nlabel = \"t\"\ncmd = \"examples/hello.jl n=1\"\njulia_args = [\"--trace-compile=a b\"]\n"), loc)))
            text = SimLaunch.prepare_script(loc, "toy", [c])
            @test occursin("'--trace-compile=a b' --startup-file=no", text) && !occursin("echo \"=== precompile", text)
            # unknown keys are refused also in [after], [combine] and another site's table; an unknown site is warned of
            @test_throws "[after]: unknown key `when`" job(spec_text(RUNS) * "\n[after]\ncmd = \"true\"\nwhen = 1\n", loc)
            @test_throws "[combine]: unknown key `args`" job(spec_text(RUNS) * "\n[combine]\ncmd = \"c.jl\"\nargs = []\n", loc)
            @test_throws "[site.trillium]: unknown key `thread`" job(replace(spec_text(RUNS), "threads = 32" => "thread = 32"), loc)
            @test_throws "[site.trillium]: `mem` is not implemented yet" job(replace(spec_text(RUNS), "threads = 32" => "mem = \"8G\""), loc)
            @test_logs (:warn, r"\[site.lcoal\] names a site that has no profile") job(spec_text(RUNS) * "\n[site.lcoal]\nthreads = 1\n", loc)
            # refusals
            many = join(["[[run]]\nlabel = \"r$i\"\ncmd = \"examples/hello.jl n=$i\"\n" for i in 1:7], "\n")
            @test_throws "224 threads" job(spec_text(many), trillium)             # 7 × 32 > 192
            @test_throws "at most 1:00:00" job(spec_text(RUNS), trillium; queue = "debug")
            # the queue is chosen by rule: the first in the profile's order that fits
            short = replace(spec_text(RUNS), "3:00:00" => "0:10:00")
            @test job(short, trillium).queue.partition == "debug"
            @test_throws "no less than 0:15:00" job(short, trillium; busy = Set(["debug"]))   # debug takes one job at a time
            @test job(replace(spec_text(RUNS), "3:00:00" => "0:30:00"), trillium; busy = Set(["debug"])).queue.partition == "compute"
            @test_throws "no queue" job(spec_text(RUNS), trillium; queue = "nonesuch")
            @test_throws "unknown key" job(spec_text(RUNS; top = "tiem = \"1:00:00\""), trillium)
            @test_throws "[restart] table" job(spec_text(RUNS; top = "checkpoints = true"), trillium)
            # a run with ranks that names no recipe gets the site's default; a site without one refuses it
            mspec(extra) = "name = \"m\"\n[site.trillium]\ntime = \"1:00:00\"\n[site.local]\nthreads = 1\n[site.cluster]\ntime = \"0:10:00\"\n" *
                           "[[run]]\nlabel = \"a\"\ncmd = \"examples/hello.jl n=1\"\n" * extra
            r = only(job(mspec("ranks = 8\n"), trillium).runs)
            @test r.mpi == "mpiabi" && r.envdir == "envs/default-mpi-mpiabi" && r.threads == 24
            @test only(job(mspec(""), trillium).runs).mpi == ""                     # no ranks, no MPI
            @test only(job(mspec("mpi = \"default\"\n"), trillium).runs).mpi == "mpiabi"
            @test only(job(mspec("ranks = 8\nmpi = \"jll\"\n"), trillium).runs).mpi == "jll"
            @test only(job(mspec("ranks = 2\n"), loc).runs).mpi == "mpiabi"
            @test load_site("cluster").mpi_default === nothing
            @test_throws "names no default" job(mspec("ranks = 2\n"), load_site("cluster"))
            @test_throws "names no default" job(mspec("mpi = \"default\"\n"), load_site("cluster"))
            @test_throws "runs its own Julia" job(mspec("ranks = 2\njulia = \"1.14\"\n"), trillium)   # its recipe's patched Julia
            @test_throws "no variant" job(spec_text(RUNS * "variant = \"base\"\n"), trillium)
            # a spec written for one site names it, and has no site tables
            one = "name = \"hello\"\nsite = \"kepler\"\ntime = \"1:00:00\"\n" * RUNS
            @test_throws "for site kepler only" job(one, trillium)
            @test job(replace(one, "kepler" => "trillium"), trillium).time == 3600
            @test_throws "no `time`" job(replace(spec_text(RUNS), "time = \"3:00:00\"" => ""), trillium)
            # a spec written in Julia: the value of the file, read as its TOML is
            jl(text) = (f = tempname(root) * ".jl"; write(f, text); f)
            f = jl("""
                   using Printf
                   runs = [(label = @sprintf("n%d%s", n, v), cmd = "examples/hello.jl n=\$n", vars = (TOYVAR = v,))
                           for n in (3, 5), v in ("a", "b")]
                   (name = "hello", site = Dict("trillium" => (time = "3:00:00", mode = "parallel", threads = Int32(32))),
                    run = runs)
                   """)
            same = """
                name = "hello"
                [site.trillium]
                time = "3:00:00"
                mode = "parallel"
                threads = 32
                """ * join(["[[run]]\nlabel = \"n$n$v\"\ncmd = \"examples/hello.jl n=$n\"\nvars = { TOYVAR = \"$v\" }\n"
                            for v in ("a", "b") for n in (3, 5)])
            @test load_spec(f) == TOML.parse(same)
            @test TOML.parse(SimLaunch.spec_toml(f)) == load_spec(f)
            j = resolve(load_spec(f), trillium; study = "toy", project = "Toy", file = f)
            @test [r.label for r in j.runs] == ["n3a", "n5a", "n3b", "n5b"] && j.runs[3].vars == Dict("TOYVAR" => "b")
            @test_throws "is a Symbol" load_spec(jl("(name = \"x\", run = [(label = :a,)])"))
            @test_throws "the spec.run[1].label" load_spec(jl("(name = \"x\", run = [(label = :a,)])"))
            @test_throws "named tuple or a dictionary" load_spec(jl("42"))
            @test_throws "boom" load_spec(jl("error(\"boom\")"))
            @test_throws UserError load_spec(jl("(name = "))
            @test_throws "unknown key" resolve(load_spec(jl("(name = \"x\", tiem = \"1:00\")")), trillium; study = "toy", project = "Toy")
        end

        @testset "the generated script for Trillium" begin
            j = resolve(load_spec(spec(spec_text(RUNS))), load_site("trillium"); study = "toy", project = "Toy")
            script = generate(j)
            reference = joinpath(@__DIR__, "reference", "trillium-hello.sh")
            get(ENV, "SIMLAUNCH_UPDATE_REFERENCE", "") == "1" && write(reference, script)
            @test script == read(reference, String)
            @test success(`bash -n $reference`)
        end

        gpu_spec = """
            name = "gpu"
            [site.kepler]
            time = "0:30:00"
            resources = { gpus = 1 }
            env = "cuda"
            [site.trillium-gpu]
            time = "1:00:00"
            resources = { gpus = 2 }
            env = "cuda"
            [site.nibi]
            time = "3:00:00"
            mode = "parallel"
            threads = 32
            [[run]]
            label = "n3"
            cmd = "examples/hello.jl n=3"
            """
        @testset "architectures" begin
            sym, fir, tri = load_site("kepler"), load_site("fir"), load_site("trillium")
            # kinds of node: the first CPU kind and the first GPU kind are the defaults
            @test [t.name for t in sym.types] == ["amd", "largemem", "intel", "h200"]
            cpu, gpu = SimLaunch.node_type(sym, nothing; gpus = false), SimLaunch.node_type(sym, nothing; gpus = true)
            @test cpu.name == "amd" && cpu.arch == "amd" && gpu.name == "h200" && gpu.arch == "h200" && sym.login_arch == "login"
            @test sym.archs["amd"] == "znver2" && sym.archs["h200"] == "" && sym.archs["intel"] == "skylake-avx512"
            # nodes of one architecture share a depot; the login node compiles for the nodes that have its own
            @test SimLaunch.precompile_where(sym, "amd") == SimLaunch.precompile_where(sym, "h200") == "compute"
            @test SimLaunch.study_depot(sym, "s", "h200") == "/home/user/studies/s/depot-h200"
            @test SimLaunch.precompile_where(fir, "zen5") == "login" && SimLaunch.precompile_where(fir, "zen4") == "compute"
            @test tri.archs == Dict("default" => "") && only(tri.types).arch == "default" && SimLaunch.precompile_where(tri, "default") == "login"
            @test_throws "; it has amd, largemem, intel, h200" SimLaunch.node_type(sym, "arm"; gpus = false)
            @test_throws "the h200 nodes of kepler are GPU nodes" SimLaunch.node_type(sym, "h200"; gpus = false)
            @test_throws "the intel nodes of kepler are CPU nodes" SimLaunch.node_type(sym, "intel"; gpus = true)
            # a job runs on the default kind, or on the kind it names, with that kind's queues, shape and architecture
            big = "name = \"big\"\nsite = \"kepler\"\ntime = \"2:00:00\"\n[[run]]\nlabel = \"a\"\ncmd = \"examples/hello.jl n=1\"\n"
            job(text; kw...) = resolve(TOML.parse(text), sym; study = "toy", project = "Toy", kw...)
            j = job(big)
            @test j.type.name == "amd" && j.queue.partition == "amdq" && SimLaunch.job_arch(j) == "amd" && only(combos(j)).target == "znver2"
            @test occursin("#SBATCH --exclude=cn112\n", generate(j)) && occursin("/toy/depot-amd ", generate(j))
            pre = SimLaunch.precompile_script(sym, "toy", combos(j))
            @test occursin("#SBATCH --partition=amddebugq\n", pre) && occursin("#SBATCH --exclude=cn112\n", pre)
            @test occursin("DEPOT=/home/user/studies/toy/depot-amd\n", pre) && occursin("export JULIA_CPU_TARGET=znver2\n", pre)
            named(t, text = big) = replace(text, "time =" => "node_type = \"$t\"\ntime =")
            j = job(named("largemem"))
            @test j.queue.partition == "largememq" && SimLaunch.job_arch(j) == "zen4c" && only(combos(j)).arch == "zen4c"
            @test only(combos(j)).target == "" && only(combos(j)).type == "largemem"
            @test !occursin("--exclude", generate(j)) && occursin("/toy/depot-zen4c ", generate(j)) && !occursin("export JULIA_CPU_TARGET", generate(j))
            pre = SimLaunch.precompile_script(sym, "toy", combos(j))
            @test occursin("#SBATCH --partition=largememq\n", pre) && !occursin("--exclude", pre) && occursin("#SBATCH --exclusive\n", pre)
            @test occursin("DEPOT=/home/user/studies/toy/depot-zen4c\n", pre)
            @test occursin("node type: largemem\n", sprint(SimLaunch.describe, j))
            # another shape: 40 cores and two NUMA domains
            j = job(named("intel"))
            @test j.queue.partition == "defq" && j.cores == 40 && only(j.runs).threads == 40 && SimLaunch.job_arch(j) == "intel"
            @test occursin("export JULIA_CPU_TARGET=skylake-avx512", generate(j)) && occursin("/toy/depot-intel ", generate(j))
            @test only(job(named("intel", replace(big, "cmd =" => "ranks = 2\nplacement = \"numa\"\ncmd ="))).runs).threads == 20
            @test_throws "names no NUMA domains (`numa` of its largemem nodes)" job(named("largemem", replace(big, "cmd =" => "ranks = 2\nplacement = \"numa\"\ncmd =")))
            # a queue belongs to its kind of node: another kind's is named by its kind
            @test_throws "largememq is a queue of its largemem nodes: give `node_type = " job(big; queue = "largememq")
            @test job(named("largemem"); queue = "largememq").queue.partition == "largememq"
            why = try job(replace(big, "2:00:00" => "30:00:00")); "" catch err; err.msg end
            @test occursin("which no queue of kepler for its amd nodes takes", why) && !occursin("largememq", why)
            @test_throws "at most 1 nodes" job(named("largemem", replace(big, "time =" => "resources = { nodes = 2 }\ntime =")))
            @test_throws "has no kind of node" job(named("arm"))
            # profiles
            head = "name = \"odd\"\n[paths]\ncode = \"/c\"\nscratch = \"/s\"\n[connect]\nhost = \"odd\"\n"
            profile(text; node = "") = (write(joinpath(sites, "odd.toml"), head * "[[slurm.nodes]]\nname = \"n\"\ncores = 4\n" * node * text);
                                        load_site("odd"))
            @test only(profile("").types).arch == "default"
            @test_throws "`precompile_on` is gone" profile("[julia]\nprecompile_on = \"compute\"\n")
            @test_throws "`cpu_target` is gone" profile("[julia]\ncpu_target = \"generic\"\n")
            @test_throws "[julia]: `arch` is gone" profile("[julia]\narch = \"zen\"\n")
            @test_throws "has no [arch] table" profile(""; node = "arch = \"zen\"\n")
            @test_throws "`arch` must name one of the architectures in [arch]: zen" profile("[arch]\nzen = \"znver2\"\n")
            @test_throws "`arch` must name one of the architectures" profile("[arch]\nzen = \"znver2\"\n"; node = "arch = \"zen3\"\n")
            @test_throws "queue p: unknown key `arhc`" profile(""; node = "queues = [{ partition = \"p\", arhc = \"zen\" }]\n")
            @test_throws "queue p: `arch` is gone" profile(""; node = "queues = [{ partition = \"p\", arch = \"zen\" }]\n")
            @test_throws "queue p: `on_request` is gone" profile(""; node = "queues = [{ partition = \"p\", on_request = true }]\n")
            @test_throws "`max_time` is for nodes without queues" profile(""; node = "max_time = \"1:00:00\"\nqueues = [{ partition = \"p\" }]\n")
            @test_throws "node type n: unknown key `cpus`" profile(""; node = "cpus = 4\n")
            @test_throws "two kinds of node in [[slurm.nodes]] have the same name" profile("[[slurm.nodes]]\nname = \"n\"\ncores = 8\n")
            @test_throws "gives its `cores` per GPU" profile("[[slurm.nodes]]\nname = \"g\"\ncores = 8\ngpus = { request = \"--gpus=%d\", cores = 4 }\n")
            @test_throws "needs a %d" profile("[[slurm.nodes]]\nname = \"g\"\ngpus = { request = \"--gpus\", cores = 4 }\n")
            g = profile("[[slurm.nodes]]\nname = \"g\"\ngpus = { request = \"--gpus=%d\", cores = 4 }\nmax_time = \"2:00:00\"\n")
            @test SimLaunch.node_type(g, nothing; gpus = true).gpus.cores == 4 && isempty(SimLaunch.node_type(g, nothing; gpus = true).queues)
            write(joinpath(sites, "odd.toml"), head * "[slurm]\nnode = { cores = 4 }\nqueues = [{ partition = \"p\" }]\n")
            @test_throws "`node`, `queues` belong to the form of a profile before 2026-11-19" load_site("odd")
            write(joinpath(sites, "odd.toml"), head * "[slurm]\naccount = \"a\"\n")
            @test_throws "[slurm] needs its kinds of node" load_site("odd")
            # MPI recipes: a default, and a binary by its name in MPIPreferences
            @test profile("[mpi]\ndefault = \"a\"\n[mpi.a]\nbinary = \"MPIABI_jll\"\n").mpi_default == "a"
            @test_throws "`default` names one of the recipes" profile("[mpi]\ndefault = \"b\"\n[mpi.a]\nbinary = \"jll\"\n")
            @test_throws "`binary` is" profile("[mpi.a]\nbinary = \"mpich\"\n")
            # an mpiexec on several nodes: its implementation, from the binary or given
            several = "launcher = \"mpiexec\"\nmulti_node = true\n"
            @test profile("[mpi.a]\nbinary = \"jll\"\n" * several).mpi["a"].implementation == "mpich"
            @test profile("[mpi.a]\nbinary = \"system\"\nimplementation = \"openmpi\"\n" * several).mpi["a"].implementation == "openmpi"
            @test_throws "needs `implementation`" profile("[mpi.a]\nbinary = \"system\"\n" * several)
            @test_throws "`implementation` is" profile("[mpi.a]\nbinary = \"system\"\nimplementation = \"hydra\"\n" * several)
            @test profile("[mpi.a]\nbinary = \"system\"\nlauncher = \"mpiexec\"\n").mpi["a"].implementation == ""   # one node
            @test sym.mpi_default == "mpiabi" && sym.mpi["mpiabi"].preferences["abi"] == "MPIABI" && isempty(sym.mpi["hpcx"].preferences)
            @test_throws "is a JULIA_CPU_TARGET" profile("[arch]\nzen = \"znver2 generic\"\n"; node = "arch = \"zen\"\n")
            odd = profile("[arch]\nzen = \"znver2\"\n[julia]\nlogin_arch = \"zen\"\n"; node = "arch = \"zen\"\n")
            @test odd.archs == Dict("zen" => "znver2") && SimLaunch.precompile_where(odd, "zen") == "login"
            # profiles: the user's come before the package's, and one with a `base` holds only what differs
            tri = load_site("trillium")
            @test tri.account == "def-user" && tri.code == "/home/user/studies" && only(tri.types).cores == 192 && tri.mpi_default == "mpiabi"
            @test tri.mpi["mpiabi"].modules == ["StdEnv/2023"] && isempty(tri.mpi["mpiabi"].unset)
            @test tri.mpi["mpiabi"].preferences["abi"] == "MPIABI" && startswith(tri.mpi["mpiabi"].preferences["mpiexec"], "/home/user/")
            @test SimLaunch.read_profile("trillium")[2] == [joinpath(sites, "trillium.toml"), joinpath(pkgdir(SimLaunch), "sites", "trillium.toml")]
            @test issubset(["cluster", "fir", "kepler", "local", "nibi", "trillium", "trillium-gpu"], SimLaunch.known_sites())
            write(joinpath(sites, "mine.toml"), "base = \"trillium\"\n[slurm]\naccount = \"def-other\"\n")   # on top of the user's
            @test load_site("mine").account == "def-other" && load_site("mine").code == "/home/user/studies"
            write(joinpath(sites, "mine.toml"), "base = \"nowhere\"\n")
            @test_throws "no profile for its base" load_site("mine")
            write(joinpath(sites, "mine.toml"), "base = \"mine\"\n")
            @test_throws "no profile for its base" load_site("mine")
            rm(joinpath(sites, "mine.toml"))
            @test_throws "no profile for site" load_site("mine")
            # the package's profile of a public cluster leaves the account and the directories to the user
            withenv("SIMLAUNCH_SITES" => mkpath(joinpath(root, "nosites"))) do
                @test SimLaunch.known_sites() == ["fir", "local", "nibi", "trillium", "trillium-gpu"]
                @test load_site("local").mpi_default == "mpiabi"
                why = try load_site("trillium"); "" catch err; err.msg end
                @test occursin("leaves these to you: `paths.code`", why) && occursin("`slurm.account` (your Slurm account", why)
                @test occursin(joinpath(root, "nosites", "trillium.toml"), why) && occursin("base = \"trillium\"", why)
                @test !occursin("mpi.", why)
                write(joinpath(root, "nosites", "trillium.toml"),
                      "base = \"trillium\"\n[paths]\ncode = \"/c\"\nscratch = \"/s\"\n[slurm]\naccount = \"a\"\n")
                bare = load_site("trillium")
                @test bare.mpi_default == "jll" && isempty(bare.mpi["jll"].unset)
                @test length(bare.mpi["mpiabi"].unset) == 3 && any(startswith("`mpi.mpiabi.julia`"), bare.mpi["mpiabi"].unset)
                mpispec = "name = \"m\"\ntime = \"1:00:00\"\n[[run]]\nlabel = \"a\"\nranks = 8\ncmd = \"examples/hello.jl\"\n"
                onbare(text) = resolve(TOML.parse(text), bare; study = "toy", project = "Toy")
                @test onbare(mpispec).runs[1].mpi == "jll"
                @test_throws "the MPI recipe mpiabi of trillium leaves these to you" onbare(mpispec * "mpi = \"mpiabi\"\n")
            end
            rm(joinpath(sites, "odd.toml"))
            # a site without a queue compiles where it runs
            write(joinpath(sites, "odd.toml"), "name = \"odd\"\n[paths]\ncode = \"/c\"\nscratch = \"/s\"\n[arch]\nm = \"native\"\n[julia]\narch = \"m\"\n")
            @test_throws "compiles where it runs" load_site("odd")
            rm(joinpath(sites, "odd.toml"))
        end

        @testset "the other sites" begin
            job(site; text = gpu_spec, kw...) =
                resolve(load_spec(spec(text)), load_site(site); study = "toy", project = "Toy", kw...)
            j = job("kepler")
            @test j.gpus == 1 && j.cores == 8 && j.queue.partition == "h200debugq" && j.runs[1].threads == 8
            @test j.runs[1].envdir == "envs/default-cuda"
            @test combo_line(only(combos(j))) == "envs/default-cuda\t\tgpu"
            j = job("trillium-gpu")
            @test j.gpus == 2 && j.cores == 48 && j.queue.partition == "debug"
            # all 4 GPUs of a node: the partitions for whole nodes, and only those
            whole(time; kw...) = job("trillium-gpu"; text = replace(gpu_spec, "gpus = 2" => "gpus = 4", "1:00:00" => time), kw...)
            @test whole("1:00:00").queue.partition == "debug_full_node" && whole("2:00:00").queue.partition == "compute_full_node"
            @test_throws "allows at most 3 GPUs" whole("1:00:00"; queue = "compute")
            @test_throws "takes no fewer than 4 GPUs" job("trillium-gpu"; queue = "compute_full_node")
            @test job("trillium-gpu"; text = replace(gpu_spec, "1:00:00\"\n            resources = { gpus = 2 }" => "1:30:00\"\n            resources = { gpus = 2 }")).queue.partition == "debug"
            j = job("nibi")
            @test j.gpus == 0 && j.queue === nothing && j.runs[1].envdir == "src/Toy"
            @test combo_line(only(combos(j))) == "Toy"
            for (site, name) in (("kepler", "kepler-gpu"), ("trillium-gpu", "trillium-gpu"), ("nibi", "nibi-hello"))
                script = generate(job(site))
                reference = joinpath(@__DIR__, "reference", "$name.sh")
                get(ENV, "SIMLAUNCH_UPDATE_REFERENCE", "") == "1" && write(reference, script)
                @test script == read(reference, String)
                @test success(`bash -n $reference`)
            end
            # refusals
            @test job("kepler"; text = replace(gpu_spec, "gpus = 1" => "gpus = 3")).queue.partition == "h200q"
            @test_throws "at most 2 GPUs" job("kepler"; text = replace(gpu_spec, "gpus = 1" => "gpus = 3"), queue = "h200debugq")
            @test_throws "at most 4" job("trillium-gpu"; text = replace(gpu_spec, "gpus = 2" => "gpus = 5"))
            @test_throws "at most 1:00:00" job("kepler"; text = replace(gpu_spec, "0:30:00" => "2:00:00"), queue = "h200debugq")
            @test job("kepler"; text = replace(gpu_spec, "0:30:00" => "2:00:00")).queue.partition == "h200q"
            @test_throws "pre-emptible" job("kepler"; queue = "h200preq")
            @test_throws "for its h200 nodes; its queues: h200debugq, h200q, h200preq. amdq is a queue of its amd nodes, which are CPU nodes" job("kepler"; queue = "amdq")
            @test_throws "GPU jobs only" job("trillium-gpu"; text = replace(gpu_spec, "resources = { gpus = 2 }" => ""))
            @test_throws "has none" job("trillium"; text = replace(gpu_spec, "site.nibi" => "site.trillium",
                                                                    "mode = \"parallel\"" => "resources = { gpus = 1 }"))
            @test_throws "chooses the partition" job("nibi"; queue = "cpubase")
            @test_throws "at most 168:00:00" job("nibi"; text = replace(gpu_spec, "3:00:00" => "8-00:00:00"))
            @test_throws "no environment" job("kepler"; text = replace(gpu_spec, "\"cuda\"" => "\"opencl\""))
            @test job("kepler"; text = replace(gpu_spec, "\"cuda\"" => "\"test+cuda\"")).runs[1].envdir == "envs/default-test+cuda"
            # the second login node is reached through the first
            cmd = SimLaunch.sitecmd(load_site("trillium-gpu"), "echo 'a b'")
            @test cmd.exec[1:2] == ["ssh", "trillium"] && startswith(cmd.exec[3], "ssh trig-login01 ")
            @test readchomp(`bash -c $(replace(cmd.exec[3], "ssh trig-login01" => "eval"))`) == "a b"
        end

        scratch = study_scratch(load_site("local"), "toy")
        @testset "prepare and submit, local" begin
            f = spec(spec_text(RUNS))
            @test_throws "not prepared" submit("toy", f; site = "local", io = devnull)
            redirect_stdout(devnull) do
                prepare("toy"; site = "local")
            end
            @test_throws "--check-bounds=yes" submit("toy", f; site = "local", io = devnull)
            redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [f])
            end
            jobid = submit("toy", f; site = "local", io = devnull)
            n3, n5 = wait_for(scratch, ["hello-n3", "hello-n5"])
            @test n3["status"] == "finished" && n5["status"] == "finished"
            dir = joinpath(scratch, "hello-n3", "001-$jobid")
            @test occursin("answer = 7, threads = $(Sys.CPU_THREADS), var = a b", read(joinpath(dir, "output.log"), String))
            @test read(joinpath(dir, "result.csv"), String) == "n,answer\n3,7\n"
            @test !iswritable(joinpath(dir, "result.csv")) && !iswritable(dir)   # immutable once the job has ended
            # the snapshot in the cache is untouched; the site resolved its own manifest
            @test !ispath(joinpath(ENV["SIMLAUNCH_CACHE"], "toy", "src", "Toy", "Manifest.toml"))
            # a second job of the same run gets a new directory; a third, in the same second, a job of its own
            jobid2 = submit("toy", f; site = "local", io = devnull)
            jobid3 = submit("toy", f; site = "local", io = devnull)
            @test jobid3 != jobid2 && jobid2 != jobid
            t0 = time()
            ended(id) = startswith(try read(joinpath(scratch, "hello-n5", ".simlaunch-job"), String) catch; "" end, "$id ")
            dirs_of(id) = filter(n -> endswith(n, "-$id"), readdir(joinpath(scratch, "hello-n3")))
            while !(length(dirs_of(jobid3)) == 1 && ended(jobid3)) && time() - t0 < 120; sleep(0.3); end
            @test length(dirs_of(jobid2)) == length(dirs_of(jobid3)) == 1 && isdir(dir)
            @test length(filter(n -> startswith(n, "hello-") && endswith(n, ".sh"), readdir(joinpath(study_code(load_site("local"), "toy"), "jobs")))) == 3

            # a copy on the site that is not the snapshot: changed there, incomplete, or another snapshot of the name
            hello = joinpath(study_code(load_site("local"), "toy"), "src", "Toy", "examples", "hello.jl")
            original = read(hello, String)
            chmod(hello, 0o644)
            write(hello, original * "# changed on the site\n")
            @test_throws "differs from its snapshot in src/Toy/examples/hello.jl" submit("toy", f; site = "local", io = devnull)
            @test_throws "it was changed there" prepare("toy"; site = "local", specs = [f], io = devnull)
            write(hello, original)
            mv(hello, hello * ".moved")
            @test_throws "lacks src/Toy/examples/hello.jl" submit("toy", f; site = "local", io = devnull)
            mv(hello * ".moved", hello)
            cached = joinpath(ENV["SIMLAUNCH_CACHE"], "toy")
            mv(cached, cached * ".kept")
            try
                sleep(1)                                  # a snapshot's time has seconds
                snapshot(toy; study = "toy")
                @test_throws "holds another snapshot named toy" prepare("toy"; site = "local", specs = [f], io = devnull)
                @test_throws "holds another snapshot named toy" submit("toy", f; site = "local", io = devnull)
            finally
                rm(cached; recursive = true, force = true)
                mv(cached * ".kept", cached)
            end
        end

        @testset "a run's Julia version" begin
            f = spec(replace(spec_text("""
                                       [[run]]
                                       label = "own"
                                       cmd = "examples/hello.jl n=2"
                                       threads = 1

                                       [[run]]
                                       label = "other"
                                       cmd = "examples/hello.jl n=2"
                                       threads = 1
                                       julia = "9.9"
                                       """), "name = \"hello\"" => "name = \"jv\""))
            loc = load_site("local")
            code = study_code(loc, "toy")
            redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [f], io = devnull)
            end
            # an environment of its own, written by prepare: its manifest is for that Julia
            env = joinpath(code, "envs", "default-julia9.9")
            @test isfile(joinpath(env, "Project.toml")) && isfile(joinpath(env, "Manifest.toml"))
            marker = SimLaunch.prepared_file(loc, "toy", only(loc.types).arch)
            @test "envs/default-julia9.9\tjulia $VERSION" in readlines(marker)
            # compiled by another build of that Julia, as when a juliaup channel has moved on: not prepared
            write(marker, replace(read(marker, String), "envs/default-julia9.9\tjulia $VERSION" => "envs/default-julia9.9\tjulia 9.9.0"))
            @test_throws "not prepared" submit("toy", f; site = "local", io = devnull)
            redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [f], io = devnull)
            end
            @test "envs/default-julia9.9\tjulia $VERSION" in readlines(marker)
            jobid = submit("toy", f; site = "local", io = devnull)
            own, other = wait_for(scratch, ["jv-own", "jv-other"])
            @test own["status"] == other["status"] == "finished"
            @test occursin("answer = 5", read(joinpath(scratch, "jv-other", "001-$jobid", "output.log"), String))
            # a version that the site has neither as a binary nor as juliaup's channel
            bad = spec(replace(read(f, String), "\"9.9\"" => "\"8.8\"", "name = \"jv\"" => "name = \"jvbad\""))
            @test_throws Exception redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [bad], io = devnull)
            end
            @test occursin("Julia 8.8 does not run on local", read(joinpath(scratch, "prepare.log"), String))
        end

        @testset "a failing run and a stopped job" begin
            f = spec(spec_text("""
                               [[run]]
                               label = "bad"
                               cmd = "examples/hello.jl n=1 fail"
                               threads = 1

                               [[run]]
                               label = "long"
                               cmd = "examples/hello.jl n=2 sleep"
                               threads = 1

                               [[run]]
                               label = "never"
                               cmd = "examples/hello.jl n=3"
                               threads = 1
                               """))
            jobid = submit("toy", f; site = "local", io = devnull)
            bad, = wait_for(scratch, ["hello-bad"])
            @test bad["status"] == "failed" && occursin("exit code 7", bad["message"])
            # the second run is now running; stop the job as scancel would
            pidfile = joinpath(scratch, "logs", "hello-$jobid.pid")
            while !isfile(joinpath(scratch, "hello-long", "001-$jobid", "result.csv")); sleep(0.2); end
            run(`kill -TERM $(readchomp(pidfile))`)
            long, never = wait_for(scratch, ["hello-long", "hello-never"])
            # ended from outside, before any time limit: cancelled, not failed
            @test long["status"] == "cancelled" && occursin("the job was cancelled in 001-", long["message"])
            @test never["status"] == "cancelled" && occursin("cancelled before this run finished", never["message"])
            sleep(1)
            @test !iswritable(joinpath(scratch, "hello-long", "001-$jobid"))
            log = read(joinpath(scratch, "logs", "hello-$jobid.out"), String)
            @test occursin("=== output of bad", log) && occursin("ended with exit code", log)
            # with checkpoints, a run that the stopped job never started is stopped, not failed: a later job runs it
            fc = spec("""
                      name = "ckseq"
                      checkpoints = true
                      [restart]
                      to = "checkpoint"
                      from = "restart_from"
                      [site.local]
                      threads = 1
                      [[run]]
                      label = "first"
                      cmd = "examples/count.jl steps=40 delay=0.1"
                      [[run]]
                      label = "second"
                      cmd = "examples/count.jl steps=2 delay=0.1"
                      """)
            jobid = submit("toy", fc; site = "local", io = devnull)
            while !isfile(joinpath(scratch, "ckseq-first", "001-$jobid", "count.csv")); sleep(0.1); end
            run(`kill -TERM $(readchomp(joinpath(scratch, "logs", "ckseq-$jobid.pid")))`)
            states() = [try TOML.parsefile(joinpath(scratch, n, "simwatch.toml")) catch; Dict("status" => "") end
                        for n in ("ckseq-first", "ckseq-second")]
            t0 = time()
            while any(t -> t["status"] in ("", "queued", "starting", "running"), states()) && time() - t0 < 60; sleep(0.3); end
            first, second = states()
            @test first["status"] == "stopped" && occursin("stopped by a signal", first["message"])
            @test second["status"] == "stopped" && second["message"] == "job $jobid stopped before this run started; a later job runs it"
            sleep(1.1)
            submit("toy", fc; site = "local", io = devnull)
            @test all(t -> t["status"] == "finished", wait_for(scratch, ["ckseq-first", "ckseq-second"]))
        end

        @testset "cancel" begin
            f = spec(replace(spec_text("""
                                       [[run]]
                                       label = "long"
                                       cmd = "examples/hello.jl n=2 sleep"
                                       threads = 1

                                       [[run]]
                                       label = "next"
                                       cmd = "examples/hello.jl n=3"
                                       threads = 1

                                       [[run]]
                                       label = "done"
                                       cmd = "examples/hello.jl n=4"
                                       threads = 1
                                       """), "name = \"hello\"" => "name = \"can\""))
            @test_throws "no job of spec can has been submitted" cancel("toy", f; site = "local", io = devnull)
            # one run finishes, then the job is cancelled while the next one runs
            only1 = submit("toy", f; site = "local", only_runs = ["done"], io = devnull)
            wait_for(scratch, ["can-done"])
            sleep(1.1)
            jobid = submit("toy", f; site = "local", only_runs = ["long", "next"], io = devnull)
            while !isfile(joinpath(scratch, "can-long", "001-$jobid", "result.csv")); sleep(0.2); end
            # a look that does not wait: the job runs still
            out = IOBuffer()
            @test wait_spec("toy", f; site = "local", once = true, io = out) === nothing
            text = String(take!(out))
            @test occursin(r"can-long\s+running", text) && occursin(r"can-done\s+finished", text)
            @test occursin("job $jobid of spec can is queued or running on local", text)
            @test SimLaunch.command(["wait", "toy", f, "--site", "local", "--once"]) == SimLaunch.ACTIVE
            @test_throws "exclude each other" SimLaunch.command(["wait", "toy", f, "--site", "local", "--once", "--poll", "1"])
            marked = cancel("toy", f; site = "local", message = "superseded by \"can2\"", poll = 0.3, io = out)
            @test marked == ["can-long", "can-next"]
            text = String(take!(out))
            @test occursin("cancelled job $jobid of spec can on local", text) && occursin("marked as cancelled: can-long, can-next", text)
            long, next, done = [TOML.parsefile(joinpath(scratch, n, "simwatch.toml")) for n in ("can-long", "can-next", "can-done")]
            @test long["status"] == next["status"] == "cancelled" && long["message"] == next["message"] == "superseded by can2"
            @test done["status"] == "finished"                                    # a run that has ended stays as it is
            @test startswith(read(joinpath(scratch, "can-long", ".simlaunch-job"), String), "$jobid cancelled ")
            @test !iswritable(joinpath(scratch, "can-long", "001-$jobid"))
            # again: nothing runs, and nothing is left to mark but what is cancelled already
            cancel("toy", f; site = "local", poll = 0.3, io = out)
            @test occursin("no job of spec can was queued or running", String(take!(out)))
            @test TOML.parsefile(joinpath(scratch, "can-long", "simwatch.toml"))["message"] == "cancelled with simlaunch cancel"
            @test SimLaunch.command(["cancel", "toy", f, "--site", "local", "--message", "x"]) == 0
            # a run of an older job is marked too, not only those of the newest batch script
            sleep(1.1)
            older = submit("toy", f; site = "local", only_runs = ["long"], io = devnull)
            while !isfile(joinpath(scratch, "can-long", "002-$older", "result.csv")); sleep(0.2); end
            sleep(1.1)
            newer = submit("toy", f; site = "local", only_runs = ["done"], io = devnull)
            job_state() = try read(joinpath(scratch, "can-done", ".simlaunch-job"), String) catch; "" end
            while !startswith(job_state(), "$newer done"); sleep(0.2); end      # the newer job has ended
            # (can-next, cancelled already, takes the new message too; the newest script alone would mark nothing)
            @test cancel("toy", f; site = "local", message = "both jobs", poll = 0.3, io = devnull) == ["can-long", "can-next"]
            long = TOML.parsefile(joinpath(scratch, "can-long", "simwatch.toml"))
            @test long["status"] == "cancelled" && long["message"] == "both jobs"
            # a spec with a run this site cannot take: prepared and submitted with --run, and cancelled all the same
            odd = spec(replace(spec_text("""
                                         [[run]]
                                         label = "small"
                                         cmd = "examples/hello.jl n=2 sleep"
                                         threads = 1

                                         [[run]]
                                         label = "huge"
                                         cmd = "examples/hello.jl n=2"
                                         threads = 100000
                                         """), "name = \"hello\"" => "name = \"part\""))
            @test_throws "100000 threads" prepare("toy"; site = "local", specs = [odd], io = devnull)
            @test_throws "exactly one `--spec`" prepare("toy"; site = "local", specs = [odd, f], only_runs = ["small"], io = devnull)
            redirect_stdout(devnull) do
                @test SimLaunch.command(["prepare", "toy", "--site", "local", "--spec", odd, "--run", "small"]) == 0
            end
            part = submit("toy", odd; site = "local", only_runs = ["small"], io = devnull)
            while !isfile(joinpath(scratch, "part-small", "001-$part", "result.csv")); sleep(0.2); end
            @test cancel("toy", odd; site = "local", poll = 0.3, io = devnull) == ["part-small"]
        end

        @testset "wait" begin
            good = spec(replace(spec_text(RUNS), "name = \"hello\"" => "name = \"w\""))
            @test_throws "no job of spec w" wait_spec("toy", good; site = "local", poll = 0.3, io = devnull)
            submit("toy", good; site = "local", io = devnull)
            out = IOBuffer()
            @test wait_spec("toy", good; site = "local", poll = 0.3, io = out)
            text = String(take!(out))
            @test occursin(r"w-n3\s+finished", text) && occursin("all 2 runs have finished", text)
            bad = spec(replace(spec_text("[[run]]\nlabel = \"bad\"\ncmd = \"examples/hello.jl n=1 fail\"\nthreads = 1\n"),
                               "name = \"hello\"" => "name = \"wbad\""))
            submit("toy", bad; site = "local", io = devnull)
            @test !wait_spec("toy", bad; site = "local", poll = 0.3, io = out)
            text = String(take!(out))
            @test occursin("exit code 7", text) && occursin("answer = 3", text)      # with the end of its output
            # from the command line: the exit code says whether the runs finished
            @test SimLaunch.command(["wait", "toy", bad, "--site", "local", "--poll", "0.3"]) == SimLaunch.NOT_FINISHED == 1
            # a look that does not wait, once the jobs have ended
            @test wait_spec("toy", good; site = "local", once = true, io = devnull) === true
            @test SimLaunch.command(["wait", "toy", good, "--site", "local", "--once"]) == 0
            @test SimLaunch.command(["wait", "toy", bad, "--site", "local", "--once"]) == SimLaunch.NOT_FINISHED
            # an error is not a run that did not finish: a site that cannot be reached
            write(joinpath(sites, "away.toml"), "base = \"local\"\n[connect]\nhost = \"away.invalid\"\ncheck = \"false\"\n" *
                                                "[paths]\ncode = \"/away/code\"\nscratch = \"/away/scratch\"\n")
            @test redirect_stderr(devnull) do
                SimLaunch.main(["wait", "toy", good, "--site", "away", "--once"])
            end == SimLaunch.ERROR == 2
            rm(joinpath(sites, "away.toml"))
        end

        @testset "a spec in Julia, a job's record, and the [after] command again" begin
            code = study_code(load_site("local"), "toy")
            f = joinpath(root, "tab.jl")
            write(f, """
                  show = "echo jobs \\\$JOBID; cat \\"\\\$PROJECT\\"/examples/note.txt 2>/dev/null || echo no note; " *
                         "for d in \\\$SIMLAUNCH_JOBDIRS; do cat \\\$d/result.csv; done"
                  (name = "tab", site = Dict("local" => (threads = 1,)), after = (cmd = show,),
                   run = [(label = "n\$n", cmd = "examples/hello.jl n=\$n") for n in (2, 4)])
                  """)
            jobid = submit("toy", f; site = "local", io = devnull)
            @test wait_spec("toy", f; site = "local", poll = 0.3, io = devnull)
            # what the spec evaluated to is kept beside the script, with the file itself
            kept = only(filter(n -> startswith(n, "tab-") && endswith(n, ".toml"), readdir(joinpath(code, "jobs"))))
            @test TOML.parsefile(joinpath(code, "jobs", kept)) == load_spec(f)
            @test isfile(joinpath(code, "jobs", replace(kept, ".toml" => ".jl")))
            # every job directory says where it ran
            record = TOML.parsefile(joinpath(scratch, "tab-n2", "001-$jobid", "simlaunch-job.toml"))
            @test record["job_id"] == jobid && record["run"] == "tab-n2" && !isempty(record["cpu"]) && !isempty(record["host"])
            log = read(joinpath(scratch, "logs", "tab-$jobid.out"), String)
            @test occursin("jobs $jobid\nno note\nn,answer\n2,5\nn,answer\n4,9\n", log)
            # the command again, over all runs and over one
            out = IOBuffer()
            again = after("toy", f; site = "local", io = out)
            text = String(take!(out))
            @test occursin("jobs $jobid\nno note\nn,answer\n2,5\nn,answer\n4,9\n", text)
            @test read(again, String) * "log: $again\n" == text
            sleep(1.1)                                                           # a log's name holds the second
            after("toy", f; site = "local", only_runs = ["n4"], io = out)
            text = String(take!(out))
            @test occursin("jobs $jobid\nno note\nn,answer\n4,9\n", text) && !occursin("2,5", text)
            @test_throws "unknown option --checkout" SimLaunch.command(["after", "toy", f, "--site", "local", "--checkout"])
            @test_throws "no [after] table" after("toy", spec(spec_text(RUNS)); site = "local", io = devnull)
            @test SimLaunch.command(["after", "toy", f, "--site", "local"]) == 0
        end

        @testset "a program's own SimWatch file, merged into the run's" begin
            code = """
                   write(joinpath(ENV["SIMLAUNCH_SIMWATCH_DIR"], "simwatch.toml"), \"\"\"
                   status = "finished"
                   message = "step 3"
                   summary = ["err.l2", "progress.iteration"]

                   [progress]
                   iteration = 3
                   time = 1.5
                   time_end = 6.0
                   walltime = 1

                   [err]
                   l2 = 0.25

                   [[images]]
                   file = "plots/a.png"

                   [slurm]
                   job_id = "1"
                   \"\"\")
                   """
            f = joinpath(root, "prog.toml")
            open(io -> TOML.print(io, Dict("name" => "prog", "site" => Dict("local" => Dict("threads" => 1)),
                                           "run" => [Dict("label" => "p", "cmd" => "-e '$code'")])), f; write = true)
            jobid = submit("toy", f; site = "local", io = devnull)
            st = only(wait_for(scratch, ["prog-p"]))
            @test st["status"] == "finished" && st["message"] == "finished in 001-$jobid"   # ours, once it has ended
            @test st["progress"]["iteration"] == 3 && st["progress"]["time"] == 1.5 && st["progress"]["time_end"] == 6.0
            @test st["progress"]["fraction"] == 1.0 && st["progress"]["walltime"] != 1     # ours win
            @test st["summary"] == ["err.l2", "progress.iteration"] && st["err"]["l2"] == 0.25
            @test only(st["images"])["file"] == "001-$jobid/.simwatch/plots/a.png"
            @test !haskey(st, "slurm") && st["resources"]["threads"] == 1
        end

        @testset "a site that precompiles in a job, and an environment" begin
            cluster = load_site("cluster")
            cscratch, ccode = study_scratch(cluster, "toy"), study_code(cluster, "toy")
            f = spec("""
                     name = "dev"
                     [site.cluster]
                     time = "0:10:00"
                     resources = { gpus = 1 }
                     env = "dates"
                     [site.local]
                     env = "dates"
                     [[run]]
                     label = "n4"
                     cmd = "examples/hello.jl n=4"
                     """)
            @test_throws "not prepared" submit("toy", f; site = "cluster", io = devnull)
            # a lock left by a job that has ended is taken over
            mine, other = lock_dir(cluster, "toy", "gpu"), lock_dir(cluster, "other", "gpu")
            @test mine == joinpath(ccode, "depot-gpu", "precompile.lock")        # the lock is the depot's
            mkpath(mine); write(joinpath(mine, "jobid"), "999\n")
            mkpath(other); write(joinpath(other, "jobid"), "999\n")            # another study's lock is not this one's
            out = IOBuffer()
            needed = redirect_stdout(devnull) do
                prepare("toy"; site = "cluster", specs = [f], poll = 0.5, io = out)
            end
            @test combo_line.(needed) == ["envs/default-dates\t\tgpu"]
            text = String(take!(out))                                            # it says how the job ended, and that it is done
            @test occursin(r"precompile job \d+ on cluster: finished, \d+:\d\d after it was submitted\n", text)
            @test endswith(text, "study toy is prepared on cluster\n")
            @test occursin("names job 999, which has ended: taking it over", text)
            @test !ispath(mine)                                                  # given back by the job
            @test read(joinpath(other, "jobid"), String) == "999\n"             # and the other study's was left alone
            rm(joinpath(study_code(cluster, "other")); recursive = true)
            @test readlines(joinpath(ccode, "depot-gpu", "prepared")) == ["envs/default-dates\t\tgpu\tjulia $VERSION"]
            # the caches are the study's own; the packages are the site's
            @test "Toy" in readdir(joinpath(ccode, "depot-gpu", "compiled", "v$(VERSION.major).$(VERSION.minor)"))
            @test islink(joinpath(ccode, "depot-gpu", "packages"))
            # one depot per architecture: the login node's holds nothing of the project, the CPU nodes' is not made yet
            @test !ispath(joinpath(ccode, "depot-login", "compiled", "v$(VERSION.major).$(VERSION.minor)", "Toy"))
            @test !ispath(joinpath(ccode, "depot-cpu")) && !ispath(joinpath(ccode, "depot"))
            @test occursin("DEPOT=$(joinpath(ccode, "depot-gpu")) ", generate(only(SimLaunch.load_jobs("toy", cluster, [f]))))
            env = TOML.parsefile(joinpath(ccode, "envs", "default-dates", "Project.toml"))
            @test issubset(["Toy", "ToyDep", "Dates"], keys(env["deps"]))
            @test env["sources"]["ToyDep"]["path"] == joinpath(ccode, "src", "ToyDep")
            @test !ispath(joinpath(ccode, "src", "Toy", "Manifest.toml"))        # the project itself is untouched
            log = only(filter(startswith("precompile-"), readdir(joinpath(cscratch, "logs"))))
            @test occursin("warm: ", read(joinpath(cscratch, "logs", log), String))
            # prepared already: no second job
            redirect_stdout(devnull) do
                prepare("toy"; site = "cluster", specs = [f], poll = 0.5, io = devnull)
            end
            @test length(filter(startswith("precompile-"), readdir(joinpath(cscratch, "logs")))) == 1

            jobid = submit("toy", f; site = "cluster", io = devnull)
            n4, = wait_for(cscratch, ["dev-n4"])
            @test n4["status"] == "finished" && n4["slurm"]["job_id"] == jobid
            @test occursin("answer = 9, threads = 2", read(joinpath(cscratch, "dev-n4", "001-$jobid", "output.log"), String))

            # the same environment on a second site, and the report of what the two resolved
            out = IOBuffer()
            redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [f], io = out)
            end
            @test occursin("local and cluster resolved the same versions", String(take!(out)))
            versions = manifest_versions(joinpath(ENV["SIMLAUNCH_CACHE"], ".sites", "toy", "local", "envs--default-dates.toml"))
            @test versions["julia"] == string(VERSION) && versions["Toy"] == "the study's sources"
            other = joinpath(ENV["SIMLAUNCH_CACHE"], ".sites", "toy", "cluster", "envs--default-dates.toml")
            write(other, replace(read(other, String), "julia_version = \"$VERSION\"" => "julia_version = \"1.0.0\""))
            redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [f], io = out)
            end
            @test occursin(r"julia\s+\S+\s+cluster: 1\.0\.0", String(take!(out)))
        end

        # a spec written for one cluster: two versions of the package, MPI ranks placed on NUMA domains, two recipes
        nested = """
            name = "nested"
            site = "kepler"
            time = "1:00:00"
            resources = { nodes = 2 }
            node = "cn[095-096]"
            sbatch_args = ["--switches=1"]
            env = "test"
            placement = "numa"
            mpi = "jll"

            [after]
            cmd = "awk -f \\"\$PROJECT\\"/bench/table.awk */output.log"

            [[run]]
            label = "base-8r"
            variant = "base"
            cmd = "examples/hello.jl n=1"
            ranks = 8
            nodes = 1

            [[run]]
            label = "new-16r"
            cmd = "examples/hello.jl n=1"
            ranks = 16
            mpi = "mpiabi"
            prefix = "perf stat -e cache-misses"

            [[run]]
            label = "serial"
            cmd = "examples/hello.jl n=1"
            vars = { TOYVAR = "x" }
            """
        ckpt = """
            name = "chain"
            checkpoints = true

            [restart]
            to = "checkpoint"
            from = "restart_from"
            walltime = "walltime"
            continue_code = 3
            compare = "examples/compare.jl"

            [combine]
            cmd = "examples/combine.jl"

            [site.kepler]
            time = "12:00:00"
            resources = { gpus = 1 }
            env = "cuda"

            [site.cluster]
            time = "0:10:00"

            [site.local]

            [[run]]
            label = "c"
            cmd = "examples/count.jl steps=20 delay=0.3"
            threads = 1
            """
        @testset "variants, MPI, placement and restarts in a spec" begin
            dest = snapshot(toy; study = "toy2", variants = ["base" => toy])
            @test isfile(joinpath(dest, "variants", "base", "src", "Toy", "src", "Toy.jl"))
            @test isfile(joinpath(dest, "variants", "base", "src", "ToyDep", "Project.toml"))
            snap = load_snapshot("toy2")
            @test SimLaunch.study_variants(snap) == ["default", "base"]
            @test SimLaunch.project_home(snap) == realpath(toy)
            @test_throws "the study's own version" snapshot(toy; study = "toy3", variants = ["default" => toy])
            job(text, site; kw...) = resolve(load_spec(spec(text)), load_site(site); study = "toy2", project = "Toy",
                                             variants = ["default", "base"], kw...)
            j = job(nested, "kepler")
            @test j.queue.partition == "amdq" && j.nodes == 2 && j.tasks == 8         # two nodes: not amddebugq
            @test [r.envdir for r in j.runs] == ["envs/base-test+mpi-jll", "envs/default-test+mpi-mpiabi", "envs/default-test+mpi-jll"]
            @test [r.threads for r in j.runs] == [8, 8, 8]                            # a NUMA domain each
            # the marker of what is prepared names the CPU target of a site with several CPU types
            @test combo_line.(combos(j)) == ["envs/base-test+mpi-jll", "envs/default-test+mpi-mpiabi", "envs/default-test+mpi-jll"] .*
                                            "\t\t\tznver2"
            @test occursin("export JULIA_CPU_TARGET=znver2", generate(j))
            @test occursin("DEPOT=/home/user/studies/toy2/depot-amd ", generate(j))
            prep = SimLaunch.prepare_script(load_site("kepler"), "toy2", combos(j))
            @test occursin("make_env.jl \"\$CODE\"/variants/base/src/Toy \"\$CODE\"/envs/base-test+mpi-jll --test MPI MPIPreferences", prep)
            @test occursin("set_mpi.jl system", prep) && occursin("module load nvhpc-hpcx-cuda12/24.9", prep)
            # ranks under srun end together; a rank's NUMA domain is counted on its node, not taken from the profile
            cmd = SimLaunch.run_command(j, j.runs[1])
            @test occursin("srun --mpi=pmi2 --kill-on-bad-exit=1 --nodes=1 --ntasks=8 ", cmd)
            bind = match(r"bash -c ('[^']*') numa ", cmd)[1]
            fake = mkpath(joinpath(root, "fakenuma"))
            numactl(n) = (write(joinpath(fake, "numactl"), "#!/bin/bash\nif [ \"\$1\" = -H ]; then echo \"available: $n nodes (0-$(n - 1))\"; " *
                                                           "echo \"node 0 cpus: 0 1\"; else echo \"\$@\"; fi\n");
                          chmod(joinpath(fake, "numactl"), 0o755))
            placed(l) = withenv("PATH" => fake * ":" * ENV["PATH"], "SLURM_LOCALID" => l) do
                err = IOBuffer()
                p = run(pipeline(ignorestatus(`bash -c "bash -c $bind numa the run"`); stdout = err, stderr = err))
                (p.exitcode, String(take!(err)))
            end
            numactl(16)
            @test placed("3") == (0, "--cpunodebind=6-7 --membind=6-7 the run\n")
            numactl(8)
            @test placed("3") == (0, "--cpunodebind=3 --membind=3 the run\n")
            for n in (4, 12)                                                          # too few, and not a multiple
                numactl(n)
                code, said = placed("3")
                @test code == 1 && occursin("has $n NUMA domains, which 8 ranks cannot share evenly", said)
            end
            # fewer ranks than domains: each rank has its share of them, and of the cores
            j2 = job(replace(nested, "ranks = 8" => "ranks = 2\nlauncher_args = [\"--label\", \"a b\"]"), "kepler")
            @test j2.runs[1].threads == 32
            cmd = SimLaunch.run_command(j2, j2.runs[1])
            @test occursin("srun --mpi=pmi2 --label 'a b' --kill-on-bad-exit=1 --nodes=1 --ntasks=2 --cpus-per-task=32 ", cmd)
            bind = match(r"bash -c ('[^']*') numa ", cmd)[1]
            numactl(8)
            @test placed("0") == (0, "--cpunodebind=0-3 --membind=0-3 the run\n")
            @test placed("1") == (0, "--cpunodebind=4-7 --membind=4-7 the run\n")
            # an mpiexec on several nodes is told the run's nodes and its ranks on each, which the header's
            # tasks per node do not say: Open MPI's by --host; a rank's place on its node is its local rank
            cmd = SimLaunch.run_command(j, j.runs[2])
            @test occursin("mpiexec.jl --bind-to none --host \"\$(node_list 2 :8)\" -n 16 bash -c 'l=\${OMPI_COMM_WORLD_LOCAL_RANK:-\${MPI_LOCALRANKID:-0}}; ", cmd)
            j3 = job(replace(nested, "ranks = 16" => "ranks = 8"), "kepler")                  # 4 on a node of the 8 the header has
            @test j3.tasks == 8 && occursin("--host \"\$(node_list 2 :4)\" -n 8 ", SimLaunch.run_command(j3, j3.runs[2]))
            j3 = job(replace(nested, "ranks = 16" => "ranks = 4\nnodes = 1"), "kepler")       # one of the job's two nodes
            @test occursin("--host \"\$(node_list 1 :4)\" -n 4 ", SimLaunch.run_command(j3, j3.runs[2]))
            # Hydra's mpiexec, and the nodes as the job's script finds them
            write(joinpath(sites, "kepler-hydra.toml"), "base = \"kepler\"\nname = \"kepler-hydra\"\n" *
                  "[mpi.mpiabi]\nbinary = \"jll\"\nmodules = []\nlauncher_args = []\nimplementation = \"mpich\"\n")
            j3 = job(replace(nested, "site = \"kepler\"" => "site = \"kepler-hydra\""), "kepler-hydra")
            @test occursin("mpiexec.jl -ppn 8 -hosts \"\$(node_list 2)\" -n 16 ", SimLaunch.run_command(j3, j3.runs[2]))
            rm(joinpath(sites, "kepler-hydra.toml"))
            write(joinpath(fake, "scontrol"), "#!/bin/bash\n[ \"\$*\" = \"show hostnames cn[095-097]\" ] && printf 'cn095\\ncn096\\ncn097\\n'\n")
            chmod(joinpath(fake, "scontrol"), 0o755)
            nodes(args) = withenv("PATH" => fake * ":" * ENV["PATH"], "SLURM_JOB_NODELIST" => "cn[095-097]") do
                helpers = joinpath(dirname(@__DIR__), "templates", "job_helpers.sh")
                read(`bash -c ". $(SimLaunch.q(helpers)); node_list $args"`, String)
            end
            @test nodes("2 :8") == "cn095:8,cn096:8" && nodes("1") == "cn095" && nodes("3") == "cn095,cn096,cn097"
            # a run without ranks keeps to one domain
            @test j.runs[3].threads == 8
            bind = match(r"bash -c ('[^']*') numa ", SimLaunch.run_command(j, j.runs[3]))[1]
            @test placed("0") == (0, "--cpunodebind=0 --membind=0 the run\n")
            @test_throws "evenly" job(replace(nested, "ranks = 8" => "ranks = 3"), "kepler")
            # `domains_per_rank`: a rank keeps to that many domains, from the start of its share on
            jd = job(replace(nested, "ranks = 8" => "ranks = 2\ndomains_per_rank = 1"), "kepler")
            @test jd.runs[1].domains == 1 && jd.runs[1].threads == 8 && jd.runs[2].domains == 0 && jd.runs[2].threads == 8
            bind = match(r"bash -c ('[^']*') numa ", SimLaunch.run_command(jd, jd.runs[1]))[1]
            @test placed("0") == (0, "--cpunodebind=0 --membind=0 the run\n")
            @test placed("1") == (0, "--cpunodebind=4 --membind=4 the run\n")
            numactl(4)                                                                # counted on the node
            @test placed("1") == (0, "--cpunodebind=2 --membind=2 the run\n")
            numactl(1)
            code, said = placed("1")
            @test code == 1 && occursin("has 1 NUMA domains, too few for 2 ranks with 1 each", said)
            numactl(8)
            jd = job(replace(nested, "ranks = 8" => "ranks = 2\ndomains_per_rank = 2"), "kepler")
            @test jd.runs[1].threads == 16
            bind = match(r"bash -c ('[^']*') numa ", SimLaunch.run_command(jd, jd.runs[1]))[1]
            @test placed("1") == (0, "--cpunodebind=4-5 --membind=4-5 the run\n")
            # with it the ranks need not divide the domains: 3 ranks on 8 start at 0, 2 and 5
            jd = job(replace(nested, "ranks = 8" => "ranks = 3\ndomains_per_rank = 2"), "kepler")
            bind = match(r"bash -c ('[^']*') numa ", SimLaunch.run_command(jd, jd.runs[1]))[1]
            @test [placed(l)[2] for l in ("0", "1", "2")] == ["--cpunodebind=$d --membind=$d the run\n" for d in ("0-1", "2-3", "5-6")]
            @test_throws "3 ranks on a node with 3 NUMA domains each do not fit its 8 domains" job(replace(nested, "ranks = 8" => "ranks = 3\ndomains_per_rank = 3"), "kepler")
            @test_throws "the 1 NUMA domain it is bound to has 8 cores" job(replace(nested, "ranks = 8" => "ranks = 2\ndomains_per_rank = 1\nthreads = 9"), "kepler")
            @test_throws "positive integer" job(replace(nested, "ranks = 8" => "ranks = 2\ndomains_per_rank = 0"), "kepler")
            # a run without ranks: that many domains from 0 on
            jd = job(replace(nested, "vars = { TOYVAR = \"x\" }" => "domains_per_rank = 2"), "kepler")
            @test jd.runs[3].threads == 16
            bind = match(r"bash -c ('[^']*') numa ", SimLaunch.run_command(jd, jd.runs[3]))[1]
            @test placed("0") == (0, "--cpunodebind=0-1 --membind=0-1 the run\n")
            # the job's is for its runs that are placed; a run's own needs a placement
            jd = job(replace(nested, "placement = \"numa\"" => "placement = \"numa\"\ndomains_per_rank = 1",
                             "vars = { TOYVAR = \"x\" }" => "placement = \"\""), "kepler")
            @test [r.domains for r in jd.runs] == [1, 1, 0] && jd.runs[3].threads == 64
            @test_throws "`domains_per_rank` is for a run with `placement" job(replace(nested, "vars = { TOYVAR = \"x\" }" => "placement = \"\"\ndomains_per_rank = 1"), "kepler")
            # a prefix is words, each quoted: as a string split as a shell would, or as a list
            @test occursin(" numa perf stat -e cache-misses \"\$JULIA\" ", SimLaunch.run_command(j, j.runs[2]))
            jp = job(replace(nested, "prefix = \"perf stat -e cache-misses\"" => "prefix = \"env 'A=b c' X=\$HOME\""), "kepler")
            @test jp.runs[2].prefix == ["env", "A=b c", "X=\$HOME"]
            @test occursin(" env 'A=b c' 'X=\$HOME' ", SimLaunch.run_command(jp, jp.runs[2]))
            jp = job(replace(nested, "prefix = \"perf stat -e cache-misses\"" => "prefix = [\"taskset\", \"-c\", \"0-7\", \"a b\"]"), "kepler")
            @test occursin(" taskset -c 0-7 'a b' ", SimLaunch.run_command(jp, jp.runs[2]))
            @test_throws "`prefix`" job(replace(nested, "prefix = \"perf stat -e cache-misses\"" => "prefix = 3"), "kepler")
            # the launcher's arguments are for runs with ranks
            @test_throws "`launcher_args` is for a run with `ranks`" job(replace(nested, "vars = { TOYVAR = \"x\" }" => "launcher_args = [\"-v\"]"), "kepler")
            # under an mpiexec a run's variables are set for the launcher and again for every rank
            jm = job(replace(nested, "mpi = \"mpiabi\"" => "mpi = \"hpcx\"\nvars = { ROMIO_HINTS = \"/a b/hints\" }"), "kepler")
            cmd = SimLaunch.run_command(jm, jm.runs[2])
            @test startswith(cmd, "env ROMIO_HINTS='/a b/hints' ") && occursin(" -n 16 env ROMIO_HINTS='/a b/hints' bash -c ", cmd)
            @test_throws "do not fit" job(replace(nested, "ranks = 8" => "ranks = 16"), "kepler")
            @test_throws "64 cores" job(replace(nested, "label = \"base-8r\"" => "label = \"base-8r\"\nthreads = 9"), "kepler")
            @test_throws "no MPI recipe" job(replace(nested, "\"mpiabi\"" => "\"cray\""), "kepler")
            # only the named runs are checked: another run may be written for a recipe this site does not have
            jo = job(replace(nested, "\"mpiabi\"" => "\"cray\""), "kepler"; only_runs = ["serial"])
            @test [r.label for r in jo.runs] == ["serial"]
            @test_throws "its runs: base-8r, new-16r, serial" job(nested, "kepler"; only_runs = ["none"])
            @test_throws "one node only" job(replace(nested, "\"mpiabi\"" => "\"jll-fork\""), "kepler")
            @test_throws "pin = true" job(replace(nested, "placement = \"numa\"" => "placement = \"numa\"\npin = true"), "kepler")
            @test_throws "for site kepler only" job(nested, "trillium")
            # a chain of jobs: a pre-emptible queue first, and never the queue that is not for chains
            j = job(ckpt, "kepler")
            @test j.checkpoints && j.queue.partition == "h200preq" && j.restart.continue_code == 3
            @test_throws "not for a chain" job(replace(ckpt, "12:00:00" => "0:30:00"), "kepler"; queue = "h200debugq")
            @test_throws "needs `checkpoints = true`" job(replace(ckpt, "checkpoints = true" => ""), "kepler")
            @test_throws "a chain of jobs needs" job(gpu_spec, "kepler"; chain = 2)
            @test_throws "remove `from`" job(replace(ckpt, "checkpoints = true" => "checkpoints = true\nmutable_restarts = true"), "kepler")
            m = job(replace(ckpt, "checkpoints = true" => "checkpoints = true\nmutable_restarts = true", "from = \"restart_from\"" => ""), "kepler")
            @test occursin("#SBATCH --requeue\n#SBATCH --open-mode=append", generate(m)) && !occursin("seal_earlier \"\$i\"", generate(m))
            for (name, text) in (("kepler-nested", nested), ("kepler-chain", ckpt))
                script = generate(job(text, "kepler"))
                reference = joinpath(@__DIR__, "reference", "$name.sh")
                get(ENV, "SIMLAUNCH_UPDATE_REFERENCE", "") == "1" && write(reference, script)
                @test script == read(reference, String)
                @test success(`bash -n $reference`)
            end
        end

        @testset "the restart source" begin
            # the newest earlier job with a complete checkpoint: not one that holds temporary names only
            d = mktempdir()
            for (job, file) in (("001-a", "step-3"), ("002-b", "step-5.tmp"), ("003-c", ".hidden"), ("004-d", "step-9"))
                write(joinpath(mkpath(joinpath(d, "chain-c", job, "ck")), file), "x")
            end
            helpers = joinpath(pkgdir(SimLaunch), "templates", "job_helpers.sh")
            source(own) = readchomp(`bash -c "set -u; SCRATCH=$d; SPEC=chain; LABELS=(c); JOBDIRS=($d/chain-c/$own); TEMPORARY=('*.tmp' '*.tmp.*' '.*'); . $helpers; restart_source 0"`)
            @test source("004-d") == joinpath(d, "chain-c", "001-a", "ck")
            @test source("005-e") == joinpath(d, "chain-c", "004-d", "ck")
            @test SimLaunch.q("*.tmp") == "'*.tmp'" && SimLaunch.q("it's") == "'it'\\''s'" && SimLaunch.q("n=3") == "n=3"
        end

        @testset "the bounds of a test environment" begin
            # test/Project.toml's [compat] holds beside the project's, as under Pkg.test
            d = mktempdir(root)
            pkg = mkpath(joinpath(d, "Bounded"))
            mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
            write(joinpath(pkg, "src", "Bounded.jl"), "module Bounded end\n")
            head = """
                   name = "Bounded"
                   uuid = "33333333-3333-4333-8333-333333333333"
                   """
            body = """
                   [deps]
                   Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"

                   [compat]
                   Dates = "1"
                   julia = "1"
                   """
            write(joinpath(pkg, "Project.toml"), head * body)
            write(joinpath(pkg, "test", "Project.toml"), """
                  [deps]
                  Bounded = "33333333-3333-4333-8333-333333333333"
                  Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
                  Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                  [sources]
                  Bounded = {path = ".."}

                  [compat]
                  Dates = "1.6 - 1"
                  Test = "1"
                  """)
            make_env(env) = withenv("JULIA_DEPOT_PATH" => joinpath(root, "depot") * ":", "JULIA_PKG_OFFLINE" => "true",
                                     "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing) do   # as a site runs it
                err = IOBuffer()
                ok = success(pipeline(`$(Base.julia_cmd()) --startup-file=no $(joinpath(pkgdir(SimLaunch), "templates", "make_env.jl")) $pkg $(joinpath(d, env)) --test`;
                                      stdout = devnull, stderr = err))
                (; ok, err = String(take!(err)))
            end
            @test make_env("env").ok
            # where both name a package, the test project's bound is written, and the package brings its own
            @test TOML.parsefile(joinpath(d, "env", "Project.toml"))["compat"] ==
                  Dict("Dates" => "1.6 - 1", "Test" => "1", "julia" => "1")
            # a project that is not a package cannot bring its own: two different bounds are refused
            write(joinpath(pkg, "Project.toml"), body)
            write(joinpath(pkg, "test", "Project.toml"), replace(read(joinpath(pkg, "test", "Project.toml"), String),
                                                                 r"Bounded = .*\n" => ""))
            r = make_env("other")
            @test !r.ok && occursin("Dates has the bound \"1\"", r.err) && occursin("only one", r.err)
        end

        @testset "a chain of jobs, its disk usage, fetch and delete" begin
            cluster = load_site("cluster")
            cscratch = study_scratch(cluster, "toy")
            f = spec(ckpt)
            # the driver stops at its walltime after about 8 s, and the next job of the chain continues
            short = spec(replace(ckpt, "0:10:00\"" => "0:20\"", "walltime = \"walltime\"" => "walltime = \"walltime\"\nmargin = \"0:10\"",
                                 "steps=20 delay=0.3" => "steps=22 delay=0.5"))
            @test_throws "not prepared" submit("toy", short; site = "cluster", queue = "cpuq", io = devnull)
            redirect_stdout(devnull) do
                prepare("toy"; site = "cluster", specs = [short], poll = 0.5, io = devnull)
            end
            @test_throws "no job of spec chain" resubmit("toy", short; site = "cluster", queue = "cpuq", io = devnull)
            id = submit("toy", short; site = "cluster", queue = "cpuq", chain = 3, io = devnull)
            ids = string.(parse(Int, id) .+ (0:2))
            @test_throws "queued or running" submit("toy", short; site = "cluster", queue = "cpuq", io = devnull)
            queued = TOML.parsefile(joinpath(cscratch, "chain-c", "simwatch.toml"))
            @test queued["status"] in ("queued", "running")
            @test queued["description"] == "the toy study \"T\""                     # the study's note, for SimWatch
            # a study with a job in the queue is live, and nothing of it is deleted
            @test only(r for r in SimLaunch.inventory(; sites = ["cluster"]) if r.study == "toy").live > 0
            @test_throws "queued or running" SimLaunch.delete(["toy"]; sites = ["cluster"], level = :caches, yes = true, io = devnull)
            @test queued["slurm"]["cluster"] == "fakecluster"                        # which Slurm the job is in
            out = IOBuffer()
            @test wait_spec("toy", short; site = "cluster", poll = 0.5, io = out)     # the whole chain
            @test occursin(r"chain-c\s+finished", String(take!(out)))
            run_dir = joinpath(cscratch, "chain-c")
            st = TOML.parsefile(joinpath(run_dir, "simwatch.toml"))
            @test st["status"] == "finished" && st["slurm"]["previous_job_ids"] == [ids[1]]
            @test st["description"] == "the toy study \"T\""
            @test st["slurm"]["cluster"] == "fakecluster"
            dirs = sort!(filter(startswith(r"\d\d\d-"), readdir(run_dir)))
            @test dirs == ["001-$(ids[1])", "002-$(ids[2])"]                        # the third job had nothing left to do
            @test occursin("nothing is left to do", read(joinpath(cscratch, "logs", "chain-$(ids[3]).out"), String))
            @test occursin("continues from $(joinpath(run_dir, dirs[1], "ck"))", read(joinpath(cscratch, "logs", "chain-$(ids[2]).out"), String))
            rows(d) = [parse.(Int, split(l, ",")) for l in readlines(joinpath(run_dir, d, "count.csv"))[2:end]]
            first_rows, second_rows = rows(dirs[1]), rows(dirs[2])
            @test first_rows[1][1] == 1 && second_rows[1][1] == first_rows[end][1] + 1 && second_rows[end][1] == 22
            @test second_rows[end][2] == sum(2k + 1 for k in 1:22)
            @test !iswritable(joinpath(run_dir, dirs[1], "count.csv")) && !iswritable(joinpath(run_dir, dirs[1], "ck"))
            # disk usage, as each job recorded it
            use = TOML.parsefile(joinpath(run_dir, "diskusage.toml"))
            @test [j["dir"] for j in use["job"]] == dirs && all(j -> j["kb"] isa Integer, use["job"])
            @test st["diskusage"]["kb"] == sum(j["kb"] for j in use["job"])
            out = IOBuffer()
            urows = usage("toy"; site = "cluster", io = out)
            @test [r.dir for r in urows if r.run == "chain-c"] == dirs && occursin("total", String(take!(out)))
            # status: one table over the sites
            srows = status(["toy"]; io = devnull)
            @test any(r -> r.site == "cluster" && r.run == "chain-c" && r.status == "finished", srows)
            @test any(r -> r.site == "local" && r.run == "hello-bad" && r.status == "failed", srows)
            # combine: a new directory beside the jobs', read-only
            combined = only(combine("toy", short; site = "cluster", io = devnull))
            @test basename(combined) == "combined-1" && length(readlines(joinpath(combined, "combined.csv"))) == 22
            @test !iswritable(joinpath(combined, "combined.csv"))
            # fetch: into the project, by site; checkpoints stay behind
            dest = only(fetch("toy"; site = "cluster", io = devnull))
            @test dest == joinpath(realpath(toy), "simlaunch-data", "toy", "cluster")
            @test isfile(joinpath(dest, "chain-c", dirs[2], "count.csv")) && isfile(joinpath(dest, "chain-c", "simwatch.toml"))
            @test !ispath(joinpath(dest, "chain-c", dirs[1], "ck")) && isfile(joinpath(dest, "snapshot.toml"))
            @test isfile(joinpath(dest, "manifests", "src--Toy.toml")) && isfile(joinpath(dest, "logs", "chain-$(ids[1]).out"))
            fetch("toy"; site = "cluster", runs = ["chain-c"], with_checkpoints = true, to = joinpath(root, "fetched"), io = devnull)
            @test isdir(joinpath(root, "fetched", "cluster", "chain-c", dirs[2], "ck"))
            @test !ispath(joinpath(root, "fetched", "cluster", "dev-n4"))
            fetch("toy"; site = "cluster", runs = ["c"], to = joinpath(root, "bylabel"), io = devnull)  # a label
            @test isdir(joinpath(root, "bylabel", "cluster", "chain-c")) && !ispath(joinpath(root, "bylabel", "cluster", "dev-n4"))
            @test_throws "has no run" fetch("toy"; site = "cluster", runs = ["c", "nosuch"], to = joinpath(root, "x"), io = devnull)
            @test !ispath(joinpath(root, "x", "cluster", "chain-c"))
            # a scan's label names all its runs, and a label of its own comes first
            cl = load_site("cluster")
            fake = joinpath(study_scratch(cl, "toy"), "scan-sc-t2")
            mkpath(fake)
            write(joinpath(fake, "simwatch.toml"), "name = \"toy scan/sc-t2\"\n")
            @test SimLaunch.chosen_runs(cl, "toy", ["sc", "c"]) == (["scan-sc-t2", "chain-c"], String[])
            @test SimLaunch.chosen_runs(cl, "toy", ["s"]) == (String[], ["s"])
            rm(fake; recursive = true)
            # old checkpoints are deleted only after a yes
            del(level; kw...) = SimLaunch.delete(["toy"]; sites = ["cluster"], level, kw...)
            out = IOBuffer()
            @test !del(:old_checkpoints; io = out, input = IOBuffer("n\n"))
            @test occursin("chain-c/$(dirs[1])/ck", String(take!(out))) && isdir(joinpath(run_dir, dirs[1], "ck"))
            @test !del(:old_checkpoints; runs = ["c"], io = out, input = IOBuffer("n\n"))
            @test occursin("chain-c/$(dirs[1])/ck", String(take!(out)))
            @test_throws "has no run" del(:old_checkpoints; runs = ["nosuch"], yes = true, io = devnull)
            @test del(:old_checkpoints; yes = true, io = devnull)
            @test !ispath(joinpath(run_dir, dirs[1], "ck")) && isdir(joinpath(run_dir, dirs[2], "ck"))
            @test !iswritable(joinpath(run_dir, dirs[1]))
            @test only(r for r in usage("toy"; site = "cluster", io = devnull) if r.dir == dirs[1]).ck == 0
            # a large file, outside the checkpoints: listed with the warning, deleted, recorded
            big = joinpath(run_dir, dirs[2], "big.dat")
            chmod(dirname(big), 0o755); write(big, zeros(UInt8, 4000)); chmod(dirname(big), 0o555)
            before = only(r for r in usage("toy"; site = "cluster", io = devnull) if r.dir == dirs[2]).kb
            @test !del(:large; max_size = "2K", io = out, input = IOBuffer("n\n"))
            text = String(take!(out))
            @test occursin("chain-c/$(dirs[2])/big.dat", text) && occursin("they are lost", text)
            @test !occursin("simwatch.toml", text) && !occursin("/ck/", text)
            @test del(:large; max_size = "2K", runs = ["c"], yes = true, io = devnull)
            @test !ispath(big) && !iswritable(dirname(big)) && isdir(joinpath(run_dir, dirs[2], "ck"))
            @test only(r for r in usage("toy"; site = "cluster", io = devnull) if r.dir == dirs[2]).kb < before
            # every checkpoint: the run cannot continue
            @test del(:checkpoints; runs = ["c"], yes = true, io = devnull)
            @test !ispath(joinpath(run_dir, dirs[2], "ck")) && !iswritable(joinpath(run_dir, dirs[2]))
            @test only(r for r in usage("toy"; site = "cluster", io = devnull) if r.dir == dirs[2]).ck == 0

            # a job stopped on a pre-emptible queue submits its successor, which starts after it has ended
            g = spec(replace(ckpt, "name = \"chain\"" => "name = \"pre\"", "steps=20 delay=0.3" => "steps=16 delay=0.4"))
            id = submit("toy", g; site = "cluster", io = devnull)                    # the pre-emptible queue is chosen
            pre = joinpath(cscratch, "pre-c")
            while !any(startswith("step-"), try readdir(joinpath(pre, "001-$id", "ck")) catch; String[] end); sleep(0.2); end
            run(`kill -TERM $(readchomp(joinpath(ENV["FAKESLURM"], "$id.pid")))`)
            sleep(1)
            while !isempty(SimLaunch.active_jobs(cluster, "toy", "pre")); sleep(0.5); end
            next = readchomp(joinpath(cscratch, "logs", "pre-$id.next"))
            st = TOML.parsefile(joinpath(pre, "simwatch.toml"))
            @test st["status"] == "finished" && st["slurm"]["job_id"] == next && st["slurm"]["partition"] == "preq"
            @test isdir(joinpath(pre, "002-$next")) && !iswritable(joinpath(pre, "001-$id"))
            @test occursin("job $next continues it", read(joinpath(cscratch, "logs", "pre-$id.out"), String))
            done = merge([Dict(parse.(Int, split(l, ","))[1] => l for l in readlines(joinpath(pre, d, "count.csv"))[2:end])
                          for d in ("001-$id", "002-$next")]...)
            @test sort!(collect(keys(done))) == 1:16
        end

        @testset "check-restart" begin
            f = spec(ckpt)
            redirect_stdout(devnull) do
                prepare("toy"; site = "local", specs = [f])
            end
            out = IOBuffer()
            @test check_restart("toy", f; site = "local", poll = 0.3, io = out)
            text = String(take!(out))
            @test occursin("directory is unchanged", text) && occursin("check-restart: passed", text)
            # a project whose comparison does not accept the chain
            bad = spec(replace(ckpt, "examples/compare.jl" => "examples/hello.jl n=1 fail"))
            out = IOBuffer()
            @test !check_restart("toy", bad; site = "local", poll = 0.3, io = out)
            @test occursin("FAILED: the comparison", String(take!(out)))
            @test_throws "needs `compare`" check_restart("toy", spec(replace(ckpt, "compare = \"examples/compare.jl\"" => "")); site = "local", io = devnull)
        end

        @testset "list and delete" begin
            cluster, here = load_site("cluster"), load_site("local")
            out = IOBuffer()
            rows = SimLaunch.list(; io = out)
            text = String(take!(out))
            toy_cluster = only(r for r in rows if r.study == "toy" && r.site == "cluster")
            @test toy_cluster.live == 0 && toy_cluster.caches > 0 && toy_cluster.note == "the toy study \"T\""
            @test toy_cluster.project == "Toy@" * only(p for p in load_snapshot("toy")["package"] if p["name"] == "Toy")["sha"][1:7]
            @test any(r -> r.study == "toy" && r.site == "local", rows)
            @test occursin(r"^study\s+site\s+project", text) && occursin("the toy study", text)
            @test all(r -> r.live > 0 || !isempty(r.error), SimLaunch.list(; older_than = "1d", io = devnull))   # all is new
            @test_throws "an age is" SimLaunch.list(; older_than = "3x", io = devnull)
            @test_throws "--run chooses" SimLaunch.delete(["toy"]; sites = ["cluster"], runs = ["x"], io = devnull)
            @test_throws "not both" SimLaunch.delete(["toy"]; older_than = "1d", io = devnull)
            @test_throws "no study" SimLaunch.delete(["nosuch"]; sites = ["local"], yes = true, io = devnull)
            @test_throws "simlaunch delete" SimLaunch.command(["clean", "toy", "--site", "cluster"])
            # the compiled caches: the sources stay, and `prepare` must run again
            code = study_code(cluster, "toy")
            @test !SimLaunch.delete(["toy"]; sites = ["cluster"], level = :caches, io = out, input = IOBuffer("n\n"))
            text = String(take!(out))
            @test occursin("compiled caches", text) && occursin("`prepare` compiles them again", text)
            @test SimLaunch.delete(["toy"]; sites = ["cluster"], level = :caches, yes = true, io = devnull)
            @test !any(startswith("depot"), readdir(code)) && isdir(joinpath(code, "src"))
            @test only(r for r in SimLaunch.inventory(; sites = ["cluster"]) if r.study == "toy").caches == 0
            # the whole study on one site: the snapshot stays
            @test !SimLaunch.delete(["toy"]; sites = ["cluster"], io = out, input = IOBuffer("\n"))
            @test occursin("delete all this?", String(take!(out))) && isdir(code)
            @test SimLaunch.delete(["toy"]; sites = ["cluster"], yes = true, io = devnull)
            @test !ispath(code) && !ispath(study_scratch(cluster, "toy"))
            @test isfile(joinpath(ENV["SIMLAUNCH_CACHE"], "toy", "snapshot.toml"))
            @test all(r -> r.site == "local", status(["toy"]; io = devnull))
            @test_throws "no study" SimLaunch.delete(["toy"]; sites = ["cluster"], yes = true, io = devnull)
            # a study whose snapshot is gone from the laptop can still be deleted on a site
            for dir in (study_code(here, "lost"), study_scratch(here, "lost"))
                mkpath(joinpath(dir, "sub")); chmod(joinpath(dir, "sub"), 0o555)
            end
            @test any(r -> r.study == "lost" && r.site == "local" && r.project == "?", SimLaunch.inventory())
            @test SimLaunch.delete(["lost"]; sites = ["local"], yes = true, io = out)
            @test !ispath(study_code(here, "lost")) && !ispath(study_scratch(here, "lost"))
            @test !occursin("snapshot", String(take!(out)))
            # without --site: every site, and the snapshot on the laptop
            @test SimLaunch.delete(["toy"]; yes = true, io = out)
            @test occursin("deleted the snapshot of study toy", String(take!(out)))
            @test !ispath(joinpath(ENV["SIMLAUNCH_CACHE"], "toy")) && !ispath(study_code(here, "toy"))
            @test !any(r -> r.study == "toy", SimLaunch.inventory())
        end
    end
    run(`chmod -R u+w $root`)
    delete!(SimLaunch.ENV_KINDS, "dates")
end
