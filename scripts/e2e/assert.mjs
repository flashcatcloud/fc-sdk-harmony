#!/usr/bin/env node
/**
 * E2E assertions over the mock-intake capture file.
 * Usage: node assert.mjs <phase: events|crash> <captureFile>
 *
 * events: verifies the production data-quality symptoms are gone —
 *   view events with session + anonymous id, action delivered, no
 *   "[object Object]" / "Error name:" / sourcemap-banner error titles, and
 *   the BusinessError-shaped rejection unwrapped to "message (code N)".
 * crash: verifies the crash error was delivered on relaunch, flagged
 *   is_crash, and attributed to a session that ALSO has view documents
 *   (the original-session attribution the console queries depend on).
 */
import fs from 'node:fs';

const phase = process.argv[2];
const captureFile = process.argv[3] ?? '/tmp/flashcat-e2e-capture.ndjson';

const lines = fs.existsSync(captureFile)
  ? fs.readFileSync(captureFile, 'utf8').split('\n').filter((l) => l.length > 0)
  : [];
const events = [];
for (const line of lines) {
  try { events.push(JSON.parse(line)); } catch (_e) { /* skip torn */ }
}

const failures = [];
function check(name, ok, detail) {
  if (ok) console.log(`  PASS ${name}`);
  else { failures.push(name); console.error(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`); }
}
const byType = (t) => events.filter((e) => e.type === t);

console.log(`${events.length} events captured (${byType('view').length} view, ` +
  `${byType('error').length} error, ${byType('action').length} action)`);

if (phase === 'events') {
  const views = byType('view');
  check('view events delivered', views.length >= 1);
  check('view has session.id', views.every((v) => v.session && v.session.id && v.session.id.length > 0));
  check('usr.anonymous_id present', views.every((v) => v.usr && typeof v.usr.anonymous_id === 'string' && v.usr.anonymous_id.length > 0));
  check('action delivered', byType('action').some((a) => a.action && a.action.target && a.action.target.name === 'e2e-tap'));

  const errors = byType('error');
  check('errors delivered', errors.length >= 2);
  const titles = errors.map((e) => (e.error && e.error.message) || '');
  check('no [object Object] titles', titles.every((t) => !t.includes('[object')), JSON.stringify(titles));
  check('no raw "Error name:" titles', titles.every((t) => !t.startsWith('Error name:')), JSON.stringify(titles));
  check('no sourcemap-banner titles', titles.every((t) => !t.startsWith('Cannot get SourceMap info')), JSON.stringify(titles));
  check('BusinessError rejection unwrapped', titles.some((t) => t.includes('e2e biz error (code 1234567)')), JSON.stringify(titles));
  check('every error has error.id', errors.every((e) => e.error && typeof e.error.id === 'string' && e.error.id.length > 0));
} else if (phase === 'crash') {
  const crashErrors = byType('error').filter((e) => e.error && e.error.is_crash === true);
  check('crash error delivered after relaunch', crashErrors.length >= 1);
  const marker = crashErrors.filter((e) => (e.error.message || '').includes('E2E crash marker'));
  check('crash carries the thrown message', marker.length >= 1,
    JSON.stringify(crashErrors.map((e) => e.error.message)));
  const viewSessionIds = new Set(byType('view').map((v) => v.session && v.session.id).filter(Boolean));
  check('crash session exists in session list (has view docs)',
    marker.every((e) => e.session && viewSessionIds.has(e.session.id)),
    `crash sessions: ${JSON.stringify(marker.map((e) => e.session && e.session.id))}`);
  const crashCounted = byType('view').some((v) => v.view && v.view.crash && v.view.crash.count >= 1);
  check('crash counted in a view document (crash-free rate)', crashCounted);
} else if (phase === 'crash-only') {
  // trackErrors=false: the auto-captured rejection must NOT appear; the crash must.
  const errors = byType('error');
  const suppressed = errors.filter((e) => (e.error && e.error.message || '').includes('suppressed rejection'));
  check('auto-captured rejection suppressed', suppressed.length === 0,
    JSON.stringify(errors.map((e) => e.error && e.error.message)));
  const crash = errors.filter((e) => e.error && e.error.is_crash === true
    && (e.error.message || '').includes('E2E crash-only marker'));
  check('crash still delivered with trackErrors=false', crash.length >= 1,
    JSON.stringify(errors.map((e) => e.error && e.error.message)));
  const viewSessionIds = new Set(byType('view').map((v) => v.session && v.session.id).filter(Boolean));
  check('crash session has view docs', crash.every((e) => e.session && viewSessionIds.has(e.session.id)));
  const crashCounted = byType('view').some((v) => v.view && v.view.crash && v.view.crash.count >= 1);
  check('crash counted in a view document', crashCounted);
} else {
  console.error(`unknown phase: ${phase}`);
  process.exit(2);
}

if (failures.length > 0) {
  console.error(`\n${failures.length} assertion(s) failed`);
  process.exit(1);
}
console.log('\nALL E2E ASSERTIONS PASSED');
