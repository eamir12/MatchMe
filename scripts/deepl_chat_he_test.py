#!/usr/bin/env python3
"""Run a chat-focused DeepL test matrix for Hebrew (HE).

Usage:
  export DEEPL_API_KEY=your_key_here
  python scripts/deepl_chat_he_test.py

This script sends a set of short chat messages twice:
 - "current": a basic translate request (no context)
 - "context": a request with a small `context` hint (e.g., speaker_gender/recipient_gender)
 - "explicit": when applicable, an explicit source variant ("You (female) ...")

It writes results to scripts/deepl_chat_he_results.json and prints a summary.

Note: This sends text to DeepL; do not include real PII in messages. Use a DeepL Pro account for data/privacy guarantees.
"""

import os
import json
import sys
import time
from typing import List, Dict, Any

API_KEY = os.environ.get("DEEPL_API_KEY")
# Use api-free for free-plan keys (these often include a suffix like ':fx')
if API_KEY and (API_KEY.endswith(':fx') or ':' in API_KEY):
    API_URL = "https://api-free.deepl.com/v2/translate"
else:
    API_URL = "https://api.deepl.com/v2/translate"

if not API_KEY:
    print("ERROR: Set DEEPL_API_KEY in environment before running this script.")
    sys.exit(1)

# Try to use requests if available for nicer output; otherwise fall back to urllib
try:
    import requests
    POST = lambda url, headers, json_payload: requests.post(url, headers=headers, json=json_payload)
    HAS_REQUESTS = True
except Exception:
    import urllib.request
    import urllib.error

    def POST(url, headers, json_payload):
        data = json.dumps(json_payload).encode('utf-8')
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')
        return urllib.request.urlopen(req)

    HAS_REQUESTS = False

# Expanded test matrix: short, chatty messages typical for newly matched users
TESTS: List[Dict[str, Any]] = [
    {"id": "greeting_hey", "text": "Hey, nice to meet you!", "type": "neutral"},
    {"id": "greeting_hi", "text": "Hi!", "type": "neutral"},
    {"id": "compliment", "text": "You look great!", "type": "second_person", "recipient_gender_examples": ["female", "male", "nonbinary"]},
    {"id": "where_from", "text": "Where are you from?", "type": "neutral"},
    {"id": "coffee", "text": "Do you want to grab coffee sometime?", "type": "neutral"},
    {"id": "liked_photos", "text": "I liked your photos.", "type": "first_person", "speaker_gender_examples": ["female", "male", "nonbinary"]},
    {"id": "meet_tmr", "text": "Do you want to meet tomorrow?", "type": "neutral"},
    {"id": "sent_message", "text": "I sent you a message.", "type": "first_person", "speaker_gender_examples": ["female", "male", "nonbinary"]},
    {"id": "call", "text": "Can I call you?", "type": "first_person", "speaker_gender_examples": ["female", "male"]},
    {"id": "typing", "text": "is typing...", "type": "typing", "recipient_gender_examples": ["female","male","nonbinary"]},
    {"id": "placeholder_name", "text": "Hey <name/>, want to meet tonight?", "type": "placeholder", "tag_handling": "xml", "non_splitting_tags": ["name"]},
    {"id": "messages_count", "text": "You have {count} new messages.", "type": "count", "counts": [1,2,5], "placeholder_tag": "count"},
    {"id": "ambiguous_they", "text": "They liked your message.", "type": "ambiguous_pronoun"},
    {"id": "on_my_way", "text": "I'm on my way.", "type": "first_person", "speaker_gender_examples": ["female","male"]},
]

headers = {
    "Authorization": f"DeepL-Auth-Key {API_KEY}",
    "Content-Type": "application/json",
}

results = {}

# CSV-friendly rows summary
csv_rows = []

