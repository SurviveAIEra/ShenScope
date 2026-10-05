import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve,join } from 'node:path';
import { CoreClient } from '../dist/rpcClient.mjs';

async function until(predicate,timeout=120_000) {
    const deadline=Date.now()+timeout;
    while(!predicate()){if(Date.now()>=deadline){throw new Error('Sampling event timed out');}await new Promise(resolve=>setTimeout(resolve,25));}
}

test('Owned periodic sampling scopes approvals, cancellation and address-free measured backtraces',{timeout:180_000},async()=>{
    const root=await mkdtemp(join(tmpdir(),'shenscope-sampling-client-'));const project=resolve(new URL('../../',import.meta.url).pathname);
    await writeFile(join(root,'config.toml'),"[permissions]\nread='allow'\ndynamic='ask'\nprocess='ask'\npersistence='deny'\nnetwork='deny'\n");
    const client=new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,
        env:{...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'},
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--',
            'serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',join(root,'config.toml')]});
    const events=[];client.onNotification(event=>events.push(event));
    try {
        const hello=await client.start();assert.equal(hello.capabilities.compiler_periodic_sampling,true);
        const owner=await client.request('sessions/create',{title:'Sampling owner'});const other=await client.request('sessions/create',{title:'Other owner'});
        const start=()=>client.request('diagnostics/start',{session_id:owner.id,action:'sample',target:'cliptext_string',timeout:120,
            duration_seconds:0.1,max_samples:16,max_frames:3,buffer_words:4096});
        await assert.rejects(client.request('diagnostics/query',{session_id:owner.id,action:'sample',target:'cliptext_string'}),/diagnostics\/start/);
        await assert.rejects(client.request('diagnostics/start',{session_id:owner.id,action:'sample',target:'cliptext_string',sample_rate:1}),/parameter/);
        const cancelled=await start();await until(()=>events.some(event=>event.params?.kind==='permission_request'));
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
            assert.equal(approval.category,category);await client.request('permissions/respond',{session_id:owner.id,request_id:approval.id,decision:'once'});
        }
        await until(()=>events.some(event=>['diagnostics_job_completed','diagnostics_job_failed'].includes(event.params?.kind)&&event.params.payload.job_id===started.job_id));
        const job=await client.request('diagnostics/job',{session_id:owner.id,job_id:started.job_id});assert.equal(job.status,'complete',job.error);
        const report=job.result.report;assert.equal(report.schema,'shenscope.compiler-sampling/1');assert.equal(job.metadata.mode,'sampling');
        assert.equal(report.runtime.threads,1);assert.equal(job.result.execution.os_sandbox,false);assert.equal(report.runtime_execution_observed,true);
        assert.ok(report.sampling_summary.observed_backtraces>0);assert.ok(report.sampling_summary.backtraces_with_core_frames>0);
        assert.ok(report.samples.length<=16);assert.equal(report.sampling_summary.cpu_utilization_measured,false);
        assert.equal(report.buffer.metadata_exported,false);assert.ok(!JSON.stringify(report).includes(project));
        assert.deepEqual(report.run.output,report.warmup.output);
        assert.ok(report.sampling_summary.top_frames.every(frame=>frame.fraction_of_retained_backtraces>0&&frame.fraction_of_retained_backtraces<=1));
        assert.ok(report.measurement_notes.some(note=>note.includes('not CPU utilization')));
        await assert.rejects(client.request('diagnostics/query',{session_id:owner.id,action:'evidence',sampling_job_id:started.job_id,compiler_job_id:started.job_id}),/completed compiler/);
        const config=await client.request('config/get');config.value.permissions.read='deny';
        await client.request('config/set',{value:config.value,expected_sha256:config.sha256});
        await assert.rejects(client.request('diagnostics/job',{session_id:owner.id,job_id:started.job_id}),/retired/);
    } finally {await client.dispose();await rm(root,{recursive:true,force:true});}
});
