import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '../api/node_modules/playwright/index.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const output = resolve(root, 'target/docs/site');
const screenshots = resolve(root, 'target/docs/site-checks');
mkdirSync(screenshots, { recursive: true });
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const read = path => readFileSync(resolve(output, path), 'utf8');
const metadata = JSON.parse(read('build.json'));
assert.equal(metadata.commit, commit);
assert.equal(metadata.dirty, false);
const hash = data => createHash('sha256').update(data).digest('hex');
const api = JSON.parse(read('api/build.json'));
const guide = JSON.parse(read('guide/build.json'));
for (const [section, bundle] of [['api', api], ['guide', guide]]) {
  assert.equal(bundle.commit, commit);
  assert.equal(bundle.dirty, false);
  for (const [name, checksum] of Object.entries(bundle.files)) {
    assert.equal(hash(readFileSync(resolve(output, section, name))), checksum, name);
  }
  const actual = readdirSync(resolve(output, section), { recursive: true })
    .filter(name => statSync(resolve(output, section, name)).isFile());
  assert.deepEqual(actual.sort(), [...Object.keys(bundle.files), 'build.json'].sort());
  assert.ok(!actual.some(name => /(?:endpoint|overview|schema)-check\.png$/.test(name)));
}
const raw = read('api/openapi.json');
assert.equal(hash(raw), api.openapiSha256);
assert.equal(api.openapiSha256, metadata.openapiSha256);
assert.equal(raw, readFileSync(resolve(root, 'target/docs/api/openapi.json'), 'utf8'));
const csp = html => html.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)[1];
assert.equal(csp(read('api/index.html')), csp(readFileSync(resolve(root, 'target/docs/api/index.html'), 'utf8')));
const spec = JSON.parse(raw);
const operationIds = Object.values(spec.paths).flatMap(path => Object.values(path).map(op => op.operationId).filter(Boolean));
assert.equal(Object.values(spec.paths).flatMap(Object.values).find(op => op.operationId === 'createCommand').summary, 'Create command');

