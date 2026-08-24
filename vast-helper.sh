#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

TEMPLATE_CACHE=""
TEMPLATE_LIST_MAX=25

TEMPLATE_ID=""
TEMPLATE_HASH=""
TEMPLATE_NAME=""
TEMPLATE_IMAGE=""
TEMPLATE_DISK=""
TEMPLATE_FILTERS=""
OFFER_ID=""
OFFER_GPUS=""
OFFER_PRICE=""
OFFER_LOCATION=""
OFFER_LIST_MAX=20
DEFAULT_DISK=32

cleanup() {
    [[ -n "$TEMPLATE_CACHE" && -f "$TEMPLATE_CACHE" ]] && rm -f "$TEMPLATE_CACHE"
}
trap cleanup EXIT

load_templates() {
    [[ -n "$TEMPLATE_CACHE" && -s "$TEMPLATE_CACHE" ]] && return 0

    command -v python3 >/dev/null 2>&1 || die "python3 is required to parse template results"
    TEMPLATE_CACHE=$(mktemp)
    local popular recent cutoff
    popular=$(mktemp)
    recent=$(mktemp)
    cutoff=$(($(date +%s) - 30 * 86400))

    # each query is capped at 2048 rows ordered by popularity, so pull a popular
    # page and a recent page to also see freshly published templates
    c_yellow "fetching template catalog..."
    "$VAST_BIN" search templates 'count_created > 100' --raw >"$popular" 2>/dev/null || true
    "$VAST_BIN" search templates "created_at > $cutoff" --raw >"$recent" 2>/dev/null || true

    python3 - "$popular" "$recent" >"$TEMPLATE_CACHE" <<'PY'
import json, sys

merged = {}
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            for t in json.load(fh):
                merged[t.get("id")] = t
    except (OSError, ValueError):
        pass
json.dump(list(merged.values()), sys.stdout)
PY
    rm -f "$popular" "$recent"

    [[ -s "$TEMPLATE_CACHE" ]] || die "template search returned nothing"
}

# prints: id<TAB>hash<TAB>name<TAB>image<TAB>count_created<TAB>disk_gb<TAB>offer_query
# $1 = template json file, $2 = optional substring filter
format_templates() {
    python3 - "$1" "$2" "$TEMPLATE_LIST_MAX" <<'PY'
import json, sys

OPS = {"gte": ">=", "gt": ">", "lte": "<=", "lt": "<", "eq": "==", "neq": "!=", "in": "in", "notin": "notin"}
# templates express gpu memory in MB, search offers expects GB
MB_FIELDS = {"gpu_ram", "gpu_total_ram", "cpu_ram"}


def offer_query(raw):
    """translate a template's extra_filters blob into search-offers query syntax"""
    try:
        filters = json.loads(raw) if isinstance(raw, str) else (raw or {})
    except ValueError:
        return ""

    parts = []
    for field, cond in (filters.items() if isinstance(filters, dict) else []):
        if not isinstance(cond, dict):
            continue
        for op, value in cond.items():
            if op not in OPS:
                continue
            if isinstance(value, list):
                rendered = "[{}]".format(",".join(str(v).replace(" ", "_") for v in value))
            elif isinstance(value, bool):
                rendered = str(value)
            elif field in MB_FIELDS and isinstance(value, (int, float)):
                rendered = "{:.0f}".format(value / 1024)
            else:
                rendered = str(value).replace(" ", "_")
            parts.append("{} {} {}".format(field, OPS[op], rendered))
    return " ".join(parts)


path, query, limit = sys.argv[1], sys.argv[2].lower(), int(sys.argv[3])
with open(path) as fh:
    try:
        templates = json.load(fh)
    except ValueError:
        templates = []

if query:
    templates = [
        t for t in templates
        if query in (t.get("name") or "").lower()
        or query in (t.get("image") or "").lower()
        or query in (t.get("desc") or "").lower()
    ]
templates.sort(key=lambda t: (t.get("count_created") or 0, t.get("created_at") or 0), reverse=True)

for t in templates[:limit]:
    print("\t".join([
        str(t.get("id", "")),
        str(t.get("hash_id", "")),
        (t.get("name") or "unnamed").replace("\t", " ")[:60],
        "{}:{}".format(t.get("image") or "?", t.get("tag") or t.get("default_tag") or "latest")[:50],
        str(t.get("count_created") or 0),
        str(int(t.get("recommended_disk_space") or 0)),
        offer_query(t.get("extra_filters")).replace("\t", " "),
    ]))
PY
}

