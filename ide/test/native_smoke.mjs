import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';
const require = createRequire('/workspace/references/vscode/package.json');
const { _electron } = require('playwright');
const root = await mkdtemp(join(tmpdir(), 'shenscope-native-'));
const checkout = '/workspace/references/vscode';
const project = resolve(new URL('../../', import.meta.url).pathname);
const xvfb = spawn('/workspace/toolchains/xvfb/usr/bin/Xvfb', [':101', '-screen', '0', '1280x900x24', '-nolisten', 'tcp'], { stdio: 'ignore' });
const requests = [];
const fixture = createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) { chunks.push(chunk); }
    const body = JSON.parse(Buffer.concat(chunks).toString()); requests.push(body);
    const hasTool = body.messages.some(message => message.role === 'tool');
    const delta = hasTool ? { content: 'Native sidebar complete' } : { tool_calls: [{ index: 0, id: 'native-write', type: 'function',
        function: { name: 'write', arguments: JSON.stringify({ path: 'native.txt', content: 'native Core verified' }) } }] };
    const frame = { choices: [{ index: 0, delta, finish_reason: hasTool ? 'stop' : 'tool_calls' }] };
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    response.end(`data: ${JSON.stringify(frame)}\n\ndata: [DONE]\n\n`);
});
await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
const port = fixture.address().port;
const config = join(root, 'config.toml');
await writeFile(config, `[provider]\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\nretries = 0\n[permissions]\nnetwork = 'allow'\nedit = 'ask'\n`);
await writeFile(join(root, 'README.md'), 'Native sidebar test workspace\n');
let application;
try {
    await new Promise(resolve => setTimeout(resolve, 500));
    application = await _electron.launch({ executablePath: join(checkout, '.build/electron/electron'), cwd: checkout,
        args: [checkout, root, '--disable-extensions', '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes',
            '--user-data-dir', join(root, 'user-data'), '--extensions-dir', join(root, 'extensions')],
        env: { ...process.env, DISPLAY: ':101', VSCODE_DEV: '1', SHENSCOPE_CORE_DIR: project,
            SHENSCOPE_JULIA: '/workspace/toolchains/julia-1.11.7/bin/julia', JULIA_DEPOT_PATH: '/workspace/julia-depot', SHENSCOPE_CONFIG: config }, timeout: 120_000 });
    const page = await application.firstWindow();
    page.on('pageerror', error => console.error('Workbench error:', error.message));
    await page.locator('.monaco-workbench').waitFor({ timeout: 120_000 });
    const icon = page.getByRole('tab', { name: 'ShenScope', exact: true });
    await icon.click({ timeout: 60_000 });
    const panel = page.locator('.shenscope-panel');
    await panel.getByText('Ready · native-fixture', { exact: true }).waitFor({ timeout: 120_000 });
    await panel.locator('textarea').fill('Write a file from the native sidebar');
    await panel.getByRole('button', { name: 'Send / steer', exact: true }).click();
    await panel.getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 120_000 });
    await panel.getByText('Native sidebar complete', { exact: true }).waitFor({ timeout: 120_000 });
    assert.equal(await readFile(join(root, 'native.txt'), 'utf8'), 'native Core verified');
    assert.equal(requests.length, 2);
    assert.ok(requests[1].messages.some(message => message.role === 'tool'));
    await page.screenshot({ path: join(project, '.local/native-sidebar.png') });
    console.log('PASS: native Workbench, extensions disabled, real Julia HTTP/tool/approval/session flow');
} finally {
    await application?.close(); xvfb.kill(); fixture.close(); await rm(root, { recursive: true, force: true });
}
