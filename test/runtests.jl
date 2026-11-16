using SimLaunch
using SimLaunch: UserError, parse_time, load_site, load_spec, load_snapshot, resolve, generate, snapshot,
                 prepare, submit, study_scratch
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
          registry_update = false
          """)
    cp(joinpath(pkgdir(SimLaunch), "sites", "trillium.toml"), joinpath(sites, "trillium.toml"))
    spec(text) = (f = tempname(root) * ".toml"; write(f, text); f)

    withenv("SIMLAUNCH_CACHE" => joinpath(root, "cache"), "SIMLAUNCH_SITES" => sites) do
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
            @test_throws "no less than 0:15:00" job(replace(spec_text(RUNS), "3:00:00" => "0:10:00"), trillium)
            @test_throws "no queue" job(spec_text(RUNS), trillium; queue = "nonesuch")
            @test_throws "unknown key" job(spec_text(RUNS; top = "tiem = \"1:00:00\""), trillium)
            @test_throws "milestone 3" job(spec_text(RUNS; top = "checkpoints = true"), trillium)
            @test_throws "milestone 3" job(spec_text(RUNS * "ranks = 8\n"), trillium)
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
    end
    run(`chmod -R u+w $root`)
end
