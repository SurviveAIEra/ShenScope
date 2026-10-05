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

test('Real PTY RPC keeps input, resize, replay and interruption in the owning conversation', {timeout:180_000}, async () => {
    const root=await mkdtemp(join(tmpdir(),'shenscope-terminal-editor-'));const project=resolve('..');
    await writeFile(join(root,'config.toml'),"[permissions]\nread='allow'\nprocess='ask'\npersistence='allow'\nnetwork='deny'\n");
    const client=new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,
        env:{...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'},
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--','serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',join(root,'config.toml')]});
    const events=[];client.onNotification(event=>events.push(event));
    try{
        const hello=await client.start();assert.equal(hello.capabilities.terminal_pty.host_pty_implemented,true);
        const owner=await client.request('sessions/create',{title:'PTY owner'});const foreign=await client.request('sessions/create',{title:'Other conversation'});
        const code="import os,sys,signal;assert os.isatty(0);print('PTY_NODE_READY',flush=True);signal.signal(signal.SIGWINCH,lambda *_:print('NODE_RESIZE',flush=True));[(print('NODE:'+line.strip(),flush=True)) for line in sys.stdin]";
        const start=await client.request('terminal/start',{session_id:owner.id,action:'start',argv:['python3','-u','-c',code],timeout:30});
        await until(()=>events.some(event=>event.params?.kind==='permission_request'&&event.params.payload.tool==='terminal.start'));
        const approval=events.find(event=>event.params?.kind==='permission_request'&&event.params.payload.tool==='terminal.start').params.payload;
        await assert.rejects(client.request('terminal/job',{session_id:foreign.id,job_id:start.job_id}),/another conversation/i);
        await client.request('permissions/respond',{session_id:owner.id,request_id:approval.id,decision:'once'});
        async function finished(job){let value;const end=Date.now()+30_000;do{value=await client.request('terminal/job',{session_id:owner.id,job_id:job});if(value.status!=='running'){assert.equal(value.status,'complete',value.error);return value.result;}await new Promise(resolve=>setTimeout(resolve,25));}while(Date.now()<end);throw new Error('PTY job timeout');}
        const terminal=await finished(start.job_id);assert.equal(terminal.controlling_terminal_confirmed,true);
        await assert.rejects(client.request('terminal/query',{session_id:foreign.id,action:'poll',handle:terminal.handle}),/another conversation/i);
        const write=await client.request('terminal/start',{session_id:owner.id,action:'write',handle:terminal.handle,input:'中文🙂\n'});
        await until(()=>events.some(event=>event.params?.kind==='permission_request'&&event.params.payload.tool==='terminal.write'));
        const input=events.find(event=>event.params?.kind==='permission_request'&&event.params.payload.tool==='terminal.write').params.payload;
        assert.equal(input.target,terminal.handle);
        await client.request('permissions/respond',{session_id:owner.id,request_id:input.id,decision:'session'});
        assert.equal((await finished(write.job_id)).written_bytes,11);
        const resize=await client.request('terminal/start',{session_id:owner.id,action:'resize',handle:terminal.handle,rows:33,columns:119});
        assert.equal((await finished(resize.job_id)).rows,33);
        let page;for(let attempt=0;attempt<100;attempt++){page=await client.request('terminal/query',{session_id:owner.id,action:'poll',handle:terminal.handle});if(page.output.text.includes('NODE:中文🙂')&&page.output.text.includes('NODE_RESIZE')){break;}await new Promise(resolve=>setTimeout(resolve,25));}
        assert.match(page.output.text,/NODE:中文🙂/);assert.match(page.output.text,/NODE_RESIZE/);
        const cursor=await client.request('terminal/query',{session_id:owner.id,action:'poll',handle:terminal.handle,offset:page.output.next_offset});assert.equal(cursor.output.text,'');
        const interrupt=await client.request('terminal/start',{session_id:owner.id,action:'interrupt',handle:terminal.handle});assert.equal((await finished(interrupt.job_id)).foreground_group_verified,true);
        await until(()=>events.some(event=>event.params?.kind==='terminal_exited'&&event.params.payload.handle===terminal.handle));
        const remove=await client.request('terminal/start',{session_id:owner.id,action:'remove',handle:terminal.handle});assert.equal((await finished(remove.job_id)).removed,true);
    }finally{await client.dispose();await rm(root,{recursive:true,force:true});}
});

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
        milestone('Conversation created');
        await client.request('agent/start', { session_id: session.id, prompt: '写入文件' });
        milestone('Agent request accepted');
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
        cwd: root, env: { ...process.env, JULIA_DEPOT_PATH: process.env.JULIA_DEPOT_PATH || '/workspace/julia-depot' },
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

test('Real editor transport combines parser evidence with pinned pagination and stale-source refusal', { timeout: 240_000 }, async t => {
    const started = Date.now();
    const milestone = label => t.diagnostic(`${label}: ${Date.now() - started} ms`);
    const root = await mkdtemp(join(tmpdir(), 'shenscope-evidence-editor-'));
    const project = resolve('..');
    await writeFile(join(root, 'sample.go'), 'package p\nfunc Greet() {}\n');
    await writeFile(join(root, 'sample_test.go'), 'package p\nfunc TestGreet() { Greet() }\n');
    await writeFile(join(root, 'config.toml'), '[permissions]\nread = "allow"\npersistence = "allow"\nprocess = "allow"\nnetwork = "deny"\n');
    const client = new CoreClient({ executable: process.env.SHENSCOPE_JULIA || '/workspace/toolchains/julia-1.11.7/bin/julia',
        cwd: root, env: { ...process.env, JULIA_DEPOT_PATH: process.env.JULIA_DEPOT_PATH || '/workspace/julia-depot' },
        args: ['--startup-file=no', '--threads=4', `--project=${project}`, '-e', 'using ShenScope; exit(ShenScope.main())', '--',
            'serve', '--stdio', '--root', root, '--state-dir', join(root, 'state'), '--config', join(root, 'config.toml')] });
    const events = []; client.onNotification(event => events.push(event));
    try {
        await client.start();
        milestone('Combined Core initialized');
        const session = await client.request('sessions/create', { title: 'Combined sources' });
        const foreign = await client.request('sessions/create', { title: 'Separate conversation' });
        const run = async args => {
            const job = await client.request('project/start', { session_id: session.id, ...args });
            milestone(`${args.backend || 'combined'} ${args.action} started`);
            await until(() => events.some(event => ['project_completed', 'project_failed'].includes(event.params?.kind)
                && event.params.payload.job_id === job.job_id), 120_000);
            await assert.rejects(client.request('project/job', { session_id: foreign.id, job_id: job.job_id }), /another conversation/i);
            const completed = await client.request('project/job', { session_id: session.id, job_id: job.job_id });
            milestone(`${args.backend || 'combined'} ${args.action} completed`);
            assert.equal(completed.status, 'complete', completed.error);
            return completed.result;
        };
        for (const backend of ['go_ast', 'tree_sitter']) { await run({ action: 'build', backend }); }
        const available = await client.request('project/query', { session_id: session.id, action: 'evidence_status' });
        assert.equal(available.sources.filter(source => source.indexed).length, 2);
        const args = { action: 'evidence_compare', backends: ['go_ast', 'tree_sitter'], limit: 1 };
        const first = await run(args);
        assert.equal(first.total, 2); assert.equal(first.items.length, 1); assert.equal(first.next_offset, 1);
        assert.equal(first.atomic_multi_source_transaction, false);
        const second = await run({ ...args, offset: first.next_offset, source_revisions: first.revision_vector,
            expected_evidence_fingerprint: first.fingerprint });
        assert.equal(second.next_offset, null); assert.notEqual(first.items[0].anchor.id, second.items[0].anchor.id);
        const tests = await run({ action: 'evidence_tests', backends: args.backends, paths: ['sample.go'] });
        assert.equal(tests.total, 2);
        assert.ok(tests.items.every(item => item.observation.symbol.name === 'TestGreet' && !item.runtime_coverage_confirmed));
        assert.ok(tests.items.every(item => item.steps.length > 0));
        await writeFile(join(root, 'sample.go'), 'package p\nfunc Greet(x int) {}\n');
        const stale = await client.request('project/start', { session_id: session.id, ...args });
        await until(() => events.some(event => event.params?.kind === 'project_failed' && event.params.payload.job_id === stale.job_id), 60_000);
        const failed = await client.request('project/job', { session_id: session.id, job_id: stale.job_id });
        assert.equal(failed.status, 'failed'); assert.match(failed.error, /changed|refresh/i);
        assert.equal(events.filter(event => event.params?.kind === 'permission_request').length, 0);
    } finally { await client.dispose(); await rm(root, { recursive: true, force: true }); }
});

test('Independent Julia extensions travel through real editor RPC with registry and generation guards', { timeout: 240_000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'shenscope-extension-editor-'));
    const project = resolve('..'); const packageName = 'ShenScopeLifecycleExample';
    const uuid = 'c4e77152-5e6f-480b-8a7a-9fc6f6d7f6f2';
    await writeFile(join(root, 'config.toml'), '[permissions]\nread="allow"\ndynamic="allow"\nprocess="allow"\npersistence="allow"\nnetwork="deny"\n');
    const client = new CoreClient({ executable: process.env.SHENSCOPE_JULIA || '/workspace/toolchains/julia-1.11.7/bin/julia', cwd: root,
        env: { ...process.env, JULIA_DEPOT_PATH: process.env.JULIA_DEPOT_PATH || '/workspace/julia-depot', JULIA_LOAD_PATH: `@:${join(project, 'test/fixtures/extensions/ShenScopeLifecycleExample')}:@stdlib` },
        args: ['--startup-file=no', '--threads=4', `--project=${project}`, '-e', 'using ShenScope; exit(ShenScope.main())', '--',
            'serve', '--stdio', '--root', root, '--state-dir', join(root, 'state'), '--config', join(root, 'config.toml')] });
    const events = []; client.onNotification(event => events.push(event));
    try {
        assert.equal((await client.start()).capabilities.julia_extension_lifecycle, true);
        const session = await client.request('sessions/create', { title: 'Independent extensions' });
        const foreign = await client.request('sessions/create', { title: 'Separate extension owner' });
        const run = async args => {
            const job = await client.request('extensions/start', { session_id: session.id, ...args });
            await until(() => events.some(event => ['extensions_job_completed', 'extensions_job_failed'].includes(event.params?.kind)
                && event.params.payload.job_id === job.job_id), 120_000);
            await assert.rejects(client.request('extensions/job', { session_id: foreign.id, job_id: job.job_id }), /another conversation/i);
            const done = await client.request('extensions/job', { session_id: session.id, job_id: job.job_id });
            assert.equal(done.status, 'complete', done.error); return done.result;
        };
        const receipt = await run({ action: 'inspect_package', package_name: packageName, uuid });
        assert.equal(receipt.all_package_sources_verified, false);
        const registered = await run({ action: 'load_package', package_name: packageName, uuid, version: receipt.version,
            entry_sha256: receipt.entry_sha256, project_sha256: receipt.project_sha256 });
        assert.equal(registered.phase, 'inactive');
        const active = await run({ action: 'activate', name: 'installed_example' });
        const schema = await run({ action: 'inspect_tool', name: 'installed_example', contribution: 'echo' });
        assert.equal(schema.registry_id, active.registry_id); assert.deepEqual(schema.schema.required, ['text']);
        const result = await run({ action: 'invoke', name: 'installed_example', contribution: 'echo',
            registry_id: schema.registry_id, generation: schema.generation, arguments: { text: '真实编辑器扩展' } });
        assert.equal(result.value.echo, '真实编辑器扩展');
        assert.equal((await run({ action: 'deactivate', name: 'installed_example' })).phase, 'inactive');
        assert.equal((await run({ action: 'remove', name: 'installed_example' })).julia_methods_unloaded, false);
        assert.equal((await client.request('extensions/query', { session_id: session.id })).extensions.length, 0);
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
