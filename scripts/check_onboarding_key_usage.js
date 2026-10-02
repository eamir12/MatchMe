// One-off sweep: every translation key referenced by the onboarding tour
// must exist in the built-in English fallbacks. Run:
//   node scripts/check_onboarding_key_usage.js
const fs = require('fs');

const files = [
  'lib/screens/onboarding/onboarding_scenes.dart',
  'lib/screens/onboarding/onboarding_intro_screen.dart',
];
const used = new Set();
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  for (const m of src.matchAll(/(?:data\.text\(|getString\(\s*)'([A-Za-z][A-Za-z0-9]*)'/g)) used.add(m[1]);
}
const content = fs.readFileSync('lib/screens/onboarding/onboarding_content.dart', 'utf8');
for (const m of content.matchAll(/bodyKey: '([A-Za-z0-9]+)'/g)) used.add(m[1]);
for (const m of content.matchAll(/titleKey: '([A-Za-z0-9]+)'/g)) used.add(m[1]);

const dart = fs.readFileSync('lib/providers/locale_provider.dart', 'utf8');
const missing = [...used].filter((k) => !dart.includes("'" + k + "'"));
console.log('keys used by tour:', used.size);
console.log(missing.length ? 'MISSING from fallbacks:\n' + missing.join('\n') : 'all present in fallbacks');
