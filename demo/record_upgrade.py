#!/usr/bin/env python3
"""Capture one bounded upgrade iteration, with no more than two model-value calls."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile

from baseten_take import BIN, ENDPOINT, MODEL, ROOT, assert_public, local


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--backend", choices=("mock", "baseten"), default="baseten")
    parser.add_argument("--key-file", type=Path)
    args = parser.parse_args()
    if args.backend == "baseten" and args.key_file is None:
        parser.error("--key-file is required for a genuine Baseten capture")
    key = args.key_file.read_text().strip() if args.backend == "baseten" else "<mock>"
    if not key or any(character.isspace() for character in key):
        raise RuntimeError("The credential is empty or contains whitespace")
    original = json.loads(args.data.read_text())
    names = ("title", "subject", "date", "verdict", "gaf", "take", "summary", "bottom_line", "sources")
    seed = {name: original[name] for name in names if name in original}
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    seed_file = args.output / "before.json"
    seed_text = json.dumps(seed, indent=2, ensure_ascii=False) + "\n"
    assert_public(seed_text, key)
    seed_file.write_text(seed_text)
    template = ROOT / "knap-mcp/templates/verdict.knap"
    template_hash = hashlib.sha256(template.read_bytes()).hexdigest()
    environment = os.environ.copy()
    for name in ("MODEL_API_KEY", "KNAP_DEBUG", "KNAP_COMPAT_KEY"):
        environment.pop(name, None)
    environment.update({
        "KNAP_TEMPLATES_DIR": str(ROOT / "knap-mcp/templates"),
        "KNAP_BASETEN_URL": ENDPOINT, "KNAP_BASETEN_MODEL": MODEL,
        "KNAP_TEMPERATURE": "omit", "KNAP_CURL_TIMEOUT": "35",
    })
    started = datetime.now(timezone.utc).isoformat()
    with tempfile.TemporaryDirectory(prefix="knap-upgrade-proof-") as home:
        environment["KNAP_MCP_HOME"] = home
        before = args.output / "before.md"
        local([str(BIN), "render", "verdict", "-d", str(seed_file), "--out", str(before)], environment, key)
        private = environment.copy()
        if args.backend == "baseten":
            private["MODEL_API_KEY"] = key
        result = local([
            str(BIN), "ratchet", "verdict", "-d", str(seed_file),
            "--backend", args.backend, "--max-iters", "1",
            "--evidence", "data", "--verifier", "heuristic",
        ], private, key)
        if not result.get("ok") or not 1 <= result.get("calls", 0) <= 2:
            raise RuntimeError("The capture did not satisfy the bounded-call contract")
        upgraded_text = (Path(home) / "artifacts" / f"{result['data_id']}.json").read_text()
        upgraded = json.loads(upgraded_text)
        if any(upgraded.get(name) != value for name, value in seed.items()):
            raise RuntimeError("The upgrade changed a pre-existing value")
        assert_public(upgraded_text, key)
        after_file = args.output / "after.json"
        after_file.write_text(upgraded_text)
        after = args.output / "after.md"
        local([str(BIN), "render", "verdict", "-d", str(after_file), "--out", str(after)], environment, key)
        scores = [
            local([str(BIN), "density", str(path)], environment, key)
            for path in (before, after)
        ]
    if hashlib.sha256(template.read_bytes()).hexdigest() != template_hash:
        raise RuntimeError("The template changed during the capture")
    for measured, reported in zip(scores, (result["score"]["start"], result["score"]["final"])):
        if abs(measured["total"] - reported) > 0.11:
            raise RuntimeError("The recorded score does not match the rendered artifact")
    receipt = {
        "backend": args.backend, "model": MODEL if args.backend == "baseten" else "mock",
        "live_call": args.backend == "baseten", "recorded_at": started,
        "max_iterations": 1, "max_model_calls": 2, "calls": result["calls"],
        "accepted_steps": sum(step["accepted"] for step in result["steps"]),
        "score": result["score"], "stop": result["stop"],
        "existing_values_unchanged": True, "template_unchanged": True,
        "template_sha256": template_hash,
        "source_draft_sha256": hashlib.sha256(args.data.read_bytes()).hexdigest(),
        "credential_in_public_output": False,
        "scope": "One bounded formatting-density example, not a model-quality benchmark.",
    }
    for name, value in (("result.json", result), ("receipt.json", receipt)):
        text = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
        assert_public(text, key)
        (args.output / name).write_text(text)
    for path in args.output.iterdir():
        assert_public(path.read_bytes(), key)
    print(json.dumps(receipt))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("Upgrade capture failed; no credential output or substitute result was published.")
