#!/usr/bin/env bash
# shared config and helpers for the vast.ai single-5090 + SGLang flow

VAST_BIN="vastai"
VAST_KEY_FILE="$HOME/.config/vastai/vast_api_key"

# Hardcoded Vast template: SGLang + RadixArk Qwen3.8-27B-NVFP4 + EAGLE
# https://cloud.vast.ai/?template_id=12c8baa67b6b269becbc51634b6c740c&instanceDiskSizeMin=65
TEMPLATE_HASH="12c8baa67b6b269becbc51634b6c740c"
IMAGE="vastai/sglang:v0.5.17-cuda-13.0"
MODEL="RadixArk/Qwen3.8-27B-NVFP4"
DISK_GB=65
REMOTE_PORT=18000
LOCAL_PORT=8000

# Locked to a single RTX 5090. Disk floor matches instanceDiskSizeMin=65.
OFFER_QUERY='gpu_name=RTX_5090 num_gpus=1 cuda_max_good>=13.0 disk_space>=65 rented=False reliability>0.95 inet_down>=500 dlperf>180'
OFFER_LIST_MAX=10

# Template ships these (kept here for docs / reuse matching only):
# SGLANG_MODEL=RadixArk/Qwen3.8-27B-NVFP4
# SGLANG_ARGS=... flashinfer ... EAGLE steps=3 topk=1 draft=4 mem=0.90 kv=fp8_e4m3 ...

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

# statuses that mean the contract is still ours and worth attaching to
instance_is_reusable_status() {
    case "$1" in
        running|loading|created|pending) return 0 ;;
        *) return 1 ;;
    esac
}

# prints matching live instances as: id<TAB>status<TAB>image<TAB>model
list_candidate_instances() {
    "$VAST_BIN" show instances --raw 2>/dev/null | python3 -c '
import json, sys

want_image = sys.argv[1]
want_model = sys.argv[2]
try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []

def env_get(row, key):
    env = row.get("extra_env") or {}
    if isinstance(env, dict):
        if key in env:
            return str(env.get(key) or "")
        # vast sometimes stores docker -e flags as bare KEY=value entries
        for k, v in env.items():
            ks = str(k)
            if ks == key or ks.endswith("/" + key) or ks.endswith(" " + key):
                return str(v or "")
            if ks.startswith(key + "="):
                return ks.split("=", 1)[1]
    return ""

for row in rows:
    iid = row.get("id")
    status = (row.get("actual_status") or row.get("intended_status") or "").strip()
    image = str(row.get("image") or row.get("image_uuid") or "")
    model = env_get(row, "SGLANG_MODEL") or env_get(row, "VLLM_MODEL")
    if not iid:
        continue
    if want_image and want_image.split(":")[0] not in image:
        continue
    if want_model and model and model != want_model:
        continue
    print("\t".join([str(iid), status, image.replace("\t", " "), model.replace("\t", " ")]))
' "$IMAGE" "$MODEL"
}

# sets INSTANCE_ID from state or a live matching instance; returns 0 if found
find_reusable_instance() {
    local id status image model
    local -a rows=()

    id=$(state_get instance_id 2>/dev/null || true)
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        INSTANCE_ID="$id"
        status=$(instance_field actual_status)
        if instance_is_reusable_status "$status"; then
            return 0
        fi
        c_yellow "state instance $id is not reusable (status=${status:-gone}); looking for another"
    fi

    mapfile -t rows < <(list_candidate_instances)
    for line in "${rows[@]}"; do
        IFS=$'\t' read -r id status image model <<<"$line"
        if instance_is_reusable_status "$status"; then
            INSTANCE_ID="$id"
            return 0
        fi
    done
    return 1
}

# records local tunnel port + direct host proxy mapping for the portal vLLM port
record_proxy_ports() {
    local public_ip host_port
    state_set local_port "$LOCAL_PORT"

    public_ip=$(instance_field public_ipaddr)
    host_port=$("$VAST_BIN" show instances --raw 2>/dev/null | python3 -c '
import json, sys
iid, container_port = int(sys.argv[1]), sys.argv[2]
try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
key = container_port + "/tcp"
for row in rows:
    if row.get("id") != iid:
        continue
    ports = row.get("ports") or {}
    entries = ports.get(key) or []
    if entries and isinstance(entries, list):
        print(entries[0].get("HostPort") or "")
    break
' "$INSTANCE_ID" "8000")

    state_set public_ip "$public_ip"
    state_set host_proxy_port "$host_port"

    c_green "local proxy port for last step: $LOCAL_PORT  (http://localhost:$LOCAL_PORT/v1)"
    if [[ -n "$public_ip" && -n "$host_port" ]]; then
        c_yellow "direct host proxy (portal): http://$public_ip:$host_port/  (may require portal auth)"
    fi
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
