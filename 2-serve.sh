#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

READY_TIMEOUT=1800
RUNNING_TIMEOUT=900

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

server_ready() {
    rsh "curl -sf --max-time 5 http://127.0.0.1:$REMOTE_PORT/v1/models" >/dev/null 2>&1
}

sglang_log_snip() {
    rsh 'for f in /var/log/portal/sglang.log /workspace/sglang.log /var/log/portal/*.log; do
             [ -f "$f" ] || continue
             echo "=== $f ==="
             tail -n 80 "$f"
         done' 2>/dev/null || true
}

sglang_alive() {
    rsh 'pgrep -af "sglang" | grep -Eiv "pgrep|grep" >/dev/null' >/dev/null 2>&1
}

# returns 0 when the api answers, 1 when the process died; FAIL_REASON holds the tail
wait_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    local mem log
    FAIL_REASON=""
    while ((SECONDS < deadline)); do
        if server_ready; then
            c_green "SGLang API is up"
            return 0
        fi
        if ! sglang_alive; then
            FAIL_REASON=$(sglang_log_snip || echo "no log found on instance")
            return 1
        fi

        mem=$(rsh 'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1' || echo "?")
        printf '[%s] waiting for SGLang API  (GPU %s MiB)\n' "$(date +%H:%M:%S)" "$mem" >&2
        sleep 15
    done
    FAIL_REASON="timed out after ${READY_TIMEOUT}s"
    log=$(sglang_log_snip || true)
    [[ -n "$log" ]] && FAIL_REASON="$FAIL_REASON"$'\n'"$log"
    return 1
}

benchmark() {
    local out
    out=$(rsh "python3 /root/bench.py $MODEL" 2>/dev/null) || return 1
    grep -oE 'TPS [0-9.]+' <<<"$out" | awk '{print $2}'
}

main() {
    local tps
    ensure_cli
    need python3
    require_instance
    wait_running
    wait_ssh
    rsh 'cat > /root/bench.py' <bench.py

    c_yellow "waiting for template boot serve ($MODEL via SGLang EAGLE)"
    if ! wait_ready; then
        c_red "SGLang failed to start"
        printf '%s\n' "$FAIL_REASON" >&2
        die "template boot config did not come up; see logs on the instance"
    fi

    tps=$(benchmark) || tps=""
    if [[ -n "$tps" ]]; then
        c_green "decode throughput: $tps tok/s"
        state_set best_tps "$tps"
    else
        c_yellow "benchmark failed; api is up anyway"
        state_set best_tps ""
    fi
    state_set best_rung "boot"
    record_proxy_ports
    c_green "server ready on the instance; next: ./3-tunnel.sh"
}

main "$@"
