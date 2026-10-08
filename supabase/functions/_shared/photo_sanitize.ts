// Server-side sanitize crop for validate-primary-photo.
//
// When Gemini returns SANITIZE (face good, text/cards present), the server
// performs the crop itself — neck-up headshot framing (face + 20% margin),
// trimmed to exclude text regions where geometry allows, mosaic-pixelating
// any text that cannot be excluded — verifies the result geometrically, and
// approves it WITHOUT a second AI call. Script-agnostic: Gemini reads any
// language, so Hebrew/Arabic/Cyrillic cards are handled exactly like Latin
// ones. Returns not-ok on any failure, in which case the caller falls back to
// the legacy client-side sanitize + revalidation flow.
//
// Image processing uses ImageScript (pure WASM) — works in the Supabase edge
// runtime. Note: the WASM codecs are fetched from deno.land at module load.

import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

export interface SanitizeBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

export type SanitizeResult =
  | { ok: true; bytes: Uint8Array }
  | { ok: false; reason: string };

const JPEG_QUALITY = 88;

// --- EXIF orientation -------------------------------------------------------

// Parses the EXIF orientation (tag 0x0112) from JPEG metadata; 1 when absent
// or unreadable. Gemini's bounding boxes refer to the stored pixel data, so
// the crop below must operate on the same orientation the client's
// bakeOrientation-based flow used for display.
export function parseJpegOrientation(bytes: Uint8Array): number {
  try {
    if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return 1;
    let offset = 2;
    while (offset + 4 < bytes.length) {
      if (bytes[offset] !== 0xff) {
        offset++;
        continue;
      }
      const marker = bytes[offset + 1];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        offset += 2;
        continue;
      }
      const len = ((bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
      if (marker === 0xe1 && len > 8) {
        // APP1 — check for "Exif\0\0" header.
        const header = bytes.slice(offset + 4, offset + 10);
        const ascii = Array.from(header, (b) => String.fromCharCode(b)).join("");
        if (ascii !== "Exif\0\0") {
          offset += 2 + len;
          continue;
        }
        const tiff = offset + 10;
        const little = bytes[tiff] === 0x49 && bytes[tiff + 1] === 0x49;
        const readU16 = (p: number) =>
          little ? (bytes[p] | (bytes[p + 1] << 8)) : ((bytes[p] << 8) | bytes[p + 1]);
        const readU32 = (p: number) =>
          little
            ? ((bytes[p] | (bytes[p + 1] << 8) | (bytes[p + 2] << 16) | (bytes[p + 3] << 24)) >>> 0)
            : (((bytes[p] << 24) | (bytes[p + 1] << 16) | (bytes[p + 2] << 8) | bytes[p + 3]) >>> 0);
        const ifdOffset = readU32(tiff + 4);
        const ifd = tiff + ifdOffset;
        const entryCount = readU16(ifd);
        for (let i = 0; i < entryCount; i++) {
          const entry = ifd + 2 + i * 12;
          const tag = readU16(entry);
          if (tag === 0x0112) {
            const orientation = readU16(entry + 8);
            if (orientation >= 1 && orientation <= 8) return orientation;
            return 1;
          }
        }
        return 1;
      }
      if (len < 2) return 1;
      offset += 2 + len;
    }
    return 1;
  } catch (_) {
    return 1;
  }
}

function applyOrientation(img: Image, orientation: number): Image {
  // ImageScript rotate(θ) is counter-clockwise (verified); flip takes
  // "horizontal" / "vertical". rotate() returns Image | Frame in the typings —
  // the result is always an Image for 90/180/270, hence the casts.
  let out = img;
  switch (orientation) {
    case 2:
      out = out.flip("horizontal");
      break;
    case 3:
      out = out.rotate(180) as Image;
      break;
    case 4:
      out = out.flip("vertical");
      break;
    case 5:
      out = out.rotate(270).flip("horizontal") as Image;
      break;
    case 6:
      out = out.rotate(270) as Image;
      break;
    case 7:
      out = out.rotate(270).flip("vertical") as Image;
      break;
    case 8:
      out = out.rotate(90) as Image;
      break;
    default:
      break;
  }
  return out;
}
export { applyOrientation };

// --- Crop geometry (port of the client's neck-up algorithm) -----------------

interface PixelRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

function computeSanitizeCrop(
  wPx: number,
  hPx: number,
  face: SanitizeBox,
  textBoxes: SanitizeBox[],
): PixelRect {
  const faceW = face.w * wPx;
  const faceH = face.h * hPx;
  const facePadX = faceW * 0.2;
  const facePadY = faceH * 0.2;
  const minCropSide = Math.min(wPx, hPx) * 0.35;

  let left = Math.max(0, (face.x - facePadX) * wPx);
  let top = Math.max(0, (face.y - facePadY) * hPx);
  let right = Math.min(wPx, (face.x + face.w + facePadX) * wPx);
  let bottom = Math.min(hPx, (face.y + face.h + facePadY) * hPx);

  if (right - left < minCropSide) {
    const c = (face.x + face.w / 2) * wPx;
    left = Math.max(0, c - minCropSide / 2);
    right = Math.min(wPx, c + minCropSide / 2);
  }
  if (bottom - top < minCropSide) {
    const c = (face.y + face.h / 2) * hPx;
    top = Math.max(0, c - minCropSide / 2);
    bottom = Math.min(hPx, c + minCropSide / 2);
  }

  // Trim to exclude text boxes, keeping the face fully inside with a small
  // buffer; untrimmable overlaps are pixelated by the caller instead.
  const xGap = 0.01 * wPx;
  const yGap = 0.01 * hPx;
  const faceMinPadY = faceH * 0.05;
  const faceTopPx = face.y * hPx;
  const faceBottomPx = (face.y + face.h) * hPx;
  const faceLeftPx = face.x * wPx;
  const faceRightPx = (face.x + face.w) * wPx;
  const faceCenterX = (face.x + face.w / 2) * wPx;
  const faceCenterY = (face.y + face.h / 2) * hPx;

  for (const tb of textBoxes) {
    if (tb.w <= 0 || tb.h <= 0) continue;
    const tLeft = tb.x * wPx;
    const tTop = tb.y * hPx;
    const tRight = tLeft + tb.w * wPx;
    const tBottom = tTop + tb.h * hPx;
    if (tRight <= left || tLeft >= right || tBottom <= top || tTop >= bottom) {
      continue;
    }

    if (tTop >= faceCenterY) {
      const candidate = Math.min(bottom, tTop - yGap);
      if (candidate >= faceBottomPx + faceMinPadY && candidate > top) {
        bottom = candidate;
      }
    } else if (tBottom <= faceCenterY) {
      const candidate = Math.max(top, tBottom + yGap);
      if (candidate <= faceTopPx + 1 && candidate < bottom) {
        top = candidate;
      }
    } else if (tLeft >= faceCenterX) {
      const candidate = Math.max(left, tRight + xGap);
      if (candidate <= faceLeftPx + 1 && candidate < right) {
        right = candidate;
      }
    } else if (tRight <= faceCenterX) {
      const candidate = Math.min(right, tLeft - xGap);
      if (candidate >= faceRightPx - 1 && candidate > left) {
        right = candidate;
      }
    }
  }

  const width = Math.min(Math.round(right - left), wPx);
  const height = Math.min(Math.round(bottom - top), hPx);
  return {
    left: Math.max(0, Math.min(Math.round(left), wPx - 1)),
    top: Math.max(0, Math.min(Math.round(top), hPx - 1)),
    width: Math.max(1, width),
    height: Math.max(1, height),
  };
}

function normalizeBox(value: unknown): SanitizeBox | null {
  if (!value || typeof value !== "object") return null;
  const obj = value as Record<string, unknown>;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const x = num(obj.x);
  const y = num(obj.y);
  const w = num(obj.w);
  const h = num(obj.h);
  if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) return null;
  return { x, y, w, h };
}

