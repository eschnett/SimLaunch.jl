# --- SimLaunch helpers: directories and SimWatch status files ---------------

run_dir() {   # RUN-INDEX: the run's directory, which holds one directory per job
    echo "$SCRATCH/$SPEC-${LABELS[$1]}"
}

sw_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# sw_write RUN-INDEX STATUS MESSAGE: rewrite the run's simwatch.toml.
sw_write() {
    local i=$1 status=$2 message=$3 dir f tmp
    dir=$(run_dir "$i")
    f=$dir/simwatch.toml
    tmp=$f.tmp.$$.$RANDOM
    {
        echo "name = \"$STUDY $SPEC/${LABELS[$i]}\""
        echo "status = \"$status\""
        echo "code = \"SimLaunch\""
        echo "group = \"$STUDY\""
        echo "updated = $(sw_now)"
        echo "started = $SW_STARTED"
        echo "update_interval = 60"
        echo "host = \"$(hostname -s)\""
        echo "message = \"$message\""
        echo
        echo "[progress]"
        if [ "$status" = finished ]; then echo "fraction = 1.0"; fi
        echo "walltime = $(( $(date +%s) - SW_T0 ))"
        if [ -n "$TIME_LIMIT" ]; then echo "walltime_limit = $TIME_LIMIT"; fi
        echo
        echo "[resources]"
        echo "nodes = $NODES"
        echo "threads = ${THREADS[$i]}"
        if [ -n "${SLURM_JOB_ID:-}" ]; then
            echo
            echo "[slurm]"
            echo "job_id = \"$SLURM_JOB_ID\""
            echo "job_name = \"${SLURM_JOB_NAME:-}\""
            echo "partition = \"${SLURM_JOB_PARTITION:-}\""
        fi
    } > "$tmp" && mv -f "$tmp" "$f"
    return 0
}

# sw_queued RUN-INDEX: a submitted job, before it starts. Does nothing if the
# job has started already.
sw_queued() {
    local i=$1 dir f tmp id=
    dir=$(run_dir "$i")
    f=$dir/simwatch.toml
    tmp=$f.tmp.$$.$RANDOM
    mkdir -p "$dir" || return
    if [ -f "$dir/.simlaunch-job" ]; then read -r id _ < "$dir/.simlaunch-job"; fi
    if [ "$id" = "$JOBID" ]; then return 0; fi
    {
        echo "name = \"$STUDY $SPEC/${LABELS[$i]}\""
        echo "status = \"queued\""
        echo "code = \"SimLaunch\""
        echo "group = \"$STUDY\""
        echo "updated = $(sw_now)"
        echo "message = \"queued as job $JOBID\""
        if [ "$USE_SLURM" = 1 ]; then
            echo
            echo "[slurm]"
            echo "job_id = \"$JOBID\""
        fi
    } > "$tmp" && mv -f "$tmp" "$f"
}

# new_job_dir RUN-INDEX: this job's own directory in the run, numbered in order.
new_job_dir() {
    local dir n
    dir=$(run_dir "$1")
    # the run's directory may not exist yet: a job can start before it is marked queued
    n=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9]-*' 2>/dev/null | wc -l)
    printf '%s/%03d-%s\n' "$dir" $((n + 1)) "$JOBID"
}

# run_one RUN-INDEX: run it in its job directory, keep its SimWatch file
# current, and make the directory read-only when it has ended. Call in a
# subshell; exits with the run's exit code.
run_one() {
    local i=$1 dir jobdir=${JOBDIRS[$1]} pid heartbeat rc
    dir=$(run_dir "$i")
    cd "$jobdir" || exit 1
    echo "$JOBID running" > "$dir/.simlaunch-job"
    sw_write "$i" running "running in $(basename "$jobdir")"
    ( while sleep 60; do sw_write "$i" running "running in $(basename "$jobdir")"; done ) &
    heartbeat=$!
    "run_$i" > "$jobdir/output.log" 2>&1 &
    pid=$!
    trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
    wait "$pid"; rc=$?
    while kill -0 "$pid" 2>/dev/null; do wait "$pid"; rc=$?; done
    kill "$heartbeat" 2>/dev/null
    wait "$heartbeat" 2>/dev/null
    if [ "$rc" -eq 0 ]; then
        sw_write "$i" finished "finished in $(basename "$jobdir")"
    else
        sw_write "$i" failed "exit code $rc in $(basename "$jobdir") on $(hostname -s)"
    fi
    echo "$JOBID done $rc" > "$dir/.simlaunch-job"
    chmod -R a-w "$jobdir"
    exit "$rc"
}

# wait_runs: wait for the runs in PIDS; fails if one of them failed.
wait_runs() {
    local pid rc bad=0
    for pid in "${PIDS[@]}"; do
        wait "$pid"; rc=$?
        while kill -0 "$pid" 2>/dev/null; do wait "$pid"; rc=$?; done
        if [ "$rc" -ne 0 ]; then bad=1; fi
    done
    return $bad
}

# The job was told to stop (time limit, scancel): pass it on to the runs.
on_term() {
    TERMINATED=1
    echo "job $JOBID: terminated, stopping the runs"
    kill -TERM ${PIDS[@]+"${PIDS[@]}"} 2>/dev/null
}

# When the job ends, however it ends: mark the runs that did not finish, make
# every job directory read-only, and echo the runs' output into the job's log.
finish() {
    local rc=$? i dir id state
    for i in "${!LABELS[@]}"; do
        dir=$(run_dir "$i")
        id= state=
        if [ -f "$dir/.simlaunch-job" ]; then read -r id state _ < "$dir/.simlaunch-job"; fi
        if [ "$id" != "$JOBID" ] || [ "$state" != done ]; then
            sw_write "$i" failed "job $JOBID ended before this run finished (exit code $rc)"
            echo "$JOBID done $rc" > "$dir/.simlaunch-job"
        fi
        if [ -d "${JOBDIRS[$i]:-}" ]; then
            chmod -R a-w "${JOBDIRS[$i]}"
            echo
            echo "=== output of ${LABELS[$i]} (${JOBDIRS[$i]}/output.log) ==="
            cat "${JOBDIRS[$i]}/output.log" 2>/dev/null
        fi
    done
    echo
    echo "job $JOBID ended with exit code $rc at $(date)"
}

# --- end of the helpers ------------------------------------------------------
