// One-off consistency check: SQL migration vs Dart translation fallbacks.
// Run: node scripts/check_onboarding_translations.js  (safe to delete after)
const fs = require('fs');

const dart = fs.readFileSync('lib/providers/locale_provider.dart', 'utf8');
const dartMap = {};
const re = /'(onboarding[A-Za-z0-9]*|demo[A-Za-z0-9]*|settingsAppTour[A-Za-z]*)':\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")/g;
let m;
while ((m = re.exec(dart)) !== null) {
  const raw = m[2] !== undefined ? m[2] : m[3];
  dartMap[m[1]] = raw.replace(/\\'/g, "'").replace(/\\"/g, '"');
}

const sql = [];
for (const f of fs.readdirSync('supabase/migrations')) {
  if (!/onboarding/i.test(f)) continue;
  sql.push({ name: f, text: fs.readFileSync('supabase/migrations/' + f, 'utf8') });
}
sql.sort((a, b) => (a.name < b.name ? -1 : 1));

const sqlMap = { en: {}, es: {}, he: {} };
const re2 = /\('(\w{2})',\s*'(onboarding[^']*|demo[^']*|settingsAppTour[^']*)',\s*'((?:[^']|'')*)'\)/g;
// DELETE FROM ... WHERE key IN ('a', 'b') — removes those keys, mirroring the
// cleanup migration; later migrations (and later inserts within a file) win.
const reDelete = /\bkey\s+IN\s*\(([^)]*)\)/g;
function deleteKeys(match) {
  const quoted = /'([^']*)'/g;
  let k;
  while ((k = quoted.exec(match[1])) !== null) {
    for (const locale of ['en', 'es', 'he']) delete sqlMap[locale][k[1]];
  }
}
for (const f of sql) {
  let d;
  while ((d = reDelete.exec(f.text)) !== null) deleteKeys(d);
  let m;
  while ((m = re2.exec(f.text)) !== null) {
    // Later migrations win, mirroring ON CONFLICT DO UPDATE.
    sqlMap[m[1]][m[2]] = m[3].replace(/''/g, "'");
  }
}

const dartKeys = Object.keys(dartMap);
const problems = [];
for (const locale of ['en', 'es', 'he']) {
  for (const k of dartKeys) {
    if (!(k in sqlMap[locale])) problems.push('missing in SQL ' + locale + ': ' + k);
    else if (locale === 'en' && sqlMap[locale][k] !== dartMap[k]) {
      problems.push('en value mismatch: ' + k + '\n  dart: ' + JSON.stringify(dartMap[k]) + '\n  sql:  ' + JSON.stringify(sqlMap[locale][k]));
    }
  }
  for (const k of Object.keys(sqlMap[locale])) if (!(k in dartMap)) problems.push('extra in SQL ' + locale + ': ' + k);
}
console.log('dart keys:', dartKeys.length);
console.log('sql en/es/he:', Object.keys(sqlMap.en).length, Object.keys(sqlMap.es).length, Object.keys(sqlMap.he).length);
console.log(problems.length ? problems.join('\n') : 'ALL CHECKS PASSED');
