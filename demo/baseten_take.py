#!/usr/bin/env python3
"""Make one genuine Baseten draft while keeping credentials out of the recording."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
MODEL = "meta-models/muse-spark-open-1026"
ENDPOINT = "https://inference.baseten.co/v1/chat/completions"
BIN = ROOT / "knap-mcp/zig-out/bin/knap-mcp"


def assert_public(data, key):
    encoded = data.encode() if isinstance(data, str) else data
    checks = [key.encode()]
    if len(key) >= 16:
        checks += [key[:8].encode(), key[-8:].encode()]
    if any(value in encoded for value in checks):
        raise RuntimeError("Credential material detected; output withheld")


def local(command, environment, key):
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=100)
    assert_public(result.stdout, key)
    assert_public(result.stderr, key)
    if result.returncode:
        raise RuntimeError("Local validation or rendering failed; output withheld")
    return json.loads(result.stdout)


def main():
    key_file = Path(os.environ["KNAP_DEMO_KEY_FILE"])
    output = Path(os.environ["KNAP_BASETEN_TAKE_DIR"]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError("Use a fresh output directory; a live take must not overwrite another take")
    key = key_file.read_text().strip()
    if not key or any(character.isspace() for character in key):
        raise RuntimeError("The supplied credential is empty or contains whitespace")
    environment = os.environ.copy()
    environment.pop("KNAP_DEBUG", None)
    environment.pop("MODEL_API_KEY", None)
    environment["KNAP_BASETEN_URL"] = ENDPOINT
    environment["KNAP_BASETEN_MODEL"] = MODEL
    environment["KNAP_TEMPERATURE"] = "omit"
    private = environment.copy()
    private["MODEL_API_KEY"] = key
    system = ROOT / "demo/frozen/02-draft.system.txt"
    user = ROOT / "demo/frozen/02-draft.user.txt"
    command = [
        str(BIN), "ask", "--backend", "baseten", "--task", "enrich",
        "--system", str(system), "--user", str(user),
    ]
    print("Baseten / direct API / genuine model call", flush=True)
    print(f"model: {MODEL}", flush=True)
    print("Credential loaded privately. No credential is printed.", flush=True)
    started = datetime.now(timezone.utc).isoformat()
    clock = time.monotonic()
    result = subprocess.run(command, env=private, capture_output=True, text=True, timeout=100)
    elapsed = time.monotonic() - clock
    private.pop("MODEL_API_KEY", None)
    assert_public(result.stdout, key)
    assert_public(result.stderr, key)
    if result.returncode:
        raise RuntimeError("The genuine Baseten request failed. No success result was substituted.")
    reply = json.loads(result.stdout)
    if reply.get("backend") != "baseten" or reply.get("model") != MODEL:
        raise RuntimeError("The response did not identify the requested Baseten model")
    content = reply["content"]
    data = json.loads(content)
    public_reply = {
        field: reply.get(field)
        for field in ("backend", "model", "task", "finish_reason", "usage", "content")
    }
    response_text = json.dumps(public_reply, indent=2, ensure_ascii=False) + "\n"
    data_text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    assert_public(response_text, key)
    assert_public(data_text, key)
    draft = output / "draft.json"
    draft.write_text(data_text)
    validation = local([str(BIN), "validate", "verdict", "-d", str(draft)], environment, key)
    if not validation.get("ok"):
        raise RuntimeError("The real model draft did not validate")
    markdown = output / "verdict.md"
    render = local(
        [str(BIN), "render", "verdict", "-d", str(draft), "--out", str(markdown)],
        environment, key,
    )
    if not render.get("ok"):
        raise RuntimeError("The real model draft did not render")
    assert_public(markdown.read_text(), key)
    (Path.cwd() / "baseten.md").write_text(markdown.read_text())
    receipt = {
        "backend": "baseten", "model": MODEL, "endpoint": ENDPOINT,
        "recorded_at": started, "api_elapsed_seconds": elapsed,
        "live_call": True, "mock": False,
        "usage": reply.get("usage"), "validation_ok": True, "render_ok": True,
        "system_sha256": hashlib.sha256(system.read_bytes()).hexdigest(),
        "user_sha256": hashlib.sha256(user.read_bytes()).hexdigest(),
        "response_sha256": hashlib.sha256(response_text.encode()).hexdigest(),
        "credential_in_public_output": False,
    }
    (output / "response.json").write_text(response_text)
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for artifact in output.iterdir():
        if artifact.is_file():
            assert_public(artifact.read_bytes(), key)
    print(json.dumps({
        "backend": "baseten", "model": MODEL, "usage": reply.get("usage"),
        "validation_ok": True, "render_ok": True,
    }, indent=2), flush=True)
    print("\nModel verdict:", data.get("verdict", ""), flush=True)
    print("BASE TEN_TAKE_READY", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("BASE TEN_TAKE_FAILED: no success result was substituted; credential output withheld.", flush=True)
        sys.exit(1)
