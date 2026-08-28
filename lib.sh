#!/usr/bin/env bash
# shared config and helpers for the vast.ai profile-based launch flow

VAST_BIN="vastai"
VAST_KEY_FILE="$HOME/.config/vastai/vast_api_key"

# Ordered profile ids. Add new ones here and in apply_profile() / profile_desc().
PROFILES=(qwen38-sglang)
DEFAULT_PROFILE="qwen38-sglang"

# Active profile fields (filled by apply_profile).
PROFILE=""
PROFILE_DESC=""
TEMPLATE_HASH=""
IMAGE=""
MODEL=""
DISK_GB=65
OFFER_QUERY=""
SGLANG_ARGS=""
CREATE_ENV=""
REMOTE_PORT=18000
LOCAL_PORT=8000
OFFER_LIST_MAX=10

# Claude Code injects mid-conversation system/developer messages; stock Qwen3.8
# chat templates raise on those. Patched jinja is uploaded to the instance and
# passed to SGLang via /etc/sglang-args.conf (appended by the Vast sglang.sh).
CHAT_TEMPLATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chat-templates/qwen38-claude.jinja"
CHAT_TEMPLATE_REMOTE="/workspace/qwen38-claude.jinja"
SGLANG_CHAT_TEMPLATE_ARG="--chat-template ${CHAT_TEMPLATE_REMOTE}"

profile_desc() {
    case "$1" in
        qwen38-sglang) printf '%s' "SGLang + RadixArk Qwen3.8-27B-NVFP4 + EAGLE (1x RTX 5090)" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Apply a named profile into the globals above. Add future templates as new cases.
apply_profile() {
    local id="$1"
    case "$id" in
        qwen38-sglang)
            # Template: https://cloud.vast.ai/?template_id=12c8baa67b6b269becbc51634b6c740c&instanceDiskSizeMin=65
            # Stock template uses context 65536 + mem 0.90 which OOMs the hybrid GDN
            # state pool on a 32GB 5090 once EAGLE draft weights load. Profile args
            # keep mem 0.93 / bs=1 / FP8 KV / EAGLE, but raise ctx to 48k (from the
            # cookbook 32k) — ~3 Gi free at 32k suggests room; 64k still known-bad.
            PROFILE="qwen38-sglang"
            PROFILE_DESC="$(profile_desc "$id")"
            TEMPLATE_HASH="12c8baa67b6b269becbc51634b6c740c"
            IMAGE="vastai/sglang:v0.5.17-cuda-13.0"
            MODEL="RadixArk/Qwen3.8-27B-NVFP4"
            DISK_GB=65
            OFFER_QUERY='gpu_name=RTX_5090 num_gpus=1 cuda_max_good>=13.0 disk_space>=65 rented=False reliability>0.95 inet_down>=500 dlperf>180'
            SGLANG_ARGS='--trust-remote-code --attention-backend flashinfer --reasoning-parser qwen3 --tool-call-parser qwen3_coder --download-dir /workspace/models --host 127.0.0.1 --port 18000 --context-length 49152 --mem-fraction-static 0.93 --kv-cache-dtype fp8_e4m3 --chunked-prefill-size 2048 --max-running-requests 1 --cuda-graph-max-bs 1 --mm-feature-transport cpu --speculative-algorithm EAGLE --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4 --enable-linear-replayssm-spec --enable-metrics'
            REMOTE_PORT=18000
            LOCAL_PORT=8000
            ;;
        *)
            die "unknown profile: $id (known: ${PROFILES[*]})"
            ;;
    esac
}

# Docker --env for `vastai create`. With --template_hash, --env replaces the
# template env, so this keeps the stock portal/ports and injects profile args
# (context/mem pins, --enable-metrics, etc.) at create time — no post-boot restart.
build_create_env() {
    CREATE_ENV=""
    [[ -n "$SGLANG_ARGS" ]] || return 0

    local portal
    portal='localhost:1111:11111:/:Instance Portal|localhost:7860:17860:/:Model UI|localhost:8000:18000:/docs:SGLang API|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal'
    CREATE_ENV="-p 1111:1111 -p 7860:7860 -p 8080:8080 -p 8000:8000 -p 8265:8265 -p 10100:10100 -p 10200:10200"
    CREATE_ENV="$CREATE_ENV -e OPEN_BUTTON_PORT=\"1111\" -e OPEN_BUTTON_TOKEN=\"1\""
    CREATE_ENV="$CREATE_ENV -e JUPYTER_DIR=\"/\" -e DATA_DIRECTORY=\"/workspace/\""
    CREATE_ENV="$CREATE_ENV -e PORTAL_CONFIG=\"$portal\""
    CREATE_ENV="$CREATE_ENV -e SGLANG_MODEL=\"$MODEL\""
    CREATE_ENV="$CREATE_ENV -e SGLANG_ARGS=\"$SGLANG_ARGS\""
    CREATE_ENV="$CREATE_ENV -e AUTO_PARALLEL=false"
}

# Restore the profile chosen at launch (state), else the default.
load_active_profile() {
    local p
    p=$(state_get profile 2>/dev/null || true)
    if [[ -n "$p" ]]; then
        apply_profile "$p"
    else
        apply_profile "$DEFAULT_PROFILE"
    fi
}

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
    load_active_profile
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

