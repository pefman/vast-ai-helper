#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

on_exit() {
    printf '\n' >&2
    destroy_prompt
}

main() {
    ensure_cli
    need python3
    require_instance
    resolve_ssh || die "could not resolve ssh url for $INSTANCE_ID"

    c_yellow "checking the API on the instance (profile=$PROFILE)..."
    local deadline=$((SECONDS + 900))
    until rsh "curl -sf --max-time 5 http://127.0.0.1:$REMOTE_PORT/v1/models" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "API never answered; run ./2-serve.sh first"
        printf '[%s] api not ready yet...\n' "$(date +%H:%M:%S)" >&2
        sleep 8
    done

    # Belt-and-suspenders for instances that skipped 2-serve after the Claude fix.
    ensure_chat_template
    deadline=$((SECONDS + 900))
    until rsh "curl -sf --max-time 5 http://127.0.0.1:$REMOTE_PORT/v1/models" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "API never answered after chat-template apply"
        printf '[%s] api not ready yet (after chat-template)...\n' "$(date +%H:%M:%S)" >&2
        sleep 8
    done

    local local_port host_proxy public_ip
    local_port=$(state_get local_port 2>/dev/null || true)
    [[ "$local_port" =~ ^[0-9]+$ ]] && LOCAL_PORT="$local_port"
    host_proxy=$(state_get host_proxy_port 2>/dev/null || true)
    public_ip=$(state_get public_ip 2>/dev/null || true)

    trap on_exit EXIT
    c_green "tunnel up:  http://localhost:$LOCAL_PORT/v1"
    c_green "metrics:    http://localhost:$LOCAL_PORT/metrics"
    c_green "local proxy port: $LOCAL_PORT"
    c_green "model:      $MODEL"
    c_green "api key:    any non-empty value, e.g. x"
    if [[ -n "$public_ip" && -n "$host_proxy" ]]; then
        c_yellow "direct host proxy: http://$public_ip:$host_proxy/  (portal; may need auth)"
    fi
    c_yellow "ctrl+c to close the tunnel"

    ssh -p "$SSH_PORT" "${ssh_opts[@]}" \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -L "$LOCAL_PORT:localhost:$REMOTE_PORT" \
        -N "$SSH_USER@$SSH_HOST" || true
}

main "$@"
