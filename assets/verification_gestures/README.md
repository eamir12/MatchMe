Fluent Emoji gesture assets (curated subset)

These 3D PNG images are a small curated subset of Microsoft's Fluent Emoji
project, included to give the photo-verification gesture instructions one
frozen, modern-looking artwork set on every platform (Web, iOS, Android,
Windows). The same six images are also inlined as base64 PNG data URIs in
assets/verification_capture/index.html and web/verification_capture.html so
the capture view never depends on the platform's emoji fonts.

Source: https://github.com/microsoft/fluentui-emoji

License: MIT, Copyright (c) Microsoft Corporation.

Gesture code mapping (each file stems from the Fluent "Default/3D" variant):
  CLOSED_FIST   -> closed_fist.png  (Raised fist)
  OPEN_PALM     -> open_palm.png    (Raised hand)
  PEACE_SIGN    -> peace_sign.png   (Victory hand)
  POINTING_UP   -> pointing_up.png  (Index pointing up)
  THUMBS_UP     -> thumbs_up.png    (Thumbs up)
  THUMBS_DOWN   -> thumbs_down.png  (Thumbs down)

Handedness note: five of the six Fluent drawings read as a LEFT hand. Fist,
palm, peace and pointing were validated per gesture against the real left
hand in the mirrored camera preview; thumbs-up was user-verified (its
mirrored copy matched the right hand next to the mirrored selfie photo).
THUMBS_DOWN is the exception: its silhouette merely resembles a 180-degree
rotation of the up art, but the actual Fluent drawing reads RIGHT-handed
when shown raw (user-reported on a THUMBS_DOWN_LEFT_HAND request), so it is
mirrored for LEFT-hand requests instead. Every render site therefore mirrors
the art when the request asks for the opposite hand of what the raw drawing
reads:
  - thumbs-down: mirror for LEFT-hand requests, raw for right-hand requests;
  - all other gestures: mirror for RIGHT-hand requests, raw for left-hand.
Note this differs from the earlier Twemoji-era table, where fist/palm read
left but peace/pointing/thumbs-up read right.

If you change or re-export an image here, update the base64 copies in both
capture HTML pages and keep the mirror rule in sync:
  lib/screens/profile/verification_screen.dart (_gestureGlyphNeedsMirror)
  assets/verification_capture/index.html        (gesture example mirroring)
  web/verification_capture.html                 (gesture example mirroring)
