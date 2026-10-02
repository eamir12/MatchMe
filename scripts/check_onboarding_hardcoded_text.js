// One-off sweep: find Text widgets given a plain string literal (potential
// un-localized copy) in the onboarding tour. Run:
//   node scripts/check_onboarding_hardcoded_text.js
const fs = require('fs');
const files = [
  'lib/screens/onboarding/onboarding_scenes.dart',
  'lib/screens/onboarding/onboarding_intro_screen.dart',
];
let found = 0;
for (const f of files) {
  const lines = fs.readFileSync(f, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Text( followed by a string literal opening (same line or next line)
    const m = line.match(/\bText\(\s*$/) || line.match(/\bText\(\s*'((?:[^'\\]|\\.)*)'/);
    if (!m) continue;
    if (line.includes("Text(") && /Text\(\s*'/.test(line)) {
      const lit = line.match(/Text\(\s*'((?:[^'\\]|\\.)*)'/)[1];
      console.log(`${f}:${i + 1}: Text('${lit}')`);
      found++;
      continue;
    }
    // multi-line: Text( at end, literal on following line
    const next = (lines[i + 1] || '').trim();
    const n = next.match(/^'((?:[^'\\]|\\.)*)',?\s*$/);
    if (n) {
      console.log(`${f}:${i + 1}: Text(\n  '${n[1]}')`);
      found++;
    }
  }
}
console.log(found === 0 ? 'no hardcoded Text literals found' : found + ' candidate(s)');
