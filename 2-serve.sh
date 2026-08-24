#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

READY_TIMEOUT=1800
RUNNING_TIMEOUT=900
EXTRA_ENV=""
CURRENT_RUNG=""
BEST_RUNG=""
BEST_TPS=0
RESULTS=()

wait_running() {
    local status deadline=$((SECONDS + RUNNING_TIMEOUT))
    c_yellow "waiting for instance $INSTANCE_ID to reach 'running'..."
    while ((SECONDS < deadline)); do
        status=$(instance_field actual_status)
        case "$status" in
            running)
                c_green "instance is running"
                return 0
                ;;
            exited | offline)
                die "instance entered state '$status': $(instance_field status_msg)"
                ;;
        esac
        printf '[%s] status: %s %s\n' "$(date +%H:%M:%S)" "${status:-unknown}" "$(instance_field status_msg)" >&2
        sleep 10
    done
    die "instance never reached 'running' within ${RUNNING_TIMEOUT}s"
}

wait_ssh() {
    local deadline=$((SECONDS + 600))
    resolve_ssh || die "could not resolve ssh url for $INSTANCE_ID"
    c_yellow "ssh target: $SSH_USER@$SSH_HOST:$SSH_PORT"
    while ((SECONDS < deadline)); do
        rsh true >/dev/null 2>&1 && {
            c_green "ssh is up"
            return 0
        }
        sleep 8
    done
    die "ssh never became reachable"
}

# only enable flags this vllm build actually exposes, rather than assuming
probe_capabilities() {
    local help envs
    help=$(rsh 'vllm serve --help 2>/dev/null' || true)
    envs=$(rsh 'python3 -c "import vllm.envs as e; print(chr(10).join(dir(e)))" 2>/dev/null' || true)

    HAS_COMPILATION=0
    HAS_SPECULATIVE=0
    [[ -n "$help" ]] || c_yellow "warning: 'vllm serve --help' returned nothing, tuning rungs will be skipped"
    grep -q -- '--compilation-config' <<<"$help" && HAS_COMPILATION=1
    grep -q -- '--speculative-config' <<<"$help" && HAS_SPECULATIVE=1

    if grep -qx 'VLLM_USE_FLASHINFER_MOE_FP4' <<<"$envs"; then
        EXTRA_ENV="VLLM_USE_FLASHINFER_MOE_FP4=1"
        c_green "flashinfer nvfp4 moe kernels available, enabling them"
    fi
    c_yellow "flags: compilation-config=$HAS_COMPILATION speculative-config=$HAS_SPECULATIVE"
}

rung_supported() {
    local args
    args=$(rung_args "$1")
    [[ "$args" == *--compilation-config* ]] && ((HAS_COMPILATION == 0)) && return 1
    [[ "$args" == *--speculative-config* ]] && ((HAS_SPECULATIVE == 0)) && return 1
    return 0
}

stop_vllm() {
    rsh 'supervisorctl stop vllm >/dev/null 2>&1 || true
         pkill -9 -f "vllm serve" || true
         pkill -9 -f "unbuffer.*vllm" || true
         for _ in $(seq 30); do
             used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
             [ "$used" -lt 1500 ] && break
             sleep 2
         done' >/dev/null 2>&1 || true
}

start_rung() {
    local rung="$1" args
    args=$(rung_args "$rung")

    {
        echo '#!/bin/bash'
        [[ -n "$EXTRA_ENV" && "$rung" != "E" ]] && echo "export $EXTRA_ENV"
        echo "exec vllm serve $MODEL $args"
    } | rsh 'cat > /root/run-vllm.sh && chmod +x /root/run-vllm.sh'

    rsh "rm -f /workspace/vllm-$rung.log; setsid nohup /root/run-vllm.sh >/workspace/vllm-$rung.log 2>&1 </dev/null &"
    CURRENT_RUNG="$rung"
}

server_ready() {
    rsh "curl -sf --max-time 5 http://127.0.0.1:$REMOTE_PORT/v1/models" >/dev/null 2>&1
}

