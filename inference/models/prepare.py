#!/usr/bin/env python3
"""Prepare one checksum-verified public model cache; never load remote code."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import urllib.error
import urllib.request

MODEL_ID = "HuggingFaceTB/SmolLM2-135M"
MODEL_SPEC = json.loads(Path(__file__).with_name("model-spec.json").read_text())
REQUIRED = {"config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"}
OPTIONAL = {"generation_config.json", "special_tokens_map.json", "vocab.json", "merges.txt",
            "added_tokens.json", "README.md", "LICENSE", "LICENSE.txt"}
MAX_MODEL_BYTES = 2 * 1024**3


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_cache(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "model-manifest.json").read_text())
    if manifest["model_id"] != MODEL_ID or not re.fullmatch(r"[a-f0-9]{40}", manifest["revision"]):
        raise ValueError("unexpected model identity or unresolved revision")
    if not REQUIRED <= set(manifest["files"]):
        raise ValueError("model cache is incomplete")
    for name, metadata in manifest["files"].items():
        if name not in REQUIRED | OPTIONAL:
            raise ValueError("unexpected model artifact")
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"invalid model artifact: {name}")
        if path.stat().st_size != metadata["bytes"] or digest(path) != metadata["sha256"]:
            raise ValueError(f"model checksum mismatch: {name}")
    config = json.loads((directory / "config.json").read_text())
    if config.get("model_type") != "llama" or config.get("auto_map"):
        raise ValueError("only built-in Llama architecture is supported")
    return manifest


def read_json(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(4 * 1024**2 + 1)
    if len(data) > 4 * 1024**2:
        raise ValueError("model metadata exceeds capacity")
    return json.loads(data)


def download(url, target, sibling):
    expected_size = sibling.get("size")
    if not isinstance(expected_size, int) or not 0 < expected_size <= MAX_MODEL_BYTES:
        raise ValueError("invalid artifact size in official metadata")
    temporary = target.with_name(target.name + ".part")
    count = 0
    sha256 = hashlib.sha256()
    git_hash = hashlib.sha1(f"blob {expected_size}\0".encode())
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("xb") as output:
            while chunk := response.read(1024**2):
                count += len(chunk)
                if count > expected_size:
                    raise ValueError("artifact exceeds advertised size")
                output.write(chunk)
                sha256.update(chunk)
                git_hash.update(chunk)
        if count != expected_size:
            raise ValueError("incomplete artifact")
        lfs = sibling.get("lfs")
        if lfs:
            if sha256.hexdigest() != lfs["sha256"]:
                raise ValueError("official LFS SHA-256 mismatch")
        elif git_hash.hexdigest() != sibling["blobId"]:
            raise ValueError("official Git blob checksum mismatch")
        temporary.rename(target)
        return {"bytes": count, "sha256": sha256.hexdigest()}
    finally:
        temporary.unlink(missing_ok=True)


def reuse_verified(path, sibling):
    if path.is_symlink() or path.stat().st_size != sibling["size"]:
        raise ValueError(f"invalid existing artifact: {path.name}")
    sha256 = hashlib.sha256()
    git_hash = hashlib.sha1(f"blob {sibling['size']}\0".encode())
    with path.open("rb") as stream:
        while chunk := stream.read(1024**2):
            sha256.update(chunk)
            git_hash.update(chunk)
    expected = sibling.get("lfs", {}).get("sha256")
    if (sha256.hexdigest() != expected if expected else git_hash.hexdigest() != sibling["blobId"]):
        raise ValueError(f"existing artifact checksum mismatch: {path.name}")
    return {"bytes": path.stat().st_size, "sha256": sha256.hexdigest()}


def prepare(directory, revision):
    directory = Path(directory)
    if (directory / "model-manifest.json").exists():
        return verify_cache(directory)
    state = directory / "download-state.json"
    if directory.exists() and any(directory.iterdir()) and not state.is_file():
        raise ValueError("partial model cache requires inspection; it is not overwritten")
    directory.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(directory).free < MAX_MODEL_BYTES + 8 * 1024**3:
        raise ValueError("need model capacity plus 8 GiB free reserve")
    metadata = (json.loads(state.read_text()) if state.is_file() else MODEL_SPEC if revision == MODEL_SPEC["sha"] else
                read_json(f"https://huggingface.co/api/models/{MODEL_ID}/revision/{revision}?blobs=true"))
    commit = metadata.get("sha", "")
    if (metadata.get("id") != MODEL_ID or not re.fullmatch(r"[a-f0-9]{40}", commit)
            or metadata.get("gated") or metadata.get("private")):
        raise ValueError("expected a public, nongated, immutable model revision")
    if revision != "main" and commit != revision:
        raise ValueError("cached preparation state uses a different revision")
    siblings = {item["rfilename"]: item for item in metadata["siblings"]}
    if not REQUIRED <= set(siblings):
        raise ValueError("expected single safetensors checkpoint and tokenizer artifacts")
    if {path.name for path in directory.iterdir()} - (REQUIRED | OPTIONAL | {state.name}):
        raise ValueError("unexpected files in model cache; nothing was overwritten")
    if not state.exists():
        with state.open("x") as stream:
            json.dump(metadata, stream)
    files = {}
    for name in sorted((REQUIRED | OPTIONAL) & set(siblings)):
        target = directory / name
        files[name] = (reuse_verified(target, siblings[name]) if target.exists() else
            download(f"https://huggingface.co/{MODEL_ID}/resolve/{commit}/{name}", target, siblings[name]))
    manifest = {"schema": 1, "model_id": MODEL_ID, "revision": commit,
                "source": "official public Hugging Face repository", "files": files}
    with (directory / "model-manifest.json").open("x") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
    state.unlink()
    return verify_cache(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=Path("/workspace/model-cache/SmolLM2-135M"))
    parser.add_argument("--revision", default=MODEL_SPEC["sha"])
    args = parser.parse_args()
    if args.revision != "main" and not re.fullmatch(r"[a-f0-9]{40}", args.revision):
        parser.error("revision must be main or a full immutable commit")
    try:
        result = prepare(args.model_dir, args.revision)
        print(json.dumps({"status": "PASS", "model_id": result["model_id"], "revision": result["revision"]}))
    except urllib.error.HTTPError as error:
        print(json.dumps({"status": "BLOCKED_DOWNLOAD", "http_status": error.code}), file=sys.stderr)
        raise SystemExit(2)
    except urllib.error.URLError as error:
        # Do not print signed redirect URLs or any request headers.
        print(json.dumps({"status": "BLOCKED_DOWNLOAD", "reason": str(error.reason)[:300]}), file=sys.stderr)
        raise SystemExit(2)
