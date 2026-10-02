import { translationMarkerMatches } from './index.ts';

Deno.test('translationMarkerMatches treats never-edited rows as current', () => {
  if (!translationMarkerMatches(null, null)) throw new Error('null/null should match');
  if (!translationMarkerMatches(undefined, undefined)) throw new Error('undefined/undefined should match');
  if (!translationMarkerMatches(null, undefined)) throw new Error('null/undefined should match');
  // Empty strings normalize to null on both sides, i.e. null/null.
  if (!translationMarkerMatches('', '')) throw new Error('empty/empty should match like null/null');
});

Deno.test('translationMarkerMatches detects edits (backlog + new)', () => {
  // Pre-migration backlog: translation stored with no marker, row edited.
  if (translationMarkerMatches(null, '2026-09-27T18:12:09.196523+00:00')) {
    throw new Error('null marker with edited_at should mismatch');
  }
  // Marker stamped at translation time, row edited afterwards.
  if (translationMarkerMatches('2026-09-27T17:51:03.094124+00:00', '2026-09-27T18:12:09.196523+00:00')) {
    throw new Error('different instants should mismatch');
  }
});

Deno.test('translationMarkerMatches accepts equal instants despite formatting', () => {
  if (!translationMarkerMatches('2026-09-27T18:12:09.196523+00:00', '2026-09-27T18:12:09.196523+00:00')) {
    throw new Error('identical strings should match');
  }
  // Same instant, different representations.
  if (!translationMarkerMatches('2026-09-27T18:12:09.196523+00:00', '2026-09-27T18:12:09.196523Z')) {
    throw new Error('same instant in different formats should match');
  }
});

Deno.test('translationMarkerMatches fails safe on garbage', () => {
  if (translationMarkerMatches('not-a-date', '2026-09-27T18:12:09.196523+00:00')) {
    throw new Error('unparseable marker should mismatch (fail safe toward retranslation)');
  }
  if (translationMarkerMatches('2026-09-27T18:12:09.196523+00:00', 'also-not-a-date')) {
    throw new Error('unparseable edited_at should mismatch (fail safe toward retranslation)');
  }
});
