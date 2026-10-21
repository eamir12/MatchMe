// supabase/functions/_shared/plural.ts
//
// The CLDR cardinal plural categories for the notifications the server
// sends, so a count of one reads as a singular ("1 minute left", not
// "1 minutes left") in the member's own language.
//
// The categories follow the Unicode CLDR cardinal rules (CLDR 43+):
//
//   en / es: singular for exactly 1, plural otherwise.
//   he:      singular for 1, dual for 2 ("שתי דקות"), plural otherwise.
//
// Keep in sync with lib/utils/plural_rules.dart in the MatchMe app and
// matchme_admin/lib/utils/plural_rules.dart in the admin dashboard.

export type PluralCategory = 'one' | 'two' | 'other';

/**
 * The language the plural rules are applied for.
 *
 * MatchMe ships exactly three languages: en, es, he. Anything else resolves
 * to English rather than silently rendering an untranslated string.
 */
export function normalizePluralLocale(raw: unknown): string {
  const s = String(raw ?? '').trim().toLowerCase();
  if (s.startsWith('he') || s.startsWith('iw')) return 'he';
  if (s.startsWith('es')) return 'es';
  return 'en';
}

/** The plural category of [count] in [locale]. */
export function pluralCategory(locale: string, count: number): PluralCategory {
  const normalized = normalizePluralLocale(locale);
  if (normalized === 'he' && count === 2) return 'two';
  if (count === 1) return 'one';
  return 'other';
}

/**
 * The translation key that carries the plural form of [key] for [count].
 *
 * The base key holds the plural ("other") form, `<key>_one` the singular
 * and `<key>_two` the Hebrew dual.
 */
export function pluralKeyFor(locale: string, key: string, count: number): string {
  const category = pluralCategory(locale, count);
  return category === 'other' ? key : `${key}_${category}`;
}
