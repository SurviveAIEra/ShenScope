import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve,join } from 'node:path';
import { CoreClient } from '../dist/rpcClient.mjs';

async function until(predicate,timeout=120_000) {
    const deadline=Date.now()+timeout;
    while(!predicate()) { if(Date.now()>=deadline){throw new Error('Runtime measurement event timed out');} await new Promise(resolve=>setTimeout(resolve,25)); }
}

test('Real owned profile jobs record bounded allocation evidence and scope approvals', {timeout:180_000}, async () => {
    const root=await mkdtemp(join(tmpdir(),'shenscope-profile-client-'));
    const project=resolve(new URL('../../',import.meta.url).pathname);
    await writeFile(join(root,'config.toml'),"[permissions]\nread='allow'\ndynamic='ask'\nprocess='ask'\npersistence='deny'\nnetwork='deny'\n");
    const client=new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,
        env:{...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'},
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--',
            'serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',join(root,'config.toml')]});
    const events=[];client.onNotification(event=>events.push(event));
    try {
        const hello=await client.start();assert.equal(hello.capabilities.compiler_runtime_profile,true);
        const owner=await client.request('sessions/create',{title:'Runtime owner'});
        const other=await client.request('sessions/create',{title:'Foreign owner'});
        const start=()=>client.request('diagnostics/start',{session_id:owner.id,action:'profile',target:'cliptext_string',timeout:120,
            iterations:2,repetitions:2,max_samples:16,max_frames:2,sample_rate:1});
        await assert.rejects(client.request('diagnostics/query',{session_id:owner.id,action:'profile',target:'cliptext_string'}),/diagnostics\/start/);
        await assert.rejects(client.request('diagnostics/start',{session_id:owner.id,action:'profile',target:'cliptext_string',mode:'graph'}),/parameter/);
        const cancelled=await start();
        await until(()=>events.some(event=>event.params?.kind==='permission_request'));
        const pending=events.find(event=>event.params?.kind==='permission_request').params.payload;
        await assert.rejects(client.request('diagnostics/job',{session_id:other.id,job_id:cancelled.job_id}),/another/);
        await assert.rejects(client.request('permissions/respond',{session_id:other.id,request_id:pending.id,decision:'once'}),/another/);
        await client.request('diagnostics/cancel_job',{session_id:owner.id,job_id:cancelled.job_id});
        await until(()=>events.some(event=>event.params?.kind==='diagnostics_job_failed'&&event.params.payload.job_id===cancelled.job_id));
        assert.equal((await client.request('diagnostics/job',{session_id:owner.id,job_id:cancelled.job_id})).status,'cancelled');
        const mark=events.length;const started=await start();
        for(const [tool,category] of [['runtime.diagnostics','dynamic'],['project.backend','process']]) {
            await until(()=>events.slice(mark).some(event=>event.params?.kind==='permission_request'&&event.params.payload.tool===tool));
            const approval=events.slice(mark).find(event=>event.params?.kind==='permission_request'&&event.params.payload.tool===tool).params.payload;
            assert.equal(approval.category,category);
            await client.request('permissions/respond',{session_id:owner.id,request_id:approval.id,decision:'once'});
        }
        await until(()=>events.some(event=>event.params?.kind==='diagnostics_job_completed'&&event.params.payload.job_id===started.job_id));
        const job=await client.request('diagnostics/job',{session_id:owner.id,job_id:started.job_id});assert.equal(job.status,'complete');
        const report=job.result.report;assert.equal(report.schema,'shenscope.compiler-profile/1');
        assert.equal(report.runtime_execution_observed,true);assert.equal(report.runtime.threads,1);
        assert.equal(job.result.execution.separate_process,true);assert.equal(job.result.execution.os_sandbox,false);
        assert.equal(report.timings.length,2);assert.ok(report.timings.every(row=>row.allocated_bytes>0&&row.seconds>=0));
        assert.deepEqual(report.warmup.output,report.sample_output);
        assert.equal(report.samples.length,16);assert.equal(report.allocation_summary.samples_truncated,true);
        assert.ok(report.allocation_summary.samples_with_core_frames>0);
        assert.equal(report.allocation_summary.instrumentation_pass_separate_from_timing,true);
        assert.equal(report.allocation_summary.external_paths_and_addresses_exposed,false);
        assert.ok(!JSON.stringify(report).includes(project));
        assert.ok(report.measurement_notes.some(note=>note.includes('need not equal')));
        const config=await client.request('config/get');config.value.permissions.read='deny';
        await client.request('config/set',{value:config.value,expected_sha256:config.sha256});
        await assert.rejects(client.request('diagnostics/job',{session_id:owner.id,job_id:started.job_id}),/retired/);
    } finally { await client.dispose();await rm(root,{recursive:true,force:true}); }
});
