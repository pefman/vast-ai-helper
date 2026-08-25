#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

DRY_RUN=0
FORCE_NEW=0
PICK=""
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --new) FORCE_NEW=1 ;;
        --pick)
            shift
            PICK="${1:-}"
            [[ -n "$PICK" ]] || die "--pick needs a number or A"
            ;;
        -h | --help)
            cat >&2 <<'EOF'
Usage: ./1-launch.sh [--new] [--dry-run] [--pick N|A]

  --new       force a fresh rental (do not reuse a live instance)
  --dry-run   print the create command without renting
  --pick N    take offer row N from the table (non-interactive)
  --pick A    auto-pick the cheapest offer (non-interactive)

Without --pick, the offer table is shown and you can type a number or A
(default) for the cheapest.
EOF
            exit 0
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
    local rows=() i gpu vram disk price dlperf net rel loc choice index=1

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

    if [[ -n "$PICK" ]]; then
        choice="$PICK"
    else
        read -r -p "pick offer #, or A for auto (cheapest) [A]: " choice </dev/tty
    fi

    # empty / A / a => cheapest (row 1); otherwise a 1-based table index
    case "${choice,,}" in
        "" | a | auto) index=1 ;;
        *)
            [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#rows[@]})) \
                || die "pick a number 1-${#rows[@]}, or A for auto"
            index="$choice"
            ;;
    esac

    IFS=$'\t' read -r OFFER_ID _ _ _ OFFER_PRICE _ _ _ OFFER_LOCATION <<<"${rows[$((index - 1))]}"
    if ((index == 1)) && [[ -z "$PICK" || "${PICK,,}" =~ ^(a|auto)?$ ]]; then
        c_green "auto-selected offer $OFFER_ID (\$$OFFER_PRICE/hr, $OFFER_LOCATION)"
    else
        c_green "selected offer #$index $OFFER_ID (\$$OFFER_PRICE/hr, $OFFER_LOCATION)"
    fi
}

create_instance() {
    local out id
    local -a cmd=(
        "$VAST_BIN" create instance "$OFFER_ID"
        --template_hash "$TEMPLATE_HASH"
        --disk "$DISK_GB"
    )

    c_yellow "template $TEMPLATE_HASH  image=$IMAGE  model=$MODEL  disk=${DISK_GB}GB  gpu=1x RTX 5090"

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
    state_set template_hash "$TEMPLATE_HASH"
    INSTANCE_ID="$id"
    c_green "instance $id created (\$$OFFER_PRICE/hr); next: ./2-serve.sh"
}

# reuse a live contract when possible so re-running launch does not double-bill
reuse_existing() {
    ((FORCE_NEW)) && return 1

    if ! find_reusable_instance; then
        return 1
    fi

    local status price
    status=$(instance_field actual_status)
    price=$(instance_field dph_total)

    if ((DRY_RUN)); then
        c_yellow "dry run, would reuse instance $INSTANCE_ID (status=$status)"
        return 0
    fi

    state_set instance_id "$INSTANCE_ID"
    if [[ -n "$price" ]]; then
        price=$(LC_ALL=C printf '%.3f' "$price")
        state_set offer_price "$price"
    fi
    record_proxy_ports
    c_green "reusing instance $INSTANCE_ID (status=$status${price:+, \$$price/hr}); next: ./2-serve.sh"
    return 0
}

ensure_cli
need python3
if reuse_existing; then
    exit 0
fi
search_offers
create_instance
if ((!DRY_RUN)); then
    record_proxy_ports
fi
