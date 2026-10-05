import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve,join } from 'node:path';
import { CoreClient } from '../dist/rpcClient.mjs';

test('Owned compiler and sampled runtime positions join hash-pinned Julia declarations', {timeout:240_000}, async () => {
    const root=await mkdtemp(join(tmpdir(),'shenscope-evidence-client-'));const project=resolve(new URL('../../',import.meta.url).pathname);
    await writeFile(join(root,'config.toml'),"[permissions]\nread='allow'\ndynamic='allow'\nprocess='allow'\npersistence='deny'\nnetwork='deny'\n");
    const client=new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,
        env:{...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'},
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--',
            'serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',join(root,'config.toml')]});
    async function job(session_id,args) {
        const started=await client.request('diagnostics/start',{session_id,...args});const deadline=Date.now()+120_000;
        for (;;) {
            const view=await client.request('diagnostics/job',{session_id,job_id:started.job_id});
            if(view.status!=='running'){assert.equal(view.status,'complete',view.error);return view;}
            if(Date.now()>=deadline){throw new Error('Evidence source job timed out');}await new Promise(resolve=>setTimeout(resolve,50));
        }
    }
    try {
        assert.equal((await client.start()).capabilities.runtime_evidence_association,true);
        const owner=await client.request('sessions/create',{title:'Runtime evidence'});const other=await client.request('sessions/create',{title:'Other owner'});
        const compiler=await job(owner.id,{action:'compile',target:'cliptext_string',mode:'graph',timeout:120});
        const profile=await job(owner.id,{action:'profile',target:'cliptext_string',iterations:2,repetitions:1,max_samples:8,max_frames:3,timeout:120});
        const args={compiler_job_id:compiler.job_id,profile_job_id:profile.job_id};
        const first=await client.request('diagnostics/query',{session_id:owner.id,action:'evidence',...args,limit:8});
        assert.equal(first.report_stamps.length,2);assert.ok(first.summary.observation_kinds.statement>40);assert.ok(first.summary.observation_kinds.allocation>=8);
        assert.equal(first.provider_stamps[0].provider,'julia_syntax');assert.equal(first.provider_stamps[0].source_evaluated,false);
        assert.equal(first.summary.allocation_observation_bytes_are_additive,false);assert.ok(!JSON.stringify(first).includes(project));
        const next=await client.request('diagnostics/query',{session_id:owner.id,action:'evidence',...args,limit:8,offset:first.next_offset,expected_evidence_sha256:first.evidence_sha256});
        assert.equal(next.evidence_sha256,first.evidence_sha256);assert.ok(!next.items.some(row=>first.items.some(prior=>prior.key===row.key)));
        const allocations=await client.request('diagnostics/query',{session_id:owner.id,action:'evidence',...args,limit:128,observation_kind:'allocation'});
        const row=allocations.items.find(item=>item.source.file);assert.ok(row);assert.equal(row.details.selected_target_binding_confirmed,false);
        const preview=await client.request('diagnostics/query',{session_id:owner.id,action:'evidence_source',...args,
            observation_key:row.key,expected_evidence_sha256:first.evidence_sha256,context_lines:2});
        assert.equal(preview.source_sha256,row.source.source_sha256);assert.equal(preview.observation_kind,'allocation');
        assert.equal(preview.lines.filter(line=>line.focus).length,1);
        await assert.rejects(client.request('diagnostics/query',{session_id:other.id,action:'evidence',...args}),/another/);
        await assert.rejects(client.request('diagnostics/query',{session_id:owner.id,action:'evidence',...args,expected_evidence_sha256:'0'.repeat(64)}),/changed/);
        await assert.rejects(client.request('diagnostics/query',{session_id:owner.id,action:'evidence_source',...args,observation_key:'0'.repeat(64),expected_evidence_sha256:first.evidence_sha256}),/absent/);
        await assert.rejects(client.request('diagnostics/query',{session_id:owner.id,action:'evidence',...args,file:'src/Core/Types.jl'}),/unknown field/i);
    } finally {await client.dispose();await rm(root,{recursive:true,force:true});}
});