# the api caps a query at 2048 rows, so exact hash/id/image lookups go server-side
# and only free text falls back to substring matching over the popular catalog
find_templates() {
    local query="$1" api_query="" tmp rc=0

    if [[ "$query" =~ ^[0-9a-fA-F]{32}$ ]]; then
        api_query="hash_id==$query"
    elif [[ "$query" =~ ^[0-9]+$ ]]; then
        api_query="id==$query"
    elif [[ "$query" == */* ]]; then
        api_query="image==$query"
    fi

    if [[ -z "$api_query" ]]; then
        load_templates
        format_templates "$TEMPLATE_CACHE" "$query"
        return
    fi

    tmp=$(mktemp)
    "$VAST_BIN" search templates "$api_query" --raw >"$tmp" 2>/dev/null || rc=$?
    ((rc == 0)) && format_templates "$tmp" ""
    rm -f "$tmp"
}

select_template() {
    load_templates

    local query choice rows=() i name image count
    while true; do
        read -r -p "search templates (text, image e.g. vastai/vllm, id, or hash): " query </dev/tty
        [[ -n "$query" ]] || continue

        mapfile -t rows < <(find_templates "$query")
        if ((${#rows[@]} == 0)); then
            c_yellow "no templates matched '$query'."
            continue
        fi

        printf '\n'
        for i in "${!rows[@]}"; do
            IFS=$'\t' read -r _ _ name image count <<<"${rows[$i]}"
            printf '%3d) %-60s %-50s %8s uses\n' "$((i + 1))" "$name" "$image" "$count"
        done
        printf '\n'

        read -r -p "pick a number, or 's' to search again, 'q' to quit: " choice </dev/tty
        case "$choice" in
            q | Q) die "cancelled" ;;
            s | S | "") continue ;;
        esac

        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#rows[@]})); then
            IFS=$'\t' read -r TEMPLATE_ID TEMPLATE_HASH TEMPLATE_NAME TEMPLATE_IMAGE _ TEMPLATE_DISK TEMPLATE_FILTERS <<<"${rows[$((choice - 1))]}"
            return 0
        fi

        c_yellow "invalid choice, searching again."
    done
}

# prints: id<TAB>gpus<TAB>gpu_ram_gb<TAB>disk_gb<TAB>$/hr<TAB>net_down<TAB>reliability<TAB>location
format_offers() {
    python3 - "$1" "$OFFER_LIST_MAX" <<'PY'
import json, sys

path, limit = sys.argv[1], int(sys.argv[2])
with open(path) as fh:
    try:
        offers = json.load(fh)
    except ValueError:
        offers = []

offers.sort(key=lambda o: o.get("dph_total") or 1e9)

for o in offers[:limit]:
    print("\t".join([
        str(o.get("id", "")),
        "{}x {}".format(o.get("num_gpus") or 1, (o.get("gpu_name") or "?").replace("\t", " "))[:28],
        "{:.0f}".format((o.get("gpu_ram") or 0) / 1024),
        "{:.0f}".format(o.get("disk_space") or 0),
        "{:.3f}".format(o.get("dph_total") or 0),
        "{:.0f}".format(o.get("inet_down") or 0),
        "{:.2f}".format(o.get("reliability2") or 0),
        (o.get("geolocation") or "?").replace("\t", " ")[:24],
    ]))
PY
}

select_offer() {
    local max_price gpu_filter query tmp rows=() choice i gpus vram disk price net rel loc

    while true; do
        read -r -p "gpu name filter (e.g. RTX_4090, blank for any): " gpu_filter </dev/tty
        read -r -p "max \$/hr (blank for any): " max_price </dev/tty

        query="rentable==true verified==true"
        [[ -n "$TEMPLATE_FILTERS" ]] && query="$query $TEMPLATE_FILTERS"
        [[ -n "$gpu_filter" ]] && query="$query gpu_name==$gpu_filter"
        [[ -n "$max_price" ]] && query="$query dph_total<$max_price"

        c_yellow "searching offers: $query"
        tmp=$(mktemp)
        "$VAST_BIN" search offers "$query" -o dph_total --raw >"$tmp" 2>/dev/null || true
        mapfile -t rows < <(format_offers "$tmp")
        rm -f "$tmp"

        if ((${#rows[@]} == 0)); then
            c_yellow "no offers matched, try different filters."
            continue
        fi

        printf '\n%3s  %-28s %6s %7s %9s %9s %6s  %s\n' "#" "gpu" "vram" "disk" "\$/hr" "mbps" "rel" "location" >&2
        for i in "${!rows[@]}"; do
            IFS=$'\t' read -r _ gpus vram disk price net rel loc <<<"${rows[$i]}"
            printf '%3d) %-28s %4sGB %5sGB %9s %9s %6s  %s\n' \
                "$((i + 1))" "$gpus" "$vram" "$disk" "$price" "$net" "$rel" "$loc" >&2
        done
        printf '\n' >&2

        read -r -p "pick an offer number, 's' to search again, 'q' to quit: " choice </dev/tty
        case "$choice" in
            q | Q) die "cancelled" ;;
            s | S | "") continue ;;
        esac

        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#rows[@]})); then
            IFS=$'\t' read -r OFFER_ID OFFER_GPUS _ _ OFFER_PRICE _ _ OFFER_LOCATION <<<"${rows[$((choice - 1))]}"
            return 0
        fi

        c_yellow "invalid choice, searching again."
    done
}

create_instance() {
    local disk answer

    disk="$TEMPLATE_DISK"
    [[ "$disk" =~ ^[0-9]+$ ]] || disk=$DEFAULT_DISK
    ((disk < DEFAULT_DISK)) && disk=$DEFAULT_DISK
    read -r -p "disk size in GB [$disk]: " answer </dev/tty
    [[ "$answer" =~ ^[0-9]+$ ]] && disk="$answer"

    c_yellow "about to rent offer $OFFER_ID ($OFFER_GPUS, \$$OFFER_PRICE/hr, $OFFER_LOCATION)"
    c_yellow "template: $TEMPLATE_NAME, disk: ${disk}GB"
    confirm "create this instance?" || die "cancelled"

    "$VAST_BIN" create instance "$OFFER_ID" --template_hash "$TEMPLATE_HASH" --disk "$disk" \
        || die "instance creation failed"
    c_green "instance requested; check status with: vastai show instances"
}

main() {
    ensure_cli
    select_template
    c_green "selected template: $TEMPLATE_NAME ($TEMPLATE_IMAGE) [id=$TEMPLATE_ID hash=$TEMPLATE_HASH]"
    select_offer
    create_instance
}

main "$@"