const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' };
const server = createServer((req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (path.startsWith('/space/')) path = path.slice('/space'.length);
  if (path.endsWith('/')) path += 'index.html';
  const file = resolve(output, '.' + path);
  if (!file.startsWith(output + '/') || req.method !== 'GET') return res.writeHead(403).end();
  try { res.setHeader('Content-Type', mime[extname(file)] || 'application/octet-stream'); res.end(readFileSync(file)); }
  catch { res.writeHead(404).end(); }
});
await new Promise(done => server.listen(0, '127.0.0.1', done));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch();
async function checkPrefix(prefix) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [], external = [], failures = [];
  page.on('pageerror', error => errors.push(String(error)));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('response', response => { if (response.status() >= 400) failures.push(response.url()); });
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin !== origin || route.request().method() !== 'GET') {
      external.push(route.request().url()); return route.abort();
    }
    return route.continue();
  });
  const sidebar = () => page.getByRole('navigation', { name: 'Table of contents', exact: true });
  async function openSidebar() {
    if (await page.locator('#sidebar-toggle').getAttribute('aria-expanded') !== 'true') {
      await page.locator('#sidebar-toggle').click();
    }
    await sidebar().getByRole('link', { name: 'Introduction', exact: true }).waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#sidebar').getBoundingClientRect().left >= -0.5);
  }
  async function checkPage(prefix) {
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, page.url());
    const source = await page.locator('footer a').first().getAttribute('href');
    assert.ok(source.startsWith(`https://github.com/perplexityai/SPACE/tree/${commit}`)
      || source.startsWith(`https://github.com/perplexityai/SPACE/blob/${commit}/`), source);
    assert.equal(await page.locator('.docs-nav').count(), 0);
    if (new URL(page.url()).pathname.endsWith('/api/index.html')) {
      assert.equal(await page.locator('input, [data-role="search:results"]').count(), 0);
    }
    assert.equal(await page.locator('input[type="password"], textarea').count(), 0);
    assert.equal(await page.getByRole('button', { name: /^(try it.*|send request|execute|authorize|run)$/i }).count(), 0);
    for (const link of await page.locator('a[href], link[href], script[src], img[src], iframe[src]').evaluateAll(
      elements => elements.map(element => element.getAttribute('href') || element.getAttribute('src')))) {
      const url = new URL(link, page.url());
      if (url.origin !== origin) continue;
      assert.ok(url.pathname.startsWith(prefix), link);
      let local = decodeURIComponent(url.pathname.slice(prefix.length));
      if (local.endsWith('/') || !local) local += 'index.html';
      assert.ok(existsSync(resolve(output, local)), `${page.url()}: ${link}`);
      if (url.hash && local.endsWith('.html')) {
        const fragment = decodeURIComponent(url.hash.slice(1));
        if (local === 'api/index.html' && fragment.startsWith('operation/')) {
          assert.ok(operationIds.includes(fragment.slice(10)), fragment);
        } else if (local === 'api/index.html' && fragment.startsWith('schema/')) {
          assert.ok(spec.components.schemas[fragment.slice(7)], fragment);
        } else if (local === 'api/index.html' && url.pathname === new URL(page.url()).pathname) {
          assert.ok(await page.locator('[id], [data-section-id]').evaluateAll(
            (elements, id) => elements.some(el => el.id === id || el.dataset.sectionId === id), fragment), fragment);
        } else {
          assert.ok(read(local).includes(`id="${fragment}"`), `${link}: fragment`);
        }
      }
    }
  }
  try {
    let phaseStarted = performance.now();
    const finishPhase = name => {
      console.log(`Site ${prefix} ${name}: ${Math.round(performance.now() - phaseStarted)} ms`);
      phaseStarted = performance.now();
    };
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto(origin + prefix + '?from=docs#use-the-api');
    await page.waitForURL(origin + prefix + 'guide/index.html?from=docs#use-the-api');
    await page.goto(origin + prefix);
    await page.waitForURL(origin + prefix + 'guide/index.html');
    assert.equal(await page.locator('main h1').textContent(), 'Introduction');
    await openSidebar();
    assert.equal(await sidebar().locator('.part-title').count(), 0);
    assert.deepEqual(await sidebar().locator('.chapter > .chapter-item > a').allTextContents(), [
      'Introduction', 'Using the API', 'Running SPACE', 'Development',
    ]);
    assert.deepEqual(await sidebar().locator('.chapter-item > a').allTextContents(), [
      'Introduction', 'Using the API', 'Your first sandbox', 'Running SPACE', 'Install and configure locally',
      'Observability', 'Troubleshooting', 'Development', 'Architecture', 'Versioning and compatibility',
      'Development workflow', 'Contributing',
    ]);
    assert.deepEqual(await sidebar().locator('.chapter > li > ol.section').evaluateAll(
      groups => groups.map(group => [...group.querySelectorAll('.chapter-item > a')].map(link => link.textContent))), [
      ['Your first sandbox'],
      ['Install and configure locally', 'Observability', 'Troubleshooting'],
      ['Architecture', 'Versioning and compatibility', 'Development workflow', 'Contributing'],
    ]);
    for (const [title, chapter] of [
      ['Using the API', 'using-api'], ['Running SPACE', 'running-space'], ['Development', 'development-overview'],
    ]) {
      await sidebar().getByRole('link', { name: title, exact: true }).click();
      await page.waitForURL(origin + prefix + `guide/${chapter}.html`);
      assert.equal(await page.locator('main h1').textContent(), title);
      assert.equal(await sidebar().locator('.chapter-item > a.active').textContent(), title);
      await page.locator('#search-toggle').click();
      await page.locator('#searchbar').pressSequentially(title);
      const result = page.locator(`#searchresults a[href*="${chapter}.html"]`).first();
      await result.waitFor({ state: 'visible' });
      await result.click();
      await page.waitForURL(url => url.pathname === prefix + `guide/${chapter}.html`);
      await page.goto(origin + prefix + 'guide/index.html');
      await openSidebar();
    }
    for (const [chapter, aliases] of [
      ['first-sandbox', { 'before-you-start': 'prepare-your-environment', 'command-output': 'read-command-output',
        'if-a-step-fails': 'troubleshoot-failures' }],
      ['installation', { 'before-you-begin': 'prepare-your-environment', configuration: 'configure-your-environment',
        'shim-telemetry-selectors': 'select-shim-telemetry', 'if-setup-fails': 'troubleshoot-setup' }],
    ]) {
      for (const [old, current] of Object.entries(aliases)) {
        await page.goto(origin + prefix + `guide/${chapter}.html#${old}`);
        assert.equal(await page.evaluate(({ old, current }) => {
          const alias = document.getElementById(old);
          const heading = alias.parentElement.nextElementSibling;
          const top = heading.getBoundingClientRect().top;
          return heading.id === current && top >= 0 && top < innerHeight;
        }, { old, current }), true, `${chapter}#${old}`);
      }
    }
    await page.goto(origin + prefix + 'guide/index.html');
    await openSidebar();
    await sidebar().getByRole('link', { name: 'Your first sandbox', exact: true }).focus();
    assert.notEqual(await page.locator(':focus').evaluate(el => getComputedStyle(el).outlineStyle), 'none');
    await page.keyboard.press('Enter');
    await page.waitForURL(origin + prefix + 'guide/first-sandbox.html');
    for (const [index, chapter] of guide.chapters.entries()) {
      await page.goto(origin + prefix + 'guide/' + chapter.replace('.md', '.html'));
      await openSidebar();
      await checkPage(prefix);
      assert.deepEqual(await sidebar().locator('.section-nav a').allTextContents(), ['SPACE Guide', 'API Reference']);
      assert.equal(await sidebar().locator('.section-nav [aria-current="true"]').textContent(), 'SPACE Guide');
      assert.equal(await sidebar().locator('.chapter .section-nav').count(), 0);
      assert.equal(await page.getByRole('link', { name: 'Documentation', exact: true }).count(), 0);
      assert.equal(await sidebar().locator('.page-toc').count(), await page.locator('main h2[id]').count() ? 1 : 0);
      assert.deepEqual(await sidebar().locator('.page-toc a').allTextContents(), await page.locator('main h2[id]').allTextContents());
      assert.equal(await sidebar().getByRole('link', { name: 'API Reference', exact: true }).getAttribute('href'), '../api/index.html');
      // Exercise native buttons AND arrow keys, including both end boundaries.
      const current = origin + prefix + 'guide/' + chapter.replace('.md', '.html');
      for (const [offset, direction, key] of [[-1, 'previous', 'ArrowLeft'], [1, 'next', 'ArrowRight']]) {
        const adjacent = guide.chapters[index + offset];
        const button = page.locator(`.nav-chapters.${direction}`).first();
        assert.equal(await button.count(), adjacent ? 1 : 0);
        if (adjacent) {
          const expected = origin + prefix + 'guide/' + adjacent.replace('.md', '.html');
          await button.click();
          await page.waitForURL(expected);
          await page.goto(current);
          await page.keyboard.press(key);
          await page.waitForURL(expected);
          await page.goto(current);
        } else {
          await page.keyboard.press(key);
          assert.equal(page.url(), current);
        }
      }
    }
    await sidebar().getByRole('link', { name: 'Development workflow', exact: true }).click();
    await page.waitForURL(origin + prefix + 'guide/development.html');
    assert.match(await page.locator('main').innerText(), /tilt up/);
    await sidebar().getByRole('link', { name: 'Contributing', exact: true }).click();
    await page.waitForURL(origin + prefix + 'guide/contributing.html');
    assert.equal(await sidebar().locator('a.active').textContent(), 'Contributing');
    await sidebar().getByRole('link', { name: 'Propose a change', exact: true }).click();
    await page.waitForURL(url => url.hash === '#propose-a-change');
    await page.locator('#search-toggle').click();
    await page.locator('#searchbar').pressSequentially('maintainer');
    await page.locator('#searchresults a[href*="contributing.html"]').first().waitFor({ state: 'visible' });
    await page.locator('#search-toggle').click();
    await page.locator('#search-toggle').click();
    await page.locator('#searchbar').fill('');
    await page.locator('#searchbar').pressSequentially('authenticate');
    const result = page.locator('#searchresults a').filter({ hasText: /Authenticate/ }).first();
    await result.waitFor({ state: 'visible' });
    await result.click();
    await page.waitForURL(url => url.pathname === prefix + 'guide/installation.html' && url.hash === '#authenticate');
    await page.waitForFunction(() => {
      const top = document.querySelector('#authenticate').getBoundingClientRect().top;
      return top >= document.querySelector('#menu-bar').getBoundingClientRect().bottom && top < 220;
    });
    await sidebar().getByRole('link', { name: 'API Reference', exact: true }).click();
    await page.waitForSelector('body[data-render-ready="true"]');
    await checkPage(prefix);
    assert.equal(await page.locator('[data-section-id^="operation/"]').count(), operationIds.length);
    assert.deepEqual(await page.locator('.section-nav a').allTextContents(), ['SPACE Guide', 'API Reference']);
    assert.equal(await page.locator('.section-nav [aria-current="true"]').textContent(), 'API Reference');
    assert.equal(await page.locator('[data-section-id="operation/createCommand"] h2').innerText(), 'Create command');
    if (prefix === '/') {
      await page.locator('.menu-content [data-item-id="tag/Operation-polling"]').click();
      await page.locator('.menu-content [data-item-id$="/operation/getOperation"]').first().click();
      const operation = page.locator('[data-section-id="operation/getOperation"]');
      for (const [status, code] of [['400', 'invalid_request'], ['401', 'unauthorized'], ['500', 'internal']]) {
        await operation.getByRole('tab', { name: status, exact: true }).click();
        const sample = JSON.parse(await operation.locator('[role="tabpanel"]:visible .redoc-json').innerText());
        assert.equal(sample.code, code);
        assert.equal(sample.retryable, status === '500');
        await page.screenshot({ path: resolve(screenshots, `api-error-${status}.png`) });
      }
    }
    const createMenuItem = page.locator('.menu-content [data-item-id$="/operation/createSandbox"]').first();
    if (!await createMenuItem.isVisible()) {
      await page.locator('.menu-content [data-item-id="tag/Sandboxes"]').click();
    }
    await createMenuItem.click();
    await page.waitForURL(url => decodeURIComponent(url.hash).endsWith('/operation/createSandbox'));
    await page.waitForFunction(() => {
      const heading = document.querySelector('[data-section-id="operation/createSandbox"] h2');
      const top = heading.getBoundingClientRect().top;
      return top >= 0 && top < 200;
    });
    const download = await context.request.get(origin + prefix + 'api/openapi.json');
    assert.equal(await download.text(), raw);
    await page.locator('[data-section-id="section/Overview"] a[href="../guide/installation.html#authenticate"]').click();
    await page.waitForURL(url => url.pathname === prefix + 'guide/installation.html' && url.hash === '#authenticate');
    await openSidebar();
    await sidebar().getByRole('link', { name: 'API Reference', exact: true }).click();
    await page.locator('.section-nav').getByRole('link', { name: 'SPACE Guide', exact: true }).click();
    await page.waitForURL(origin + prefix + 'guide/index.html');
    const noJS = await browser.newContext({ javaScriptEnabled: false });
    const fallback = await noJS.newPage();
    await fallback.goto(origin + prefix);
    assert.equal(await fallback.getByRole('link', { name: 'Open the SPACE Guide' }).getAttribute('href'), 'guide/index.html');
    await noJS.close();
    finishPhase('navigation');
    for (const width of [390, 768, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      for (const [section, path] of [['introduction', 'guide/index.html'], ['guide', 'guide/first-sandbox.html'], ['contributing', 'guide/contributing.html'], ['api', 'api/index.html']]) {
        await page.goto(origin + prefix + path);
        if (section === 'api') {
          await page.waitForSelector('body[data-render-ready="true"]');
          await page.locator('.section-nav').getByRole('link', { name: 'SPACE Guide', exact: true }).focus();
          assert.notEqual(await page.locator(':focus').evaluate(el => getComputedStyle(el).outlineStyle), 'none');
          await page.goto(origin + prefix + 'api/index.html#operation/streamSessionEvents');
          const events = page.locator('[data-section-id="operation/streamSessionEvents"]');
          await events.getByRole('tab', { name: '200', exact: true }).click();
          const sample = events.locator('[role="tabpanel"]:visible');
          assert.match(await sample.innerText(), /text\/event-stream[\s\S]*stdout[\s\S]*process_exited/);
          const panels = await events.evaluate(el => [...el.children].map(child => {
            const box = child.getBoundingClientRect();
            return { left: box.left, width: box.width, top: box.top, bottom: box.bottom };
          }));
          assert.equal(panels.length, 2);
          assert.ok(Math.abs(panels[0].left - panels[1].left) < 1, 'Samples use native inline layout');
          assert.ok(panels[1].top >= panels[0].bottom - 1, 'Samples appear below the operation');
          assert.equal(await sample.evaluate(el => getComputedStyle(el).color), 'rgb(255, 255, 255)');
          for (const label of [
            events.getByRole('tab', { name: '200', exact: true }),
            sample.getByText('Content type', { exact: true }),
          ]) {
            const contrast = await label.evaluate(el => {
              const rgba = value => {
                const numbers = value.match(/[\d.]+/g).map(Number);
                return [...numbers.slice(0, 3), numbers[3] ?? 1];
              };
              const over = (front, back) => front.slice(0, 3).map((c, i) => c * front[3] + back[i] * (1 - front[3]));
              const ancestors = [];
              for (let node = el; node; node = node.parentElement) ancestors.unshift(node);
              let background = [255, 255, 255];
              for (const node of ancestors) background = over(rgba(getComputedStyle(node).backgroundColor), background);
              const foreground = over(rgba(getComputedStyle(el).color), background);
              const luminance = rgb => rgb.map(c => c / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4)
                .reduce((sum, c, i) => sum + c * [.2126, .7152, .0722][i], 0);
              const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
              return (values[0] + .05) / (values[1] + .05);
            });
            assert.ok(contrast >= 4.5, `Sample label contrast ${contrast}`);
          }
          await sample.scrollIntoViewIfNeeded();
          if (prefix === '/') await page.screenshot({ path: resolve(screenshots, `api-sse-200-${width}.png`) });
          await page.goto(origin + prefix + path);
          await page.waitForSelector('body[data-render-ready="true"]');
        } else {
          await openSidebar();
          const headings = sidebar().locator('.page-toc a');
          assert.ok(await headings.count() > 0);
          await headings.first().focus();
          assert.notEqual(await page.locator(':focus').evaluate(el => getComputedStyle(el).outlineStyle), 'none');
          if (width <= 1080) {
            if (prefix === '/') await page.screenshot({ path: resolve(screenshots, `${section}-sidebar-${width}.png`) });
          }
          await page.keyboard.press('Enter');
          await page.waitForFunction(() => {
            const heading = document.getElementById(decodeURIComponent(location.hash.slice(1)));
            if (!heading) return false;
            const bounds = heading.getBoundingClientRect();
            return bounds.top >= Math.max(0, document.querySelector('#menu-bar').getBoundingClientRect().bottom)
              && bounds.bottom <= innerHeight;
          });
          if (width <= 1080) {
            assert.equal(await page.locator('#sidebar-toggle').getAttribute('aria-expanded'), 'false');
            // Native mobile search remains available after closing the sidebar.
            await page.locator('#search-toggle').click();
            await page.locator('#searchbar').fill('');
            await page.locator('#searchbar').pressSequentially('authenticate');
            await page.locator('#searchresults a').filter({ hasText: /Authenticate/ }).first().waitFor({ state: 'visible' });
            await page.locator('#search-toggle').click();
          }
          await page.goto(origin + prefix + path);
        }
        await checkPage(prefix);
        if (section !== 'api') {
          assert.ok(await page.evaluate(() => document.querySelector('main h1').getBoundingClientRect().top
            >= document.querySelector('#menu-bar').getBoundingClientRect().bottom), 'Guide title is not covered by its toolbar');
        }
        if (prefix === '/') await page.screenshot({ path: resolve(screenshots, `${section}-${width}.png`) });
      }
    }
    finishPhase('responsive pages');
    for (const width of [390, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      for (const name of ['CreateCommandRequest', 'ConditionStatus', 'TerminalSize']) {
        await page.goto(origin + prefix + `api/index.html?model=${name}#schema/${name}`);
        await page.waitForSelector('body[data-render-ready="true"]');
        await page.waitForFunction(name => {
          const top = document.querySelector(`[data-section-id="schema/${name}"] h2`).getBoundingClientRect().top;
          return top >= 0 && top < 150;
        }, name);
        await checkPage(prefix);
        if (prefix === '/') await page.screenshot({ path: resolve(screenshots, `schema-${name}-${width}.png`) });
        const section = page.locator(`[data-section-id="schema/${name}"]`);
        if (name === 'ConditionStatus') {
          const details = section.locator('.schema-example');
          await details.locator('summary').focus();
          await page.keyboard.press('Enter');
          assert.equal(await details.locator('.redoc-json').isVisible(), true);
          const text = await details.locator('.redoc-json').innerText();
          await page.setViewportSize({ width: width === 390 ? 1440 : 390, height: 900 });
          assert.equal(await details.locator('.redoc-json').innerText(), text);
          await page.setViewportSize({ width, height: 900 });
          await details.locator('summary').focus();
          await page.keyboard.press('Enter');
          assert.equal(await details.getAttribute('open'), null);
          await section.locator('.schema-context a').first().click();
          await page.waitForURL(url => url.hash === '#schema/SandboxCondition');
          assert.equal(await page.locator('[data-section-id="schema/ConditionStatus"] .schema-example').count(), 1);
        }
      }
      if (width === 390) await page.locator('.menu-content + div').click();
      assert.equal(await page.locator('input, [data-role="search:results"]').count(), 0);
      const commandMenuItem = page.locator('.menu-content [data-item-id="schema/CreateCommandRequest"]');
      if (!await commandMenuItem.isVisible()) {
        await page.locator('.menu-content [data-item-id="tag/Command-and-process-models"]').click();
      }
      await commandMenuItem.click();
      await page.waitForURL(url => url.hash === '#schema/CreateCommandRequest');
      await page.waitForFunction(() => {
        const top = document.querySelector('[data-section-id="schema/CreateCommandRequest"] h2').getBoundingClientRect().top;
        return top >= 0 && top < 150;
      });
      assert.equal(await page.locator('[data-section-id="schema/CreateCommandRequest"] .schema-context code').innerText(), 'CreateCommandRequest');
    }
    finishPhase('schemas');
    for (const width of [390, 768, 1440]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.goto(origin + prefix + 'guide/architecture.html#local-kind-topology');
      const diagram = page.locator('.mermaid-diagram');
      await diagram.locator('svg').waitFor();
      assert.equal(await diagram.locator('.node').count(), 11);
      assert.equal(await diagram.locator('.flowchart-link').count(), 11);
      assert.equal(await diagram.locator('.flowchart-link[marker-start][marker-end]').count(), 2);
      const compact = labels => labels.map(text => text.replace(/\s/g, ''));
      assert.deepEqual(compact(await diagram.locator('.node .label').allTextContents()), compact([
        'Application', 'API', 'PostgreSQL', 'Cluster controller', 'Kubernetes sandbox pod',
        'SPACE runtime shim', 'Worker services', 'Object storagetemplates/snapshots',
        'Firecracker microVM', 'Data plane', 'Guest process',
      ]));
      assert.deepEqual(compact(await diagram.locator('.edgeLabel .label').allTextContents()),
        compact(['Management', 'desired state', 'Command stream']));
      // Check connections, not just counts: IDs encode authored endpoints.
      const edges = await diagram.locator('.flowchart-link').evaluateAll(nodes =>
        nodes.map(node => node.id.replace(/^space-diagram-\d+-\d+-L_/, '').replace(/_\d+$/, '')).sort());
      assert.deepEqual(edges, [
        'application_api', 'api_postgres', 'postgres_controller', 'controller_pod',
        'pod_shim', 'shim_workers', 'workers_storage', 'workers_vm', 'vm_guest',
        'application_data', 'data_guest',
      ].sort());
      assert.equal(await page.locator('pre:has(code.language-mermaid)').isVisible(), false);
      assert.ok(await diagram.locator('svg').getAttribute('aria-labelledby'));
      assert.ok(await diagram.locator('svg').getAttribute('aria-describedby'));
      await page.keyboard.press('Tab');
      await diagram.focus();
      assert.notEqual(await diagram.evaluate(el => getComputedStyle(el).outlineStyle), 'none');
      for (const theme of ['light', 'navy']) {
        const previous = await diagram.locator('svg').getAttribute('id');
        const currentTheme = await page.locator('html').getAttribute('class');
        if (!currentTheme.split(' ').includes(theme)) {
          await page.evaluate(() => scrollTo(0, 0));
          await page.waitForFunction(() => scrollY === 0);
          await page.locator('#theme-toggle').click();
          await page.locator(`#theme-list #${theme}`).click();
          await page.keyboard.press('Escape');
          await page.waitForFunction(id => document.querySelector('.mermaid-diagram svg')?.id !== id, previous);
        }
        const colors = await diagram.evaluate(el => ({
          text: getComputedStyle(el.querySelector('.node text')).fill,
          foreground: getComputedStyle(document.body).color,
          background: getComputedStyle(el.querySelector('.node rect')).fill,
          page: getComputedStyle(document.documentElement).backgroundColor,
        }));
        assert.equal(colors.text, colors.foreground);
        assert.equal(colors.background, colors.page);
        assert.notEqual(colors.text, colors.background);
        await checkPage(prefix);
        await diagram.scrollIntoViewIfNeeded();
        if (width === 390) await page.locator('.diagram-scroll-hint').scrollIntoViewIfNeeded();
        if (prefix === '/') await page.screenshot({ path: resolve(screenshots, `architecture-${theme}-${width}.png`) });
      }
      if (width === 390) {
        assert.equal(await page.locator('.diagram-scroll-hint').isVisible(), true);
        await diagram.focus();
        await page.keyboard.press('ArrowRight');
        await page.waitForFunction(() => document.querySelector('.mermaid-diagram').scrollLeft > 0);
        assert.equal(new URL(page.url()).pathname, prefix + 'guide/architecture.html');
        // Keep pressing the native pan key until the right-hand path is visible.
        for (let step = 0; step < 8; step++) await page.keyboard.press('ArrowRight');
        await page.waitForFunction(() => {
          const diagram = document.querySelector('.mermaid-diagram');
          const right = diagram.getBoundingClientRect().right;
          return ['data', 'guest'].every(id =>
            diagram.querySelector(`[id*="-flowchart-${id}-"]`).getBoundingClientRect().right <= right);
        });
        await page.locator('.diagram-scroll-hint').scrollIntoViewIfNeeded();
        if (prefix === '/') await page.screenshot({ path: resolve(screenshots, 'architecture-mobile-panned.png') });
      } else {
        assert.equal(await page.locator('.diagram-scroll-hint').isVisible(), false);
        if (prefix === '/' && width === 1440) {
          await diagram.screenshot({ path: resolve(screenshots, 'architecture-complete.png') });
        }
      }
    }
    // Spy on the actual mdBook load->print path. A dark stored preference must
    // still print a completed, black-on-white SVG, not an unfinished fence.
    const printPage = await context.newPage();
    await printPage.addInitScript(() => {
      window.print = () => {
        const diagram = document.querySelector('.mermaid-diagram');
        window.printProof = {
          nodes: diagram?.querySelectorAll('.node').length,
          hidden: diagram?.hidden,
          sourceHidden: document.querySelector('pre:has(code.language-mermaid)')?.hidden,
          text: diagram?.querySelector('.node text') && getComputedStyle(diagram.querySelector('.node text')).fill,
        };
      };
    });
    await printPage.goto(origin + prefix + 'guide/print.html');
    await printPage.waitForFunction(() => window.printProof);
    assert.deepEqual(await printPage.evaluate(() => window.printProof),
      { nodes: 11, hidden: false, sourceHidden: true, text: 'rgb(0, 0, 0)' });
    await printPage.emulateMedia({ media: 'print' });
    assert.equal(await printPage.locator('.mermaid-diagram .node rect').first().evaluate(el => getComputedStyle(el).fill), 'rgb(255, 255, 255)');
    if (prefix === '/') await printPage.screenshot({ path: resolve(screenshots, 'architecture-print.png'), fullPage: true });
    await printPage.close();
    finishPhase('diagrams and print');
    assert.deepEqual(errors, []);
    assert.deepEqual(external, []);
    assert.deepEqual(failures, []);
  } finally {
    await context.close();
  }
}
try {
  const checks = await Promise.allSettled(['/', '/space/'].map(checkPrefix));
  for (const check of checks) if (check.status === 'rejected') throw check.reason;
  // An unavailable renderer must leave readable source + equivalent prose and
  // must not strand print or the native chapter navigation.
  const unavailable = await browser.newContext();
  await unavailable.route('**/mermaid.min.js', route => route.abort());
  const fallbackDiagram = await unavailable.newPage();
  await fallbackDiagram.addInitScript(() => { window.print = () => { window.didPrint = true; }; });
  await fallbackDiagram.goto(origin + '/guide/print.html');
  await fallbackDiagram.waitForFunction(() => window.didPrint);
  assert.equal(await fallbackDiagram.locator('pre:has(code.language-mermaid)').isVisible(), true);
  await fallbackDiagram.locator('.diagram-description summary').click();
  assert.ok((await fallbackDiagram.locator('.diagram-description').innerText()).includes('templates/snapshots'));
  await fallbackDiagram.goto(origin + '/guide/architecture.html');
  await fallbackDiagram.getByRole('link', { name: 'Next chapter', exact: true }).click();
  await fallbackDiagram.waitForURL(origin + '/guide/versioning.html');
  await unavailable.close();
  console.log(`Site checks passed at / and /space/: ${guide.chapters.length} chapters, sibling sections, all native Next/Previous/arrow paths, guide search, 11-node/11-edge offline Mermaid (light/dark/mobile/actual print readiness/failure fallback), API menus with no search, ${operationIds.length} operations, matching revision/hash, keyboard/focus, 390/768/1440px, no overflow, credentials, execution controls, external requests, or browser errors.`);
} finally {
  await browser.close();
  await new Promise(done => server.close(done));
}
