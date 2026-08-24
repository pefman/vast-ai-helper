#!/usr/bin/env python3
"""Measures decode throughput against a local vLLM server. Prints 'TPS <value>'."""
import json
import sys
import time
import urllib.request

URL = "http://127.0.0.1:18000/v1/chat/completions"
MODEL = sys.argv[1]


def complete(max_tokens):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": "Write a long story about a robot."}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
        "ignore_eos": True,
    }).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    start = time.time()
    with urllib.request.urlopen(req, timeout=600) as resp:
        payload = json.load(resp)
    elapsed = time.time() - start
    return payload["usage"]["completion_tokens"], elapsed


complete(32)  # warmup so graph capture / first-token cost is not measured
best = 0.0
for _ in range(2):
    tokens, elapsed = complete(512)
    if elapsed > 0:
        best = max(best, tokens / elapsed)
print("TPS %.1f" % best)
