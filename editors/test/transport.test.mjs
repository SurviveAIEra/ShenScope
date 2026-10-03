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

test('Node editor transport talks to real Julia Core with scoped approvals and Unicode', { timeout: 120_000 }, async () => {
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
        assert.equal(hello.protocol_version, '1.0');
        const session = await client.request('sessions/create', { title: '中文对话' });
        await client.request('agent/start', { session_id: session.id, prompt: '写入文件' });
        await until(() => events.some(event => event.params?.kind === 'permission_request'));
        const approval = events.find(event => event.params?.kind === 'permission_request').params;
        await assert.rejects(client.request('permissions/respond', { session_id: 'foreign', request_id: approval.payload.id, decision: 'once' }), /another session/);
        await client.request('permissions/respond', { session_id: session.id, request_id: approval.payload.id, decision: 'once' });
        await until(() => events.some(event => event.params?.kind === 'session_completed'));
        assert.equal(await readFile(join(root, '中文.txt'), 'utf8'), 'permission verified');
        const saved = await client.request('sessions/get', { session_id: session.id });
        assert.equal(saved.status, 'complete');
        assert.equal(saved.messages.at(-1).text, '完成');
        await client.request('credentials/set', { variable: 'FIXTURE_EDITOR_KEY', value: 'fixture-editor-sensitive' });
        assert.equal((await client.request('credentials/status', { variable: 'FIXTURE_EDITOR_KEY' })).configured, true);
        assert.ok(!JSON.stringify(await client.request('config/get')).includes('fixture-editor-sensitive'));
        await assert.rejects(client.request('unknown/method'), /Method not found/);
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
