// Build from the locked dependency tree, not the upstream prebuilt UMD (whose
// embedded dependencies would bypass our patched lodash-es override).
import assert from 'node:assert/strict';
import { build } from '../api/node_modules/esbuild/lib/main.js';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const output = resolve(here, '../../target/docs/diagram');
const result = await build({
  stdin: {
    contents: 'import mermaid from "mermaid"; window.mermaid = mermaid;',
    resolveDir: resolve(here, '../api'),
  },
  outfile: resolve(output, 'mermaid.min.js'),
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2022',
  minify: true,
  legalComments: 'inline',
  metafile: true,
});
const outputs = Object.values(result.metafile.outputs);
assert.equal(outputs.length, 1, 'The offline diagram must be a single JavaScript bundle');
assert.deepEqual(outputs[0].imports, [], 'The diagram must not load runtime chunks');
// Record actual bundled inputs and retain the licenses of every included npm
// package, not just Mermaid's own MIT notice.
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.includes('node_modules/')) continue;
  let directory = dirname(resolve(input));
  let info;
  while (directory !== dirname(directory)) {
    if (existsSync(resolve(directory, 'package.json'))) {
      info = JSON.parse(readFileSync(resolve(directory, 'package.json'), 'utf8'));
      if (info.name && info.version) break;
    }
    directory = dirname(directory);
  }
  assert.ok(info?.name && info?.version, `Missing package identity: ${input}`);
  packages.set(`${info.name}@${info.version}`, directory);
}
assert.ok(packages.has('lodash-es@4.18.1'), 'The emitted bundle must use patched lodash-es');
assert.equal([...packages.keys()].filter(name => name.startsWith('lodash-es@')).length, 1);
const notices = [...packages].sort().map(([name, directory]) => {
  const files = readdirSync(directory).filter(name => /^(licen[cs]e|copying|notice)([.-]|$)/i.test(name));
  assert.ok(files.length, `Missing bundled dependency license: ${name}`);
  return `${name}\n${files.map(file => readFileSync(resolve(directory, file), 'utf8')).join('\n')}`;
});
writeFileSync(resolve(output, 'MERMAID-LICENSES.txt'), notices.join('\n\n-----\n\n'));
writeFileSync(resolve(output, 'metafile.json'), JSON.stringify(result.metafile, null, 2) + '\n');
console.log(`Offline Mermaid: ${outputs[0].bytes} bytes, ${packages.size} licensed packages, no runtime imports`);
