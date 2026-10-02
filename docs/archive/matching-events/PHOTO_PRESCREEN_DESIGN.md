# Photo Prescreen Service Architecture

## Overview

The Photo Prescreen Service provides local photo validation before sending images to Google Gemini AI for final approval. This reduces costs, improves user experience with faster feedback, and filters out obviously invalid photos.

## User Flow

1. User picks a photo (gallery or camera) in the profile wizard.
2. The photo opens in the crop editor first — users can fix issues (crop away extra people, zoom in on a small face) before being judged.
3. The prescreen runs on the **final edited bytes** (off the UI thread).
4. On failure, a dialog shows the rejected photo, a per-rule icon, and an actionable message with two options: **Adjust photo** (re-opens the editor) or **Choose another photo** (aborts).
5. On success, the bytes are compressed and handed to the upload path, where the existing Gemini validation (`validate-primary-photo` / `validate-secondary-photo` edge functions) runs as before.

## Architecture

### 1. Service Layer (`photo_prescreen_service.dart`)

**Core Components:**
- `PhotoPrescreenService` - Main service class
- `PhotoPrescreenResult` - Result object with detailed analysis
- `PrescreenConfig` - Configuration for different photo types
- Analysis models: `FaceAnalysis`, `BodyAnalysis`, `ImageQuality`

**Validation Pipeline (in order):**
1. **File Validation** - Format whitelist (JPEG/PNG/WEBP by header bytes), size limits from the active config
2. **Duplicate Detection** - MD5 hash check against caller-provided `existingHashes`
3. **Image Quality** - Single background-isolate decode pass computing resolution, aspect ratio, blur score, and brightness score; all thresholds come from the active config
4. **Native ML Detection** - Platform-specific face/body detection; platforms without local ML skip person checks (Gemini still validates)
5. **Photo-Type Rules** - Apply primary vs secondary photo rules

All heavy work (hashing, decode, blur/brightness) runs in background isolates via `compute()`; the prescreen never decodes on the UI thread.

### 2. Native Platform Integration

#### Android (`PhotoPrescreenHandler.kt`)
- Uses ML Kit Vision APIs
- Face detection with tracking and pose estimation
- Body pose detection for full/upper body classification
- ML Kit exposes no per-face detection probability, so any face returned by the ACCURATE-mode detector reports `faceConfidence = 1.0` (matching iOS Vision, whose confidence is ~1.0). Size/position quality is enforced via `faceSizeRatio` on the Dart side.

#### iOS (`AppDelegate.swift` - `analyzePhotoPrescreen`)
- Uses Vision framework
- Face rectangle detection (`VNDetectFaceRectanglesRequest`)
- Human body detection (`VNDetectHumanRectanglesRequest`)
- Uses real Vision confidence values

#### Web
- Runs the same person checks as mobile via MediaPipe Tasks Vision in the page (`web/photo_prescreen.js`: BlazeFace short-range FaceDetector for face count/confidence/size + PoseLandmarker-lite for body presence, same CDN/wasm pinned as `verification_capture.html`). The Dart bridge (`lib/services/photo_prescreen_web.dart`) passes image bytes as base64 and maps the result into the native-shaped `FaceAnalysis`/`BodyAnalysis`, so `PrescreenConfig.primaryPhoto`/`secondaryPhoto` rules apply identically.
- First-ever prescreen may still be downloading models: the Dart call is bounded at 25s and degrades to Gemini on timeout/unavailability (the JS layer keeps loading in the background, so the next photo is fast). The script also prewarms on page load. A `supported:false` JS result likewise defers to Gemini instead of falsely rejecting.

#### Desktop
- No local ML; person-related checks are skipped and validation falls through to Gemini. There is no user-visible "unsupported platform" error.

### 3. Configuration Profiles

