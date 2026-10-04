import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { CoreClient } from '../dist/rpcClient.mjs';

async function until(predicate, timeout = 30_000) {
    const end = Date.now() + timeout;
    while (!predicate()) {
        if (Date.now() >= end) { throw new Error('Expected event did not arrive'); }
        await new Promise(resolve => setTimeout(resolve, 25));
    }
}

test('Node editor transport talks to real Julia Core with scoped approvals and Unicode', { timeout: 240_000 }, async t => {
    const started = Date.now();
    const milestone = label => t.diagnostic(`${label}: ${Date.now() - started} ms`);
    const root = await mkdtemp(join(tmpdir(), 'shenscope-editor-'));
    const project = resolve('..');
    const script = join(root, 'script.json');
    await writeFile(script, JSON.stringify([
        { calls: [{ name: 'write', arguments: { path: '中文.txt', content: 'permission verified' } }] },
        { text: '完成' },
    ]));
    const client = new CoreClient({ executable: process.env.SHENSCOPE_JULIA || '/workspace/toolchains/julia-1.11.7/bin/julia',
        cwd: root, env: { ...process.env, JULIA_DEPOT_PATH: process.env.JULIA_DEPOT_PATH || '/workspace/julia-depot' },
        args: ['--startup-file=no', '--threads=4', `--project=${project}`, '-e', 'using ShenScope; exit(ShenScope.main())', '--',
            'serve', '--stdio', '--root', root, '--state-dir', join(root, 'state'), '--config', join(root, 'config.toml'), '--script', script] });
    const events = [];
    client.onNotification(event => events.push(event));
    try {
        const hello = await client.start();
        milestone('Core initialized');
        assert.equal(hello.protocol_version, '1.0');
        const session = await client.request('sessions/create', { title: '中文对话' });
        await client.request('agent/start', { session_id: session.id, prompt: '写入文件' });
        await until(() => events.some(event => event.params?.kind === 'permission_request'));
        const approval = events.find(event => event.params?.kind === 'permission_request').params;
        await assert.rejects(client.request('permissions/respond', { session_id: 'foreign', request_id: approval.payload.id, decision: 'once' }), /another session/);
        await client.request('permissions/respond', { session_id: session.id, request_id: approval.payload.id, decision: 'once' });
        milestone('Edit approved');
        await until(() => events.some(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'context.archive'));
        const archive = events.find(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'context.archive').params;
        assert.equal(archive.payload.category, 'persistence');
        assert.equal(archive.payload.target, `session:${session.id}`);
        await assert.rejects(client.request('permissions/respond', { session_id: 'foreign', request_id: archive.payload.id, decision: 'session' }), /another session/);
        await client.request('permissions/respond', { session_id: session.id, request_id: archive.payload.id, decision: 'session' });
        milestone('Archive approved');
        await until(() => events.some(event => event.params?.kind === 'session_completed'));
        assert.equal(await readFile(join(root, '中文.txt'), 'utf8'), 'permission verified');
        const saved = await client.request('sessions/get', { session_id: session.id });
        assert.equal(saved.status, 'complete');
        assert.equal(saved.messages.at(-1).text, '完成');
        const tool = saved.messages.find(message => message.role === 'tool');
        const hash = JSON.parse(tool.text).artifact_sha256;
        assert.match(hash, /^[0-9a-f]{64}$/);
        const artifact = JSON.parse(await readFile(join(root, 'state', 'outputs', session.id, `${hash}.json`), 'utf8'));
        assert.equal(artifact.ok, true);
        milestone('Conversation and artifact verified');
        await client.request('credentials/set', { variable: 'FIXTURE_EDITOR_KEY', value: 'fixture-editor-sensitive' });
        assert.equal((await client.request('credentials/status', { variable: 'FIXTURE_EDITOR_KEY' })).configured, true);
        assert.ok(!JSON.stringify(await client.request('config/get')).includes('fixture-editor-sensitive'));
        await assert.rejects(client.request('unknown/method'), /Method not found/);
    } finally { await client.dispose(); await rm(root, { recursive: true, force: true }); }
});