// --- Main entry -------------------------------------------------------------

/**
 * Crops and sanitizes a photo using Gemini-provided face/text boxes.
 * Returns not-ok when processing fails or the geometry is unsafe; callers
 * then fall back to the legacy client-side sanitize flow.
 */
export async function sanitizeProfilePhoto(
  jpegBytes: Uint8Array,
  faceBoxRaw: unknown,
  textBoxesRaw: unknown,
): Promise<SanitizeResult> {
  try {
    const face = normalizeBox(faceBoxRaw);
    if (!face) return { ok: false, reason: "missing_or_invalid_face_box" };

    const textBoxes: SanitizeBox[] = Array.isArray(textBoxesRaw)
      ? (textBoxesRaw
          .map((t) => normalizeBox(t))
          .filter((t): t is SanitizeBox => t !== null))
      : [];

    const img = await Image.decode(jpegBytes);
    const oriented = applyOrientation(img, parseJpegOrientation(jpegBytes));
    const wPx = oriented.width;
    const hPx = oriented.height;

    const crop = computeSanitizeCrop(wPx, hPx, face, textBoxes);

    // Geometric verification: the face must sit fully inside the final crop
    // with a 1px tolerance. computeSanitizeCrop's trims enforce this, but the
    // assertion guards against future algorithm changes.
    const faceLeft = face.x * wPx;
    const faceTop = face.y * hPx;
    const faceRight = (face.x + face.w) * wPx;
    const faceBottom = (face.y + face.h) * hPx;
    const faceInside =
      faceLeft >= crop.left - 1 &&
      faceTop >= crop.top - 1 &&
      faceRight <= crop.left + crop.width + 1 &&
      faceBottom <= crop.top + crop.height + 1;
    if (!faceInside) {
      return { ok: false, reason: "face_not_fully_inside_crop" };
    }

    let out = oriented.clone().crop(crop.left, crop.top, crop.width, crop.height);

    // Pixelate any text region still intersecting the crop (mosaic: shrink
    // with nearest-neighbor, then blow back up).
    for (const tb of textBoxes) {
      const tLeft = Math.max(0, Math.round(tb.x * wPx) - crop.left);
      const tTop = Math.max(0, Math.round(tb.y * hPx) - crop.top);
      const tRight = Math.min(crop.width, Math.round((tb.x + tb.w) * wPx) - crop.left);
      const tBottom = Math.min(crop.height, Math.round((tb.y + tb.h) * hPx) - crop.top);
      const rw = tRight - tLeft;
      const rh = tBottom - tTop;
      if (rw < 4 || rh < 4) continue;
      const region = out.clone().crop(tLeft, tTop, rw, rh);
      const mosaic = region
        .resize(Math.max(1, Math.round(rw / 10)), Math.max(1, Math.round(rh / 10)), Image.RESIZE_NEAREST_NEIGHBOR)
        .resize(rw, rh, Image.RESIZE_NEAREST_NEIGHBOR);
      out = out.composite(mosaic, tLeft, tTop);
    }

    // Guard against absurd outputs: a valid headshot crop keeps the face as a
    // substantial part of the image.
    const outFaceArea = (face.w * wPx / crop.width) * (face.h * hPx / crop.height);
    if (!Number.isFinite(outFaceArea) || outFaceArea < 0.08) {
      return { ok: false, reason: "face_too_small_in_crop" };
    }

    const encoded = await out.encodeJPEG(JPEG_QUALITY);
    return { ok: true, bytes: new Uint8Array(encoded) };
  } catch (e) {
    return {
      ok: false,
      reason: `sanitize_failed: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
}
