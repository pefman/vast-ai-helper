#!/usr/bin/env bash
# shared config and helpers for the vast.ai 5090 + vLLM flow

VAST_BIN="vastai"
VAST_KEY_FILE="$HOME/.config/vastai/vast_api_key"

IMAGE="vastai/vllm:v0.27.1-cuda-12.9"
MODEL="unsloth/Qwen3.8-27B-NVFP4"
DISK_GB=70
REMOTE_PORT=18000
LOCAL_PORT=8000
TARGET_TPS=60

OFFER_QUERY='gpu_name=RTX_5090 num_gpus=1 cuda_max_good>=12.9 disk_space>=70 rented=False reliability>0.95 inet_down>=500 dlperf>180'
OFFER_LIST_MAX=10

VLLM_COMMON_ARGS="--host 127.0.0.1 --port $REMOTE_PORT --download-dir /workspace/models --trust-remote-code --tensor-parallel-size 1 --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 --enable-chunked-prefill --max-num-batched-tokens 4096"

# boot config for `vastai create`: cuda graphs on (no --enforce-eager) but no JSON
# flags, since the vast --env parser mangles nested quotes. 2-serve.sh tunes from here.
BOOT_VLLM_ARGS="$VLLM_COMMON_ARGS --max-num-seqs 4 --max-model-len 32768 --gpu-memory-utilization 0.82 --enable-prefix-caching"

# tuning ladder, best first; 2-serve.sh stops at the first rung beating TARGET_TPS.
# fp8 kv cache is only used on the last rung: this model is a mamba/attention hybrid
# and fp8 kv + prefix caching + mtp is the most likely source of the earlier crash.
rung_args() {
    case "$1" in
        A) echo "$VLLM_COMMON_ARGS --max-num-seqs 4 --max-model-len 32768 --gpu-memory-utilization 0.82 --enable-prefix-caching --compilation-config '{\"cudagraph_mode\":\"FULL_AND_PIECEWISE\"}' --speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":3}'" ;;
        B) echo "$VLLM_COMMON_ARGS --max-num-seqs 4 --max-model-len 24576 --gpu-memory-utilization 0.78 --enable-prefix-caching --compilation-config '{\"cudagraph_mode\":\"FULL_AND_PIECEWISE\"}' --speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":3}'" ;;
        C) echo "$VLLM_COMMON_ARGS --max-num-seqs 4 --max-model-len 24576 --gpu-memory-utilization 0.80 --enable-prefix-caching --compilation-config '{\"cudagraph_mode\":\"FULL_DECODE_ONLY\"}' --speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":2}'" ;;
        D) echo "$VLLM_COMMON_ARGS --max-num-seqs 4 --max-model-len 32768 --gpu-memory-utilization 0.85 --enable-prefix-caching --enforce-eager --speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":3}'" ;;
        E) echo "$VLLM_COMMON_ARGS --max-num-seqs 4 --max-model-len 16384 --gpu-memory-utilization 0.85 --kv-cache-dtype fp8 --enforce-eager" ;;
        *) return 1 ;;
    esac
}
RUNGS=(A B C D E)

STATE_DIR="$HOME/.cache/vast-helper"
STATE_FILE="$STATE_DIR/state"

c_red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_green() { printf '\033[32m%s\033[0m\n' "$*" >&2; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

die() {
    c_red "error: $*"
    exit 1
}

confirm() {
    local prompt="$1" answer
    read -r -p "$prompt [y/N] " answer </dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

is_installed() {
    command -v "$VAST_BIN" >/dev/null 2>&1
}

install_cli() {
    local pipx pip
    if command -v pipx >/dev/null 2>&1; then
        c_yellow "installing vastai with pipx..."
        pipx install vastai
    elif pip=$(command -v pip3 || command -v pip); then
        c_yellow "installing vastai with $pip --user..."
        "$pip" install --user --upgrade vastai
    else
        die "neither pipx nor pip found; install python3-pip or pipx first"
    fi

    hash -r
    is_installed || die "vastai installed but not on PATH; add ~/.local/bin to PATH and re-run"
    c_green "vastai installed: $("$VAST_BIN" --version 2>/dev/null || echo unknown)"
}

is_authed() {
    [[ -s "$VAST_KEY_FILE" ]] && "$VAST_BIN" show user --raw >/dev/null 2>&1
}

auth_cli() {
    local key
    c_yellow "get your API key at https://cloud.vast.ai/account/"
    read -r -s -p "vast.ai API key: " key </dev/tty
    echo
    [[ -n "$key" ]] || die "no API key entered"

    "$VAST_BIN" set api-key "$key" >/dev/null
    unset key

    is_authed || die "authentication failed; check the API key and try again"
    c_green "authenticated as: $("$VAST_BIN" show user --raw | grep -o '"email": *"[^"]*"' | head -1 | cut -d'"' -f4)"
}

ensure_cli() {
    if is_installed; then
        c_green "vast cli found: $(command -v "$VAST_BIN")"
    else
        c_yellow "vast cli not found."
        confirm "install the vast.ai cli now?" || die "vast cli is required"
        install_cli
    fi

    if is_authed; then
        c_green "vast cli is authenticated."
    else
        c_yellow "vast cli is not authenticated."
        confirm "authenticate now?" || die "authentication is required"
        auth_cli
    fi
}

state_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
    tmp=$(mktemp)
    grep -v "^$key=" "$STATE_FILE" >"$tmp" || true
    printf '%s=%q\n' "$key" "$value" >>"$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_get() {
    local key="$1" line
    [[ -s "$STATE_FILE" ]] || return 1
    line=$(grep "^$key=" "$STATE_FILE" | tail -1) || return 1
    [[ -n "$line" ]] || return 1
    eval "printf '%s' ${line#*=}"
}

require_instance() {
    INSTANCE_ID=$(state_get instance_id) \
        || die "no instance in $STATE_FILE; run ./1-launch.sh first"
    [[ "$INSTANCE_ID" =~ ^[0-9]+$ ]] || die "bad instance id in state: $INSTANCE_ID"
}

# resolves SSH_HOST/SSH_PORT from `vastai ssh-url`, which also works on proxy-only hosts
resolve_ssh() {
    local url
    url=$("$VAST_BIN" ssh-url "$INSTANCE_ID" 2>/dev/null | tr -d '[:space:]') || return 1
    [[ "$url" =~ ^ssh://([^@]+)@([^:]+):([0-9]+)$ ]] || return 1
    SSH_USER="${BASH_REMATCH[1]}"
    SSH_HOST="${BASH_REMATCH[2]}"
    SSH_PORT="${BASH_REMATCH[3]}"
    return 0
}

ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

rsh() {
    ssh -p "$SSH_PORT" "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$@"
}

instance_field() {
    "$VAST_BIN" show instances --raw 2>/dev/null \
        | python3 -c '
import json, sys
iid, field = int(sys.argv[1]), sys.argv[2]
try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
for row in rows:
    if row.get("id") == iid:
        print(row.get(field) or "")
        break
' "$INSTANCE_ID" "$1"
}

destroy_prompt() {
    c_yellow "instance $INSTANCE_ID is still running and billing."
    if confirm "destroy instance $INSTANCE_ID?"; then
        "$VAST_BIN" destroy instance "$INSTANCE_ID" && c_green "destroyed $INSTANCE_ID"
        state_set instance_id ""
    else
        c_yellow "left running. destroy later with: $VAST_BIN destroy instance $INSTANCE_ID"
    fi
}
