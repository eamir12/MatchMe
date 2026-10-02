#!/usr/bin/env python3
"""Generate onboarding voice comparison samples (ElevenLabs vs Google Cloud TTS).

Usage:
  set ELEVENLABS_API_KEY=...
  set GOOGLE_CLOUD_TTS_KEY=...
  python scripts/generate_onboarding_audio.py --provider both
  python scripts/generate_onboarding_audio.py --provider elevenlabs
  python scripts/generate_onboarding_audio.py --provider google

Reads scripts/onboarding_audio_samples.json, normalizes text the same way
VoiceGuidanceService._naturalizeForSpeech does (ellipsis -> sentence break,
dashes -> comma, strip speaking-symbols), then synthesizes:

  ElevenLabs: model eleven_multilingual_v2, voice Rachel (warm female,
    multilingual so the SAME persona speaks en/es/he).
    Override: --eleven-voice-id / ELEVENLABS_VOICE_ID
    NOTE (Sep 2026): the Free plan rejects library/premade voices via the
    API ("Free users cannot use library voices via the API") — API
    generation needs Starter (~$5-6/mo) or a voice ID from your own
    collection. For a free listen-only comparison, paste the sample texts
    into the ElevenLabs website playground instead.
  Google: en-US-Neural2-F, es-ES-Neural2-A, he-IL-Wavenet-A (per-language
    female voices; Google has no single cross-lingual persona).
    Auth: GOOGLE_CLOUD_TTS_KEY (API-key JSON) or
    GOOGLE_APPLICATION_CREDENTIALS (service-account file).

Output (default --out-dir, kept out of the repo):
  <out-dir>/<provider>_<lang>_<beat>.mp3 + preview_onboarding_voices.html
  with side-by-side <audio> players per beat.

Do not put real PII in the sample texts; these are the public tour lines.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.request

SAMPLES_FILE = os.path.join(os.path.dirname(__file__), "onboarding_audio_samples.json")

ELEVEN_MODEL = "eleven_multilingual_v2"
ELEVEN_DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"  # Rachel
GOOGLE_VOICES = {
    "en": {"languageCode": "en-US", "name": "en-US-Neural2-F"},
    "es": {"languageCode": "es-ES", "name": "es-ES-Neural2-A"},
    "he": {"languageCode": "he-IL", "name": "he-IL-Wavenet-A"},
}


def naturalize(text: str) -> str:
    out = re.sub(r"\s+", " ", text.strip())
    out = out.replace("…", ". ")
    out = re.sub(r"\.{2,}", ". ", out)
    out = re.sub(r"\s+[—–-]\s+", ", ", out)
    out = re.sub(r'[★☆•●►»«""“”„‟]', "", out)
    out = re.sub(r"\s+([,.!?;:])", r"\1", out)
    out = re.sub(r"\s+", " ", out)
    out = re.sub(r"\.\s*\.\s*", ". ", out)
    return out.strip()


def elevenlabs(text: str, api_key: str, voice_id: str) -> bytes:
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
    payload = {
        "model_id": ELEVEN_MODEL,
        "text": text,
        "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "xi-api-key": api_key,
            "Accept": "audio/mpeg",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def _google_access_token() -> str | None:
    creds_file = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not creds_file or not os.path.isfile(creds_file):
        return None
    try:
        from google.oauth2 import service_account  # type: ignore
        import google.auth.transport.requests  # type: ignore

        creds = service_account.Credentials.from_service_account_file(
            creds_file,
            scopes=["https://www.googleapis.com/auth/cloud-platform"],
        )
        creds.refresh(google.auth.transport.requests.Request())
        return creds.token
    except ImportError:
        print("ERROR: google-auth not installed. pip install google-auth, or use GOOGLE_CLOUD_TTS_KEY instead.")
        sys.exit(1)


def google_tts(text: str, lang: str) -> bytes:
    voice = GOOGLE_VOICES[lang]
    body = {
        "input": {"text": text},
        "voice": {"languageCode": voice["languageCode"], "name": voice["name"]},
        "audioConfig": {"audioEncoding": "MP3", "speakingRate": 1.0, "pitch": 0.0},
    }
    api_key = os.environ.get("GOOGLE_CLOUD_TTS_KEY")
    if api_key:
        url = f"https://texttospeech.googleapis.com/v1/text:synthesize?key={api_key}"
        headers = {"Content-Type": "application/json"}
    else:
        token = _google_access_token()
        if not token:
            print("ERROR: set GOOGLE_CLOUD_TTS_KEY or GOOGLE_APPLICATION_CREDENTIALS.")
            sys.exit(1)
        url = "https://texttospeech.googleapis.com/v1/text:synthesize"
        headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if "audioContent" not in data:
        raise RuntimeError(f"Google TTS error: {data}")
    return base64.b64decode(data["audioContent"])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", choices=["elevenlabs", "google", "both"], default="both")
    ap.add_argument("--out-dir", default=os.path.join(os.environ.get("TEMP", "."), "opencode", "onboarding_voice_compare"))
    ap.add_argument("--eleven-voice-id", default=os.environ.get("ELEVENLABS_VOICE_ID", ELEVEN_DEFAULT_VOICE))
    args = ap.parse_args()

    with open(SAMPLES_FILE, encoding="utf-8") as f:
        samples = json.load(f)["samples"]

    providers = ["elevenlabs", "google"] if args.provider == "both" else [args.provider]
    if "elevenlabs" in providers and not os.environ.get("ELEVENLABS_API_KEY"):
        print("ERROR: set ELEVENLABS_API_KEY before generating ElevenLabs samples.")
        return 1
    if "google" in providers and not (os.environ.get("GOOGLE_CLOUD_TTS_KEY") or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")):
        print("ERROR: set GOOGLE_CLOUD_TTS_KEY (or GOOGLE_APPLICATION_CREDENTIALS) before generating Google samples.")
        return 1

    os.makedirs(args.out_dir, exist_ok=True)
    made: list[tuple[str, str, str, str]] = []  # (beat, lang, provider, filename)
    for beat in samples:
        for lang in ("en", "es", "he"):
            text = naturalize(beat[lang])
            for provider in providers:
                try:
                    if provider == "elevenlabs":
                        audio = elevenlabs(text, os.environ["ELEVENLABS_API_KEY"], args.eleven_voice_id)
                    else:
                        audio = google_tts(text, lang)
                except Exception as e:  # noqa: BLE001 - report per-file, keep going
                    print(f"FAILED {provider} {lang} {beat['id']}: {e}")
                    continue
                fname = f"{provider}_{lang}_{beat['id']}.mp3"
                with open(os.path.join(args.out_dir, fname), "wb") as f:
                    f.write(audio)
                made.append((beat["id"], lang, provider, fname))
                print(f"wrote {fname} ({len(audio)//1024} KB)")

    # Side-by-side preview page.
    cards = []
    for beat in samples:
        for lang in ("en", "es", "he"):
            row = f"<h3>{beat['id']} · {lang}</h3><p>{beat[lang]}</p>"
            for provider in providers:
                fname = f"{provider}_{lang}_{beat['id']}.mp3"
                if os.path.isfile(os.path.join(args.out_dir, fname)):
                    row += f"<p><b>{provider}</b><br><audio controls src='{fname}'></audio></p>"
            cards.append(row)
    html = "<html><head><meta charset='utf-8'><title>Onboarding voice comparison</title></head><body><h2>ElevenLabs vs Google — onboarding samples</h2>" + "<hr>".join(cards) + "</body></html>"
    with open(os.path.join(args.out_dir, "preview_onboarding_voices.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print(f"preview: {os.path.join(args.out_dir, 'preview_onboarding_voices.html')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
