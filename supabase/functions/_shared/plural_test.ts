// supabase/functions/_shared/plural_test.ts
//
// The notifications the server sends carry a count, so the noun form has to
// follow the CLDR rules of the member's language. These tests pin the rules
// for the three shipped languages.
import { normalizePluralLocale, pluralCategory, pluralKeyFor } from './plural.ts';

Deno.test('English uses the singular only for exactly one', () => {
  if (pluralCategory('en', 1) !== 'one') throw new Error('1 must be singular');
  for (const count of [0, 2, 3, 10, 21, 100]) {
    if (pluralCategory('en', count) !== 'other') {
      throw new Error(`${count} must be plural in English`);
    }
  }
});

Deno.test('Spanish uses the singular only for exactly one', () => {
  if (pluralCategory('es', 1) !== 'one') throw new Error('1 must be singular');
  for (const count of [0, 2, 3, 10, 21]) {
    if (pluralCategory('es', count) !== 'other') {
      throw new Error(`${count} must be plural in Spanish`);
    }
  }
});

Deno.test('Hebrew has a dual for exactly two', () => {
  if (pluralCategory('he', 1) !== 'one') throw new Error('1 must be singular');
  if (pluralCategory('he', 2) !== 'two') throw new Error('2 must be the dual');
  for (const count of [0, 3, 10, 21, 100]) {
    if (pluralCategory('he', count) !== 'other') {
      throw new Error(`${count} must be plural in Hebrew`);
    }
  }
});

Deno.test('the legacy Hebrew code and a region suffix resolve to Hebrew', () => {
  if (normalizePluralLocale('iw') !== 'he') throw new Error('iw must be Hebrew');
  if (normalizePluralLocale('he-IL') !== 'he') throw new Error('he-IL must be Hebrew');
  if (normalizePluralLocale('fr') !== 'en') throw new Error('unknown must fall back to en');
});

Deno.test('the key carries the category suffix', () => {
  if (pluralKeyFor('en', 'matchExpiryTitle', 1) !== 'matchExpiryTitle_one') {
    throw new Error('the singular key is wrong');
  }
  if (pluralKeyFor('he', 'matchExpiryTitle', 2) !== 'matchExpiryTitle_two') {
    throw new Error('the dual key is wrong');
  }
  if (pluralKeyFor('en', 'matchExpiryTitle', 5) !== 'matchExpiryTitle') {
    throw new Error('the plural key is the base key');
  }
});
