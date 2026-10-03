import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';
const require = createRequire('/workspace/references/vscode/package.json');
const { _electron } = require('playwright');
const root = await mkdtemp(join(tmpdir(), 'shenscope-native-'));
const checkout = '/workspace/references/vscode';
const project = resolve(new URL('../../', import.meta.url).pathname);
const vsix = process.argv.includes('--vsix');
const mcpOnly = process.argv.includes('--mcp-only');
const display = vsix ? ':102' : ':101';
const xvfb = spawn('/workspace/toolchains/xvfb/usr/bin/Xvfb', [display, '-screen', '0', '1280x900x24', '-nolisten', 'tcp'], { stdio: 'ignore' });
const requests = [];
const fixture = createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) { chunks.push(chunk); }
    const body = JSON.parse(Buffer.concat(chunks).toString()); requests.push(body);
    const hasTool = body.messages.some(message => message.role === 'tool');
    const delta = hasTool ? { content: '**Native sidebar complete**\n\n```julia\nsum([1, 2, 3])\n```\n\n[Open file](native.txt:1)\n\n<script>window.compromised = true</script>' } : { tool_calls: [{ index: 0, id: 'native-write', type: 'function',
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
await writeFile(join(root, 'sample.go'), 'package fixture\nfunc Greet() int { return 1 }\nfunc TestGreet() int { return Greet() }\n');
await mkdir(join(root, 'user-data', 'User'), { recursive: true });
await writeFile(join(root, 'user-data', 'User', 'settings.json'), JSON.stringify({
    'shenscope.juliaPath': '/workspace/toolchains/julia-1.11.7/bin/julia',
    'shenscope.corePath': project, 'shenscope.statePath': join(root, 'state'),
    'window.zoomLevel': 0, 'workbench.colorTheme': 'Default Dark Modern',
}));
let application;
let panel;
try {
    await new Promise(resolve => setTimeout(resolve, 500));
    application = await _electron.launch({ executablePath: join(checkout, '.build/electron/electron'), cwd: checkout,
        args: [checkout, root, ...(vsix ? ['--extensionDevelopmentPath', join(project, 'editors/vscode')] : ['--disable-extensions']), '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes',
            '--user-data-dir', join(root, 'user-data'), '--extensions-dir', join(root, 'extensions')],
        env: { ...process.env, DISPLAY: display, XDG_CACHE_HOME: join(root, 'cache'), VSCODE_DEV: '1', SHENSCOPE_CORE_DIR: project,
            SHENSCOPE_JULIA: '/workspace/toolchains/julia-1.11.7/bin/julia', JULIA_DEPOT_PATH: '/workspace/julia-depot', SHENSCOPE_CONFIG: config }, timeout: 120_000 });
    const page = await application.firstWindow();
    page.on('pageerror', error => console.error('Workbench error:', error.message));
    await page.locator('.monaco-workbench').waitFor({ timeout: 120_000 });
    const icons = page.getByRole('tab', { name: 'ShenScope', exact: true });
    const nativeGlyph = page.locator('.codicon-code');
    const icon = vsix ? icons.filter({ hasNot: nativeGlyph }) : icons.filter({ has: nativeGlyph });
    await icon.click({ timeout: 60_000 });
    panel = page.locator('.shenscope-panel');
    if (vsix) {
        const deadline = Date.now() + 120_000;
        let frame;
        while (!frame && Date.now() < deadline) {
            for (const candidate of page.frames()) {
                if (candidate === page.mainFrame()) { continue; }
                if (await candidate.locator('.shenscope-panel').count()) { frame = candidate; break; }
            }
            if (!frame) { await new Promise(resolve => setTimeout(resolve, 200)); }
        }
        assert.ok(frame, 'Extension webview must start independently of the native panel');
        assert.notEqual(frame, page.mainFrame()); panel = frame.locator('.shenscope-panel');
    }
    await panel.getByText('Ready · native-fixture', { exact: true }).waitFor({ timeout: 120_000 });
    await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-welcome.png`) });
    if (!mcpOnly) {
    await panel.locator('textarea').fill('Write a file from the native sidebar');
    await panel.getByRole('button', { name: 'Send message', exact: true }).click();
    await panel.getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 120_000 });
    await panel.getByText('Native sidebar complete', { exact: true }).waitFor({ timeout: 120_000 });
    await panel.locator('.status').filter({ hasText: 'Complete ·' }).waitFor();
    assert.equal(await readFile(join(root, 'native.txt'), 'utf8'), 'native Core verified');
    assert.equal(requests.length, 2);
    assert.ok(requests[1].messages.some(message => message.role === 'tool'));
    assert.equal(await panel.locator('.code-block code').textContent(), 'sum([1, 2, 3])');
    assert.equal(await panel.locator('.message-body script').count(), 0);
    await panel.getByRole('button', { name: 'Open file', exact: true }).click();
    await panel.getByRole('button', { name: 'History', exact: true }).click();
    await panel.getByRole('button', { name: 'Write a file from the native sidebar', exact: true }).waitFor();
    await panel.getByRole('button', { name: 'Chat', exact: true }).click();
    await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-conversation.png`) });
    await panel.getByRole('button', { name: 'Project', exact: true }).click();
    await panel.getByRole('combobox', { name: 'Project backend' }).selectOption('go_ast');
    await panel.getByRole('button', { name: 'Index project', exact: true }).click();
    for (let approval = 0; approval < 2; approval++) { await panel.getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 30_000 }); }
    await panel.getByRole('button', { name: 'Refresh index', exact: true }).waitFor({ timeout: 120_000 });
    await panel.getByRole('textbox', { name: 'Search project symbols' }).fill('Greet');
    await panel.getByRole('button', { name: 'Greet', exact: true }).waitFor();
    await panel.getByRole('textbox', { name: 'Files to analyze (comma separated)' }).fill('sample.go');
    await panel.getByRole('button', { name: 'Test candidates', exact: true }).click();
    await panel.locator('.analysis-title').filter({ hasText: 'test selection' }).waitFor({ timeout: 120_000 });
    await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-project.png`) });
    console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, Julia HTTP/tool/approval/history/Markdown/file flow`);
    }
    if (mcpOnly) {
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('MCP');
        await panel.getByText('Add connection', { exact: true }).click();
        await panel.getByRole('textbox', { name: 'Connection name', exact: true }).fill('fixture');
        await panel.getByRole('textbox', { name: 'Executable', exact: true }).fill('python3');
        await panel.getByRole('textbox', { name: 'Arguments · one per line', exact: true }).fill(join(project, 'test/fixtures/mcp_server.py'));
        await panel.getByRole('button', { name: 'Save connection', exact: true }).click();
        const server = panel.locator('.mcp-server').filter({ hasText: 'fixture' });
        await server.getByRole('button', { name: 'Connect', exact: true }).click();
        for (const action of ['mcp.connect', 'mcp.process']) {
            const card = panel.locator('.permission-card').filter({ hasText: `${action} ·` });
            await card.getByRole('button', { name: 'Allow session', exact: true }).click({ timeout: 60_000 });
            await card.waitFor({ state: 'detached' });
        }
        await server.getByRole('button', { name: 'Tools', exact: true }).click({ timeout: 60_000 });
        await server.getByText('echo/input', { exact: true }).click();
        await server.getByRole('textbox', { name: 'value', exact: true }).fill('"GUI 中文"');
        await server.getByRole('button', { name: 'Run tool', exact: true }).first().click();
        await panel.getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 30_000 });
        await server.locator('.mcp-result .tool-output').filter({ hasText: 'GUI 中文' }).waitFor({ timeout: 60_000 });
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-mcp.png`) });
        await server.getByRole('button', { name: 'Resources', exact: true }).click();
        await server.getByRole('button', { name: 'Read resource', exact: true }).click({ timeout: 30_000 });
        await server.locator('.tool-output').filter({ hasText: '资源内容' }).waitFor({ timeout: 30_000 });
        await server.getByRole('button', { name: 'Resources', exact: true }).click();
        await server.getByRole('button', { name: 'Subscribe', exact: true }).click({ timeout: 30_000 });
        await server.getByRole('button', { name: 'Unsubscribe', exact: true }).click({ timeout: 30_000 });
        await server.getByRole('button', { name: 'Unsubscribe', exact: true }).waitFor({ state: 'detached' });
        await server.getByRole('button', { name: 'Prompts', exact: true }).click();
        await server.getByText('review', { exact: true }).click();
        await server.getByRole('textbox', { name: 'file', exact: true }).fill('app.jl');
        await server.getByRole('button', { name: 'Get prompt', exact: true }).click();
        await server.locator('.tool-output').filter({ hasText: 'Review app.jl' }).waitFor({ timeout: 30_000 });
        await server.getByRole('button', { name: 'Test connection', exact: true }).click();
        await server.locator('.mcp-connection-test').filter({ hasText: 'Connected ·' }).waitFor({ timeout: 30_000 });
        await server.getByRole('button', { name: 'Restart', exact: true }).click();
        await server.locator('.mcp-result pre').filter({ hasText: '"generation": 2' }).waitFor({ state: 'attached', timeout: 30_000 });
        await server.getByText('Connection diagnostics', { exact: true }).click();
        await server.getByText(/Protocol 2025-11-25 · generation 2/).waitFor();
        await server.getByRole('button', { name: 'Disconnect', exact: true }).click();
        await server.getByRole('button', { name: 'Connect', exact: true }).waitFor({ timeout: 30_000 });
        await server.getByRole('checkbox', { name: 'Enabled fixture', exact: true }).uncheck();
        await server.getByText('disabled', { exact: true }).waitFor({ timeout: 30_000 });
        assert.equal(await server.getByRole('button', { name: 'Connect', exact: true }).count(), 0);
        await server.getByRole('checkbox', { name: 'Enabled fixture', exact: true }).check();
        await server.getByRole('button', { name: 'Connect', exact: true }).waitFor({ timeout: 30_000 });
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual MCP configuration/permissions/tool/resource/subscription/prompt/ping/restart/diagnostics/disable flow`);
    }
} catch (error) {
    if (panel) {
        console.error('Panel failure state:', await panel.innerText().catch(() => 'Unavailable'));
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-failure.png`) }).catch(() => {});
    }
    throw error;
} finally {
    await application?.close(); xvfb.kill(); fixture.close(); await rm(root, { recursive: true, force: true });
}