test('Julia source indexing and dispatch evidence travel through the real editor transport', { timeout: 180_000 }, async t => {
    const started = Date.now(); const milestone = label => t.diagnostic(`${label}: ${Date.now() - started} ms`);
    const root = await mkdtemp(join(tmpdir(), 'shenscope-julia-transport-'));
    const project = resolve(new URL('../../', import.meta.url).pathname);
    await writeFile(join(root, 'methods.jl'), 'module 中文\nf(x::Int,y)=x\nf(x,y::Int)=y\nend\n');
    await writeFile(join(root, 'config.toml'), "[permissions]\nread='allow'\npersistence='ask'\nprocess='deny'\nnetwork='deny'\n");
    const client = new CoreClient({ executable: process.env.SHENSCOPE_JULIA || '/workspace/toolchains/julia-1.11.7/bin/julia',
        cwd: root, env: { ...process.env, JULIA_DEPOT_PATH: '/workspace/julia-depot' },
        args: ['--startup-file=no', '--threads=4', `--project=${project}`, '-e', 'using ShenScope; exit(ShenScope.main())', '--',
            'serve', '--stdio', '--root', root, '--state-dir', join(root, 'state'), '--config', join(root, 'config.toml')] });
    const events = []; client.onNotification(event => events.push(event));
    try {
        await client.start();
        milestone('Julia Core initialized');
        const backends = await client.request('project/backends');
        milestone('Julia backend capabilities');
        const julia = backends.find(item => item.name === 'julia_syntax');
        assert.deepEqual(julia.languages, ['julia']); assert.equal(julia.types, false);
        const session = await client.request('sessions/create', { title: 'Julia project' });
        milestone('Julia conversation created');
        const job = await client.request('project/start', { session_id: session.id, backend: 'julia_syntax', action: 'build' });
        milestone('Julia index job started');
        await until(() => events.some(event => event.params?.kind === 'permission_request'), 60_000);
        const request = events.find(event => event.params?.kind === 'permission_request').params;
        assert.equal(request.payload.category, 'persistence');
        await client.request('permissions/respond', { session_id: session.id, request_id: request.payload.id, decision: 'session' });
        await until(() => events.some(event => event.params?.kind === 'project_completed'), 60_000);
        milestone('Julia index completed');
        assert.equal((await client.request('project/job', { session_id: session.id, job_id: job.job_id })).status, 'complete');
        const query = { session_id: session.id, backend: 'julia_syntax', action: 'julia_dispatch', query: '中文.f' };
        const result = await client.request('project/query', query);
        milestone('Julia dispatch queried');
        assert.equal(result.compiler_confirmed, false); assert.equal(result.source_evaluated, false);
        assert.equal(result.items[0].method_count, 2); assert.equal(result.items[0].pairs[0].classification, 'crossed_annotation_pattern');
        const method = result.items[0].methods[0];
        assert.equal(method.location.column_unit, 'utf8_byte');
        assert.equal(method.qualified_name, '中文.f');
        await writeFile(join(root, 'methods.jl'), 'f(x)=x\n');
        await assert.rejects(client.request('project/query', query), /changed|stale|Refresh/i);
        milestone('Julia stale evidence refused');
        assert.ok(events.filter(event => event.params?.kind === 'permission_request').every(event => event.params.payload.category === 'persistence'));
    } finally { await client.dispose(); await rm(root, { recursive: true, force: true }); }
});

test('Malformed child framing closes transport and rejects pending requests', async () => {
    const source = `process.stdin.once('data', () => { const body=JSON.stringify({jsonrpc:'2.0',id:1,result:{protocol_version:'1.0'}}); process.stdout.write('Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body); process.stdin.once('data',()=>process.stdout.write('Content-Length: 999999999\\r\\n\\r\\n')); });`;
    const client = new CoreClient({ executable: process.execPath, args: ['-e', source], cwd: process.cwd() });
    try {
        await client.start();
        await assert.rejects(client.request('health'), /exceeds limit/);
        await assert.rejects(client.request('health'), /unavailable/);
    } finally { await client.dispose(); }
});

test('Disposal terminates an owned child that ignores shutdown and SIGTERM', { timeout: 10_000 }, async () => {
    const source = `process.on('SIGTERM', () => {}); process.stdin.once('data', () => { const body=JSON.stringify({jsonrpc:'2.0',id:1,result:{protocol_version:'1.0'}}); process.stdout.write('Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body); }); setInterval(() => {}, 1000);`;
    const client = new CoreClient({ executable: process.execPath, args: ['-e', source], cwd: process.cwd() });
    await client.start();
    const started = Date.now(); await client.dispose();
    assert.ok(Date.now() - started < 7000, 'Owned process and pipes must be drained within the escalation bound');
    await assert.rejects(client.request('health'), /unavailable/);
});