**Primary Photo Config (`PrescreenConfig.primaryPhoto`)** - stricter:
- Minimum resolution: 400x400, minimum file size 20KB
- Face-only selfie with exactly one face: face-count > 1 → `multipleFaces`; 0 faces with a body → `bodyShotNotAllowed`; 0 faces with no body → `noFaceDetected`. A detected body never lets a faceless shot pass as primary (beach-photo fix).
- Face must be sufficiently large and confident (`faceTooSmall` / `faceNotVisible` otherwise)
- Higher blur/brightness thresholds
- When no local ML result exists (detector unavailable/failed), person checks are skipped without crashing and Gemini remains the final validator.

**Secondary Photo Config (`PrescreenConfig.secondaryPhoto`)** - lenient:
- Minimum resolution: 200x200
- Accepts one person or a group, faces and/or bodies, close-up or distant,
  provided at least one detected face is fully in-frame or one full body is
  in-frame. A partial head/body fragment does not satisfy the local check.
- It does not apply face count, subject-size, blur, or brightness restrictions.
  Gemini is the final authority for context and unsafe/inauthentic content.

Both profiles apply file size, resolution, and aspect-ratio checks. Blur,
brightness, and strict face-quality thresholds apply only to primary photos.

### 4. UI Layer (`photo_editor_widget.dart`)

- `PhotoEditor.pickAndEdit` / `PhotoEditor.editWithPrescreen` implement the editor → prescreen → failure-dialog loop
- `showPrescreenFailureDialog` renders the visual failure dialog with the photo preview and localized message
- The profile wizard additionally maintains a session map of photo hashes (`_sessionPhotoHashByPath`) to block re-adding the same photo twice; entries are released when a photo is removed or replaced
- Both the add-photo and edit-photo paths run the prescreen

### 5. Guidance

The profile wizard's photo step shows a visual rules card (icon + text items, mirroring the verification screen's instruction style) covering: first photo = clear solo face photo, no group shots, well-lit/sharp, real photos only (no screenshots/memes/watermarks). Translation keys: `photoRulesTitle`, `photoRulePrimaryFace`, `photoRuleOnlyYou`, `photoRuleClearPhoto`, `photoRuleRealPerson`.

Primary selfies use live-gated capture (`openPrimarySelfieCapture` in `lib/services/primary_selfie_capture.dart`), which runs the shared MediaPipe capture page in `FACE_ONLY` mode: the face oval turns green only while a single clear face is inside it (`setRoiState`), the checklist tracks face visibility, and the photo auto-captures once the face criteria hold steady. Gesture ROI/hand/gesture checks are hidden and neutralized in this mode; the gesture verification flow is unchanged (all branches guarded by `isFaceOnlyMode`). Keys: `primarySelfieCaptureInstruction`, `primarySelfieCaptureDescription`, `primarySelfieCaptureLoading`.

## Error Messages / Translations

Failure reasons map to `photoError*` translation keys (see `supabase/migrations/20260916120000_add_photo_prescreen_translations.sql`, en/es/he). English fallbacks for all keys are built into `locale_provider.dart` (`_defaultTranslations`), so missing DB rows never surface raw keys.

Note: some rules only Gemini can check (screenshots, memes, prominent text/watermarks, explicit content). A photo that passes the prescreen can still be rejected by Gemini with its own translated reason message.

## Expected Performance

- **File validation + format check**: < 1ms (header bytes only, no decode)
- **Hash + quality analysis**: 100-300ms (background isolate)
- **ML detection**: 200-500ms (mobile only)
- **Total prescreen time**: < 1 second on mobile devices, off the UI thread

## Rollback Strategy

If prescreening causes issues, you can:
1. Call `PhotoEditor.pickAndEdit` without `ref` (legacy behaviour: editor only, no prescreen)
2. Adjust thresholds in `PrescreenConfig`
3. Revert the wizard call sites to the plain `PhotoEditor.editBytes` path

## Monitoring (planned)

- **Prescreen pass rate** vs **Gemini rejection rate** after prescreening
- **Average prescreen time** per platform
- Log `photo_prescreen_failed` events with reason + platform + isPrimary (not yet wired)
