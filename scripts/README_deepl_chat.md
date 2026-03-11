deepl_chat_he_test.py — DeepL chat translation quick tests (Hebrew)

Purpose
-------
This small script runs a set of short chat messages through DeepL to compare "current" (no hints) translations with translation outputs when adding small contextual hints or explicit source variants (e.g., recipient_gender or speaker_gender). It's intended to help decide whether adding gender hints or explicit variants would improve chat translation quality for Hebrew.

How to run
----------
1. Set your DeepL API key:

   Windows (PowerShell):
     $env:DEEPL_API_KEY = "your-key-here"

   macOS / Linux (bash):
     export DEEPL_API_KEY=your-key-here

2. Install requests (optional, the script will fall back to urllib if requests is not present):

   pip install requests

3. Run the script from repository root:

   python scripts/deepl_chat_he_test.py

Output
------
- Writes `scripts/deepl_chat_he_results.json` containing translations for each test case.
- Writes `scripts/deepl_chat_he_results.csv` with a concise summary (test_id, source, case, translation).
- Prints a concise summary to stdout.

Notes
-----
- Avoid sending real PII to DeepL in test runs. Use anonymized or synthetic texts.
- DeepL calls are billed according to your DeepL plan; small test sets should incur minimal cost.
