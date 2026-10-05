import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseDashboardUrl } from './dashboard-url.ts';

for (const [name, configured, expected] of [
  ['unset', undefined, null],
  ['empty', '', null],
  ['whitespace', '  ', null],
  [
    'HTTPS dashboard with query and fragment',
    'https://dashboard.example.com/sandbox?team=example#details',
    'https://dashboard.example.com/sandbox?team=example#details',
  ],
  [
    'surrounding whitespace',
    '  https://dashboard.example.com/sandbox  ',
    'https://dashboard.example.com/sandbox',
  ],
  ['malformed URL', 'not a URL', null],
  ['relative URL', '/dashboard', null],
  ['plaintext HTTP', 'http://dashboard.example.com/sandbox', null],
  ['script URL', 'javascript:alert(1)', null],
  ['username', 'https://user@dashboard.example.com/sandbox', null],
  ['password', 'https://:secret@dashboard.example.com/sandbox', null],
  ['username and password', 'https://user:secret@dashboard.example.com/sandbox', null],
  ['encoded credentials', 'https://%75ser:%73ecret@dashboard.example.com/sandbox', null],
]) {
  test(`dashboard URL: ${name}`, () => {
    const actual = parseDashboardUrl(configured);

    assert.equal(actual, expected);
  });
}
