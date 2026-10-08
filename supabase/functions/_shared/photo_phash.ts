// Perceptual (dHash) image hashing for photo-dedup dedupe across re-encodes.
//
// The exact-byte SHA-256 dedupe misses the trivially common case of the same
// photo re-uploaded after a re-encode, recompression or screenshot. The dHash
// below downscales to 9x8 and compares horizontally adjacent luminance,
// producing a 64-char bit string; a Hamming distance of <= 8 between two such
// strings is a near-certain same-photo match. Returned as a bit STRING (not an
// integer) so storage and comparison are platform-independent.

import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";
import { applyOrientation, parseJpegOrientation } from "./photo_sanitize.ts";

const HASH_WIDTH = 9;
const HASH_HEIGHT = 8;

export const PHASH_DISTANCE_THRESHOLD = 8;

function luminance(px: Uint8ClampedArray): number {
  // ImageScript getRGBAAt returns [r, g, b, a].
  return 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2];
}

/**
 * Computes the 64-bit dHash bit string of an encoded image, EXIF-orientation
 * aware. Returns null when the image cannot be decoded.
 */
export async function perceptualHash(bytes: Uint8Array): Promise<string | null> {
  try {
    const img = await Image.decode(bytes);
    const oriented = applyOrientation(img, parseJpegOrientation(bytes));
    const small = oriented.resize(HASH_WIDTH, HASH_HEIGHT);
    const bits: string[] = [];
    // ImageScript pixel accessors are 1-based.
    for (let y = 1; y <= HASH_HEIGHT; y++) {
      for (let x = 1; x <= HASH_WIDTH - 1; x++) {
        const left = luminance(small.getRGBAAt(x, y));
        const right = luminance(small.getRGBAAt(x + 1, y));
        bits.push(left > right ? "1" : "0");
      }
    }
    return bits.join("");
  } catch (_) {
    return null;
  }
}

export function hammingDistance(a: string, b: string): number {
  if (!a || !b || a.length !== b.length) return 64;
  let distance = 0;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) distance++;
  }
  return distance;
}

/** True when `candidate` is a near-duplicate of any stored hash. */
export function matchesStoredHash(
  candidate: string | null,
  stored: string[],
): boolean {
  if (!candidate) return false;
  return stored.some(
    (hash) => hammingDistance(candidate, hash) <= PHASH_DISTANCE_THRESHOLD,
  );
}
