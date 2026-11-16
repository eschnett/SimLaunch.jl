using SimLaunch
using SimLaunch: UserError, parse_time, load_site, load_spec, load_snapshot, resolve, generate, snapshot,
                 prepare, submit, study_scratch, study_code, combos, combo_line, lock_dir, manifest_versions,
                 resubmit, status, fetch, usage, clean, combine, check_restart
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
        all(t -> t !== nothing && t["status"] in ("finished", "failed"), tables) && return tables
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
          """)
    for name in ("trillium", "trillium-gpu", "symmetry", "nibi")
        cp(joinpath(pkgdir(SimLaunch), "sites", "$name.toml"), joinpath(sites, "$name.toml"))
    end
    # a Slurm site on this machine, with the stand-ins of test/fakeslurm for sbatch and squeue
    write(joinpath(sites, "cluster.toml"), """
          name = "cluster"
          [paths]
          code = "$(joinpath(root, "cluster", "code"))"
          scratch = "$(joinpath(root, "cluster", "scratch"))"
          [slurm]
          node = { cores = 4, header = ["--exclusive"] }
          queues = [{ partition = "cpuq", max_time = "1:00:00" }, { partition = "preq", max_time = "1:00:00", preempt = true }]
          [slurm.gpu]
          request = "--gres=gpu:%d"
          cores = 2
          mem = "8G"
          max = 2
          queues = [{ partition = "gpuq", max_time = "1:00:00", max_gpus = 1 }]
          [julia]
          bin = "$(joinpath(Sys.BINDIR, "julia"))"
          depot = "$(joinpath(root, "depot"))"
          registry_update = false
          precompile_on = "compute"
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

        @testset "snapshot" begin
            dest = snapshot(toy; study = "toy")
            @test isfile(joinpath(dest, "src", "Toy", "src", "Toy.jl"))
            @test isfile(joinpath(dest, "src", "ToyDep", "src", "ToyDep.jl"))     # relative position kept
            @test !ispath(joinpath(dest, "src", "Toy", "Manifest.toml"))          # manifests are not copied
            @test !ispath(joinpath(dest, "src", "Toy", "backup.jl~"))
            @test !ispath(joinpath(dest, "src", "Toy", ".git"))
            snap = load_snapshot("toy")
            @test snap["project"] == "Toy"
            pkgs = Dict(p["name"] => p for p in snap["package"])
            @test pkgs["Toy"]["dirty"] && length(pkgs["Toy"]["sha"]) == 40
            @test occursin("an uncommitted change", read(joinpath(dest, pkgs["Toy"]["diff"]), String))
            @test !pkgs["ToyDep"]["git"]
            @test_throws UserError snapshot(toy; study = "toy")                    # a study is never rewritten
            @test_throws UserError snapshot(toy; study = "bad name")
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
            @test_throws "needs `mpi`" job(spec_text(RUNS * "ranks = 8\n"), trillium)
            @test_throws "milestone 4" job(spec_text(RUNS * "julia = \"+1.13\"\n"), trillium)
            @test_throws "no variant" job(spec_text(RUNS * "variant = \"base\"\n"), trillium)
            # a spec written for one site names it, and has no site tables
            one = "name = \"hello\"\nsite = \"symmetry\"\ntime = \"1:00:00\"\n" * RUNS
            @test_throws "for site symmetry only" job(one, trillium)
            @test job(replace(one, "symmetry" => "trillium"), trillium).time == 3600
            @test_throws "no `time`" job(replace(spec_text(RUNS), "time = \"3:00:00\"" => ""), trillium)
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
            [site.symmetry]
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
        @testset "the other sites" begin
            job(site; text = gpu_spec, kw...) =
                resolve(load_spec(spec(text)), load_site(site); study = "toy", project = "Toy", kw...)
            j = job("symmetry")
            @test j.gpus == 1 && j.cores == 8 && j.queue.partition == "h200debugq" && j.runs[1].threads == 8
            @test j.runs[1].envdir == "envs/default-cuda"
            @test combo_line(only(combos(j))) == "envs/default-cuda\t\tgpu"
            j = job("trillium-gpu")
            @test j.gpus == 2 && j.cores == 48 && j.queue.partition == "debug"
            j = job("nibi")
            @test j.gpus == 0 && j.queue === nothing && j.runs[1].envdir == "src/Toy"
            @test combo_line(only(combos(j))) == "Toy"
            for (site, name) in (("symmetry", "symmetry-gpu"), ("trillium-gpu", "trillium-gpu"), ("nibi", "nibi-hello"))
                script = generate(job(site))
                reference = joinpath(@__DIR__, "reference", "$name.sh")
                get(ENV, "SIMLAUNCH_UPDATE_REFERENCE", "") == "1" && write(reference, script)
                @test script == read(reference, String)
                @test success(`bash -n $reference`)
            end
            # refusals
            @test job("symmetry"; text = replace(gpu_spec, "gpus = 1" => "gpus = 3")).queue.partition == "h200q"
            @test_throws "at most 2 GPUs" job("symmetry"; text = replace(gpu_spec, "gpus = 1" => "gpus = 3"), queue = "h200debugq")
            @test_throws "at most 4" job("trillium-gpu"; text = replace(gpu_spec, "gpus = 2" => "gpus = 5"))
            @test_throws "at most 1:00:00" job("symmetry"; text = replace(gpu_spec, "0:30:00" => "2:00:00"), queue = "h200debugq")
            @test job("symmetry"; text = replace(gpu_spec, "0:30:00" => "2:00:00")).queue.partition == "h200q"
            @test_throws "pre-emptible" job("symmetry"; queue = "h200preq")
            @test_throws "for GPU jobs" job("symmetry"; queue = "amdq")
            @test_throws "GPU jobs only" job("trillium-gpu"; text = replace(gpu_spec, "resources = { gpus = 2 }" => ""))
            @test_throws "has none" job("trillium"; text = replace(gpu_spec, "site.nibi" => "site.trillium",
                                                                    "mode = \"parallel\"" => "resources = { gpus = 1 }"))
            @test_throws "chooses the partition" job("nibi"; queue = "cpubase")
            @test_throws "at most 168:00:00" job("nibi"; text = replace(gpu_spec, "3:00:00" => "8-00:00:00"))
            @test_throws "no environment" job("symmetry"; text = replace(gpu_spec, "\"cuda\"" => "\"opencl\""))
            @test job("symmetry"; text = replace(gpu_spec, "\"cuda\"" => "\"test+cuda\"")).runs[1].envdir == "envs/default-test+cuda"
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
            # a second job of the same run gets a new directory
            sleep(1.1)
            jobid2 = submit("toy", f; site = "local", io = devnull)
            wait_for(scratch, ["hello-n3", "hello-n5"])
            sleep(1)
            @test isdir(joinpath(scratch, "hello-n3", "002-$jobid2")) && isdir(dir)
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
            # the second run is now running; stop the job as a time limit would
            pidfile = joinpath(scratch, "logs", "hello-$jobid.pid")
            while !isfile(joinpath(scratch, "hello-long", "001-$jobid", "result.csv")); sleep(0.2); end
            run(`kill -TERM $(readchomp(pidfile))`)
            long, never = wait_for(scratch, ["hello-long", "hello-never"])
            @test long["status"] == "failed" && never["status"] == "failed"
            sleep(1)
            @test !iswritable(joinpath(scratch, "hello-long", "001-$jobid"))
            log = read(joinpath(scratch, "logs", "hello-$jobid.out"), String)
            @test occursin("=== output of bad", log) && occursin("ended with exit code", log)
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
            mkpath(lock_dir(cluster)); write(joinpath(lock_dir(cluster), "jobid"), "999\n")
            out = IOBuffer()
            needed = redirect_stdout(devnull) do
                prepare("toy"; site = "cluster", specs = [f], poll = 0.5, io = out)
            end
            @test combo_line.(needed) == ["envs/default-dates\t\tgpu"]
            @test !ispath(lock_dir(cluster))                                     # given back by the job
            @test readlines(joinpath(ccode, "depot", "prepared")) == ["envs/default-dates\t\tgpu"]
            # the caches are the study's own; the packages are the site's
            @test "Toy" in readdir(joinpath(ccode, "depot", "compiled", "v$(VERSION.major).$(VERSION.minor)"))
            @test islink(joinpath(ccode, "depot", "packages"))
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

        # a spec written for Symmetry: two versions of the package, MPI ranks placed on NUMA domains, two recipes
        nested = """
            name = "nested"
            site = "symmetry"
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
            mpi = "system"
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

            [site.symmetry]
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
            j = job(nested, "symmetry")
            @test j.queue.partition == "amdq" && j.nodes == 2 && j.tasks == 8         # two nodes: not amddebugq
            @test [r.envdir for r in j.runs] == ["envs/base-test+mpi-jll", "envs/default-test+mpi-system", "envs/default-test+mpi-jll"]
            @test [r.threads for r in j.runs] == [8, 8, 8]                            # a NUMA domain each
            @test combo_line.(combos(j)) == ["envs/base-test+mpi-jll", "envs/default-test+mpi-system", "envs/default-test+mpi-jll"]
            prep = SimLaunch.prepare_script(load_site("symmetry"), "toy2", combos(j))
            @test occursin("make_env.jl \"\$CODE\"/variants/base/src/Toy \"\$CODE\"/envs/base-test+mpi-jll --test MPI MPIPreferences", prep)
            @test occursin("set_mpi.jl system", prep) && occursin("module load nvhpc-hpcx-cuda12/24.9", prep)
            @test_throws "do not fit" job(replace(nested, "ranks = 8" => "ranks = 16"), "symmetry")
            @test_throws "64 cores" job(replace(nested, "label = \"base-8r\"" => "label = \"base-8r\"\nthreads = 9"), "symmetry")
            @test_throws "no MPI recipe" job(replace(nested, "\"system\"" => "\"cray\""), "symmetry")
            @test_throws "one node only" job(replace(nested, "\"system\"" => "\"jll-fork\""), "symmetry")
            @test_throws "pin = true" job(replace(nested, "placement = \"numa\"" => "placement = \"numa\"\npin = true"), "symmetry")
            @test_throws "for site symmetry only" job(nested, "trillium")
            # a chain of jobs: a pre-emptible queue first, and never the queue that is not for chains
            j = job(ckpt, "symmetry")
            @test j.checkpoints && j.queue.partition == "h200preq" && j.restart.continue_code == 3
            @test_throws "not for a chain" job(replace(ckpt, "12:00:00" => "0:30:00"), "symmetry"; queue = "h200debugq")
            @test_throws "needs `checkpoints = true`" job(replace(ckpt, "checkpoints = true" => ""), "symmetry")
            @test_throws "a chain of jobs needs" job(gpu_spec, "symmetry"; chain = 2)
            @test_throws "remove `from`" job(replace(ckpt, "checkpoints = true" => "checkpoints = true\nmutable_restarts = true"), "symmetry")
            m = job(replace(ckpt, "checkpoints = true" => "checkpoints = true\nmutable_restarts = true", "from = \"restart_from\"" => ""), "symmetry")
            @test occursin("#SBATCH --requeue\n#SBATCH --open-mode=append", generate(m)) && !occursin("seal_earlier \"\$i\"", generate(m))
            for (name, text) in (("symmetry-nested", nested), ("symmetry-chain", ckpt))
                script = generate(job(text, "symmetry"))
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

        @testset "a chain of jobs, its disk usage, fetch and clean" begin
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
            while !isempty(SimLaunch.active_jobs(cluster, "toy", "chain")); sleep(0.5); end
            run_dir = joinpath(cscratch, "chain-c")
            st = TOML.parsefile(joinpath(run_dir, "simwatch.toml"))
            @test st["status"] == "finished" && st["slurm"]["previous_job_ids"] == [ids[1]]
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
            @test dest == joinpath(realpath(toy), ".claude", "data", "toy", "cluster")
            @test isfile(joinpath(dest, "chain-c", dirs[2], "count.csv")) && isfile(joinpath(dest, "chain-c", "simwatch.toml"))
            @test !ispath(joinpath(dest, "chain-c", dirs[1], "ck")) && isfile(joinpath(dest, "snapshot.toml"))
            @test isfile(joinpath(dest, "manifests", "src--Toy.toml")) && isfile(joinpath(dest, "logs", "chain-$(ids[1]).out"))
            fetch("toy"; site = "cluster", runs = ["chain-c"], with_checkpoints = true, to = joinpath(root, "fetched"), io = devnull)
            @test isdir(joinpath(root, "fetched", "cluster", "chain-c", dirs[2], "ck"))
            @test !ispath(joinpath(root, "fetched", "cluster", "dev-n4"))
            # old checkpoints are deleted only after a yes
            out = IOBuffer()
            @test !clean("toy"; site = "cluster", old_checkpoints = true, io = out, input = IOBuffer("n\n"))
            @test occursin("chain-c/$(dirs[1])/ck", String(take!(out))) && isdir(joinpath(run_dir, dirs[1], "ck"))
            @test clean("toy"; site = "cluster", old_checkpoints = true, yes = true, io = devnull)
            @test !ispath(joinpath(run_dir, dirs[1], "ck")) && isdir(joinpath(run_dir, dirs[2], "ck"))
            @test !iswritable(joinpath(run_dir, dirs[1]))
            @test only(r for r in usage("toy"; site = "cluster", io = devnull) if r.dir == dirs[1]).ck == 0

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

        @testset "clean" begin
            cluster = load_site("cluster")
            out = IOBuffer()
            @test !clean("toy"; site = "cluster", io = out, input = IOBuffer("\n"))
            @test occursin("delete both directories?", String(take!(out))) && isdir(study_code(cluster, "toy"))
            @test clean("toy"; site = "cluster", yes = true, io = devnull)
            @test !ispath(study_code(cluster, "toy")) && !ispath(study_scratch(cluster, "toy"))
            @test isfile(joinpath(ENV["SIMLAUNCH_CACHE"], "toy", "snapshot.toml"))   # the snapshot stays
            @test all(r -> r.site == "local", status(["toy"]; io = devnull))
        end
    end
    run(`chmod -R u+w $root`)
    delete!(SimLaunch.ENV_KINDS, "dates")
end
