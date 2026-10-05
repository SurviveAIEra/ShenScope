import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { CoreClient } from '../dist/rpcClient.mjs';

async function until(predicate, timeout = 60_000) {
    const deadline = Date.now() + timeout;
    while (!predicate()) {
        if (Date.now() >= deadline) { throw new Error('Compiler event did not arrive'); }
        await new Promise(resolve => setTimeout(resolve, 25));
    }
}

test('Real compiler RPC scopes approvals, cancellation and inferred graph evidence', { timeout: 180_000 }, async t => {
    const root = await mkdtemp(join(tmpdir(), 'shenscope-compiler-editor-'));
    const project = resolve(new URL('../../', import.meta.url).pathname);
    await writeFile(join(root, 'config.toml'), "[permissions]\nread='allow'\ndynamic='ask'\nprocess='ask'\npersistence='ask'\nnetwork='deny'\n");
    const client = new CoreClient({ executable: process.env.SHENSCOPE_JULIA || '/workspace/toolchains/julia-1.11.7/bin/julia',
        cwd: root, env: { ...process.env, JULIA_DEPOT_PATH: process.env.JULIA_DEPOT_PATH || '/workspace/julia-depot' },
        args: ['--startup-file=no', '--threads=4', `--project=${project}`, '-e', 'using ShenScope;exit(ShenScope.main())', '--',
            'serve', '--stdio', '--root', root, '--state-dir', join(root, 'state'), '--config', join(root, 'config.toml')] });
    const events = []; client.onNotification(event => events.push(event));
    try {
        const hello = await client.start(); assert.equal(hello.capabilities.structured_compiler_ir, true);
        const owner = await client.request('sessions/create', { title: 'Compiler owner' });
        const other = await client.request('sessions/create', { title: 'Foreign conversation' });
        const targets = await client.request('diagnostics/query', { session_id: owner.id, action: 'targets' });
        assert.ok(targets.some(target => target.name === 'cliptext_string'));
        await assert.rejects(client.request('diagnostics/start', { session_id: owner.id, action: 'compile', target: 'Base.eval' }));
        await assert.rejects(client.request('diagnostics/query', { session_id: owner.id, action: 'compile', target: 'cliptext_string' }), /diagnostics\/start/);
        const start = () => client.request('diagnostics/start', { session_id: owner.id, action: 'compile', target: 'cliptext_string', mode: 'graph', timeout: 120 });
        const cancelled = await start();
        await until(() => events.some(event => event.params?.kind === 'permission_request'));
        const pending = events.find(event => event.params?.kind === 'permission_request').params.payload;
        await assert.rejects(client.request('diagnostics/job', { session_id: other.id, job_id: cancelled.job_id }), /another/);
        await assert.rejects(client.request('permissions/respond', { session_id: other.id, request_id: pending.id, decision: 'once' }), /another/);
        await assert.rejects(client.request('sessions/rename', { session_id: owner.id, title: 'Busy' }), /compiler|active|running|finish/i);
        await client.request('diagnostics/cancel_job', { session_id: owner.id, job_id: cancelled.job_id });
        await until(() => events.some(event => event.params?.kind === 'diagnostics_job_failed' && event.params.payload.job_id === cancelled.job_id));
        assert.equal((await client.request('diagnostics/job', { session_id: owner.id, job_id: cancelled.job_id })).status, 'cancelled');
        await assert.rejects(client.request('permissions/respond', { session_id: owner.id, request_id: pending.id, decision: 'once' }));
        const mark = events.length; const started = await start();
        for (const [tool, category] of [['runtime.diagnostics', 'dynamic'], ['project.backend', 'process']]) {
            await until(() => events.slice(mark).some(event => event.params?.kind === 'permission_request' && event.params.payload.tool === tool));
            const approval = events.slice(mark).find(event => event.params?.kind === 'permission_request' && event.params.payload.tool === tool).params.payload;
            assert.equal(approval.category, category);
            await client.request('permissions/respond', { session_id: owner.id, request_id: approval.id, decision: 'once' });
        }
        await until(() => events.some(event => event.params?.kind === 'diagnostics_job_completed' && event.params.payload.job_id === started.job_id), 120_000);
        const job = await client.request('diagnostics/job', { session_id: owner.id, job_id: started.job_id });
        assert.equal(job.status, 'complete');
        const report = job.result.report;
        assert.equal(report.schema, 'shenscope.compiler-ir/1');
        assert.match(report.report_sha256, /^[0-9a-f]{64}$/);
        assert.match(report.source.fingerprint, /^[0-9a-f]{64}$/);
        assert.equal(report.methods[0].return_type.type, 'String');
        assert.ok(report.methods[0].control_flow.blocks.length > 1);
        assert.equal(report.methods[0].runtime_execution_observed, false);
        assert.equal(report.effects.safety_boundary, false);
        assert.equal(job.result.execution.separate_process, true);
        assert.equal(job.result.execution.os_sandbox, false);
        assert.ok(report.methods[0].statements.length > 40);
        assert.equal(hello.capabilities.compiler_report_archives, true);
        const query = args => client.request('diagnostics/query', { session_id: owner.id, ...args });
        const catalog = await query({ action: 'archive_list' }); assert.equal(catalog.total, 0);
        await assert.rejects(query({ action: 'archive_save', job_id: started.job_id, expected_revision: 0 }), /diagnostics\/start/);
        await assert.rejects(query({ action: 'archive_list', job_id: started.job_id }), /parameter/i);
        async function archiveOperation(args, { approve = true, session = owner.id } = {}) {
            const mark = events.length;
            const job = await client.request('diagnostics/start', { session_id: session, ...args });
            if (approve) {
                await until(() => events.slice(mark).some(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'compiler.archive'));
                const permission = events.slice(mark).find(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'compiler.archive').params.payload;
                assert.equal(permission.category, 'persistence');
                await assert.rejects(client.request('permissions/respond', { session_id: other.id, request_id: permission.id, decision: 'once' }), /another/);
                await client.request('permissions/respond', { session_id: owner.id, request_id: permission.id, decision: 'once' });
            }
            await until(() => events.some(event => ['diagnostics_job_completed', 'diagnostics_job_failed'].includes(event.params?.kind) && event.params.payload.job_id === job.job_id));
            return client.request('diagnostics/job', { session_id: session, job_id: job.job_id });
        }
        const foreignSave = await archiveOperation({ action: 'archive_save', job_id: started.job_id, expected_revision: 0 }, { approve: false, session: other.id });
        assert.equal(foreignSave.status, 'failed'); assert.equal(foreignSave.error_code, 'permission');
        const saving = await client.request('diagnostics/start', { session_id: owner.id, action: 'archive_save', job_id: started.job_id, expected_revision: 0 });
        await until(() => events.some(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'compiler.archive'));
        await client.request('diagnostics/cancel_job', { session_id: owner.id, job_id: saving.job_id });
        await until(() => events.some(event => event.params?.kind === 'diagnostics_job_failed' && event.params.payload.job_id === saving.job_id));
        assert.equal((await query({ action: 'archive_list' })).total, 0);
        const saved = await archiveOperation({ action: 'archive_save', job_id: started.job_id, expected_revision: 0, title: 'Editor persisted inference 中文' });
        assert.equal(saved.status, 'complete'); assert.equal(saved.result.revision, 1);
        const opened = await query({ action: 'archive_get', report_id: report.report_sha256 });
        assert.deepEqual(opened.report, report); assert.equal(opened.source_currentness, 'not_checked'); assert.equal(opened.producer_authenticated, false);
        await assert.rejects(client.request('diagnostics/query', { session_id: other.id, action: 'archive_get', report_id: report.report_sha256 }), /conversation|archive/);
        const comparison = await query({ action: 'archive_compare', before_id: report.report_sha256, after_id: report.report_sha256 });
        assert.equal(comparison.changes_total, 0); assert.equal(comparison.performance_change_proven, false);
        const labelled = await archiveOperation({ action: 'archive_label', report_id: report.report_sha256, expected_revision: 1, title: 'Renamed evidence' });
        assert.equal(labelled.status, 'complete'); assert.equal(labelled.result.revision, 2);
        const stale = await archiveOperation({ action: 'archive_delete', report_id: report.report_sha256, expected_revision: 1 });
        assert.equal(stale.status, 'failed'); assert.equal(stale.error_code, 'conflict');
        const deleted = await archiveOperation({ action: 'archive_delete', report_id: report.report_sha256, expected_revision: 2 });
        assert.equal(deleted.result.revision, 3);
        const cleanup = await query({ action: 'archive_gc', dry_run: true, expected_revision: 3 });
        assert.equal(cleanup.items.length, 1); assert.equal(cleanup.deletes_referenced_reports, false);
        const cleaned = await archiveOperation({ action: 'archive_gc', dry_run: false, expected_revision: 3 });
        assert.equal(cleaned.status, 'complete'); assert.equal(cleaned.result.removed_assets, 1);
        assert.equal((await query({ action: 'archive_list' })).asset_bytes, 0);
        const configuration = await client.request('config/get');
        configuration.value.permissions.read = 'ask';
        await client.request('config/set', { value: configuration.value, expected_sha256: configuration.sha256 });
        await assert.rejects(query({ action: 'targets' }), /permissioned reads/);
        const readMark = events.length;
        const reading = await client.request('diagnostics/start', { session_id: owner.id, action: 'archive_list' });
        await until(() => events.slice(readMark).some(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'compiler.archive'));
        const readPermission = events.slice(readMark).find(event => event.params?.kind === 'permission_request' && event.params.payload.tool === 'compiler.archive').params.payload;
        assert.equal(readPermission.category, 'read');
        await client.request('permissions/respond', { session_id: owner.id, request_id: readPermission.id, decision: 'once' });
        await until(() => events.some(event => event.params?.kind === 'diagnostics_job_completed' && event.params.payload.job_id === reading.job_id));
        assert.equal((await client.request('diagnostics/job', { session_id: owner.id, job_id: reading.job_id })).result.total, 0);
        await assert.rejects(query({ action: 'archive_list' }), /permissioned reads/);
        t.diagnostic(`${report.methods[0].statements.length} actual statements, ${report.methods[0].control_flow.blocks.length} blocks`);
    } finally { await client.dispose(); await rm(root, { recursive: true, force: true }); }
});
