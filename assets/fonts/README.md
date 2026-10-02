This folder should contain the Noto font files used by the app.

Recommended files (place into this folder):
- NotoSans-Regular.ttf
- NotoSans-Bold.ttf
- NotoSansHebrew-Regular.ttf
- NotoSansHebrew-Bold.ttf
- NotoSansArabic-Regular.ttf
- NotoSansArabic-Bold.ttf
- NotoSansSymbols-Regular.ttf
- NotoSansSymbols2-Regular.ttf
- NotoSerif-Regular.ttf
- NotoSerif-Bold.ttf

Deliberately NOT bundled:
- NotoColorEmoji.ttf — every target platform has a system emoji font
  (Segoe UI Emoji, Noto Color Emoji, Apple Color Emoji) and chat emoji render
  from assets/twemoji/ images. Bundling it cost ~10 MB per build.
- NotoSansTC-Regular/Bold.ttf — CJK glyphs come from the platform system font.
  Bundling them cost ~13.6 MB per build. Re-add only if a CJK language ever
  has to render on a platform without a system CJK font, and add the family
  back to pubspec.yaml at the same time (a file alone is never bundled).

You can run the helper script from the repo root to attempt automatic download:

  powershell -ExecutionPolicy Bypass -File .\tools\download_noto_fonts.ps1

If the automatic download fails, the script prints direct links where you can manually obtain the fonts (GitHub raw URLs).

After placing the files, run:

  flutter pub get
  flutter clean
  flutter run -d chrome

This will ensure Flutter picks up the local font assets and the console warning about missing glyphs should be removed.

Alternate sources & manual steps for NotoSansTC-Bold (if automatic downloads fail):

1) Try Google Fonts (recommended):
   - Visit https://fonts.google.com and search for "Noto Sans TC".
   - Click "Download family" and extract the downloaded ZIP.
   - Copy the Bold file (e.g., NotoSansTC-Bold.otf or NotoSansTC-Bold.ttf) into `assets/fonts/`.

2) Direct GitHub raw links (attempted by helper script):
   - https://github.com/googlefonts/noto-fonts/raw/main/hinted/ttf/NotoSansTC/NotoSansTC-Bold.ttf
   - https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSansTC/NotoSansTC-Bold.ttf
   - https://github.com/googlefonts/noto-cjk/raw/main/Sans/OTF/NotoSansTC-Bold.otf
   - https://raw.githubusercontent.com/googlefonts/noto-cjk/main/Sans/OTF/NotoSansTC-Bold.otf

3) If you add the Bold file manually, re-run:

  flutter pub get
  flutter clean
  flutter run -d chrome

Notes:
- I attempted the common GitHub raw paths automatically but the files either returned 404 or the connection was closed; manual download from Google Fonts is the most reliable method.
- If you'd like, drop the Bold file into the repo and I can add the Bold entry back to `pubspec.yaml` and verify the web build for you.

---

Noto Serif & Symbol families: status
- **Noto Serif** (Regular & Bold) have been downloaded and added to `assets/fonts/`.
- **Noto Sans Symbols** and **Symbols2** have been downloaded and added to `assets/fonts/`.

Noto Sans CJK (SC / JP / KR): manual download recommended
- The automatic attempts to fetch the Noto Sans CJK families failed (404s / connection resets) — these packages are large and sometimes organized differently on the Noto repo. The most reliable option is to download the CJK families manually from Google Fonts or the Noto CJK GitHub releases and place the extracted OTF/TTF files in `assets/fonts/`.
- Recommended files (place into `assets/fonts/`):
  - `NotoSansSC-Regular.otf` (Simplified Chinese)
  - `NotoSansJP-Regular.otf` (Japanese)
  - `NotoSansKR-Regular.otf` (Korean)
- After adding them, run:

  flutter pub get
  flutter clean
  flutter run -d chrome

Notes & trade-offs:
- These CJK fonts are large (tens of MB each) and will increase the repo size and web bundle; for production consider using Google Fonts CDN instead of bundling locally.
- If you prefer, upload the CJK font files here and I will add the Bold/Regular entries to `pubspec.yaml` and verify the web build for you.

Twemoji fallback (optional):
- I added a Twemoji CDN fallback to `web/index.html` that parses DOM nodes and replaces emoji glyphs with SVG images from Twemoji for DOM text (e.g., overlays). For canvas-rendered Flutter text we now use jsDelivr-hosted Twemoji PNGs (safer for CORS) via the `EmojiWidget`.
- Note: Flutter typically renders most app text to a canvas; DOM Twemoji parsing won't affect canvas text. For in-app widgets that still miss emoji glyphs, options are:
  - Use the bundled `EmojiWidget` (already applied to reactions) which uses jsDelivr PNGs and avoids CORS; or
  - Add selected emoji PNG/SVG assets to `assets/` and render them locally for offline and deterministic rendering.

If you'd like, I can also download and include a small set of commonly-used emoji PNGs into `web/twemoji/` (served from the same origin) to eliminate any CDN dependency and further reduce network jitter.

Run the helper script to fetch curated Twemoji PNGs into `web/twemoji/`:

  powershell -ExecutionPolicy Bypass -File .\tools\download_twemoji_pngs.ps1

After downloading, re-build and run the web app to verify the emoji render locally.

---

About the "Could not find a set of Noto fonts" console warning
- Why it appears: Flutter attempts to find font assets that cover any missing codepoints; when it can't find a font covering some characters (for example, rare emoji sequences or certain CJK characters) it emits the console warning and suggests providing additional font assets.
- What to do:
  1. Add Noto font families that cover the missing characters (e.g., **Noto Color Emoji**, **Noto Sans Symbols**, and the CJK families) into `assets/fonts/` and add entries to `pubspec.yaml` as shown earlier.
  2. Re-run `flutter pub get` and `flutter clean` then rebuild the web app.
- Important caveat for web: browsers handle color emoji in different ways; bundling a Color Emoji font does not guarantee the emoji will be rendered in color on every browser. For deterministic appearance across browsers, use the `EmojiWidget` image fallback (already implemented) which renders a PNG when glyphs are unavailable.
- Practical tip: with the recent glyph-first `EmojiWidget` change in the app, most in-message emoji will be rendered via `EmojiWidget` (native glyphs when available, PNG fallback when not), which reduces the frequency of the warning. If you continue to see the warning for specific codepoints, add the appropriate Noto family for those scripts or include targeted emoji PNGs as assets.

If you'd like, I can add instructions to automatically detect frequently-missing codepoints (from logs) and produce a short list of fonts or emoji assets to add — tell me if you want that scan run.