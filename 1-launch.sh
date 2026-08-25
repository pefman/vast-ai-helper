#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

DRY_RUN=0
FORCE_NEW=0
PICK=""
PROFILE_ARG=""
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --new) FORCE_NEW=1 ;;
        --profile)
            shift
            PROFILE_ARG="${1:-}"
            [[ -n "$PROFILE_ARG" ]] || die "--profile needs a name"
            ;;
        --pick)
            shift
            PICK="${1:-}"
            [[ -n "$PICK" ]] || die "--pick needs a number or A"
            ;;
        -h | --help)
            cat >&2 <<EOF
Usage: ./1-launch.sh [--new] [--dry-run] [--profile NAME] [--pick N|A]

  --new           force renting a fresh instance (skip proxy-to-existing)
  --dry-run       print the create command without renting
  --profile NAME  use this profile when renting (skip profile prompt)
  --pick N        take offer row N from the table (non-interactive)
  --pick A        auto-pick the cheapest offer (non-interactive)

Profiles (add more in lib.sh):
$(for id in "${PROFILES[@]}"; do printf '  %-18s %s\n' "$id" "$(profile_desc "$id")"; done)

If a matching instance is already running, you are asked whether to start a
proxy to it or rent a new one. Profile selection only runs when renting.
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

choose_profile() {
    local choice index=1 id i

    if [[ -n "$PROFILE_ARG" ]]; then
        apply_profile "$PROFILE_ARG"
        c_green "profile: $PROFILE — $PROFILE_DESC"
        return 0
    fi

    printf '\nprofiles:\n' >&2
    for i in "${!PROFILES[@]}"; do
        id="${PROFILES[$i]}"
        printf '%3d) %-18s %s%s\n' \
            "$((i + 1))" "$id" "$(profile_desc "$id")" \
            "$([[ "$id" == "$DEFAULT_PROFILE" ]] && printf '  [default]' || true)" >&2
    done
    printf '\n' >&2

    if ((${#PROFILES[@]} == 1)); then
        apply_profile "${PROFILES[0]}"
        c_green "profile: $PROFILE — $PROFILE_DESC"
        return 0
    fi

    read -r -p "pick profile # or name [${DEFAULT_PROFILE}]: " choice </dev/tty
    case "${choice,,}" in
        "")
            apply_profile "$DEFAULT_PROFILE"
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                ((choice >= 1 && choice <= ${#PROFILES[@]})) \
                    || die "pick a number 1-${#PROFILES[@]}, or a profile name"
                apply_profile "${PROFILES[$((choice - 1))]}"
            else
                apply_profile "$choice"
            fi
            ;;
    esac
    c_green "profile: $PROFILE — $PROFILE_DESC"
}

# Show live instances; ask proxy vs rent-new. Returns 0 if attached (caller should stop).
maybe_use_existing() {
    ((FORCE_NEW)) && return 1

    local -a rows=()
    local i id status image model profile price choice index=1

    mapfile -t rows < <(list_live_instances)
    ((${#rows[@]})) || return 1

    printf '\nlive instances:\n' >&2
    printf '%3s  %-10s %-10s %-12s %-28s %s\n' "#" "id" "status" "profile" "model" "\$/hr" >&2
    for i in "${!rows[@]}"; do
        IFS=$'\t' read -r id status image model profile price <<<"${rows[$i]}"
        printf '%3d) %-10s %-10s %-12s %-28s %s\n' \
            "$((i + 1))" "$id" "$status" "$profile" "${model:0:28}" "$price" >&2
    done
    printf '\n' >&2

    read -r -p "P) proxy to existing, or N) rent new [P]: " choice </dev/tty
    case "${choice,,}" in
        "" | p | proxy)
            ;;
        n | new)
            return 1
            ;;
        *)
            die "type P to proxy, or N to rent new"
            ;;
    esac

    if ((${#rows[@]} == 1)); then
        index=1
    else
        read -r -p "pick instance # [1]: " choice </dev/tty
        case "${choice}" in
            "") index=1 ;;
            *)
                [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#rows[@]})) \
                    || die "pick a number 1-${#rows[@]}"
                index="$choice"
                ;;
        esac
    fi

    IFS=$'\t' read -r id status image model profile price <<<"${rows[$((index - 1))]}"

    if ((DRY_RUN)); then
        c_yellow "dry run, would proxy to instance $id (profile=$profile, status=$status)"
        return 0
    fi

    attach_instance "$id" "$profile" "$image" "$model" "$price"
    record_proxy_ports
    c_green "using instance $INSTANCE_ID (profile=$PROFILE, status=$status${price:+, \$$price/hr}); next: ./2-serve.sh"
    return 0
}

search_offers() {
    local rows=() i gpu vram disk price dlperf net rel loc choice index=1

    c_yellow "searching offers: $OFFER_QUERY"
    mapfile -t rows < <("$VAST_BIN" search offers "$OFFER_QUERY" -o dph_total --raw 2>/dev/null | format_offers)
    ((${#rows[@]})) || die "no offers matched for profile $PROFILE; supply may be dry, retry shortly"

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

    build_create_env
    if [[ -n "$CREATE_ENV" ]]; then
        cmd+=(--env "$CREATE_ENV")
    fi

    c_yellow "profile=$PROFILE  template=$TEMPLATE_HASH  image=$IMAGE  model=$MODEL  disk=${DISK_GB}GB"
    if [[ "$SGLANG_ARGS" == *--enable-metrics* ]]; then
        c_yellow "SGLANG_ARGS include --enable-metrics (Prometheus at /metrics)"
    fi

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
    state_set profile "$PROFILE"
    INSTANCE_ID="$id"
    c_green "instance $id created (\$$OFFER_PRICE/hr); next: ./2-serve.sh"
}

ensure_cli
need python3
apply_profile "$DEFAULT_PROFILE"

if maybe_use_existing; then
    exit 0
fi

choose_profile
search_offers
create_instance
if ((!DRY_RUN)); then
    record_proxy_ports
fi
