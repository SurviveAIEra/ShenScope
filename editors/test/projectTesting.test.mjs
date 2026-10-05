import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {CoreClient} from '../dist/rpcClient.mjs';

async function until(check, timeout=120_000) { const end=Date.now()+timeout; while (!await check()) { if(Date.now()>end){throw new Error('Project testing fixture timed out');} await new Promise(resolve=>setTimeout(resolve,25)); } }
test('Actual Core test discovery, scoped approvals, two project languages and current source receipts',{timeout:240_000},async()=>{
    const root=await mkdtemp(join(tmpdir(),'shenscope-testing-client-'));const project=resolve(new URL('../../',import.meta.url).pathname);const config=join(root,'config.toml');
    await writeFile(config,"[permissions]\nread='allow'\nprocess='ask'\npersistence='allow'\nnetwork='deny'\n");
    await writeFile(join(root,'pyproject.toml'),"[project]\nname='calc'\nversion='0.1.0'\n");
    await writeFile(join(root,'calc.py'),'def add(a,b): return a-b\n');
    await writeFile(join(root,'test_calc.py'),"import unittest\nfrom calc import add\nclass Addition(unittest.TestCase):\n    def test_add(self): self.assertEqual(add(2,3),5)\n");
    await writeFile(join(root,'package.json'),JSON.stringify({scripts:{test:'node --test --test-reporter=tap test_calc.mjs'}}));
    await writeFile(join(root,'test_calc.mjs'),"import {test} from 'node:test';\nimport assert from 'node:assert/strict';\ntest('addition',()=>assert.equal(2+3,5));\n");
    const environment={...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'};
    // Node's own test runner injects a binary child-reporter context. The Core
    // fixture must represent a normal client process so nested Node tests TAP.
    delete environment.NODE_TEST_CONTEXT;
    const client=new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,
        env:environment,
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--','serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',config]});
    const events=[];client.onNotification(event=>events.push(event));
    try {
        const hello=await client.start();assert.equal(hello.capabilities.project_testing.argument_vector_any_language,true);
        const owner=(await client.request('sessions/create')).id;const foreign=(await client.request('sessions/create')).id;
        const query=(action,args={})=>client.request('testing/query',{session_id:owner,action,...args});
        async function job(job_id) {let value;await until(async()=>{value=await client.request('testing/job',{session_id:owner,job_id});return value.status!=='running';});return value;}
        async function start(action,args={},decision) {
            const baseline=events.length;const result=await client.request('testing/start',{session_id:owner,action,...args});
            if(decision){await until(()=>events.slice(baseline).some(event=>event.params?.kind==='permission_request'));
                const approval=events.slice(baseline).find(event=>event.params?.kind==='permission_request').params.payload;
                assert.equal(approval.tool,'testing');assert.equal(approval.category,'process');
                await assert.rejects(client.request('permissions/respond',{session_id:foreign,request_id:approval.id,decision}),/another session/);
                await client.request('permissions/respond',{session_id:owner,request_id:approval.id,decision});}
            return job(result.job_id);
        }
        const discovered=await start('discover');assert.equal(discovered.status,'complete');assert.equal(discovered.result.candidates.length,2);
        assert.equal((await query('reports')).reports.length,0);
        const python=discovered.result.candidates.find(value=>value.framework==='unittest');
        const selected={catalog_id:discovered.result.catalog_id,candidate_id:python.id};
        const denied=await start('run',selected,'deny');assert.equal(denied.status,'failed');assert.equal((await query('reports')).reports.length,0);
        const failed=await start('run',selected,'once');assert.equal(failed.status,'complete');assert.equal(failed.result.outcome,'command_failed');
        assert.equal(failed.result.parsed.observed_case_counts.failed,1);
        await assert.rejects(client.request('testing/query',{session_id:foreign,action:'report',run_id:failed.result.run_id}),/another conversation/);
        const frame=failed.result.parsed.frames.find(value=>value.path==='test_calc.py');assert.ok(frame);
        const source=await query('source',{run_id:failed.result.run_id,frame_id:frame.id});assert.equal(source.execution_source_snapshot_verified,false);
        await writeFile(join(root,'test_calc.py'),await readFile(join(root,'test_calc.py'),'utf8')+'# changed after execution\n');
        await assert.rejects(query('source',{run_id:failed.result.run_id,frame_id:frame.id,expected_sha256:source.sha256}),/preview changed/);
        await writeFile(join(root,'calc.py'),'def add(a,b): return a+b\n');
        const repaired=await start('run',selected,'once');assert.equal(repaired.result.outcome,'command_succeeded');assert.equal(repaired.result.parsed.observed_case_counts.passed,1);
        const node=await start('custom',{argv:['node','--test','--test-reporter=tap','test_calc.mjs'],framework:'tap'},'once');
        assert.equal(node.result.exit_code,0);assert.equal(node.result.parsed.observed_case_counts.passed,1);assert.equal(node.result.parsed.complete_project_coverage,false);
        const baseline=events.length;const pending=await client.request('testing/start',{session_id:owner,action:'custom',argv:['python3','-c','print("must not run")']});
        await until(()=>events.slice(baseline).some(event=>event.params?.kind==='permission_request'));
        await client.request('testing/cancel_job',{session_id:owner,job_id:pending.job_id});assert.equal((await job(pending.job_id)).status,'cancelled');
        assert.equal((await client.request('health')).pending_approvals,0);assert.equal((await query('reports')).reports.length,3);
        const before=await client.request('config/get');before.value.permissions.read='deny';await client.request('config/set',{value:before.value,expected_sha256:before.sha256});
        await assert.rejects(query('report',{run_id:failed.result.run_id}),/Read Allow/);
    } finally {await client.dispose();await rm(root,{recursive:true,force:true});}
});
