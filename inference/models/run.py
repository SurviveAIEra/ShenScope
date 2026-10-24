#!/usr/bin/env python3
"""Paired, separate-process pretrained CPU generation evaluation."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
from statistics import median
import subprocess
import sys
import tempfile
import time

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from models.prepare import verify_cache, MODEL_SPEC

CONDITIONS = ("original", "torch_native", "julia")
LOGIT_RTOL, LOGIT_ATOL = 1e-4, 1e-4


def source_hashes():
    files = [*ROOT.glob("src/*.jl"), *ROOT.glob("models/*.py"), ROOT / "bridge.py",
             ROOT / "model-requirements.lock", ROOT / "models/model-spec.json"]
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(files)}


def run_worker(command, env, log, timeout=240):
    with log.open("w") as stream:
        process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   cwd=ROOT.parent, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    continue
            process.wait()
            raise
    if status:
        raise RuntimeError(f"worker exit {status}: {log.read_text()[-5000:]}")


def compare_triplet(receipts, directories):
    if set(receipts) != set(CONDITIONS):
        raise ValueError("all three real model conditions are required")
    baseline = receipts["original"]
    checks = []
    for name, receipt in receipts.items():
        if receipt.get("condition", name) != name:
            raise ValueError("worker returned a different condition")
        prompts = receipt["records"]
        if len(prompts) != 3 or {record["prompt"] for record in prompts} != {"short", "medium", "long"}:
            raise ValueError("missing or duplicate prompt records")
        for record in prompts:
            for field in ("ttft_ns", "decode_ns", "decode_tokens_per_second"):
                if field in record and (not math.isfinite(record[field]) or record[field] <= 0):
                    raise ValueError("invalid generation timing")
            if "generated_tokens" in record and (record["generated_tokens"] != 32 or len(record["token_ids"]) != 32):
                raise ValueError("generation did not perform the fixed work")
    for condition in CONDITIONS[1:]:
        candidate = receipts[condition]
        for field in ("model_id", "model_revision", "dtype", "attention", "threads", "parameter_count"):
            if candidate[field] != baseline[field]:
                raise ValueError(f"comparison changed {field}")
        if candidate["adapter_calls"] <= 0:
            raise ValueError("candidate adapter did not execute")
        if len(candidate["records"]) != 3 or len(baseline["records"]) != 3:
            raise ValueError("missing prompt records")
        for reference, actual in zip(baseline["records"], candidate["records"]):
            if reference["prompt"] != actual["prompt"] or reference["input_ids"] != actual["input_ids"]:
                raise ValueError("conditions used different prompts")
            tokens_equal = reference["token_ids"] == actual["token_ids"]
            numerical = {}
            for suffix in ("prefill", "final"):
                name = f"{reference['prompt']}-{suffix}.f32"
                left = np.fromfile(directories["original"] / name, dtype="<f4")
                right = np.fromfile(directories[condition] / name, dtype="<f4")
                if left.shape != right.shape or left.size == 0:
                    raise ValueError("logit output is missing or has changed shape")
                comparable = suffix == "prefill" or tokens_equal
                finite = bool(np.isfinite(left).all() and np.isfinite(right).all())
                numerical[suffix] = dict(comparable=comparable,
                    finite=finite,
                    within_tolerance=bool(np.allclose(left, right, rtol=LOGIT_RTOL, atol=LOGIT_ATOL)) if comparable and finite else False,
                    max_absolute_error=float(np.max(np.abs(left.astype(np.float64) - right))) if comparable and finite else None)
            checks.append(dict(condition=condition, prompt=reference["prompt"], token_ids_equal=tokens_equal,
                               logits=numerical, passed=tokens_equal and all(x["within_tolerance"] for x in numerical.values())))
    return checks


def summarize(trials, checks):
    if not trials or not checks:
        raise ValueError("no complete real-model trials")
    rows = []
    for threads in sorted({trial["threads"] for trial in trials}):
        for prompt in ("short", "medium", "long"):
            by_condition = {}
            for condition in CONDITIONS:
                matching = [trial for trial in trials if trial["threads"] == threads and trial["condition"] == condition]
                records = [next(record for record in trial["records"] if record["prompt"] == prompt) for trial in matching]
                by_condition[condition] = dict(decode_tps=median(r["decode_tokens_per_second"] for r in records),
                    ttft_ms=median(r["ttft_ns"] / 1e6 for r in records),
                    peak_rss_bytes=median(t["peak_rss_bytes"] for t in matching))
            fastest = max(CONDITIONS[:2], key=lambda condition: by_condition[condition]["decode_tps"])
            speed = by_condition["julia"]["decode_tps"] / by_condition[fastest]["decode_tps"]
            memory = by_condition["julia"]["peak_rss_bytes"] / by_condition[fastest]["peak_rss_bytes"]
            rows.append(dict(threads=threads, prompt=prompt, methods=by_condition,
                             fastest_baseline=fastest, julia_decode_speed_ratio=speed, julia_peak_rss_ratio=memory))
    speed_ratio = math.exp(sum(math.log(row["julia_decode_speed_ratio"]) for row in rows) / len(rows))
    correctness = all(check["passed"] for check in checks)
    return dict(workloads=rows, geometric_mean_decode_speed_ratio=speed_ratio,
                outputs_match=correctness, speed_gate=speed_ratio >= 1.10,
                memory_gate=max(row["julia_peak_rss_ratio"] for row in rows) <= 1.10,
                decision="MEETS_INITIAL_GATE" if correctness and speed_ratio >= 1.10 and
                         max(row["julia_peak_rss_ratio"] for row in rows) <= 1.10 else "DOES_NOT_MEET_INITIAL_GATE")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=Path("/workspace/model-cache/SmolLM2-135M"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output exists; retain previous receipts and choose a new path")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, status="RUNNING", started_at=datetime.now(timezone.utc).isoformat(),
        source_sha256=source_hashes(), trials=[], comparisons=[], profiles=[], summary=None,
        plan=dict(model="HuggingFaceTB/SmolLM2-135M", dtype="float32", threads=[1, 4],
            model_revision=MODEL_SPEC["sha"],
            conditions=list(CONDITIONS), rounds=3, input_lengths=[24, 96, 256], generated_tokens=32,
            logit_rtol=LOGIT_RTOL, logit_atol=LOGIT_ATOL,
            continue_gate="All sampled outputs agree; >=10% geometric-mean decode throughput gain and <=10% peak RSS increase versus fastest existing baseline. These are project investment criteria, not industry standards."),
        hardware=dict(platform=platform.platform(), available_cpus=sorted(os.sched_getaffinity(0))),
        limits=["One small pretrained base model on one CPU VM; no general quality or hardware claim.",
                "Model-only generation timings exclude tokenization and text rendering; EOS is ignored for equal fixed work.",
                "Prefill and final logits are checked; broad accuracy/perplexity and long-context workloads are unmeasured.",
                "No GPU, quantized model, llama.cpp comparison or production serving claim."])
    code = 1
    try:
        try:
            manifest = verify_cache(args.model_dir)
        except FileNotFoundError:
            report["status"] = "BLOCKED_MODEL_DOWNLOAD"
            report["blocker"] = "Official public model cache is absent. Run models/prepare.py to acquire a verified checkpoint. No real-model inference or performance measurement was executed."
            code = 2
            return code
        report["model_manifest"] = manifest
        if manifest["revision"] != MODEL_SPEC["sha"]:
            raise ValueError("model cache revision differs from the fixed evaluation plan")
        cpus = sorted(os.sched_getaffinity(0))
        if len(cpus) < 4:
            raise ValueError("plan requires at least four available CPUs")
        scratch_parent = ROOT.parent / ".local/model-runs"
        scratch_parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="smollm-", dir=scratch_parent) as temporary:
            scratch = Path(temporary)
            for round_index in range(3):
                order = CONDITIONS[round_index:] + CONDITIONS[:round_index]
                for threads in (1, 4):
                    receipts, directories = {}, {}
                    for condition in order:
                        name = f"round{round_index}-threads{threads}-{condition}"
                        artifacts = scratch / name
                        env = dict(os.environ, JULIA_NUM_THREADS="1", JULIA_DEPOT_PATH="/workspace/julia-depot",
                            SHEN_INFERENCE_JULIA="/workspace/toolchains/julia-1.11.7/bin/julia",
                            PYTHONDONTWRITEBYTECODE="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                            OMP_NUM_THREADS=str(threads), MKL_NUM_THREADS=str(threads), OPENBLAS_NUM_THREADS=str(threads))
                        command = [sys.executable, str(ROOT / "models/worker.py"), "--model-dir", str(args.model_dir.resolve()),
                            "--condition", condition, "--threads", str(threads), "--cpus", ",".join(map(str, cpus[:threads])),
                            "--artifacts", str(artifacts)]
                        print(f"Starting {name}", flush=True)
                        run_worker(command, env, scratch / f"{name}.log")
                        receipt = json.loads((artifacts / "receipt.json").read_text())
                        receipt["round"] = round_index
                        receipts[condition], directories[condition] = receipt, artifacts
                        report["trials"].append(receipt)
                    comparisons = compare_triplet(receipts, directories)
                    for comparison in comparisons:
                        comparison.update(round=round_index, threads=threads)
                    report["comparisons"].extend(comparisons)
            # Profiling runs in separate processes, after all timing trials, so
            # profiler allocations cannot bias the baseline peak-memory metric.
            for threads in (1, 4):
                artifacts = scratch / f"profile-threads{threads}"
                env = dict(os.environ, JULIA_NUM_THREADS="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                    PYTHONDONTWRITEBYTECODE="1", OMP_NUM_THREADS=str(threads), MKL_NUM_THREADS=str(threads),
                    OPENBLAS_NUM_THREADS=str(threads))
                command = [sys.executable, str(ROOT / "models/worker.py"), "--model-dir", str(args.model_dir.resolve()),
                    "--condition", "original", "--threads", str(threads), "--cpus", ",".join(map(str, cpus[:threads])),
                    "--artifacts", str(artifacts), "--profile"]
                run_worker(command, env, scratch / f"profile-threads{threads}.log")
                report["profiles"].append(json.loads((artifacts / "receipt.json").read_text()))
            if verify_cache(args.model_dir) != manifest or source_hashes() != report["source_sha256"]:
                raise ValueError("model or benchmark source changed during measurement")
            report["summary"] = summarize(report["trials"], report["comparisons"])
            report["status"] = "PASS" if report["summary"]["outputs_match"] else "FAIL_CORRECTNESS"
            code = 0 if report["status"] == "PASS" else 1
    except Exception as error:
        report["status"], report["error"] = "FAIL", f"{type(error).__name__}: {error}"
        raise
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["temporary_case_data_removed"] = True
        with args.output.open("x") as stream:
            json.dump(report, stream, indent=2, allow_nan=False)
            stream.write("\n")
        print(f"{report['status']}: {args.output}", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
