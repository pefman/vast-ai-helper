# vast-ai-helper

Rents GPUs on [vast.ai](https://vast.ai) from named **profiles** (Vast templates),
waits for the OpenAI-compatible API, and tunnels it to `http://localhost:8000/v1`.

## Profiles

Profiles live in `lib.sh` (`PROFILES` + `apply_profile`). Add more later by
appending an id and a new `case` arm.

| profile | what it rents |
| --- | --- |
| `qwen38-sglang` (default) | [`12c8baa67b6b269becbc51634b6c740c`](https://cloud.vast.ai/?template_id=12c8baa67b6b269becbc51634b6c740c&instanceDiskSizeMin=65) — SGLang + `RadixArk/Qwen3.8-27B-NVFP4` + EAGLE on **1× RTX 5090**, 65 GB disk |

## Usage

```bash
./run.sh          # launch -> serve+bench -> tunnel
```

Or run the stages separately:

```bash
./1-launch.sh     # existing instance? proxy vs rent-new; else pick profile + offer
./2-serve.sh      # wait for API, one throughput sample
./3-tunnel.sh     # ssh tunnel to localhost:8000, prompts to destroy on exit
```

### Launch flow

1. If a matching instance is already running → ask **P)** proxy to it or **N)** rent new.
2. When renting → choose a **profile** (skipped if only one exists, or with `--profile`).
3. Pick a Vast offer → `create instance --template_hash …` with profile
   `SGLANG_ARGS` (context/mem pins, `--enable-metrics`, …) passed in `--env`
   so the first boot is already correct — no post-create restart.

Flags:

```bash
./1-launch.sh --new                     # skip proxy prompt; always rent
./1-launch.sh --profile qwen38-sglang   # skip profile prompt
./1-launch.sh --pick A                  # cheapest offer, non-interactive
./1-launch.sh --dry-run --new --pick A  # print create command only
```

Point any OpenAI-compatible client at `http://localhost:8000/v1` with the
profile’s model id and any non-empty API key.

`2-serve.sh` / `3-tunnel.sh` also upload `chat-templates/qwen38-claude.jinja`
and pass it to SGLang via `--chat-template`. Stock Qwen3.8 templates reject
Claude Code’s mid-conversation `system`/`developer` messages and
`reasoning_effort=high`; the patched template accepts those instead of raising
(which otherwise shows up as HTTP 500 on `/v1/messages`).

SGLang Prometheus metrics are enabled at create (`--enable-metrics`) and
available at `http://localhost:8000/metrics` once the tunnel is up.

## Requirements

`bash`, `python3`, `ssh`, and the `vastai` CLI. The scripts install and
authenticate the CLI on first run if it is missing.

## Scripts

| file | purpose |
| --- | --- |
| `lib.sh` | profiles, CLI/state/ssh helpers |
| `1-launch.sh` | proxy-or-rent, profile pick, offer search, create |
| `2-serve.sh` | wait for API, one throughput sample |
| `3-tunnel.sh` | local port forward and destroy prompt |
| `bench.py` | decode throughput measurement, runs on the instance |
| `vast-helper.sh` | standalone interactive template + offer browser |

State (instance id, profile) lives in `~/.cache/vast-helper/state`.

## Cost

The instance bills until it is destroyed. `3-tunnel.sh` prompts on exit; to
destroy manually:

```bash
vastai destroy instance <id>
```