for t in TESTS:
    tid = t["id"]
    source_text = t["text"]
    results[tid] = {"text": source_text, "cases": {}}

    # Utility to call API and record
    def call_and_record(payload):
        try:
            resp = POST(API_URL, headers, payload)
            if HAS_REQUESTS:
                data = resp.json()
            else:
                data = json.loads(resp.read().decode('utf-8'))
            translated = data["translations"][0]["text"]
            return translated, data
        except Exception as e:
            return f"ERROR: {e}", None

    # 1) Current (no context) - simple or templated
    if t.get("type") == "count":
        for n in t["counts"]:
            text_n = t["text"].format(count=n)
            payload = {"text": [text_n], "target_lang": "HE", "source_lang": "EN"}
            translated, _ = call_and_record(payload)
            key = f"current_count_{n}"
            results[tid]["cases"][key] = {"payload": payload, "translation": translated}
            csv_rows.append((tid, text_n, key, translated))
    else:
        payload = {"text": [source_text], "target_lang": "HE", "source_lang": "EN"}
        if "tag_handling" in t:
            payload["tag_handling"] = t["tag_handling"]
            if "non_splitting_tags" in t:
                payload["non_splitting_tags"] = t["non_splitting_tags"]
        translated, _ = call_and_record(payload)
        results[tid]["cases"]["current"] = {"payload": payload, "translation": translated}
        csv_rows.append((tid, source_text, "current", translated))

    # 2) Gender hints / speaker/recipient tests
    if t.get("type") == "second_person" and t.get("recipient_gender_examples"):
        for gender in t["recipient_gender_examples"]:
            ctx = f"recipient_gender: {gender}"
            payload_c = {"text": [source_text], "target_lang": "HE", "source_lang": "EN", "context": ctx}
            translated_c, _ = call_and_record(payload_c)
            key = f"context_recipient_gender_{gender}"
            results[tid]["cases"][key] = {"context": ctx, "translation": translated_c}
            csv_rows.append((tid, source_text, key, translated_c))

            explicit = source_text.replace("You", f"You ({gender})")
            payload_e = {"text": [explicit], "target_lang": "HE", "source_lang": "EN"}
            translated_e, _ = call_and_record(payload_e)
            key = f"explicit_recipient_{gender}"
            results[tid]["cases"][key] = {"explicit": explicit, "translation": translated_e}
            csv_rows.append((tid, explicit, key, translated_e))

    if t.get("type") == "first_person" and t.get("speaker_gender_examples"):
        for gender in t["speaker_gender_examples"]:
            ctx = f"speaker_gender: {gender}"
            payload_c = {"text": [source_text], "target_lang": "HE", "source_lang": "EN", "context": ctx}
            translated_c, _ = call_and_record(payload_c)
            key = f"context_speaker_gender_{gender}"
            results[tid]["cases"][key] = {"context": ctx, "translation": translated_c}
            csv_rows.append((tid, source_text, key, translated_c))

            explicit = source_text.replace("I ", f"I ({gender}) ")
            payload_e = {"text": [explicit], "target_lang": "HE", "source_lang": "EN"}
            translated_e, _ = call_and_record(payload_e)
            key = f"explicit_speaker_{gender}"
            results[tid]["cases"][key] = {"explicit": explicit, "translation": translated_e}
            csv_rows.append((tid, explicit, key, translated_e))

    if t.get("type") == "typing" and t.get("recipient_gender_examples"):
        for gender in t["recipient_gender_examples"]:
            ctx = f"recipient_gender: {gender}"
            payload_c = {"text": [source_text], "target_lang": "HE", "source_lang": "EN", "context": ctx}
            translated_c, _ = call_and_record(payload_c)
            key = f"context_recipient_gender_{gender}"
            results[tid]["cases"][key] = {"context": ctx, "translation": translated_c}
            csv_rows.append((tid, source_text, key, translated_c))

    # 3) Count placeholder variant: send placeholder and tag_handling
    if t.get("type") == "count":
        placeholder = t["text"].replace("{count}", f"<{t['placeholder_tag']}/> ")
        payload_p = {"text": [placeholder], "target_lang": "HE", "source_lang": "EN", "tag_handling": "xml", "non_splitting_tags": [t['placeholder_tag']]}
        translated_p, _ = call_and_record(payload_p)
        key = "placeholder_with_tag"
        results[tid]["cases"][key] = {"payload": payload_p, "translation": translated_p}
        csv_rows.append((tid, placeholder, key, translated_p))

    # 4) Ambiguous pronoun check
    if t.get("type") == "ambiguous_pronoun":
        # try context with explicit antecedent
        ctx = "antecedent: nonbinary_person" 
        payload_c = {"text": [source_text], "target_lang": "HE", "source_lang": "EN", "context": ctx}
        translated_c, _ = call_and_record(payload_c)
        key = "context_ambiguous_antecedent_nonbinary"
        results[tid]["cases"][key] = {"context": ctx, "translation": translated_c}
        csv_rows.append((tid, source_text, key, translated_c))

    # Sleep a little to avoid hitting rate limits
    time.sleep(0.5)

# Output results
out_path = os.path.join(os.path.dirname(__file__), 'deepl_chat_he_results.json')
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(results, f, ensure_ascii=False, indent=2)

# Write CSV summary
import csv
csv_path = os.path.join(os.path.dirname(__file__), 'deepl_chat_he_results.csv')
with open(csv_path, 'w', newline='', encoding='utf-8') as csvfile:
    writer = csv.writer(csvfile)
    writer.writerow(['test_id', 'source', 'case', 'translation'])
    for row in csv_rows:
        writer.writerow(row)

print(f"Wrote results to {out_path} and CSV {csv_path}")

# Print a concise summary
for tid, info in results.items():
    print('\n---')
    print(f"Test: {tid}")
    print(f"Source: {info['text']}")
    for case, data in info['cases'].items():
        translation = data.get('translation')
        if not translation and isinstance(data, dict):
            translation = data.get('translation')
        print(f"\nCase: {case}\n  -> {translation}")

print('\nDone.')
# Output results
out_path = os.path.join(os.path.dirname(__file__), 'deepl_chat_he_results.json')
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(results, f, ensure_ascii=False, indent=2)

print(f"Wrote results to {out_path}")

# Print a concise summary
for tid, info in results.items():
    print('\n---')
    print(f"Test: {tid}")
    print(f"Source: {info['text']}")
    for case, data in info['cases'].items():
        translation = data.get('translation')
        if not translation and isinstance(data, dict):
            translation = data.get('translation')
        print(f"\nCase: {case}\n  -> {translation}")

print('\nDone.')
