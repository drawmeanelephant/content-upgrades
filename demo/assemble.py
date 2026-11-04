#!/usr/bin/env python3
"""Build a narrated rough cut and editable FilmCraft project from the demo tapes."""

import argparse
from array import array
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import subprocess
import textwrap
import wave

from PIL import Image, ImageDraw, ImageFont, ImageOps

from filmcraft_session import FilmcraftSession


ROOT = Path(__file__).resolve().parents[1]
FPS = 30
TICKS = 254_016_000_000
SIZE = (1920, 1080)
BACKGROUND = "#181825"
WHITE = "#cdd6f4"
ACCENT = "#cba6f7"
FONT = "/System/Library/Fonts/Supplemental/Avenir Next.ttc"


def run(command, log=None):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    if log:
        Path(log).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {result.stderr[-3000:]}")
    return result.stdout


def probe(path):
    return json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path]))


def fingerprint(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def make_plan(videos, hero=None):
    tape = ROOT / "demo/out/tapes"
    hero = hero or ROOT / "demo/hero/verdict.png"
    plan = []

    def add(kind, source, start, duration, title, caption, provenance, narration):
        plan.append({
            "kind": kind, "source": str(source), "source_in": start,
            "frames": round(duration * FPS), "title": title, "caption": caption,
            "provenance": provenance, "narration": narration,
        })

    recorded = "META MUSE WONDER / RECORDED TAKE / OFFLINE REPLAY"
    sample = "MUSE SPARK OPEN / BASETEN / SAME MODEL RESPONSE"
    add("mascot", videos / "knap1.mp4", 1.4, 2.6, "Raw material",
        "Meta built the brains.", "GENERATED MASCOT",
        "Meta built the brains.")
    add("mascot", videos / "knap2.mp4", 2.7, 1.4, "Give it an edge",
        "Meet Knap.", "GENERATED MASCOT", "Meet Nap.")
    add("hero", hero, 0, 8, "Muse Spark can reason. Give it a publishing system.",
        "Stop making an intelligent model babysit Markdown.", sample,
        "Muse Spark can reason. Stop making it babysit Markdown. Nap gives Meta's intelligence a document worth reading.")
    add("product", tape / "02-verdict-data.mp4", 0.2, 20.3, "01 / Content, not layout",
        "The model supplies structured values. Templates own the page.", recorded,
        "Muse Wonder writes the content as structured values. That is the useful division of labor. Meta's model reasons about the material. Nap handles the document.")
    add("hero", hero, 0, 15, "02 / Let Spark write. Let the template typeset.",
        "Human-authored layout. Muse Spark's actual words.", sample,
        "Spark writes the verdict and backs it with the supplied sources. Nap takes that structured response and renders the page. The model does the interesting work. The template handles the formatting. No begging a chatbot to please keep the table intact.")
    add("hero-bottom", hero, 0, 5, "02 / Keep the receipts",
        "Muse Spark's verdict, with the evidence beside it.", sample,
        "The verdict is up front. The receipts are right there.")
    add("product", tape / "03-repair.mp4", 0.3, 20, "03 / Give Wonder the diagnostic",
        "A broken template. A concrete diagnostic. A Meta model repair.", recorded,
        "Now I break the template. Muse Wonder gets the diagnostic and the broken region. It restores the missing tag, and you can inspect the patch. This is why I want Meta models in the loop. Give them a concrete problem and an answer we can check.")
    add("mascot", videos / "knap5.mp4", 3.3, 2.6, "Where is the source?",
        "Citation? What citation?", "GENERATED MASCOT",
        "Citation? What citation?")
    add("product", tape / "05-boris-catch.mp4", 0.2, 16.4, "04 / Check the parts a computer can check",
        "A deliberately missing reference, caught before publication.", "SEEDED REFERENCE TEST / SEPARATE FIXTURE / LOCAL GRAPH",
        "For this test, I planted a bogus reference. Nap catches the missing page before publication. Fix the reference and the check goes green. Let Meta reason about the content. Let deterministic checks handle the parts with a right answer.")
    add("mascot", videos / "knap4.mp4", 3.8, 2, "Same stone. Different attitude.",
        "Your document does not have to sound like HR.", "GENERATED MASCOT",
        "Less corporate.")
    add("product", tape / "06-voice.mp4", 0.2, 19.4, "05 / Wonder brings the attitude",
        "Mild or feral. The document keeps its structure.", recorded,
        "And please, stop sanding the personality off everything. These Muse Wonder takes go from mild to feral while keeping the same document structure. The hash stays the same. The attitude does not. A useful document is allowed to sound like a person.")
    add("hero-bottom", hero, 0, 5, "The finished artifact",
        "Meta does the thinking. Knap gives the words an edge.", sample,
        "Meta does the thinking. Nap gives the words an edge.")
    add("mascot", videos / "knap6.mp4", 3.4, 1.5, "Sharp enough",
        "Good work has a little character.", "GENERATED MASCOT", "")
    add("end", hero, 0, 6, "Built with Meta", "Give the words an edge.",
        "MUSE SPARK OPEN ON BASETEN / MUSE WONDER VIA ACP",
        "Muse Spark. Base ten. Nap. Give the words an edge.")
    return plan


def add_baseten_take(plan, take_directory, tape):
    receipt = json.loads((take_directory / "receipt.json").read_text())
    if (
        receipt.get("backend") != "baseten"
        or receipt.get("model") != "meta-models/muse-spark-open-1026"
        or receipt.get("live_call") is not True
        or receipt.get("mock") is not False
        or receipt.get("validation_ok") is not True
        or receipt.get("render_ok") is not True
        or receipt.get("credential_in_public_output") is not False
    ):
        raise RuntimeError("The Baseten scene requires a genuine, validated, credential-safe take")
    duration = float(probe(tape)["format"]["duration"])
    head = min(8, duration / 3)
    tail = min(10, duration - head)
    replacement = [
        {
            "kind": "product", "source": str(tape), "source_in": 0,
            "frames": round(head * FPS), "title": "01 / Connect Baseten",
            "caption": "Nice try. Not on camera.",
            "provenance": "STAGED PLACEHOLDER / REAL KEY NEVER DISPLAYED",
            "narration": "Meta's Muse Spark open. Base ten inference. And absolutely not my A P I key.",
        },
        {
            "kind": "product", "source": str(tape), "source_in": duration - tail,
            "frames": round(tail * FPS), "title": "01 / A genuine Baseten response",
            "caption": "Spark makes the call: skip it for now.",
            "provenance": "BASETEN / GENUINE RESPONSE / API WAIT SHORTENED",
            "narration": "Spark says, skip it for now. Fast laptop numbers, no backups. That's useful judgment. Nap renders that exact response.",
        },
    ]
    plan[3:4] = replacement
    plan[-1]["provider_line"] = "Meta Muse Spark open / Baseten  +  Meta Muse Wonder / ACP"
    return plan


def font(size):
    return ImageFont.truetype(FONT, size)


def center(draw, text, y, size, color=WHITE):
    draw.text((SIZE[0] / 2, y), text, font=font(size), fill=color, anchor="mt")


def make_overlay(segment, output):
    image = Image.new("RGBA", SIZE)
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 1920, 92), fill=BACKGROUND)
    draw.rectangle((0, 1008, 1920, 1080), fill=BACKGROUND)
    draw.text((60, 18), "KNAP", font=font(30), fill=ACCENT)
    if segment["kind"] != "mascot":
        draw.text((210, 21), segment["title"], font=font(27), fill=WHITE)
        draw.text((1860, 61), segment["provenance"], font=font(18), fill="#a6adc8", anchor="ra")
    caption_size = 30
    while draw.textlength(segment["caption"], font=font(caption_size)) > 1800:
        caption_size -= 1
    draw.text((60, 1023), segment["caption"], font=font(caption_size), fill=WHITE)
    draw.rectangle((60, 1073, 1860, 1076), fill="#313244")
    draw.rectangle((60, 1073, 60 + 1800 * segment["end_frame"] / segment["total_frames"], 1076), fill=ACCENT)
    image.save(output)


