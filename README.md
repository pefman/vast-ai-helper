# vast-ai-helper

Rents a **single RTX 5090** on [vast.ai](https://vast.ai) from a hardcoded
SGLang template, serves `RadixArk/Qwen3.8-27B-NVFP4` with EAGLE speculative
decoding, and exposes it locally as an OpenAI-compatible endpoint at
`http://localhost:8000/v1`.

## Template

Always creates from:

[`12c8baa67b6b269becbc51634b6c740c`](https://cloud.vast.ai/?template_id=12c8baa67b6b269becbc51634b6c740c&instanceDiskSizeMin=65)

- image: `vastai/sglang:v0.5.17-cuda-13.0`
- model: `RadixArk/Qwen3.8-27B-NVFP4`
- disk: **65 GB** (`instanceDiskSizeMin=65`)
- GPU filter: **1× RTX 5090** only (`num_gpus=1`)

## Usage

```bash
./run.sh          # launch -> serve+bench -> tunnel
```

Or run the stages separately:

```bash
./1-launch.sh     # pick a single-5090 offer and create from the template
./2-serve.sh      # wait for SGLang boot, one throughput sample
./3-tunnel.sh     # ssh tunnel to localhost:8000, prompts to destroy on exit
```

`1-launch.sh` reuses a matching running instance when one already exists (from
state or `vastai show instances`). Pass `--new` to force renting a fresh one.
`1-launch.sh --dry-run` prints the `vastai create` command without renting.

Offer selection prints a table, then prompts for a row number or **A** (default)
to auto-pick the cheapest. Non-interactive: `--pick N` or `--pick A`.

After launch it prints the local proxy port (`8000` by default) for
`./3-tunnel.sh` / OpenAI clients at `http://localhost:8000/v1`.

Point any OpenAI-compatible client at `http://localhost:8000/v1` with model
`RadixArk/Qwen3.8-27B-NVFP4` and any non-empty API key.

## Requirements

`bash`, `python3`, `ssh`, and the `vastai` CLI. The scripts install and
authenticate the CLI on first run if it is missing.

## Scripts

| file | purpose |
| --- | --- |
| `lib.sh` | shared config (template hash, single-5090 query), CLI/state/ssh helpers |
| `1-launch.sh` | offer search and `create instance --template_hash` |
| `2-serve.sh` | wait for SGLang API, one throughput sample |
| `3-tunnel.sh` | local port forward and destroy prompt |
| `bench.py` | decode throughput measurement, runs on the instance |
| `vast-helper.sh` | standalone interactive template + offer browser |

State (instance id, winning config) lives in `~/.cache/vast-helper/state`.

## Serve config

Serve flags come from the Vast template (`SGLANG_ARGS`), including flashinfer,
fp8 KV, and EAGLE (`steps=3`, `topk=1`, `draft-tokens=4`). Edit the template on
Vast or override env on a live box if you need a different recipe (e.g. DSpark).

## Cost

The instance bills until it is destroyed. `3-tunnel.sh` prompts on exit; to
destroy manually:

```bash
vastai destroy instance <id>
```
