#!/usr/bin/env bash
set -u

# Remote worker for swb.ps1.  It deliberately keeps all simulation data in
# the user's SWB project and only adds .codex-controller for orchestration
# state, retry logs, and process recovery.

action=${1:-status}
project=${2:-}
max_retries=${3:-1}
keep_days=${4:-14}

die() { printf 'ERROR=%s\n' "$*" >&2; exit 1; }
is_number() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

[[ -n "$project" && "$project" = /* ]] || die 'Project path must be absolute.'
[[ -d "$project" ]] || die "Project directory does not exist: $project"

control="$project/.codex-controller"
runs="$control/runs"
current="$control/current.env"
lock="$control/active.lock"
mkdir -p "$runs"

get_value() {
    local file=$1 key=$2
    [[ -f "$file" ]] || return 0
    awk -F= -v k="$key" '$1 == k { value=substr($0, index($0, "=")+1) } END { if (value != "") print value }' "$file"
}

latest_swb_status() {
    if [[ -f "$project/.status" ]]; then
        awk -F'|' 'NF >= 4 { value=$4 } END { if (value != "") print value; else print unknown }' "$project/.status"
    else
        printf 'unknown\n'
    fi
}

process_alive() {
    local pid=${1:-}
    is_number "$pid" && kill -0 "$pid" 2>/dev/null
}

write_state() {
    local key=$1 value=$2
    printf '%s=%s\n' "$key" "$value" >> "$state"
    printf '%s=%s\n' "$key" "$value" >> "$current"
}

node_counts() {
    local done=0 running=0 queued=0 failed=0 total=0 file status
    shopt -s nullglob
    for file in "$project"/n*_*.sta; do
        total=$((total + 1))
        status=$(awk -F'|' 'NF >= 3 { value=$3 } END { print value }' "$file")
        case "$status" in
            done) done=$((done + 1)) ;;
            running) running=$((running + 1)) ;;
            queued) queued=$((queued + 1)) ;;
            failed|error) failed=$((failed + 1)) ;;
        esac
    done
    printf 'NODES_TOTAL=%s\nNODES_DONE=%s\nNODES_RUNNING=%s\nNODES_QUEUED=%s\nNODES_FAILED=%s\n' \
        "$total" "$done" "$running" "$queued" "$failed"
}

status() {
    if [[ ! -f "$current" ]]; then
        printf 'STATE=none\nSWB_STATUS=%s\n' "$(latest_swb_status)"
        node_counts
        return 0
    fi
    local pid run_state swb process
    run_state=$(get_value "$current" status)
    pid=$(get_value "$current" pid)
    swb=$(latest_swb_status)
    if process_alive "$pid"; then process=running; else process=stopped; fi
    printf 'STATE=%s\nPROCESS=%s\nPID=%s\nSWB_STATUS=%s\n' "$run_state" "$process" "$pid" "$swb"
    for key in runId project startedAt finishedAt exitCode attempt log; do
        value=$(get_value "$current" "$key")
        [[ -n "$value" ]] && printf '%s=%s\n' "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" "$value"
    done
    node_counts
}

retryable_log() {
    local file=$1
    [[ -f "$file" ]] || return 1
    grep -Eiq 'license|checkout|temporar|connection|network|resource temporarily|cannot connect|timed out|timeout' "$file"
}

worker() {
    local project_path=$1 state_path=$2 current_path=$3 log_path=$4 control_path=$5 retries=$6
    local attempt=0 rc=1 final=failed swb status_line
    append() {
        printf '%s=%s\n' "$1" "$2" >> "$state_path"
        printf '%s=%s\n' "$1" "$2" >> "$current_path"
    }
    while :; do
        attempt=$((attempt + 1))
        append attempt "$attempt"
        printf '\n===== SWB ATTEMPT %s (%s) =====\n' "$attempt" "$(date -Is)" >> "$log_path"
        gsub -e all "$project_path" >> "$log_path" 2>&1
        rc=$?
        swb=unknown
        if [[ -f "$project_path/.status" ]]; then
            swb=$(awk -F'|' 'NF >= 4 { value=$4 } END { if (value != "") print value; else print unknown }' "$project_path/.status")
        fi
        if [[ "$rc" -eq 0 && "$swb" == done ]]; then
            final=done
            break
        fi
        if [[ "$attempt" -le "$retries" ]] && retryable_log "$log_path"; then
            append recovery "retrying after transient failure (exit=$rc, swb=$swb)"
            sleep 3
            continue
        fi
        final=failed
        break
    done
    append exitCode "$rc"
    append swbStatus "$swb"
    append finishedAt "$(date -Is)"
    append status "$final"
    rmdir "$control_path/active.lock" 2>/dev/null || true
}

start() {
    is_number "$max_retries" || die 'Retry count must be a non-negative integer.'
    command -v gsub >/dev/null 2>&1 || bash -lc 'command -v gsub >/dev/null 2>&1' || die 'gsub is not available in the Sentaurus environment.'
    if [[ -f "$current" ]]; then
        local old_pid old_state
        old_pid=$(get_value "$current" pid)
        old_state=$(get_value "$current" status)
        if process_alive "$old_pid"; then
            printf 'ACTIVE=1\nRUN_ID=%s\nPID=%s\n' "$(get_value "$current" runId)" "$old_pid"
            exit 20
        fi
        if [[ "$old_state" == running ]]; then
            printf 'RECOVERED_STALE=1\nOLD_RUN_ID=%s\n' "$(get_value "$current" runId")" >> "$runs/recovery.log"
            printf 'status=stale\nrecoveredAt=%s\n' "$(date -Is)" >> "$current"
        fi
    fi
    if ! mkdir "$lock" 2>/dev/null; then
        die 'Another SWB controller is starting or running this project.'
    fi
    local run_id state log pid
    run_id="swb-$(date +%Y%m%d-%H%M%S)-$$"
    state="$runs/$run_id.env"
    log="$runs/$run_id.log"
    : > "$state"
    : > "$log"
    : > "$current"
    printf 'runId=%s\nproject=%s\nstartedAt=%s\nstatus=running\nlog=%s\n' \
        "$run_id" "$project" "$(date -Is)" "$log" | tee "$state" "$current" >/dev/null
    export -f worker
    nohup setsid bash -lc 'worker "$@"' -- "$project" "$state" "$current" "$log" "$control" "$max_retries" \
        >/dev/null 2>&1 < /dev/null &
    pid=$!
    printf 'pid=%s\n' "$pid" | tee -a "$state" "$current" >/dev/null
    printf 'RUN_ID=%s\nPID=%s\nLOG=%s\nPROJECT=%s\n' "$run_id" "$pid" "$log" "$project"
}

stop() {
    [[ -f "$current" ]] || { printf 'STATE=none\n'; return 0; }
    local pid
    pid=$(get_value "$current" pid)
    if process_alive "$pid"; then
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        sleep 2
        kill -9 -- "-$pid" 2>/dev/null || true
    fi
    printf 'status=stopped\nstoppedAt=%s\n' "$(date -Is)" | tee -a "$current" >/dev/null
    rmdir "$lock" 2>/dev/null || true
    printf 'STOPPED=1\nPID=%s\n' "$pid"
}

report() {
    status
    local log
    log=$(get_value "$current" log)
    if [[ -n "$log" && -f "$log" ]]; then
        printf '\n--- LOG_TAIL ---\n'
        tail -n 40 "$log"
    fi
    printf '\n--- NODE_LOGS ---\n'
    shopt -s nullglob
    local file
    for file in "$project"/n*_*.err "$project"/n*_local.err; do
        [[ -f "$file" ]] || continue
        printf '%s (%s bytes)\n' "$(basename "$file")" "$(wc -c < "$file")"
    done
}

clean() {
    is_number "$keep_days" || die 'KeepDays must be a non-negative integer.'
    local pid
    pid=$(get_value "$current" pid)
    process_alive "$pid" && die 'Cannot clean while a SWB run is active; use stop first.'
    find "$runs" -type f -mtime "+$keep_days" -delete
    rmdir "$lock" 2>/dev/null || true
    printf 'CLEANED=1\nKEEP_DAYS=%s\n' "$keep_days"
}

case "$action" in
    start) start ;;
    status) status ;;
    stop) stop ;;
    report) report ;;
    clean) clean ;;
    *) die "Unknown action: $action" ;;
esac