def make_still(segment, output):
    canvas = Image.new("RGB", SIZE, BACKGROUND)
    if segment["kind"] == "end":
        draw = ImageDraw.Draw(canvas)
        center(draw, "KNAP", 220, 150, ACCENT)
        center(draw, "Give the words an edge.", 430, 58)
        center(draw, "Meta's intelligence. Human-authored structure.", 565, 32)
        center(draw, "Your document does not have to sound like HR.", 615, 32)
        center(draw, segment.get("provider_line", "Meta Muse Wonder  /  Zig  /  MCP"), 745, 27, "#a6e3a1")
        center(draw, "github.com/drawmeanelephant/content-upgrades", 920, 28, "#a6adc8")
    else:
        with Image.open(segment["source"]) as source:
            box = (20, 20, 1260, 715) if segment["kind"] == "hero" else (20, 390, 1260, 1080)
            crop = source.crop(box).convert("RGB")
            crop = ImageOps.contain(crop, (1600, 900), Image.Resampling.LANCZOS)
            canvas.paste(crop, ((1920 - crop.width) // 2, 100 + (900 - crop.height) // 2))
    canvas.save(output)


def prepare_segment(index, segment, directory):
    stem = f"{index + 1:02d}"
    seconds = segment["frames"] / FPS
    scene = directory / f"{stem}-scene.mp4"
    overlay = directory / f"{stem}-titles.png"
    make_overlay(segment, overlay)
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-n"]
    if segment["kind"] in ("hero", "hero-bottom", "end"):
        still = directory / f"{stem}-still.png"
        make_still(segment, still)
        command += ["-loop", "1", "-framerate", FPS, "-i", still]
        filters = "format=yuv420p"
    else:
        command += ["-ss", segment["source_in"], "-i", segment["source"]]
        if segment["kind"] == "mascot":
            filters = (
                "split=2[back][front];"
                "[back]scale=1920:1080:force_original_aspect_ratio=increase,"
                "crop=1920:1080,gblur=sigma=32,eq=brightness=-0.15[blurred];"
                "[front]scale=-2:900[subject];"
                "[blurred][subject]overlay=(W-w)/2:100,setsar=1,format=yuv420p"
            )
        else:
            filters = "scale=1600:900,pad=1920:1080:160:100:color=0x181825,setsar=1,format=yuv420p"
        source_seconds = segment.get("source_frames", segment["frames"]) / FPS
        hold = max(0, seconds - source_seconds)
        filters += f",trim=duration={source_seconds},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={hold}"
    command += [
        "-vf", filters, "-r", FPS, "-frames:v", segment["frames"], "-an",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-threads", "2",
        "-movflags", "+faststart", scene,
    ]
    run(command, directory / f"{stem}-video.log")
    speech_seconds = segment.get("speech_seconds", 0)
    audio_command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-n"]
    if segment.get("voice_source"):
        audio_command += [
            "-ss", segment["voice_start"], "-t", speech_seconds,
            "-i", segment["voice_source"], "-af",
            "loudnorm=I=-18:TP=-3:LRA=7,adelay=250:all=1,apad",
        ]
    else:
        audio_command += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
    audio = directory / f"{stem}-voice.wav"
    audio_command += ["-t", seconds, "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", audio]
    run(audio_command, directory / f"{stem}-audio.log")
    return {
        **segment, "scene": str(scene), "overlay": str(overlay),
        "audio": str(audio), "speech_seconds": speech_seconds,
    }


def make_soundtrack(plan, output):
    chunks = []
    for segment in plan:
        with wave.open(segment["audio"], "rb") as source:
            assert (source.getnchannels(), source.getsampwidth(), source.getframerate()) == (2, 2, 48000)
            data = source.readframes(source.getnframes())
        count = segment["frames"] * 1600 * 4
        chunks.append(data[:count].ljust(count, b"\0"))
    samples = array("h", b"".join(chunks))
    for frame in {plan[1]["start_frame"], plan[-2]["start_frame"]}:
        start = frame * 1600
        for offset in range(7200):
            t = offset / 48000
            value = int(3500 * math.exp(-38 * t) * math.sin(2 * math.pi * (220 * t - 240 * t * t)))
            for channel in range(2):
                position = 2 * (start + offset) + channel
                if position < len(samples):
                    samples[position] = max(-32768, min(32767, samples[position] + value))
    with wave.open(str(output), "wb") as target:
        target.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        target.writeframes(samples.tobytes())


def timecode(seconds):
    milliseconds = round(seconds * 1000)
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    seconds, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}"


def write_notes(plan, output, voice=None):
    description = (
        f"Natural narration: {voice['provider']}, {voice['voice_name']}, {voice['model']}."
        if voice else "Voiceover pending. This is a silent story review, not a final audio mix."
    )
    notes = [
        "# Knap rough cut", "",
        description + " Pronounce Knap as 'nap'.",
        "Generated mascot audio is muted. The two stone ticks are synthesized locally.",
        "Wonder takes are archived replays. Baseten, when present, is a newly recorded genuine call.",
        "The hero document renders the same genuine Baseten response shown in the API scene.",
        "An optional Baseten segment uses an invented key gag; its model response must be genuine.",
        "The Baseten API waiting interval is shortened in the edit and labeled as such.",
        "The tone examples are archived Wonder takes, not a fresh run of the current voice guard.",
        "The reference check is a separate seeded test, not a claim that the fresh draft passed publication.",
        "", "## Timed narration", "",
    ]
    subtitles = []
    number = 0
    for segment in plan:
        start = segment["start_frame"] / FPS
        end = segment["end_frame"] / FPS
        notes += [f"### {timecode(start)} – {timecode(end)} / {segment['title']}",
                  "", segment["narration"] or "(No narration.)", ""]
        lines = textwrap.wrap(segment["narration"], width=48)
        groups = ["\n".join(lines[i:i + 2]) for i in range(0, len(lines), 2)]
        weights = [len(group.split()) for group in groups]
        words = sum(weights)
        cursor = start + 0.25
        for group, weight in zip(groups, weights):
            duration = segment["speech_seconds"] * weight / words
            number += 1
            subtitles += [str(number), f"{timecode(cursor)} --> {timecode(cursor + duration)}", group, ""]
            cursor += duration
    (output / "voiceover.md").write_text("\n".join(notes))
    (output / "knap-rough-cut.srt").write_text("\n".join(subtitles))


def make_project(plan, output, soundtrack):
    with FilmcraftSession(output) as filmcraft:
        filmcraft.execute("file.newProject", name="Knap / hackathon rough cut")
        filmcraft.execute("file.newSequence", name="Knap / rough cut", width=1920, height=1080,
                          fps=FPS, video=2, audio=1)
        for segment in plan:
            imported = filmcraft.execute("file.import", paths=[segment["scene"], segment["overlay"]])
            if imported.get("errors") or len(imported["items"]) != 2:
                raise RuntimeError(f"FilmCraft import failed: {imported}")
            for item, track in zip(imported["items"], ("V1", "V2")):
                filmcraft.execute("timeline.place", item=item, track=track,
                                  frame=segment["start_frame"], sourceIn={"seconds": 0},
                                  duration={"frame": segment["frames"]},
                                  insert=False, audio=False, matchSequence=False)
        imported = filmcraft.execute("file.import", paths=[str(soundtrack)])
        if imported.get("errors") or len(imported["items"]) != 1:
            raise RuntimeError(f"FilmCraft audio import failed: {imported}")
        filmcraft.execute("timeline.place", item=imported["items"][0], track="A1", frame=0,
                          duration={"frame": plan[-1]["end_frame"]}, insert=False,
                          video=False, audio=True, matchSequence=False)
        project = output / "knap-rough-cut.fcproj"
        filmcraft.execute("file.saveAs", path=str(project))
        filmcraft.execute("file.exportOtio", path=str(output / "knap-rough-cut.otio"))
        for label, seconds in (("opening", 1.5), ("hero", 7), ("proof", 40)):
            seconds = min(seconds, plan[-1]["end_frame"] / FPS - 0.2)
            filmcraft.execute("file.exportFrame", path=str(output / f"preview-{label}.png"),
                              format="png", time=round(seconds * TICKS))
        filmcraft.connection.settimeout(1200)
        result = filmcraft.execute(
            "file.exportMedia", path=str(output / "knap-rough-cut.mp4"),
            format="h264", width=1920, height=1080, fps=FPS, crf=20,
            hardwareEncoding="auto", audio=True, range="entire", wait=True,
        )
        (output / "filmcraft-export.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"project": str(project), "export": result}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--videos", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--hero", type=Path, required=True)
    parser.add_argument("--narration", type=Path)
    parser.add_argument("--script-only", action="store_true")
    parser.add_argument("--silent-preview", action="store_true")
    parser.add_argument("--baseten-take", type=Path)
    parser.add_argument("--baseten-tape", type=Path, default=ROOT / "demo/out/tapes/02-baseten-live.mp4")
    arguments = parser.parse_args()
    if not (arguments.narration or arguments.script_only or arguments.silent_preview):
        parser.error("Provide --narration, or explicitly request --script-only or --silent-preview. No system-voice fallback.")
    plan = make_plan(arguments.videos.resolve(), arguments.hero.resolve())
    if arguments.baseten_take:
        plan = add_baseten_take(plan, arguments.baseten_take.resolve(), arguments.baseten_tape.resolve())
    if arguments.smoke:
        plan = plan[:3]
        plan[-1]["frames"] = 2 * FPS
        plan[-1]["narration"] = "Real output."
    voice = None
    if arguments.narration:
        voice = json.loads((arguments.narration / "manifest.json").read_text())
        if fingerprint(arguments.narration / "performance.mp3") != voice["audio_sha256"]:
            raise RuntimeError("The narration audio differs from the generated performance")
        if len(voice["segments"]) != len(plan):
            raise RuntimeError("Narration and edit have different scene counts")
        for segment, spoken in zip(plan, voice["segments"]):
            if spoken["text"] != segment["narration"]:
                raise RuntimeError(f"Narration text differs for {segment['title']}")
            segment["voice_source"] = str((arguments.narration / spoken["file"]).resolve()) if spoken["file"] else None
            segment["voice_start"] = spoken["start"]
            segment["speech_seconds"] = spoken["duration"]
            segment["source_frames"] = segment["frames"]
            segment["frames"] = max(segment["frames"], math.ceil((spoken["duration"] + 0.5) * FPS))
        if not voice.get("provider") or not voice.get("voice_name") or not voice.get("model"):
            raise RuntimeError("Narration provenance is missing")
    else:
        for segment in plan:
            segment["speech_seconds"] = max(0, segment["frames"] / FPS - 0.5)
        if arguments.silent_preview:
            plan[-1]["provenance"] = "VOICEOVER PENDING / VISUAL STORY REVIEW"
    cursor = 0
    for segment in plan:
        segment["start_frame"] = cursor
        cursor += segment["frames"]
        segment["end_frame"] = cursor
    if cursor >= 180 * FPS:
        raise RuntimeError("The demo must be shorter than three minutes")
    for segment in plan:
        segment["total_frames"] = cursor
    sources = {segment["source"] for segment in plan}
    for source in sources:
        if not Path(source).is_file():
            raise FileNotFoundError(source)
    original_hashes = {source: fingerprint(source) for source in sources}
    for segment in plan:
        if segment["kind"] in ("product", "mascot"):
            available = float(probe(segment["source"])["format"]["duration"])
            if segment["source_in"] + segment.get("source_frames", segment["frames"]) / FPS > available + 0.001:
                raise RuntimeError(f"Select extends past source: {segment['source']}")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output = (arguments.output or ROOT / f"demo/out/hackathon/cut-{stamp}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    if arguments.script_only:
        (output / "script.json").write_text(json.dumps({
            "fps": FPS, "seconds": cursor / FPS, "segments": plan,
        }, indent=2) + "\n")
        write_notes(plan, output)
        print(f"Script ready: {output / 'voiceover.md'}", flush=True)
        return
    media = output / "media"
    media.mkdir()
    print(json.dumps({"output": str(output), "frames": cursor, "seconds": cursor / FPS}), flush=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        plan = list(pool.map(lambda pair: prepare_segment(*pair, media), enumerate(plan)))
    soundtrack = output / "narration.wav"
    make_soundtrack(plan, soundtrack)
    write_notes(plan, output, voice)
    (output / "edit.json").write_text(json.dumps({
        "fps": FPS, "frames": cursor, "seconds": cursor / FPS,
        "source_sha256": original_hashes, "segments": plan,
    }, indent=2) + "\n")
    make_project(plan, output, soundtrack)
    metadata = probe(output / "knap-rough-cut.mp4")
    if abs(float(metadata["format"]["duration"]) - cursor / FPS) > 0.1:
        raise RuntimeError("Export duration does not match the edit")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
         "-i", output / "knap-rough-cut.mp4", "-f", "null", "-"], output / "decode-check.log")
    if original_hashes != {source: fingerprint(source) for source in sources}:
        raise RuntimeError("An original source changed during the build")
    (output / "verified.json").write_text(json.dumps({
        "duration": metadata["format"]["duration"], "all_frames_decode": True,
        "originals_unchanged": True, "voiceover_pending": voice is None,
        "narration_provider": voice["provider"] if voice else None,
    }, indent=2) + "\n")
    print(f"Verified: {output / 'knap-rough-cut.mp4'}", flush=True)


if __name__ == "__main__":
    main()
