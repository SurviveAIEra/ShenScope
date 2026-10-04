import { createRequire } from 'node:module';
import { spawn, execFileSync } from 'node:child_process';
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
async function waitCount(locator, count, timeout = 60_000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
        if (await locator.count() === count) { return; }
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(await locator.count(), count, 'Expected the completed page to render');
}
async function approve(panel, action, decision = 'Allow session') {
    const pending = panel.locator('.permission-card').filter({ hasText: action }).first();
    await pending.waitFor({ timeout: 60_000 });
    const requestId = await pending.getAttribute('data-request-id');
    assert.match(requestId, /^[0-9a-f-]+$/i);
    const card = panel.locator(`.permission-card[data-request-id="${requestId}"]`);
    await card.getByRole('button', { name: decision, exact: true }).click();
    await card.waitFor({ state: 'detached' });
}
const { _electron } = require('playwright');
const root = await mkdtemp(join(tmpdir(), 'shenscope-native-'));
const checkout = '/workspace/references/vscode';
const project = resolve(new URL('../../', import.meta.url).pathname);
const vsix = process.argv.includes('--vsix');
const mcpOnly = process.argv.includes('--mcp-only');
const skillsOnly = process.argv.includes('--skills-only');
const hooksOnly = process.argv.includes('--hooks-only');
const contextOnly = process.argv.includes('--context-only');
const semanticOnly = process.argv.includes('--semantic-only');
const analyzersOnly = process.argv.includes('--analyzers-only');
const modelsOnly = process.argv.includes('--models-only');
const routingOnly = process.argv.includes('--routing-only');
const historyOnly = process.argv.includes('--history-only');
const migrationOnly = process.argv.includes('--migration-only');
const memoryOnly = process.argv.includes('--memory-only');
const readyState = routingOnly ? 'Ready · main · writer-model' : 'Ready · native-fixture';
const userContextRoot = contextOnly ? await mkdtemp(join(tmpdir(), 'shenscope-user-context-')) : undefined;
const userHookRoot = hooksOnly ? await mkdtemp(join(tmpdir(), 'shenscope-user-hooks-')) : undefined;
const userSkillRoot = skillsOnly ? await mkdtemp(join(tmpdir(), 'shenscope-user-skills-')) : undefined;
const display = vsix ? ':102' : ':101';
const xvfb = spawn('/workspace/toolchains/xvfb/usr/bin/Xvfb', [display, '-screen', '0', '1280x900x24', '-nolisten', 'tcp'], { stdio: 'ignore' });
const requests = [];
let modelInferenceCalls = 0;
const fixture = createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) { chunks.push(chunk); }
    const raw = Buffer.concat(chunks).toString();
    if (routingOnly) {
        const body = raw ? JSON.parse(raw) : undefined; requests.push({ method: request.method, target: request.url, body });
        if (request.method === 'GET') { response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ data: [{ id: request.url.startsWith('/primary') ? 'writer-model' : 'backup-model' }] })); return; }
        if (request.url.startsWith('/primary')) { response.writeHead(503, { 'Content-Type': 'application/json' }); response.end('{}'); return; }
        response.writeHead(200, { 'Content-Type': 'text/event-stream' }); response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Role routing verified 中文' }, finish_reason: 'stop' }], usage: { prompt_tokens: 5, completion_tokens: 3 } })}\n\ndata: [DONE]\n\n`); return;
    }
    if (modelsOnly) {
        const body = raw ? JSON.parse(raw) : undefined;
        requests.push({ method: request.method, target: request.url, body });
        if (request.url === '/messages') {
            modelInferenceCalls++;
            if (modelInferenceCalls === 1) {
                response.writeHead(503, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ error: 'PROVIDER FAILURE FIXTURE' })); return;
            }
            const frames = [{ type: 'message_start', message: { usage: { input_tokens: 3 } } },
                { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
                { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Provider recovery verified 中文' } },
                { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 5 } }, { type: 'message_stop' }];
            response.writeHead(200, { 'Content-Type': 'text/event-stream' }); response.end(frames.map(frame => `data: ${JSON.stringify(frame)}\n\n`).join('')); return;
        }
        response.writeHead(200, { 'Content-Type': 'application/json', ETag: '"model-fixture"' });
        response.end(JSON.stringify(request.method === 'GET' ? { data: [{ id: 'catalog-first', display_name: 'First catalog model' }, { id: 'catalog-second', display_name: 'Second catalog model' }] } : { input_tokens: 17 }));
        return;
    }
    const body = JSON.parse(raw); requests.push(body);
    if (contextOnly) {
        const input = JSON.parse(body.messages.find(message => message.role === 'user').content);
        const source = input.sources[0];
        const summary = { version: 1, objective: 'CONTEXT GOAL SENTINEL 中文', constraints: 'Preserve the current restrictions', work: 'Seeded evidence requires real verification', next: 'Verify before action', citations: [{ message: source.message, sha256: source.sha256 }] };
        response.writeHead(200, { 'Content-Type': 'text/event-stream' });
        response.end(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: JSON.stringify(summary) }, finish_reason: 'stop' }] })}\n\ndata: [DONE]\n\n`); return;
    }
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
if (modelsOnly) {
    await writeFile(config, `[provider]\nprotocol = 'anthropic'\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\nretries = 0\n[provider.circuit]\nfailure_threshold = 1\ncooldown = 30.0\n[permissions]\nnetwork = 'ask'\nedit = 'ask'\npersistence = 'allow'\n`);
}
if (routingOnly) {
    const provider = (id, name) => `[model_routing.providers.${id}]\nprotocol = 'openai_chat'\nname = '${name}'\nendpoint = 'http://127.0.0.1:${port}/${id}'\nkey_env = 'ROUTE_${id.toUpperCase()}_KEY'\nretries = 0\n[model_routing.providers.${id}.circuit]\nfailure_threshold = 1\ncooldown = 300.0\n`;
    await writeFile(config, `[provider]\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\n[permissions]\nnetwork = 'ask'\npersistence = 'allow'\n[model_routing]\ndefault_role = 'main'\n${provider('primary', 'route-primary')}${provider('backup', 'route-backup')}[model_routing.profiles.writer]\nprovider = 'primary'\nmodel = 'writer-model'\n[model_routing.profiles.backup]\nprovider = 'backup'\nmodel = 'backup-model'\n[model_routing.profiles.worker]\nprovider = 'primary'\nmodel = 'worker-model'\n[model_routing.profiles.worker.capabilities]\ncontext_window = 128000\nmax_output = 512\n[model_routing.roles.main]\nprofiles = ['writer', 'backup']\n[model_routing.roles.worker]\nprofiles = ['worker']\n`);
}
if (contextOnly) {
    await writeFile(config, (await readFile(config, 'utf8')) + `read = 'ask'\npersistence = 'ask'\n[context]\nuser_files = ['${join(userContextRoot, 'user.md')}']\n`);
    await writeFile(join(userContextRoot, 'user.md'), 'CONTEXT USER INSTRUCTION');
    await writeFile(join(root, 'AGENTS.md'), 'CONTEXT PROJECT INSTRUCTION');
    await mkdir(join(root, 'src'), { recursive: true });
    await writeFile(join(root, 'src', 'AGENTS.md'), 'SCOPED CONTEXT INSTRUCTION');
    const seed = `using ShenScope