# prints live instances that match any known profile:
# id<TAB>status<TAB>image<TAB>model<TAB>profile<TAB>$/hr
list_live_instances() {
    local id images="" models=""
    for id in "${PROFILES[@]}"; do
        apply_profile "$id"
        images+="${IMAGE%%:*}"$'\n'
        models+="${MODEL}"$'\n'
    done
    apply_profile "$DEFAULT_PROFILE"

    "$VAST_BIN" show instances --raw 2>/dev/null | python3 -c '
import json, sys

images = [x for x in sys.argv[1].split("\n") if x]
models = [x for x in sys.argv[2].split("\n") if x]
profiles = [x for x in sys.argv[3].split("\n") if x]
try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []

def env_get(row, key):
    env = row.get("extra_env") or {}
    if isinstance(env, dict):
        if key in env:
            return str(env.get(key) or "")
        for k, v in env.items():
            ks = str(k)
            if ks == key or ks.endswith("/" + key) or ks.endswith(" " + key):
                return str(v or "")
            if ks.startswith(key + "="):
                return ks.split("=", 1)[1]
    return ""

def match_profile(image, model):
    for img, mod, prof in zip(images, models, profiles):
        if img and img not in image:
            continue
        if mod and model and model != mod:
            continue
        return prof
    return ""

reusable = {"running", "loading", "created", "pending"}
for row in rows:
    iid = row.get("id")
    status = (row.get("actual_status") or row.get("intended_status") or "").strip()
    if not iid or status not in reusable:
        continue
    image = str(row.get("image") or row.get("image_uuid") or "")
    model = env_get(row, "SGLANG_MODEL") or env_get(row, "VLLM_MODEL")
    prof = match_profile(image, model)
    if not prof:
        continue
    price = row.get("dph_total") or 0
    print("\t".join([
        str(iid),
        status,
        image.replace("\t", " "),
        model.replace("\t", " "),
        prof,
        "{:.3f}".format(float(price)),
    ]))
' "$images" "$models" "$(printf '%s\n' "${PROFILES[@]}")"
}

# Bind globals to a live instance and remember it in state.
attach_instance() {
    local id="$1" profile="$2" image="$3" model="$4" price="$5"
    INSTANCE_ID="$id"
    apply_profile "$profile"
    [[ -n "$model" ]] && MODEL="$model"
    state_set instance_id "$INSTANCE_ID"
    state_set profile "$PROFILE"
    state_set template_hash "$TEMPLATE_HASH"
    if [[ -n "$price" ]]; then
        price=$(LC_ALL=C printf '%.3f' "$price")
        state_set offer_price "$price"
    fi
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

# Upload the Claude-compatible Qwen chat template and make SGLang use it.
# Safe to call repeatedly. Restarts sglang when the running server is not using
# --chat-template pointing at CHAT_TEMPLATE_REMOTE, or when the remote file
# content changed (SGLang loads the jinja at startup).
ensure_chat_template() {
    [[ -n "${SSH_HOST:-}" && -n "${SSH_PORT:-}" ]] || die "ensure_chat_template: ssh not resolved"
    [[ -f "$CHAT_TEMPLATE_FILE" ]] || die "missing chat template: $CHAT_TEMPLATE_FILE"

    local local_sum remote_sum need_restart=0
    local_sum=$(sha256sum "$CHAT_TEMPLATE_FILE" | awk '{print $1}')
    remote_sum=$(rsh "bash --noprofile --norc -c 'sha256sum ${CHAT_TEMPLATE_REMOTE} 2>/dev/null | awk \"{print \\\$1}\"'" 2>/dev/null || true)

    c_yellow "ensuring Claude-compatible chat template on instance..."
    scp -P "$SSH_PORT" "${ssh_opts[@]}" \
        "$CHAT_TEMPLATE_FILE" "$SSH_USER@$SSH_HOST:$CHAT_TEMPLATE_REMOTE" >/dev/null

    # Vast's sglang.sh appends contents of /etc/sglang-args.conf to the serve cmdline.
    rsh "bash --noprofile --norc -c 'printf \"%s\\n\" \"$SGLANG_CHAT_TEMPLATE_ARG\" > /etc/sglang-args.conf'"

    if [[ -z "$remote_sum" || "$remote_sum" != "$local_sum" ]]; then
        c_yellow "chat template content changed (or missing on remote)"
        need_restart=1
    fi

    if ! rsh "bash --noprofile --norc -c '
        pid=\$(pgrep -n -f \"sglang serve\" || true)
        [ -n \"\$pid\" ] || exit 1
        tr \"\\0\" \" \" < /proc/\$pid/cmdline | grep -q -- \"--chat-template ${CHAT_TEMPLATE_REMOTE}\"
      '" >/dev/null 2>&1; then
        need_restart=1
    fi

    if (( need_restart == 0 )); then
        c_green "SGLang already using up-to-date $CHAT_TEMPLATE_REMOTE"
        return 0
    fi

    c_yellow "restarting SGLang to pick up --chat-template..."
    rsh "bash --noprofile --norc -c 'supervisorctl restart sglang'" >/dev/null
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


