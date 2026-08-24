# vast-ai-helper

Rents an RTX 5090 on [vast.ai](https://vast.ai), serves `unsloth/Qwen3.8-27B-NVFP4`
with vLLM, tunes it for decode throughput, and exposes it locally as an
OpenAI-compatible endpoint at `http://localhost:8000/v1`.

## Usage

```bash
./run.sh          # launch -> serve+tune -> tunnel
```

Or run the stages separately:

```bash
./1-launch.sh     # pick a 5090 offer and create the instance
./2-serve.sh      # wait for boot, tune vLLM, benchmark
./3-tunnel.sh     # ssh tunnel to localhost:8000, prompts to destroy on exit
```

`1-launch.sh --dry-run` prints the `vastai create` command without renting.
`1-launch.sh --pick N` picks row N from the offer table instead of the cheapest.

Point any OpenAI-compatible client at `http://localhost:8000/v1` with model
`unsloth/Qwen3.8-27B-NVFP4` and any non-empty API key.

## Requirements

`bash`, `python3`, `ssh`, and the `vastai` CLI. The scripts install and
authenticate the CLI on first run if it is missing.

## Scripts

| file | purpose |
| --- | --- |
| `lib.sh` | shared config, CLI install/auth, state file, ssh helpers, tuning ladder |
| `1-launch.sh` | offer search and instance creation |
| `2-serve.sh` | readiness wait, capability probe, tuning ladder, benchmark |
| `3-tunnel.sh` | local port forward and destroy prompt |
| `bench.py` | decode throughput measurement, runs on the instance |
| `vast-helper.sh` | standalone interactive template + offer browser |

State (instance id, winning config) lives in `~/.cache/vast-helper/state`.

## Tuning

`2-serve.sh` benchmarks the boot config and, if it is below 60 tok/s, walks a
ladder of vLLM configurations until one beats the target, keeping the best:

| rung | config |
| --- | --- |
| A | `FULL_AND_PIECEWISE` cuda graphs + MTP k=3, 32k ctx, mem 0.82 |
| B | same at mem 0.78 / 24k ctx, for graph-capture OOM headroom |
| C | `FULL_DECODE_ONLY` cuda graphs + MTP k=2, 24k ctx |
| D | `--enforce-eager` + MTP k=3, 32k ctx, mem 0.85 |
| E | eager, no MTP, 16k ctx, fp8 kv cache |

Each rung gets a clean GPU, and flags absent from the installed vLLM build are
skipped rather than assumed. Rungs A-D omit `--kv-cache-dtype fp8`: this model is
a Mamba/attention hybrid, where fp8 kv cache combined with prefix caching and MTP
is a known crash risk, and the VRAM is not needed at these context lengths.

## Cost

The instance bills until it is destroyed. `3-tunnel.sh` prompts on exit; to
destroy manually:

```bash
vastai destroy instance <id>
```