ctx=RuntimeContext(ARGS[1];session_id="gui-context",state_dir=joinpath(ARGS[1],"state"))
session=new_session(ctx;title="Context regression fixture")
add_message!(session,Message(:user,"CONTEXT GOAL SENTINEL 中文 keep restrictions"))
for index in 1:24
    id="seed-"*string(index)
    add_message!(session,Message(:assistant,"Seeded read";calls=[ToolCall(id,"read",Dict{String,Any}("path"=>"src/file.jl"))]))
    add_message!(session,Message(:tool,canonical(Dict("ok"=>true,"value"=>repeat("fixture evidence 中文 ",100)));call_id=id))
end`;
    execFileSync('/workspace/toolchains/julia-1.11.7/bin/julia', ['--startup-file=no', `--project=${project}`, '-e', seed, root], { env: { ...process.env, JULIA_DEPOT_PATH: '/workspace/julia-depot' }, timeout: 120_000, stdio: 'pipe' });
}
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
if (memoryOnly) {
    await writeFile(config, `[provider]\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\n[permissions]\nread = 'allow'\npersistence = 'ask'\nprocess = 'deny'\nnetwork = 'deny'\n`);
    const seed = `using ShenScope
ctx=RuntimeContext(ARGS[1];state_dir=joinpath(ARGS[1],"state"),session_id="memory-fixture",permissions=PermissionPolicy(;rules=Dict(:persistence=>Allow)))
for i in 1:19
    memory_put!(memory_store(ctx),"seed-"*lpad(string(i),2,'0'),"Saved fixture note "*string(i),ctx;expected_version=0,title="Seed note "*string(i),tags=["fixture"])
