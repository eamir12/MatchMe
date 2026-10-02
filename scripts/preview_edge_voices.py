#!/usr/bin/env python3
"""Free no-key neural preview of the onboarding tour voice (Edge TTS).

Generates the same 2 beats x 3 locales as onboarding_audio_samples.json
with warm female neural voices (Jenny/Elvira/Hila) into
$TEMP/opencode/onboarding_voice_compare/ + a side-by-side preview page.
Run: python scripts/preview_edge_voices.py
"""
import asyncio
import json
import os
import re
import sys

import edge_tts

BASE = os.path.dirname(__file__)
SAMPLES_FILE = os.path.join(BASE, "onboarding_audio_samples.json")
OUT_DIR = os.path.join(os.environ.get("TEMP", "."), "opencode", "onboarding_voice_compare")
VOICES = {"en": "en-US-JennyNeural", "es": "es-ES-ElviraNeural", "he": "he-IL-HilaNeural"}


def naturalize(text: str) -> str:
    out = re.sub(r"\s+", " ", text.strip())
    out = out.replace("…", ". ")
    out = re.sub(r"\.{2,}", ". ", out)
    out = re.sub(r"\s+[—–-]\s+", ", ", out)
    out = re.sub(r'[★☆•●►»«""“”„‟]', "", out)
    out = re.sub(r"\s+([,.!?;:])", r"\1", out)
    out = re.sub(r"\s+", " ", out)
    return out.strip()


async def one(text: str, voice: str, path: str) -> None:
    await edge_tts.Communicate(naturalize(text), voice).save(path)


async def main() -> int:
    with open(SAMPLES_FILE, encoding="utf-8") as f:
        samples = json.load(f)["samples"]
    os.makedirs(OUT_DIR, exist_ok=True)
    for beat in samples:
        for lang, voice in VOICES.items():
            path = os.path.join(OUT_DIR, f"edge_{lang}_{beat['id']}.mp3")
            try:
                await one(beat[lang], voice, path)
                print(f"wrote {os.path.basename(path)} ({os.path.getsize(path)//1024} KB)")
            except Exception as e:  # noqa: BLE001
                print(f"FAILED edge {lang} {beat['id']}: {e}")
    cards = []
    for beat in samples:
        for lang in VOICES:
            fname = f"edge_{lang}_{beat['id']}.mp3"
            exists = os.path.isfile(os.path.join(OUT_DIR, fname))
            player = f"<audio controls src='{fname}'></audio>" if exists else "<i>generation failed</i>"
            cards.append(f"<h3>{beat['id']} · {lang} · Edge {VOICES[lang]}</h3><p>{beat[lang]}</p><p>{player}</p>")
    with open(os.path.join(OUT_DIR, "preview_edge_voices.html"), "w", encoding="utf-8") as f:
        f.write("<html><head><meta charset='utf-8'><title>Free neural preview</title></head>"
                "<body><h2>Onboarding tour — free neural preview (Edge, no key)</h2>"
                "<p>Warm female neural voices. ElevenLabs/Google samples will land next to these once keys exist.</p>"
                + "<hr>".join(cards) + "</body></html>")
    print("preview: " + os.path.join(OUT_DIR, "preview_edge_voices.html"))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
