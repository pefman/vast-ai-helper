#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

DRY_RUN=0
PICK=""
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --pick)
            shift
            PICK="${1:-}"
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

# prints: id<TAB>gpu<TAB>vram_gb<TAB>disk_gb<TAB>$/hr<TAB>dlperf<TAB>mbps<TAB>rel<TAB>location
format_offers() {
    python3 -c '
import json, sys

limit = int(sys.argv[1])
try:
    offers = json.load(sys.stdin)
except ValueError:
    offers = []

# dlperf barely varies between 5090 listings while price varies ~2x, so rank on price
offers.sort(key=lambda o: (o.get("dph_total") or 1e9, -(o.get("dlperf") or 0)))

for o in offers[:limit]:
    print("\t".join([
        str(o.get("id", "")),
        "{}x {}".format(o.get("num_gpus") or 1, (o.get("gpu_name") or "?").replace("\t", " "))[:24],
        "{:.0f}".format((o.get("gpu_ram") or 0) / 1024),
        "{:.0f}".format(o.get("disk_space") or 0),
        "{:.3f}".format(o.get("dph_total") or 0),
        "{:.0f}".format(o.get("dlperf") or 0),
        "{:.0f}".format(o.get("inet_down") or 0),
        "{:.2f}".format(o.get("reliability2") or 0),
        (o.get("geolocation") or "?").replace("\t", " ")[:24],
    ]))
' "$OFFER_LIST_MAX"
}

search_offers() {
    local rows=() i gpu vram disk price dlperf net rel loc

    c_yellow "searching offers: $OFFER_QUERY"
    mapfile -t rows < <("$VAST_BIN" search offers "$OFFER_QUERY" -o dph_total --raw 2>/dev/null | format_offers)
    ((${#rows[@]})) || die "no RTX 5090 offers matched; supply may be dry, retry shortly"

    printf '\n%3s  %-24s %6s %7s %9s %8s %8s %6s  %s\n' \
        "#" "gpu" "vram" "disk" "\$/hr" "dlperf" "mbps" "rel" "location" >&2
    for i in "${!rows[@]}"; do
        IFS=$'\t' read -r _ gpu vram disk price dlperf net rel loc <<<"${rows[$i]}"
        printf '%3d) %-24s %4sGB %5sGB %9s %8s %8s %6s  %s\n' \
            "$((i + 1))" "$gpu" "$vram" "$disk" "$price" "$dlperf" "$net" "$rel" "$loc" >&2
    done
    printf '\n' >&2

    local index=1
    [[ -n "$PICK" ]] && index="$PICK"
    [[ "$index" =~ ^[0-9]+$ ]] && ((index >= 1 && index <= ${#rows[@]})) \
        || die "--pick must be between 1 and ${#rows[@]}"

    IFS=$'\t' read -r OFFER_ID _ _ _ OFFER_PRICE _ _ _ OFFER_LOCATION <<<"${rows[$((index - 1))]}"
    c_green "selected offer $OFFER_ID (\$$OFFER_PRICE/hr, $OFFER_LOCATION)"
}

build_env() {
    local portal
    portal="localhost:1111:11111:/:Instance Portal"
    portal="$portal|localhost:7860:17860:/:Model UI"
    portal="$portal|localhost:8000:18000:/docs:vLLM API"
    portal="$portal|localhost:8265:28265:/:Ray Dashboard"
    portal="$portal|localhost:8080:18080:/:Jupyter"
    portal="$portal|localhost:8080:8080:/terminals/1:Jupyter Terminal"

    ENV_BLOCK="-p 1111:1111 -p 7860:7860 -p 8080:8080 -p 8000:8000 -p 8265:8265 -p 10100:10100 -p 10200:10200"
    ENV_BLOCK="$ENV_BLOCK -e OPEN_BUTTON_PORT=\"1111\" -e OPEN_BUTTON_TOKEN=\"1\""
    ENV_BLOCK="$ENV_BLOCK -e JUPYTER_DIR=\"/\" -e DATA_DIRECTORY=\"/workspace/\""
    ENV_BLOCK="$ENV_BLOCK -e PORTAL_CONFIG=\"$portal\""
    ENV_BLOCK="$ENV_BLOCK -e VLLM_MODEL=\"$MODEL\""
    ENV_BLOCK="$ENV_BLOCK -e VLLM_ARGS=\"$BOOT_VLLM_ARGS\""
    ENV_BLOCK="$ENV_BLOCK -e AUTO_PARALLEL=\"true\" -e RAY_ADDRESS=\"127.0.0.1\""
    ENV_BLOCK="$ENV_BLOCK -e RAY_ARGS=\"--head --port 6379 --dashboard-host 127.0.0.1 --dashboard-port 28265\""
}

create_instance() {
    local out id
    local -a cmd=(
        "$VAST_BIN" create instance "$OFFER_ID"
        --image "$IMAGE"
        --env "$ENV_BLOCK"
        --onstart-cmd entrypoint.sh
        --disk "$DISK_GB"
        --jupyter --ssh --direct
    )

    if ((DRY_RUN)); then
        c_yellow "dry run, would execute:"
        printf '%q ' "${cmd[@]}" >&2
        printf '\n' >&2
        return 0
    fi

    out=$("${cmd[@]}" 2>&1) || die "create failed: $out"
    printf '%s\n' "$out" >&2

    id=$(grep -oE "['\"]new_contract['\"] *: *[0-9]+" <<<"$out" | grep -oE '[0-9]+$' | tail -1) \
        || true
    [[ "$id" =~ ^[0-9]+$ ]] || die "could not parse new_contract from create output"

    state_set instance_id "$id"
    state_set offer_price "$OFFER_PRICE"
    c_green "instance $id created (\$$OFFER_PRICE/hr); next: ./2-serve.sh"
}

ensure_cli
need python3
search_offers
build_env
create_instance
