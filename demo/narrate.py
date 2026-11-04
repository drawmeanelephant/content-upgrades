#!/usr/bin/env python3
"""Generate one continuous ElevenLabs performance and retain scene timestamps."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from baseten_take import assert_public


VOICE_ID = "CwhRBWXzGAHq8TQ4Fs17"
VOICE_NAME = "Roger"
MODEL = "eleven_multilingual_v2"


def performance_text(segments):
    paragraphs = []
    offsets = []
    cursor = 0
    for segment in segments:
        text = segment["narration"]
        if not text:
            offsets.append(None)
            continue
        if paragraphs:
            cursor += 2
        offsets.append(cursor)
        paragraphs.append(text)
        cursor += len(text)
    return "\n\n".join(paragraphs), offsets


def aligned_segments(segments, text, offsets, alignment):
    if not alignment or "".join(alignment["characters"]) != text:
        raise RuntimeError("The provider's original-text alignment differs from the script; keep the saved audio for recovery")
    starts = alignment["character_start_times_seconds"]
    ends = alignment["character_end_times_seconds"]
    if len(starts) != len(text) or len(ends) != len(text):
        raise RuntimeError("The speech alignment is incomplete")
    results = []
    for index, (segment, offset) in enumerate(zip(segments, offsets)):
        if offset is None:
            results.append({"text": "", "file": None, "start": 0, "duration": 0})
            continue
        end_index = offset + len(segment["narration"])
        start = max(0, min(starts[offset:end_index]) - 0.08)
        end = max(ends[offset:end_index]) + 0.12
        following = next((position for position in offsets[index + 1:] if position is not None), None)
        if following is not None:
            end = min(end, starts[following] - 0.02)
        if end <= start:
            raise RuntimeError(f"Invalid speech timing for scene {index + 1}")
        results.append({
            "text": segment["narration"], "file": "performance.mp3",
            "start": start, "duration": end - start,
        })
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--voice-id", default=VOICE_ID)
    parser.add_argument("--voice-name", default=VOICE_NAME)
    arguments = parser.parse_args()
    script = json.loads(arguments.script.read_text())
    text, offsets = performance_text(script["segments"])
    if not text or len(text) > 5000:
        raise RuntimeError("Expected a nonempty demo script of at most 5,000 characters")
    key = arguments.key_file.read_text().strip()
    if not key or any(character.isspace() for character in key):
        raise RuntimeError("The ElevenLabs key is empty or contains whitespace")
    assert_public(text, key)
    arguments.output.mkdir(parents=True, exist_ok=False)
    payload = {
        "text": text, "model_id": MODEL, "seed": 30572,
        "voice_settings": {
            "stability": 0.45, "similarity_boost": 0.75,
            "style": 0.15, "use_speaker_boost": True, "speed": 1.0,
        },
    }
    request = Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{arguments.voice_id}/with-timestamps?output_format=mp3_44100_128",
        data=json.dumps(payload).encode(),
        headers={"xi-api-key": key, "Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=180) as response:
            body = response.read(64 * 1024 * 1024 + 1)
    except HTTPError as error:
        raise RuntimeError(f"ElevenLabs returned HTTP {error.code}; credential and response body withheld") from None
    if len(body) > 64 * 1024 * 1024:
        raise RuntimeError("Speech response exceeded the bounded response size")
    reply = json.loads(body)
    audio = base64.b64decode(reply["audio_base64"], validate=True)
    if not audio:
        raise RuntimeError("The provider returned no audio")
    metadata = {
        "provider": "ElevenLabs", "voice_id": arguments.voice_id,
        "voice_name": arguments.voice_name, "model": MODEL,
        "text": text, "alignment": reply.get("alignment"),
        "text_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "audio_sha256": hashlib.sha256(audio).hexdigest(),
    }
    assert_public(json.dumps(metadata), key)
    (arguments.output / "performance.mp3").write_bytes(audio)
    (arguments.output / "alignment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    segments = aligned_segments(script["segments"], text, offsets, metadata["alignment"])
    manifest = {
        field: metadata[field]
        for field in ("provider", "voice_id", "voice_name", "model", "text_sha256", "audio_sha256")
    }
    manifest["segments"] = segments
    (arguments.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({
        "provider": "ElevenLabs", "voice": arguments.voice_name,
        "characters": len(text), "scenes": len(segments),
        "manifest": str(arguments.output / "manifest.json"),
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