end`;
    execFileSync('/workspace/toolchains/julia-1.11.7/bin/julia', ['--startup-file=no', `--project=${project}`, '-e', seed, root], { env: { ...process.env, JULIA_DEPOT_PATH: '/workspace/julia-depot' }, timeout: 180_000 });
}
let historyCommits;
if (migrationOnly) {
    await writeFile(config, `[provider]\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\n[permissions]\nread = 'allow'\nprocess = 'ask'\nnetwork = 'deny'\npersistence = 'allow'\n`);
    for (const [path, source] of Object.entries({
        'a.go': 'package fixture\nfunc A() int { return 1 }\n',
        'b.go': 'package fixture\nfunc B() int { return A() + C() }\n',
        'c.go': 'package fixture\nfunc C() int { return B() }\n',
        'd.go': 'package fixture\nfunc D() int { return A() }\n',
        't_test.go': 'package fixture\nfunc TestCaller() int { return B() }\n',
    })) { await writeFile(join(root, path), source); }
}
if (historyOnly) {
    await writeFile(config, `[provider]\nendpoint = 'http://127.0.0.1:${port}'\nmodel = 'native-fixture'\n[permissions]\nread = 'allow'\nprocess = 'ask'\nnetwork = 'deny'\npersistence = 'allow'\n`);
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
    const git = (...args) => execFileSync('git', ['-c', 'user.name=GUI Fixture', '-c', 'user.email=fixture@example.invalid', ...args], { cwd: root, env: { ...env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' }, timeout: 10_000 }).toString().trim();
    git('init', '--object-format=sha1', '--initial-branch=main');
    await writeFile(join(root, 'buddy.go'), 'package fixture\nfunc Buddy() int { return Greet() }\n');
    await writeFile(join(root, 'other.go'), 'package fixture\nfunc Other() int { return 1 }\n');
    historyCommits = [];
    for (let index = 0; index < 4; index++) {
        if (index > 0) {
            await writeFile(join(root, 'buddy.go'), `package fixture\nfunc Buddy() int { return Greet() + ${index} }\n`);
            await writeFile(join(root, index === 2 ? 'other.go' : 'sample.go'), index === 2 ? 'package fixture\nfunc Other() int { return 2 }\n' : `package fixture\nfunc Greet() int { return ${index + 1} }\nfunc TestGreet() int { return Greet() }\n`);
        }
        git('add', '--', 'sample.go', 'buddy.go', 'other.go'); git('commit', '--no-gpg-sign', '-m', 'fixture change'); historyCommits.push(git('rev-parse', 'HEAD'));
    }
}
if (semanticOnly) {
    await writeFile(join(root, 'greeter.ts'), "export interface Greeter { greet(name: string): string; }\nexport class English implements Greeter { greet(name: string): string { return 'Hello ' + name; } }\n");
    await writeFile(join(root, 'main.ts'), "import { English } from './greeter';\nexport function TestGreet(): string { const agent = new English(); return agent.greet('中😀'); }\nexport const wrong: number = 'type error';\n");
}
let analyzerSource;
let analyzerFixtures;
if (analyzersOnly) {
    analyzerSource = (await readFile(join(project, 'test/fixtures/analyzer_programs.jl'), 'utf8')).match(/const INCOMING_ANALYZER_SOURCE = raw"""\n([\s\S]*?)"""/)[1];
    const a = 'a'.repeat(32); const b = 'b'.repeat(32); const edge = 'c'.repeat(64);
    const notes = ['Incoming relation counts over supplied facts'];
    analyzerFixtures = [
        { name: 'empty graph', data: { symbols: [], relations: [], seed_ids: [], truncated: false }, request: {}, expected: { candidates: [], notes, truncated: false } },
        { name: 'one incoming dependency', data: { symbols: [{ id: a }, { id: b }], relations: [{ id: edge, src: a, dst: b, confidence: 0.5 }], truncated: false }, request: {},
            expected: { candidates: [{ symbol_id: b, score: 1, confidence: 0.5, reason: '1 incoming recorded relations', evidence: [edge] }], notes, truncated: false } },
    ];
    await writeFile(join(root, 'incoming.jl'), analyzerSource);
}
await mkdir(join(root, 'user-data', 'User'), { recursive: true });
await writeFile(join(root, 'user-data', 'User', 'settings.json'), JSON.stringify({
    'shenscope.juliaPath': '/workspace/toolchains/julia-1.11.7/bin/julia',
    'shenscope.corePath': project, 'shenscope.statePath': join(root, 'state'),
    'shenscope.launcher.corePath': project, 'shenscope.launcher.statePath': join(root, 'state'),
    'shenscope.launcher.juliaPath': '/workspace/toolchains/julia-1.11.7/bin/julia',
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
                if (await candidate.locator('.shenscope-panel .status').filter({ hasText: readyState }).isVisible().catch(() => false)) { frame = candidate; break; }
            }
            if (!frame) { await new Promise(resolve => setTimeout(resolve, 200)); }
        }
        assert.ok(frame, 'Extension webview must start independently of the native panel');
        assert.notEqual(frame, page.mainFrame()); panel = frame.locator('.shenscope-panel');
    }
    await panel.getByText(readyState, { exact: true }).waitFor({ timeout: 120_000 });
    await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-welcome.png`) });
    if (!mcpOnly && !skillsOnly && !hooksOnly && !contextOnly && !semanticOnly && !analyzersOnly && !modelsOnly && !routingOnly && !historyOnly && !migrationOnly && !memoryOnly) {
    await panel.locator('textarea').fill('Write a file from the native sidebar');
    await panel.getByRole('button', { name: 'Send message', exact: true }).click();
    await panel.getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 120_000 });
    await panel.locator('.permission-card').filter({ hasText: 'context.archive · persistence' }).getByRole('button', { name: 'Allow session', exact: true }).click({ timeout: 60_000 });
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
    if (memoryOnly) {
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Memory');
        await panel.getByText('19 saved notes', { exact: true }).waitFor({ timeout: 120_000 });
        const create = async (key, title, content, tags) => {
            const editor = panel.locator('.memory-editor');
            if (!(await editor.evaluate(node => node.open))) { await editor.locator('summary').click(); }
            await editor.getByRole('textbox', { name: 'Memory key', exact: true }).fill(key);
            await editor.getByRole('textbox', { name: 'Memory title', exact: true }).fill(title);
            await editor.getByRole('textbox', { name: 'Memory tags', exact: true }).fill(tags);
            await editor.getByRole('textbox', { name: 'Memory content', exact: true }).fill(content);
            await editor.getByRole('button', { name: 'Save note', exact: true }).click();
            await approve(panel, 'memory.put · persistence', 'Allow once');
            await panel.getByText('Saved note · version 1', { exact: true }).waitFor({ timeout: 120_000 });
        };
        await create('graph', '中文代码图', 'Julia 中文代码图 reviewed evidence', 'core,julia');
        await panel.getByRole('button', { name: 'New note', exact: true }).click();
        await create('companion', 'Review companion', 'Independent review note', 'core');
        await panel.getByRole('textbox', { name: 'Search memory', exact: true }).fill('代码图');
        await panel.getByRole('textbox', { name: 'Memory tag filter', exact: true }).fill('core');
        await panel.getByRole('button', { name: 'Search notes', exact: true }).click();
        await panel.getByText('1 matching note', { exact: true }).waitFor({ timeout: 120_000 });
        const note = panel.locator('.memory-result[data-memory-key="graph"]');
        await note.getByText('User supplied', { exact: true }).waitFor();
        await note.locator('.memory-evidence > summary').click();
        assert.ok((await note.innerText()).includes('Content checksum:'));
        assert.ok((await note.innerText()).includes('This records the stored source and lexical match.'));
        await note.scrollIntoViewIfNeeded();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-memory-evidence.png`) });
        await note.getByRole('button', { name: 'Read and edit note', exact: true }).click();
        const content = panel.getByRole('textbox', { name: 'Memory content', exact: true });
        await waitEnabled(content);
        assert.equal(await content.inputValue(), 'Julia 中文代码图 reviewed evidence');
        await content.fill('Julia 中文代码图 updated evidence');
        await panel.getByRole('button', { name: 'Save note', exact: true }).click();
        await approve(panel, 'memory.put · persistence', 'Allow once');
        await panel.getByText('Saved note · version 2', { exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByRole('button', { name: 'New note', exact: true }).click();
        const collection = panel.getByRole('textbox', { name: 'Memory namespace', exact: true });
        await collection.fill('scratch'); await collection.press('Tab');
        await panel.getByText('0 saved notes', { exact: true }).waitFor({ timeout: 120_000 });
        await create('graph', 'Separate collection', 'Other collection 中文', 'other');
        await panel.getByRole('button', { name: 'New note', exact: true }).click();
        const back = panel.getByRole('textbox', { name: 'Memory namespace', exact: true });
        await back.fill('default'); await back.press('Tab');
        await panel.getByText('21 saved notes', { exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByRole('button', { name: 'Refresh memory', exact: true }).click();
        await panel.getByText('21 matching notes', { exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByRole('button', { name: 'Next memory page', exact: true }).click();
        await panel.getByRole('button', { name: 'Next memory page', exact: true }).waitFor({ state: 'detached', timeout: 120_000 });
        await waitCount(panel.locator('.memory-result'), 1);
        await panel.getByRole('button', { name: 'Refresh memory', exact: true }).click();
        const companion = panel.locator('.memory-result[data-memory-key="companion"]');
        await companion.getByRole('button', { name: 'Read and edit note', exact: true }).click();
        await waitEnabled(panel.getByRole('button', { name: 'Delete note', exact: true }));
        await panel.getByRole('button', { name: 'Delete note', exact: true }).click();
        await approve(panel, 'memory.delete · persistence', 'Allow once');
        await panel.getByText('Note deleted. Retained history remains available.', { exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByText('20 saved notes', { exact: true }).waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-memory-managed.png`) });
        const verify = `using ShenScope
ctx=RuntimeContext(ARGS[1];state_dir=joinpath(ARGS[1],"state"),permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
default=memory_store(ctx);scratch=memory_store(ctx;namespace="scratch")
@assert memory_get(default,"graph",ctx)["version"]==2
@assert memory_get(default,"graph",ctx)["value"]["content"]=="Julia 中文代码图 updated evidence"
@assert memory_get(scratch,"graph",ctx)["version"]==1
@assert memory_get(default,"companion",ctx)===nothing
@assert length(memory_history(default,"companion",ctx))==2
@assert memory_namespaces(ctx)["namespaces"]==["default","scratch"]
println("memory durable proof verified")`;
        execFileSync('/workspace/toolchains/julia-1.11.7/bin/julia', ['--startup-file=no', `--project=${project}`, '-e', verify, root], { env: { ...process.env, JULIA_DEPOT_PATH: '/workspace/julia-depot' }, timeout: 120_000 });
        assert.equal(requests.length, 0, 'Memory CRUD and lexical retrieval make no model request');
        assert.equal(await panel.locator('.permission-card').count(), 0);
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual persistence approvals, Chinese evidence, CAS edit, independent same-key collections, pinned pagination, deletion/history and durable Julia verification without model requests`);
    }
    if (migrationOnly) {
        await panel.getByRole('button', { name: 'Project', exact: true }).click();
        await panel.getByRole('combobox', { name: 'Project backend' }).selectOption('go_ast');
        await panel.getByRole('button', { name: 'Index project', exact: true }).click();
        await approve(panel, 'project.backend · process', 'Allow once');
        await panel.getByRole('button', { name: 'Refresh index', exact: true }).waitFor({ timeout: 120_000 });
        const plan = async () => {
            await panel.getByRole('textbox', { name: 'Files to analyze (comma separated)' }).fill('a.go');
            await panel.getByRole('button', { name: 'Plan migration', exact: true }).click();
        };
        await plan();
        await panel.locator('.migration-summary').getByText('4 batches · 1 cycle group', { exact: true }).waitFor({ timeout: 120_000 });
        const cycle = panel.locator('.migration-batch').filter({ hasText: 'Cycle group' });
        assert.equal(await cycle.count(), 1); assert.equal(await cycle.getByRole('button', { name: 'b.go', exact: true }).count(), 1); assert.equal(await cycle.getByRole('button', { name: 'c.go', exact: true }).count(), 1);
        await cycle.locator('.migration-relations > summary').click();
        assert.ok((await cycle.innerText()).includes('b.go → c.go'));
        await cycle.scrollIntoViewIfNeeded();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-migration-cycle.png`) });
        await cycle.getByRole('button', { name: 'b.go', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'func B' }).waitFor();
        await panel.getByRole('combobox', { name: 'Migration order', exact: true }).selectOption('callers_first');
        await plan();
        await panel.locator('.migration-summary').getByText('callers first · index revision 1', { exact: true }).waitFor({ timeout: 120_000 });
        assert.equal(await panel.locator('.migration-batch').last().getByRole('button', { name: 'a.go', exact: true }).count(), 1);
        await panel.getByRole('spinbutton', { name: 'Migration depth', exact: true }).fill('0');
        await panel.getByRole('spinbutton', { name: 'Migration depth', exact: true }).blur();
        await plan();
        await panel.locator('.migration-summary').getByText('Partial proposal', { exact: true }).waitFor({ timeout: 120_000 });
        assert.equal(await panel.locator('.migration-batch').count(), 1); assert.equal(await panel.locator('.permission-card').count(), 0);
        assert.equal(requests.length, 0, 'Migration reads the saved graph without model requests');
        await panel.locator('.migration-summary').scrollIntoViewIfNeeded();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-migration-partial.png`) });
        assert.equal(await readFile(join(root, 'a.go'), 'utf8'), 'package fixture\nfunc A() int { return 1 }\n');
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual graph migration cycles, relation evidence, reversed dependency order, partial-depth proposal and native source opening without process/model calls during planning`);
    }
    if (historyOnly) {
        await panel.getByRole('button', { name: 'Project', exact: true }).click();
        await panel.getByRole('combobox', { name: 'Project backend' }).selectOption('go_ast');
        await panel.getByRole('button', { name: 'Index project', exact: true }).click();
        await panel.locator('.permission-card').first().getByRole('button', { name: 'Allow once', exact: true }).click({ timeout: 60_000 });
        await panel.getByRole('button', { name: 'Refresh index', exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByRole('textbox', { name: 'Files to analyze (comma separated)' }).fill('sample.go');
        await panel.getByRole('spinbutton', { name: 'Bulk file threshold', exact: true }).fill('2');
        await panel.getByRole('spinbutton', { name: 'Bulk file threshold', exact: true }).blur();
        const analyze = async (button, title) => {
            await panel.getByRole('button', { name: button, exact: true }).click();
            let approved = 0; const deadline = Date.now() + 120_000;
            while (Date.now() < deadline && !await panel.locator('.analysis-title').filter({ hasText: title }).count()) {
                const card = panel.locator('.permission-card').first();
                if (await card.count()) { const requestId = await card.getAttribute('data-request-id'); const fixed = panel.locator(`.permission-card[data-request-id="${requestId}"]`); assert.match(await fixed.innerText(), /git.history · process/); await fixed.getByRole('button', { name: 'Allow once', exact: true }).click(); approved++; await fixed.waitFor({ state: 'detached' }); }
                else { await new Promise(resolve => setTimeout(resolve, 50)); }
            }
            await panel.locator('.analysis-title').filter({ hasText: title }).waitFor({ timeout: 1000 }); assert.equal(approved, 5);
            assert.equal(requests.length, 0, 'Local history analysis sends no provider request');
        };
        await analyze('Git co-change', 'git cochange');
        await panel.locator('.history-candidate').getByRole('button', { name: 'buddy.go', exact: true }).waitFor();
        await panel.getByText('Score 0.400 · 2 shared commits', { exact: true }).waitFor();
        await panel.locator('.history-commit-evidence > summary').click();
        assert.equal(await panel.locator('.history-commit-evidence code').first().textContent(), historyCommits[3]);
        await panel.locator('.history-coverage').scrollIntoViewIfNeeded();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-git-cochange.png`) });
        await panel.locator('.history-candidate').getByRole('button', { name: 'buddy.go', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'func Buddy' }).waitFor();
        await panel.getByRole('textbox', { name: 'Files to analyze (comma separated)' }).fill('sample.go');
        await analyze('Review priority', 'risk');
        await panel.locator('.history-candidate').getByRole('button', { name: 'sample.go', exact: true }).waitFor();
        await panel.getByText('2 observed changes · +2 / −2 lines · 1 dependent files', { exact: true }).waitFor();
        await panel.locator('.history-coverage').scrollIntoViewIfNeeded();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-git-risk.png`) });
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual local Git history approvals, commit-linked co-change/risk results, evidence controls and native source opening without model requests`);
    }
    if (routingOnly) {
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Models');
        await panel.getByRole('heading', { name: 'Role routing', exact: true }).waitFor();
        assert.equal(await panel.locator('.configured-model h3').textContent(), 'writer-model');
        await panel.locator('.model-count-form > summary').click();
        await panel.getByRole('textbox', { name: 'Model request to count' }).fill(JSON.stringify({ messages: [{ role: 'user', text: 'Preview 中文' }], max_output: 64 }));
        await panel.getByRole('button', { name: 'Preview eligible models', exact: true }).click();
        await panel.getByRole('heading', { name: 'Eligible models · main', exact: true }).waitFor({ timeout: 60_000 });
        assert.equal(await panel.locator('.model-route-plan .model-route-row').count(), 2);
        assert.equal(requests.length, 0, 'Route preview sends no provider request');
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-routing-plan.png`) });
        await panel.getByRole('combobox', { name: 'Model service profile' }).selectOption('backup');
        await panel.locator('.configured-model h3').filter({ hasText: 'backup-model' }).waitFor();
        await panel.getByRole('button', { name: 'Refresh provider models', exact: true }).click();
        await approve(panel, 'route-backup · network', 'Allow once');
        await panel.getByRole('heading', { name: 'Provider directory · 1 models' }).waitFor({ timeout: 60_000 });
        assert.equal(requests.length, 1); assert.equal(requests[0].target, '/backup/models');
        await panel.getByRole('button', { name: 'Chat', exact: true }).click();
        await panel.getByRole('textbox', { name: 'Message ShenScope', exact: true }).fill('Use the declared main route and report its selected model');
        await panel.getByRole('button', { name: 'Send message', exact: true }).click();
        assert.equal(await panel.getByRole('combobox', { name: 'Model role' }).isDisabled(), true);
        await approve(panel, 'route-primary · network', 'Allow once');
        await approve(panel, 'route-backup · network', 'Allow once');
        await panel.getByText('Role routing verified 中文', { exact: true }).waitFor({ timeout: 120_000 });
        await panel.locator('.status').filter({ hasText: 'Complete' }).waitFor();
        const inference = requests.filter(request => request.method === 'POST'); assert.equal(inference.length, 2);
        assert.equal(inference[0].body.model, 'writer-model'); assert.equal(inference[1].body.model, 'backup-model');
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Models');
        await panel.locator('.model-route-receipts > summary').click();
        await panel.locator('.model-route-receipt[data-outcome="success"]').waitFor();
        assert.equal(await panel.locator('.model-route-receipt strong').textContent(), 'backup');
        await panel.getByText('Last observed request succeeded.', { exact: true }).waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-routing-recovery.png`) });
        await panel.getByRole('button', { name: 'Chat', exact: true }).click();
        await panel.getByRole('combobox', { name: 'Model role' }).selectOption('worker');
        await panel.getByRole('button', { name: 'worker · worker-model', exact: true }).waitFor();
        await panel.getByRole('textbox', { name: 'Message ShenScope', exact: true }).fill('Use only the selected worker role');
        await panel.getByRole('button', { name: 'Send message', exact: true }).click();
        await approve(panel, 'route-primary · network', 'Allow once');
        await panel.locator('.status').filter({ hasText: 'Task failed' }).waitFor({ timeout: 120_000 });
        assert.equal(requests.filter(request => request.method === 'POST').length, 2, 'The selected worker role cannot use the healthy main-role backup');
        assert.equal(await panel.getByRole('combobox', { name: 'Model role' }).isEnabled(), true);
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-routing-role.png`) });
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, key-free/no-network route preview, selected-profile directory, explicit two-source failure fallback, actual chosen model and scoped route receipt`);
    }
    if (modelsOnly) {
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Models');
        await panel.getByText('Provider directory · 0 models', { exact: true }).waitFor();
        await panel.getByRole('button', { name: 'Refresh provider models', exact: true }).click();
        await approve(panel, 'openai-compatible · network', 'Allow once');
        await panel.getByText('Provider directory · 2 models', { exact: true }).waitFor();
        const cards = panel.locator('.model-directory .model-card');
        assert.equal(await cards.count(), 2);
        assert.ok((await cards.first().innerText()).includes('Not provided'));
        assert.equal(await panel.locator('.configured-model h3').textContent(), 'native-fixture');
        await waitEnabled(cards.first().getByRole('button', { name: 'Inspect model metadata', exact: true }));
        await cards.first().getByRole('button', { name: 'Inspect model metadata', exact: true }).click();
        await panel.getByRole('heading', { name: 'Model metadata', exact: true }).waitFor();
        assert.ok((await panel.locator('.model-metadata').innerText()).includes('provider_api'));
        const form = panel.locator('.model-count-form');
        await form.locator('summary').click();
        await form.getByRole('textbox', { name: 'Model request to count', exact: true }).fill(JSON.stringify({ messages: [{ role: 'user', text: 'Measure 中文😀' }], max_output: 64 }));
        await form.getByRole('combobox', { name: 'Model token counting method', exact: true }).selectOption('provider');
        await waitEnabled(form.getByRole('button', { name: 'Measure input tokens', exact: true }));
        await form.getByRole('button', { name: 'Measure input tokens', exact: true }).click();
        await approve(panel, 'openai-compatible · network', 'Allow once');
        await panel.getByText('17 input tokens', { exact: true }).waitFor();
        assert.equal(requests.length, 2);
        assert.equal(requests[0].method, 'GET'); assert.equal(requests[0].target, '/models?limit=100');
        assert.equal(requests[1].target, '/messages/count_tokens');
        assert.equal(requests[1].body.model, 'native-fixture');
        assert.equal(requests[1].body.messages[0].content[0].text, 'Measure 中文😀');
        await panel.locator('.model-count-result').scrollIntoViewIfNeeded();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-models-count.png`) });
        await waitEnabled(panel.getByRole('button', { name: 'Clear cached models', exact: true }));
        await panel.getByRole('button', { name: 'Clear cached models', exact: true }).click();
        await panel.getByText('Provider directory · 0 models', { exact: true }).waitFor();
        await waitEnabled(panel.getByRole('button', { name: 'Refresh provider models', exact: true }));
        await panel.getByRole('button', { name: 'Refresh provider models', exact: true }).click();
        await panel.locator('.permission-card').filter({ hasText: 'openai-compatible · network' }).waitFor();
        await panel.getByRole('button', { name: 'Cancel model operation', exact: true }).click();
        await panel.getByText('Model operation cancelled', { exact: true }).waitFor();
        assert.equal(await panel.locator('.permission-card').count(), 0);
        assert.equal(requests.length, 2);
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-models-cancel.png`) });
        await panel.getByRole('button', { name: 'Chat', exact: true }).click();
        await panel.getByRole('textbox', { name: 'Message ShenScope', exact: true }).fill('Observe provider failure');
        await panel.getByRole('button', { name: 'Send message', exact: true }).click();
        await approve(panel, 'openai-compatible · network', 'Allow once');
        await panel.locator('.status').filter({ hasText: 'Task failed' }).waitFor({ timeout: 120_000 });
        assert.equal(modelInferenceCalls, 1);
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Models');
        await panel.locator('.model-health[data-state="open"]').waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-models-health-open.png`) });
        await panel.getByRole('button', { name: 'Reset provider health', exact: true }).click();
        await approve(panel, 'models.health.reset · network', 'Allow once');
        await panel.locator('.model-health[data-state="closed"]').waitFor();
        await panel.getByText('No recent inference result.', { exact: true }).waitFor();
        assert.equal(modelInferenceCalls, 1);
        await panel.getByRole('button', { name: 'Chat', exact: true }).click();
        await panel.getByRole('textbox', { name: 'Message ShenScope', exact: true }).fill('Verify recovery with an explicit request');
        await panel.getByRole('button', { name: 'Send message', exact: true }).click();
        await approve(panel, 'openai-compatible · network', 'Allow once');
        await panel.getByText('Provider recovery verified 中文', { exact: true }).waitFor({ timeout: 120_000 });
        await panel.locator('.status').filter({ hasText: 'Complete' }).waitFor();
        assert.equal(modelInferenceCalls, 2);
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Models');
        await panel.getByText('Last observed request succeeded.', { exact: true }).waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-models-health-recovered.png`) });
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual provider directory/count API, unknown metadata, allow-once permissions, cache/cancel, shared inference health, HTTP failure cooldown, scoped health reset without a probe and explicit verified recovery`);
    }
    if (analyzersOnly) {
        await panel.getByRole('button', { name: 'Project', exact: true }).click();
        await panel.getByRole('combobox', { name: 'Project backend' }).selectOption('go_ast');
        await panel.getByRole('button', { name: 'Index project', exact: true }).click();
        await approve(panel, 'project.index · persistence');
        await approve(panel, 'project.backend · process');
        await panel.getByRole('button', { name: 'Refresh index', exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Analyzers');
        await panel.getByRole('combobox', { name: 'Analyzer project backend' }).selectOption('go_ast');
        const register = async fixtures => {
            const form = panel.locator('.analyzer-registration'); await form.locator('summary').click();
            await form.getByRole('textbox', { name: 'Analyzer name', exact: true }).fill('incoming');
            await form.getByRole('textbox', { name: 'Source file in this workspace', exact: true }).fill('incoming.jl');
            await form.getByRole('textbox', { name: 'External analyzer fixtures', exact: true }).fill(JSON.stringify(fixtures));
            await form.getByRole('button', { name: 'Register candidate', exact: true }).click();
            await approve(panel, 'analysis.register · dynamic');
            await panel.getByText('Analyzer operation complete', { exact: true }).waitFor();
            await waitEnabled(panel.getByRole('button', { name: 'Refresh analyzers', exact: true }));
        };
        await register(analyzerFixtures);
        const first = panel.locator('.analyzer-card').first();
        const firstPrefix = (await first.locator('small').textContent()).split(' · ')[0];
        await first.getByRole('button', { name: 'Review code', exact: true }).click();
        await panel.locator('.analyzer-source').filter({ hasText: 'function analyze' }).waitFor();
        await panel.getByText('2 independent fixtures', { exact: true }).waitFor();
        await waitEnabled(first.getByRole('button', { name: 'Validate fixtures', exact: true }));
        await first.getByRole('button', { name: 'Validate fixtures', exact: true }).click();
        await approve(panel, 'analysis.compute · dynamic'); await approve(panel, 'analysis.compute · process');
        await panel.getByText('External fixtures passed · 2 cases', { exact: true }).waitFor({ timeout: 120_000 });
        await waitEnabled(first.getByRole('button', { name: 'Run on project', exact: true }));
        await first.getByRole('button', { name: 'Run on project', exact: true }).click();
        await approve(panel, 'analysis.compute · dynamic'); await approve(panel, 'analysis.compute · process');
        const candidates = panel.locator('.analyzer-candidate'); await candidates.first().waitFor({ timeout: 120_000 });
        assert.ok(await candidates.count() > 0);
        await candidates.first().locator('summary').click();
        await candidates.first().locator('.analyzer-evidence').first().waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-analyzers-results.png`) });
        await candidates.first().getByRole('button', { name: 'sample.go:2', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'func Greet' }).waitFor();
        await waitEnabled(first.getByRole('button', { name: 'Archive version', exact: true }));
        await first.getByRole('button', { name: 'Archive version', exact: true }).click();
        await approve(panel, 'analysis.archive · persistence');
        await panel.getByText('Version archived.', { exact: true }).waitFor();
        await waitEnabled(first.getByRole('button', { name: 'Promote to project', exact: true }));
        await first.getByRole('button', { name: 'Promote to project', exact: true }).click();
        await approve(panel, 'analysis.promote · persistence');
        await panel.getByText('Active version updated · revision 1', { exact: true }).waitFor({ timeout: 120_000 });
        const updated = analyzerSource.replace('Incoming relation counts over supplied facts', 'Incoming graph facts reviewed');
        const updatedFixtures = structuredClone(analyzerFixtures); for (const test of updatedFixtures) { test.expected.notes = ['Incoming graph facts reviewed']; }
        await writeFile(join(root, 'incoming.jl'), updated);
        await waitEnabled(panel.getByRole('button', { name: 'Refresh analyzers', exact: true }));
        await register(updatedFixtures);
        const candidate = panel.locator('.analyzer-card').filter({ hasText: 'Candidate' });
        await candidate.first().waitFor({ timeout: 60_000 });
        assert.equal(await candidate.count(), 1);
        await candidate.getByRole('button', { name: 'Promote to project', exact: true }).click();
        await approve(panel, 'analysis.compute · dynamic'); await approve(panel, 'analysis.compute · process');
        await approve(panel, 'analysis.promote · persistence');
        await panel.getByText('Active version updated · revision 2', { exact: true }).waitFor({ timeout: 120_000 });
        const old = panel.locator('.analyzer-version').filter({ hasText: firstPrefix });
        await waitEnabled(old.getByRole('button', { name: 'Roll back to this version', exact: true }));
        await old.getByRole('button', { name: 'Roll back to this version', exact: true }).click();
        await approve(panel, 'analysis.rollback · persistence');
        await panel.getByText('Active version updated · revision 3', { exact: true }).waitFor({ timeout: 120_000 });
        assert.equal(await old.getByText('Active', { exact: true }).count(), 1);
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-analyzers-versions.png`) });
        await panel.locator('.analyzer-registration summary').click();
        await panel.getByRole('textbox', { name: 'Analyzer name', exact: true }).fill('cancel_candidate');
        await panel.getByRole('button', { name: 'Register candidate', exact: true }).click();
        await panel.locator('.permission-card').filter({ hasText: 'analysis.register · dynamic' }).waitFor();
        await panel.getByRole('button', { name: 'Cancel analyzer operation', exact: true }).click();
        await panel.getByText('Analyzer operation cancelled', { exact: true }).waitFor({ timeout: 60_000 });
        assert.equal(await panel.locator('.permission-card').count(), 0);
        assert.equal(await panel.locator('.analyzer-card').filter({ hasText: 'cancel_candidate' }).count(), 0);
        assert.equal(requests.length, 0, 'Custom graph computations do not call the model');
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual analyzer registration, source/external fixture review, isolated fixture validation, graph evidence/file navigation, immutable archive, two CAS promotions, fresh-validation rollback and cancellation of a pending approval`);
    }
    if (semanticOnly) {
        await panel.getByRole('button', { name: 'Project', exact: true }).click();
        await panel.getByRole('combobox', { name: 'Project backend' }).selectOption('typescript');
        await panel.getByRole('button', { name: 'Index project', exact: true }).click();
        await approve(panel, 'project.index · persistence');
        await approve(panel, 'project.backend · process');
        await panel.getByRole('button', { name: 'Refresh index', exact: true }).waitFor({ timeout: 120_000 });
        await panel.getByText('TypeScript 5.9.2', { exact: true }).waitFor();
        await panel.getByRole('textbox', { name: 'Search project symbols' }).fill('TestGreet');
        await panel.getByRole('button', { name: 'Inspect TestGreet', exact: true }).click();
        await panel.locator('.semantic-type').filter({ hasText: '() => string' }).waitFor();
        await panel.getByRole('button', { name: 'Calls', exact: true }).click();
        await panel.locator('.navigation-entry').filter({ hasText: 'English.greet' }).waitFor();
        await panel.getByRole('button', { name: 'Definitions', exact: true }).click();
        await panel.locator('.navigation-entry').filter({ hasText: 'TestGreet' }).waitFor();
        await panel.getByRole('textbox', { name: 'Search project symbols' }).fill('English');
        await panel.getByRole('button', { name: 'Inspect English.greet', exact: true }).click();
        await panel.getByRole('button', { name: 'Callers', exact: true }).click();
        await panel.locator('.navigation-entry').filter({ hasText: 'TestGreet' }).waitFor();
        await panel.getByRole('button', { name: 'References', exact: true }).click();
        await panel.locator('.navigation-entry').filter({ hasText: 'main.ts:2' }).waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-semantic.png`) });
        await panel.getByRole('button', { name: 'Open declaration', exact: true }).click();
        await page.locator('.monaco-editor .view-lines').filter({ hasText: 'class English' }).waitFor();
        await panel.getByRole('button', { name: 'Show diagnostics', exact: true }).click();
        await panel.locator('.navigation-entry').filter({ hasText: '2322' }).waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-semantic-diagnostics.png`) });
        await panel.locator('.project-cache summary').click();
        await panel.getByRole('button', { name: 'Compact index history', exact: true }).click();
        await panel.getByRole('button', { name: 'Refresh index', exact: true }).waitFor({ timeout: 60_000 });
        await panel.getByText('The current index already uses less space than a replacement snapshot.', { exact: true }).waitFor();
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-project-cache.png`) });
        await panel.getByRole('button', { name: 'Watch file changes', exact: true }).click();
        await panel.locator('.watch-state').filter({ hasText: /^Watching$/ }).waitFor();
        const greeterPath = join(root, 'greeter.ts'); const greeter = await readFile(greeterPath, 'utf8');
        await writeFile(greeterPath, greeter + 'export function WatchedAddition(): number { return 3; }\n');
        await panel.locator('.watch-state').filter({ hasText: 'Changes pending' }).waitFor({ timeout: 30_000 });
        await panel.locator('.project-watch').screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-watch-pending.png`) });
        await panel.getByRole('button', { name: 'Update pending changes', exact: true }).click();
        await panel.getByText('1 batch indexed', { exact: true }).waitFor({ timeout: 30_000 });
        await panel.getByRole('textbox', { name: 'Search project symbols' }).fill('WatchedAddition');
        await panel.getByRole('button', { name: 'Inspect WatchedAddition', exact: true }).waitFor();
        await panel.getByRole('button', { name: 'Stop watching', exact: true }).click();
        await panel.locator('.watch-state').filter({ hasText: /^Stopped$/ }).waitFor();
        await panel.getByRole('checkbox', { name: 'Update index automatically', exact: true }).check();
        await panel.getByRole('button', { name: 'Watch file changes', exact: true }).click();
        await panel.locator('.watch-state').filter({ hasText: /^Watching$/ }).waitFor();
        await writeFile(greeterPath, 'export function BROKEN( {\n');
        await panel.locator('.watch-error').waitFor({ timeout: 30_000 });
        await panel.locator('.project-watch').screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-watch-error.png`) });
        await writeFile(greeterPath, greeter + 'export function WatchedAddition(): number { return 4; }\n');
        await panel.getByText('1 batch indexed', { exact: true }).waitFor({ timeout: 30_000 });
        assert.equal(await panel.locator('.watch-error').count(), 0);
        await panel.locator('.project-watch').screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-watching.png`) });
        await panel.getByRole('button', { name: 'Stop watching', exact: true }).click();
        await panel.locator('.watch-state').filter({ hasText: /^Stopped$/ }).waitFor();
        assert.equal(requests.length, 0, 'Compiler navigation must not call the model');
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual TypeScript checker indexing, permissions, navigation, cache compaction, observed changes, manual refresh, automatic watching, syntax-failure preservation and repair`);
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
    if (contextOnly) {
        await panel.getByRole('button', { name: 'History', exact: true }).click();
        await panel.getByRole('button', { name: 'Context regression fixture', exact: true }).click();
        await panel.locator('.composer-box').waitFor({ timeout: 60_000 });
        await panel.getByRole('combobox', { name: 'More views' }).selectOption('Context');
        await panel.getByRole('button', { name: 'Load context status', exact: true }).click();
        await approve(panel, 'context.status · read');
        await panel.getByText('Complete conversation in view', { exact: true }).waitFor({ timeout: 60_000 });
        await waitEnabled(panel.getByRole('button', { name: 'Inspect project instructions', exact: true }));
        await panel.getByRole('button', { name: 'Inspect project instructions', exact: true }).click();
        for (let index = 0; index < 3; index++) {
            await approve(panel, 'context.instructions · read');
        }
        await panel.getByText('CONTEXT USER INSTRUCTION', { exact: true }).waitFor({ state: 'attached', timeout: 60_000 });
        assert.equal(await panel.getByText('CONTEXT PROJECT INSTRUCTION', { exact: true }).count(), 1);
        assert.equal(await panel.getByText('SCOPED CONTEXT INSTRUCTION', { exact: true }).count(), 1);
        await waitEnabled(panel.getByRole('button', { name: 'Compact older context', exact: true }));
        await panel.getByRole('button', { name: 'Compact older context', exact: true }).click();
        await approve(panel, 'skills.catalog · read');
        await approve(panel, 'context.compact · persistence');
        await panel.getByText('Saved context checkpoint', { exact: true }).waitFor({ timeout: 60_000 });
        await waitEnabled(panel.getByRole('button', { name: 'Read message 1', exact: true }));
        await panel.getByRole('button', { name: 'Read message 1', exact: true }).click();
        await panel.locator('.context-evidence pre').filter({ hasText: 'CONTEXT GOAL SENTINEL' }).waitFor({ timeout: 60_000 });
        await waitEnabled(panel.getByRole('button', { name: 'Summarize with model', exact: true }));
        await panel.getByRole('button', { name: 'Summarize with model', exact: true }).click();
        await panel.locator('.context-checkpoint').filter({ hasText: 'Model summary' }).waitFor({ timeout: 60_000 });
        assert.equal(requests.length, 1);
        await panel.screenshot({ path: join(project, `.local/${vsix ? 'vsix' : 'native'}-context.png`) });
        await panel.getByText('Context settings', { exact: true }).click();
        await panel.getByRole('checkbox', { name: 'Automatically compact context', exact: true }).uncheck();
        await panel.getByRole('button', { name: 'Save context settings', exact: true }).click();
        await panel.getByRole('button', { name: 'Load context status', exact: true }).waitFor({ timeout: 60_000 });
        const text = await readFile(config, 'utf8'); assert.ok(text.includes('auto_compact = false'));
        console.log(`PASS: ${vsix ? 'VSIX webview' : 'native Workbench with extensions disabled'}, actual context status/permissions, scoped project and user instructions, extractive/model checkpoints, original-message evidence and settings`);
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
    if (userContextRoot) { await rm(userContextRoot, { recursive: true, force: true }); }
}
