import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';
const require = createRequire('/workspace/references/vscode/package.json');
async function waitEnabled(locator, timeout = 60_000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
        if (await locator.isEnabled().catch(() => false)) { return; }
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('Expected operation controls to become enabled');
}
const { _electron } = require('playwright');
const root = await mkdtemp(join(tmpdir(), 'shenscope-native-'));
const checkout = '/workspace/references/vscode';
const project = resolve(new URL('../../', import.meta.url).pathname);
const vsix = process.argv.includes('--vsix');
const mcpOnly = process.argv.includes('--mcp-only');
const skillsOnly = process.argv.includes('--skills-only');
const hooksOnly = process.argv.includes('--hooks-only');
const userHookRoot = hooksOnly ? await mkdtemp(join(tmpdir(), 'shenscope-user-hooks-')) : undefined;
const userSkillRoot = skillsOnly ? await mkdtemp(join(tmpdir(), 'shenscope-user-skills-')) : undefined;
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
await writeFile(config, `[provider]\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\nretries = 0\n[permissions]\nnetwork = 'allow'\nedit = 'ask'\n${skillsOnly ? `[skills]\nproject_roots = ['.shenscope/skills']\nuser_roots = ['${userSkillRoot}']\n` : ''}`);
if (hooksOnly) {
    await writeFile(config, (await readFile(config, 'utf8')) + `[hooks]\nproject_files = ['.shenscope/hooks.toml']\nuser_files = ['${join(userHookRoot, 'user-hooks.toml')}']\n`);
    await mkdir(join(root, '.shenscope'), { recursive: true });
    await writeFile(join(root, 'hook-fixture.py'), "import json,sys\npayload=json.load(sys.stdin)\nprint(json.dumps({'decision':'continue'}))\n");
    const declaration = name => `[[hooks]]\nname = '${name}'\npoint = 'before_tool'\nargv = ['python3', '-B', '${join(root, 'hook-fixture.py')}']\n`;
    await writeFile(join(root, '.shenscope', 'hooks.toml'), declaration('project-check'));
    await writeFile(join(userHookRoot, 'user-hooks.toml'), declaration('user-check'));
}
if (skillsOnly) {
    const projectSkill = join(root, '.shenscope', 'skills', 'review-code'); const userSkill = join(userSkillRoot, 'manual-review');
    await mkdir(projectSkill, { recursive: true }); await mkdir(userSkill, { recursive: true });
    await writeFile(join(projectSkill, 'SKILL.md'), '---\nname: review-code\ndescription: Review changes with inspected evidence\nallowed-tools: [Read]\n---\nProject instructions: $ARGUMENTS\n');
    await writeFile(join(userSkill, 'SKILL.md'), '---\nname: manual-review\ndescription: Explicit user review instructions\ndisable-model-invocation: true\n---\nUSER SOURCE SENTINEL\n');
}
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
                if (await candidate.locator('.shenscope-panel .status').filter({ hasText: 'Ready · native-fixture' }).isVisible().catch(() => false)) { frame = candidate; break; }
            }
            if (!frame) { await new Promise(resolve => setTimeout(resolve, 200)); }
        }
        assert.ok(frame, 'Extension webview must start independently of the native panel');
        assert.notEqual(frame, page.mainFrame()); panel = frame.locator('.shenscope-panel');
    }
    await panel.getByText('Ready · native-fixture', { exact: true }).waitFor({ timeout: 120_000 });
    await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-welcome.png`) });
    if (!mcpOnly && !skillsOnly && !hooksOnly) {
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
    if (skillsOnly) {
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Skills');
        // Locate within each card: project/user sources must not share selection state.
        const projectCard = panel.locator('.skills-group').filter({ hasText: 'Project skills' }).locator('.skill-card').first();
        const userCard = panel.locator('.skills-group').filter({ hasText: 'User skills' }).locator('.skill-card').first();
        await projectCard.getByRole('textbox', { name: 'Skill arguments', exact: true }).fill('GUI 中文');
        await projectCard.getByRole('button', { name: 'Activate', exact: true }).click();
        await panel.getByRole('button', { name: 'Allow session', exact: true }).click({ timeout: 60_000 });
        await projectCard.getByText('Active', { exact: true }).waitFor({ timeout: 60_000 });
        assert.equal(await userCard.getByText('Active', { exact: true }).count(), 0);
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-skills.png`) });
        await projectCard.getByRole('button', { name: 'Open source', exact: true }).click();
        await page.locator('.tabs-container .tab').filter({ hasText: 'SKILL.md' }).waitFor({ timeout: 60_000 });
        await projectCard.getByRole('button', { name: 'Deactivate', exact: true }).click();
        await projectCard.getByRole('button', { name: 'Activate', exact: true }).waitFor({ timeout: 60_000 });
        await projectCard.getByRole('checkbox', { name: 'Enabled review-code', exact: true }).uncheck();
        await projectCard.getByText('Disabled', { exact: true }).waitFor({ timeout: 60_000 });
        assert.equal(await projectCard.getByRole('button', { name: 'Activate', exact: true }).count(), 0);
        await projectCard.getByRole('checkbox', { name: 'Enabled review-code', exact: true }).check();
        await projectCard.getByRole('button', { name: 'Activate', exact: true }).waitFor({ timeout: 60_000 });
        await panel.getByRole('button', { name: 'Reload skills', exact: true }).click();
        await projectCard.getByRole('button', { name: 'Activate', exact: true }).waitFor({ timeout: 60_000 });
        await userCard.getByRole('button', { name: 'Open source', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'USER SOURCE SENTINEL' }).waitFor({ timeout: 60_000 });
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual project/user Skills discovery/activation/approval/deactivation/disable/reload and approved source files inside and outside the workspace`);
    }
    if (hooksOnly) {
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Hooks');
        const projectCard = panel.locator('.hook-card').filter({ hasText: 'project-check' });
        const userCard = panel.locator('.hook-card').filter({ hasText: 'user-check' });
        await projectCard.getByRole('button', { name: 'Test hook', exact: true }).click({ timeout: 60_000 });
        await panel.getByRole('button', { name: 'Allow session', exact: true }).click({ timeout: 60_000 });
        await projectCard.getByText('Last run · complete', { exact: true }).waitFor({ timeout: 60_000 });
        await projectCard.getByRole('button', { name: 'Open configuration', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'project-check' }).waitFor({ timeout: 60_000 });
        await projectCard.getByRole('checkbox', { name: 'Enabled project-check', exact: true }).uncheck();
        await projectCard.getByText('Disabled', { exact: true }).waitFor({ timeout: 60_000 });
        assert.equal(await projectCard.getByRole('button', { name: 'Test hook', exact: true }).isDisabled(), true);
        await projectCard.getByRole('checkbox', { name: 'Enabled project-check', exact: true }).check();
        await projectCard.locator('.badge').filter({ hasText: /^Enabled$/ }).waitFor({ timeout: 60_000 });
        await panel.getByRole('button', { name: 'Reload hooks', exact: true }).click();
        await waitEnabled(panel.getByRole('button', { name: 'Reload hooks', exact: true }));
        await userCard.getByRole('button', { name: 'Open configuration', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'user-check' }).waitFor({ timeout: 60_000 });
        await panel.getByRole('checkbox', { name: 'Enable lifecycle Hooks', exact: true }).uncheck();
        await projectCard.getByText('Disabled', { exact: true }).waitFor({ timeout: 60_000 });
        await panel.getByRole('checkbox', { name: 'Enable lifecycle Hooks', exact: true }).check();
        await projectCard.locator('.badge').filter({ hasText: /^Enabled$/ }).waitFor({ timeout: 60_000 });
        await panel.getByText('Add command hook', { exact: true }).click();
        await panel.getByRole('textbox', { name: 'Hook name', exact: true }).fill('inline-check');
        await panel.getByRole('combobox', { name: 'Hook lifecycle point', exact: true }).selectOption('before_model');
        await panel.getByRole('textbox', { name: 'Hook executable', exact: true }).fill('python3');
        await panel.getByRole('textbox', { name: 'Hook arguments · one per line', exact: true }).fill(`-B\n${join(root, 'hook-fixture.py')}`);
        await panel.getByRole('button', { name: 'Add hook', exact: true }).click();
        const inline = panel.locator('.hook-card').filter({ hasText: 'inline-check' });
        await inline.getByRole('button', { name: 'Test hook', exact: true }).click({ timeout: 60_000 });
        await panel.getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 60_000 });
        await inline.getByText('Last run · complete', { exact: true }).waitFor({ timeout: 60_000 });
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-hooks.png`) });
        assert.equal(requests.length, 0, 'Hook control operations do not invoke the model');
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual Hook project/user/inline configuration, command approval/test/status, per-source/global enable, reload and configuration opening inside/outside the workspace`);
    }
} catch (error) {
    if (panel) {
        console.error('Panel failure state:', await panel.innerText().catch(() => 'Unavailable'));
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-failure.png`) }).catch(() => {});
    }
    throw error;
} finally {
    await application?.close(); xvfb.kill(); fixture.close(); await rm(root, { recursive: true, force: true });
    if (userSkillRoot) { await rm(userSkillRoot, { recursive: true, force: true }); }
    if (userHookRoot) { await rm(userHookRoot, { recursive: true, force: true }); }
}
