#!/usr/bin/env python3
"""One real pretrained CPU-model condition; no synthetic-model fallback."""
import_start = __import__("time").perf_counter_ns()
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import sys
import time

import torch
import transformers
from transformers import AutoModelForCausalLM, AutoTokenizer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge import JuliaRMSNorm
from models.adapter import ResidualNormAdapter

IMPORT_NS = time.perf_counter_ns() - import_start
PROMPTS = [
    ("short", "Once upon a time, a curious child found a small wooden box beside the river. ", 24),
    ("medium", "A group of friends decided to build a little garden behind their school. They planned what to plant, shared their tools, and learned how to care for the soil. ", 96),
    ("long", "The old library stood at the center of the town. Every afternoon, people gathered there to read, talk about their work, and learn something new. A young visitor began exploring the shelves and discovered a notebook filled with careful observations about the stars. ", 256),
]


def rss():
    for line in Path("/proc/self/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    raise RuntimeError("RSS unavailable")


def fixed_prompt(tokenizer, text, length):
    ids = tokenizer.encode(text * (length // 8 + 1), add_special_tokens=False)[:length]
    if len(ids) != length:
        raise ValueError("prompt did not reach fixed token count")
    return torch.tensor([ids], dtype=torch.long)


def generate(model, ids, count, capture=True):
    start = time.perf_counter_ns()
    result = model(input_ids=ids, use_cache=True, logits_to_keep=1)
    token = result.logits[:, -1].argmax(-1, keepdim=True)
    first_ns = time.perf_counter_ns() - start
    first_logits = result.logits[0, -1].detach() if capture else None
    tokens = [int(token.item())]
    cache = result.past_key_values
    start = time.perf_counter_ns()
    for _ in range(count - 1):
        result = model(input_ids=token, past_key_values=cache, use_cache=True, logits_to_keep=1)
        token = result.logits[:, -1].argmax(-1, keepdim=True)
        tokens.append(int(token.item()))
        cache = result.past_key_values
    decode_ns = time.perf_counter_ns() - start
    last_logits = result.logits[0, -1].detach() if capture else None
    return dict(ttft_ns=first_ns, decode_ns=decode_ns, generated_tokens=count,
                decode_tokens_per_second=(count - 1) * 1e9 / decode_ns,
                total_tokens_per_second=count * 1e9 / (first_ns + decode_ns), token_ids=tokens), (first_logits, last_logits)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--condition", choices=("original", "torch_native", "julia"), required=True)
    parser.add_argument("--threads", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--cpus", required=True)
    args = parser.parse_args()
    os.sched_setaffinity(0, {int(cpu) for cpu in args.cpus.split(",")})
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    args.artifacts.mkdir(parents=True)
    manifest = json.loads((args.model_dir / "model-manifest.json").read_text())
    tokenizer = AutoTokenizer.from_pretrained(args.model_dir, local_files_only=True, trust_remote_code=False)
    start = time.perf_counter_ns()
    model = AutoModelForCausalLM.from_pretrained(args.model_dir, local_files_only=True,
        trust_remote_code=False, use_safetensors=True, dtype=torch.float32, attn_implementation="sdpa")
    model.eval().requires_grad_(False)
    if any(parameter.dtype != torch.float32 or parameter.device.type != "cpu" for parameter in model.parameters()):
        raise ValueError("all model parameters must be CPU Float32")
    load_ns = time.perf_counter_ns() - start
    loaded_rss = rss()
    bridge = JuliaRMSNorm() if args.condition == "julia" else None
    adapter = None if args.condition == "original" else ResidualNormAdapter(model, args.condition, bridge)
    prompts = [(name, fixed_prompt(tokenizer, text, length)) for name, text, length in PROMPTS]
    records = []
    profile_rows = []
    with torch.inference_mode():
        # All conditions warm the same actual model with the same cache lifecycle.
        generate(model, prompts[0][1], 8, capture=False)
        if args.profile:
            with torch.profiler.profile(activities=[torch.profiler.ProfilerActivity.CPU]) as profile:
                generate(model, prompts[1][1], 8, capture=False)
            profile_rows = [dict(name=row.key, count=row.count, self_cpu_us=row.self_cpu_time_total,
                                 total_cpu_us=row.cpu_time_total)
                            for row in sorted(profile.key_averages(), key=lambda row: row.self_cpu_time_total, reverse=True)[:40]]
        for name, ids in prompts:
            metrics, logits = generate(model, ids, 32)
            for suffix, values in zip(("prefill", "final"), logits):
                values.numpy().astype("<f4", copy=False).tofile(args.artifacts / f"{name}-{suffix}.f32")
            records.append(dict(prompt=name, input_ids=ids[0].tolist(), input_tokens=ids.numel(),
                                text=tokenizer.decode(metrics["token_ids"]), **metrics))
    if adapter and adapter.calls == 0:
        raise RuntimeError("adapter did not execute")
    report = dict(schema=1, condition=args.condition, threads=args.threads, import_ns=IMPORT_NS,
                  model_id=manifest["model_id"], model_revision=manifest["revision"],
                  dtype="float32", attention="sdpa", model_load_ns=load_ns,
                  julia_startup_ns=bridge.startup_ns if bridge else 0,
                  rss_after_model_load_bytes=loaded_rss, final_rss_bytes=rss(),
                  peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024,
                  parameter_count=sum(parameter.numel() for parameter in model.parameters()),
                  adapted_layers=len(model.model.layers) if adapter else 0,
                  adapter_calls=adapter.calls if adapter else 0, layout_copies=adapter.layout_copies if adapter else 0,
                  torch_version=torch.__version__, transformers_version=transformers.__version__,
                  cpu_affinity=sorted(os.sched_getaffinity(0)),
                  records=records, profile=profile_rows,
                  stop_policy="32 greedy tokens, EOS ignored to keep equal work",
                  logits_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.artifacts.glob('*.f32')})
    (args.artifacts / "receipt.json").write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')


if __name__ == "__main__":
    main()
