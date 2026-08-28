#!/usr/bin/env python3
"""Map vLLM boot log text to 'stage_id|human message'. Later stages win."""
import re
import sys

# Chronological boot order; last match in this list wins. Failures last.
PATTERNS = [
    ("starting", "starting vLLM process", r"non-default args|Resolved architecture"),
    ("download", "downloading model weights from Hugging Face", r"Time spent downloading weights|Fetching \d+ files"),
    ("load_weights", "loading weights onto GPU", r"Starting to load model|Loading safetensors|Loading weights took"),
    ("mtp", "loading MTP speculative draft head", r"Detected MTP model|Loading drafter model"),
    ("model_loaded", "weights on GPU; preparing caches", r"Model loading took"),
    ("compile", "torch.compile / Dynamo (often several minutes)", r"Dynamo bytecode|Compiling a graph|Using cache directory:.*torch_compile"),
    ("compile_done", "torch.compile finished; profiling / warmup", r"torch\.compile took|saved AOT compiled"),
    ("warmup", "profiling / warmup run", r"Initial profiling/warmup run took"),
    ("cudagraph", "CUDA graph capture / memory profiling", r"Profiling CUDA graph|Graph capturing|Estimated CUDA graph|CUDA graph memory"),
    ("kv_cache", "allocating KV cache", r"Available KV cache memory|GPU KV cache size"),
    ("autotune", "FlashInfer / Triton kernel autotune", r"Autotuning process|FlashInfer autotune|Warming up Qwen Triton|\[AutoTuner\]"),
    ("mm_warmup", "multimodal warmup", r"[Mm]ulti-?modal warmup"),
    ("api", "starting API server", r"Starting vLLM server|API server: HTTP server started|Application startup complete"),
    ("failed", "ENGINE FAILED - see log", r"EngineCore failed to start|Engine core initialization failed|ValueError:.*KV cache|ValueError: Free memory on device|CUDA out of memory|OutOfMemoryError"),
]


def main() -> None:
    log = sys.stdin.read()
    stage, msg = "waiting", "waiting for vLLM log output"
    for sid, human, rx in PATTERNS:
        if re.search(rx, log, re.I):
            stage, msg = sid, human
    print(f"{stage}|{msg}")


if __name__ == "__main__":
    main()
