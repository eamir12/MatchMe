# Photo Prescreen Translation Keys

All prescreen translations live in `supabase/migrations/20260916120000_add_photo_prescreen_translations.sql` and support the app's three currently supported languages: **English, Hebrew, and Spanish**.

## Key Groups

### Prescreen failure messages (`photoError*`)
Shown in the visual failure dialog when the local prescreen rejects a photo:
- `photoErrorInvalidFormat` - "Invalid image format. Please use JPEG, PNG, or WEBP."
- `photoErrorFileTooLarge` - "File is too large. Maximum size is 10MB."
- `photoErrorFileTooSmall` - "File is too small. Minimum size is 10KB."
- `photoErrorResolutionTooLow` - "Image resolution too low. Minimum resolution is 200x200 for secondary photos and 400x400 for primary photos."
- `photoErrorAspectRatioInvalid` - "Image aspect ratio not supported. Aspect ratio must be between 0.33 and 3.0."
- `photoErrorImageCorrupted` - "Image file is corrupted or invalid."
- `photoErrorDuplicatePhoto` - "This photo has already been added to your profile."
- `photoErrorNoFaceOrBody` - "Photo must show at least your face or body clearly."
- `photoErrorMultipleFaces` - "Primary photo must show only you (no group photos)."
- `photoErrorFaceTooSmall` - "Face is too small in the photo. Please use a photo where your face is clearly visible."
- `photoErrorFaceNotVisible` - "Face is not clearly visible. Please use a clearer photo."
- `photoErrorImageTooBlurry` - "Image is too blurry. Please use a sharper photo."
- `photoErrorImageTooDark` - "Image is too dark. Please use a brighter photo."
- `photoErrorImageTooBright` - "Image is too bright. Please use a photo with better lighting."
- `photoErrorGeneral` - "Photo validation failed. Please try a different photo."

### Failure dialog actions
- `photoPrescreenFailedTitle` - "Photo needs a small fix"
- `photoPrescreenAdjustPhoto` - "Adjust photo" (re-opens the crop editor)
- `photoPrescreenChooseAnother` - "Choose another photo" (aborts the flow)

### Visual photo-rules card (profile wizard photo step)
- `photoRulesTitle` - "Photo rules"
- `photoRulePrimaryFace` - "Your first photo must be a clear solo photo of your face."
- `photoRuleOnlyYou` - "Only you in the first photo — no group shots."
- `photoRuleClearPhoto` - "Well-lit, sharp, and not heavily edited."
- `photoRuleRealPerson` - "Real photos of you — no screenshots, memes, or watermarks."

## Fallbacks

English values for every key above are also built into the app (`_defaultTranslations` in `lib/providers/locale_provider.dart`), so a missing DB row never shows a raw key. DB values take precedence.
