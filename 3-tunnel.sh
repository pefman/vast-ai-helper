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

    c_yellow "checking the vllm api on the instance..."
    local deadline=$((SECONDS + 900))
    until rsh "curl -sf --max-time 5 http://127.0.0.1:$REMOTE_PORT/v1/models" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "vllm never answered; run ./2-serve.sh first"
        printf '[%s] api not ready yet...\n' "$(date +%H:%M:%S)" >&2
        sleep 8
    done

    trap on_exit EXIT
    c_green "tunnel up:  http://localhost:$LOCAL_PORT/v1"
    c_green "model:      $MODEL"
    c_green "api key:    any non-empty value, e.g. x"
    c_yellow "ctrl+c to close the tunnel"

    ssh -p "$SSH_PORT" "${ssh_opts[@]}" \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -L "$LOCAL_PORT:localhost:$REMOTE_PORT" \
        -N "$SSH_USER@$SSH_HOST" || true
}

main "$@"
