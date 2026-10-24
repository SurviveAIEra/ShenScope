#!/usr/bin/env python3
"""Print paired CPU receipts without discarding losing sizes or stages."""
import argparse
import json
from pathlib import Path
from statistics import mean


def summarize(paths):
    reports = [json.loads(path.read_text()) for path in paths]
    if not reports or any(report["status"] != "PASS" or report["smoke"] for report in reports):
        raise ValueError("provide completed full PASS receipts, not smoke or failed runs")
    first = reports[0]
    for report in reports:
        if (report["source_sha256"] != first["source_sha256"]
                or report["cases"] != first["cases"]
                or report["configuration"] != first["configuration"]
                or report["hardware"] != first["hardware"]
                or report["input_sha256"] != first["input_sha256"]):
            raise ValueError("receipts must use the same source, inputs, hardware and configuration")
        if not report["inputs_unchanged"] or not report["scratch_removed"]:
            raise ValueError("input integrity or scratch cleanup check failed")
    print("Times are microseconds: mean of each process's 21-sample median. Host dispatch is included.")
    print("Fusion ratio = preallocated Julia unfused / fused; >1 means fusion is faster.")
    print("Fastest PyTorch uses the minimum aggregate median of eager, compiled functional and compiled preallocated baselines.")
    print()
    for stage in ("norm", "norm_projection"):
        print(stage)
        print("| hidden | tokens | Julia unfused | Julia fused | fusion ratio | fastest PyTorch | Python to Julia |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for case in first["cases"]:
            collected = {}
            for report in reports:
                for runtime in report["runtimes"].values():
                    for record in runtime["records"]:
                        if record["id"] == case["id"] and record["stage"] == stage:
                            for method, data in record["methods"].items():
                                collected.setdefault(method, []).append(data["median_ns"] / 1000)
            medians = {name: mean(values) for name, values in collected.items()}
            unfused = medians["julia_unfused_preallocated"]
            fused = medians["julia_fused_preallocated"]
            torch = min(medians[name] for name in ("torch_eager_allocating", "torch_compiled_allocating", "torch_compiled_preallocated"))
            bridge = medians.get("torch_julia_bridge_preallocated")
            bridge_cell = f"{bridge:.3f}" if bridge is not None else "unmeasured"
            print(f"| {case['hidden']} | {case['tokens']} | {unfused:.3f} | {fused:.3f} | {unfused/fused:.3f} | {torch:.3f} | {bridge_cell} |")
        print()
    print(f"Correctness checks: {sum(len(report['validation']) for report in reports)}")
    print("These measurements do not establish GPU, serving or full-model generation speedups.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipts", nargs="+", type=Path)
    summarize(parser.parse_args().receipts)