# returns 0 when the api answers, 1 when the process died; FAIL_REASON holds the tail
wait_ready() {
    local rung="$1" deadline=$((SECONDS + READY_TIMEOUT))
    FAIL_REASON=""
    while ((SECONDS < deadline)); do
        server_ready && return 0
        if ! rsh 'pgrep -f "vllm serve" >/dev/null'; then
            FAIL_REASON=$(rsh "tail -40 /workspace/vllm-$rung.log 2>/dev/null || tail -40 /var/log/portal/vllm.log 2>/dev/null" || echo "no log found on instance")
            return 1
        fi
        printf '[%s] rung %s: loading...\n' "$(date +%H:%M:%S)" "$rung" >&2
        sleep 15
    done
    FAIL_REASON="timed out after ${READY_TIMEOUT}s"
    return 1
}

benchmark() {
    local out
    out=$(rsh "python3 /root/bench.py $MODEL" 2>/dev/null) || return 1
    grep -oE 'TPS [0-9.]+' <<<"$out" | awk '{print $2}'
}

record() {
    local rung="$1" tps="$2" note="$3"
    RESULTS+=("$rung|$tps|$note")
    if [[ "$tps" != "-" ]] && awk "BEGIN{exit !($tps > $BEST_TPS)}"; then
        BEST_TPS="$tps"
        BEST_RUNG="$rung"
    fi
}

measure_rung() {
    local rung="$1" tps
    c_yellow "=== rung $rung: $(rung_args "$rung")"
    if ! wait_ready "$rung"; then
        c_red "rung $rung failed to start"
        printf '%s\n' "$FAIL_REASON" >&2
        record "$rung" "-" "crashed: $(tail -1 <<<"$FAIL_REASON" | cut -c1-80)"
        return 1
    fi
    tps=$(benchmark) || tps=""
    [[ -n "$tps" ]] || {
        record "$rung" "-" "benchmark failed"
        return 1
    }
    c_green "rung $rung: $tps tok/s"
    record "$rung" "$tps" "ok"
    return 0
}

beats_target() {
    [[ -n "$BEST_TPS" ]] && awk "BEGIN{exit !($BEST_TPS >= $TARGET_TPS)}"
}

report() {
    local row rung tps note
    printf '\n%-6s %10s  %s\n' "rung" "tok/s" "result" >&2
    for row in "${RESULTS[@]}"; do
        IFS='|' read -r rung tps note <<<"$row"
        printf '%-6s %10s  %s\n' "$rung" "$tps" "$note" >&2
    done
    printf '\n' >&2

    [[ -n "$BEST_RUNG" ]] || die "every configuration failed; see logs in /workspace on the instance"
    c_green "best: rung $BEST_RUNG at $BEST_TPS tok/s"
    rsh 'nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader' >&2 || true
}

main() {
    ensure_cli
    need python3
    require_instance
    wait_running
    wait_ssh
    probe_capabilities
    rsh 'cat > /root/bench.py' <bench.py

    # the boot config from 1-launch.sh is already downloading the model and starting;
    # measure it first so a good-enough boot skips the whole ladder
    c_yellow "=== boot config (model download happens here, can take a while)"
    if wait_ready boot && tps=$(benchmark) && [[ -n "$tps" ]]; then
        c_green "boot config: $tps tok/s"
        record boot "$tps" "ok"
        CURRENT_RUNG="boot"
    else
        record boot "-" "boot config unusable"
    fi

    if ! beats_target; then
        for rung in "${RUNGS[@]}"; do
            if ! rung_supported "$rung"; then
                record "$rung" "-" "flag unsupported by this vllm build"
                continue
            fi
            stop_vllm
            start_rung "$rung"
            measure_rung "$rung" || continue
            beats_target && break
        done
    fi

    report

    if [[ "$CURRENT_RUNG" != "$BEST_RUNG" ]]; then
        c_yellow "restarting on the winning config (rung $BEST_RUNG)"
        stop_vllm
        start_rung "$BEST_RUNG"
        wait_ready "$BEST_RUNG" || die "winning config failed to restart"
    fi

    state_set best_rung "$BEST_RUNG"
    state_set best_tps "$BEST_TPS"
    c_green "server ready on the instance; next: ./3-tunnel.sh"
}

main "$@"
