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
    rsh 'f=/var/log/portal/sglang.log
         if [ -f "$f" ]; then tail -n 100 "$f"; else echo "(no sglang.log yet)"; fi' 2>/dev/null || true
}

# True when the template's sglang supervisor wrapper or the serve process is up.
sglang_alive() {
    rsh 'pgrep -f "/opt/supervisor-scripts/sglang.sh|sglang serve" >/dev/null' >/dev/null 2>&1
}

# True when supervisor reports a hard failure (not merely "not started yet").
sglang_crashed() {
    rsh 'st=$(supervisorctl status sglang 2>/dev/null || true)
         case "$st" in *FATAL*|*BACKOFF*|*EXITED*) exit 0 ;; esac
         if ! pgrep -f "/opt/supervisor-scripts/sglang.sh|sglang serve" >/dev/null; then
             if [ -f /var/log/portal/sglang.log ] && \
                grep -qE "Traceback|CUDA out of memory" /var/log/portal/sglang.log; then
                 exit 0
             fi
         fi
         exit 1' >/dev/null 2>&1
}

boot_stage() {
    # Order matters: later matches override earlier ones.
    rsh 'f=/var/log/portal/sglang.log
         [ -f "$f" ] || { echo "waiting for sglang log"; exit 0; }
         stage="starting"
         grep -q "portal.yaml" "$f" && stage="waiting for portal.yaml"
         grep -q "provisioning has completed" "$f" && stage="waiting for provisioning"
         grep -Eqi "download|fetching|will attempt download" "$f" && stage="downloading model"
         grep -Eq "Load weight|Using model weights format" "$f" && stage="loading weights"
         grep -Eqi "cuda graph|Capture cuda" "$f" && stage="capturing cuda graphs"
         grep -Eq "fired up|Uvicorn running|Application startup complete" "$f" && stage="almost ready"
         echo "$stage"' 2>/dev/null || echo "starting"
}

# returns 0 when the api answers; FAIL_REASON set on crash/timeout
wait_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    local mem stage last_stage=""
    FAIL_REASON=""
    while ((SECONDS < deadline)); do
        if server_ready; then
            c_green "SGLang API is up"
            return 0
        fi

        if sglang_crashed; then
            FAIL_REASON=$(sglang_log_snip || echo "sglang crashed; no log found")
            return 1
        fi

        stage=$(boot_stage)
        mem=$(rsh 'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1' || echo "?")
        if [[ "$stage" != "$last_stage" ]]; then
            c_yellow "[$(date +%H:%M:%S)] $stage  (GPU ${mem} MiB)"
            last_stage="$stage"
        else
            printf '[%s] still: %s  (GPU %s MiB)\n' "$(date +%H:%M:%S)" "$stage" "$mem" >&2
        fi
        sleep 15
    done
    FAIL_REASON="timed out after ${READY_TIMEOUT}s"$'\n'"$(sglang_log_snip || true)"
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

    c_yellow "waiting for boot serve ($MODEL via SGLang EAGLE; args set at create)"
    if ! wait_ready; then
        c_red "SGLang failed to start"
        printf '%s\n' "$FAIL_REASON" >&2
        die "template boot config did not come up; see logs on the instance"
    fi

    # Stock Qwen3.8 template rejects Claude Code mid-conversation system messages.
    # Upload patched jinja + restart once if needed, then wait for API again.
    ensure_chat_template
    if ! wait_ready; then
        c_red "SGLang failed after applying chat template"
        printf '%s\n' "$FAIL_REASON" >&2
        die "chat-template restart did not come up; see logs on the instance"
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
    c_yellow "prometheus metrics: http://127.0.0.1:$REMOTE_PORT/metrics (via tunnel: http://localhost:$LOCAL_PORT/metrics)"
}

main "$@"
