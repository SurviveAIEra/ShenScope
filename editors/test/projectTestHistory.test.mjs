import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {CoreClient} from '../dist/rpcClient.mjs';

async function until(check,timeout=120_000){const deadline=Date.now()+timeout;while(!await check()){if(Date.now()>deadline){throw new Error('Saved test fixture timed out');}await new Promise(resolve=>setTimeout(resolve,25));}}
test('Actual Core restart retains selected test evidence without process replay',{timeout:300_000},async()=>{
    const root=await mkdtemp(join(tmpdir(),'shenscope-saved-testing-'));const project=resolve(new URL('../../',import.meta.url).pathname);
    const config=join(root,'config.toml');await writeFile(config,"[permissions]\nread='allow'\nprocess='allow'\npersistence='ask'\nnetwork='deny'\n");
    await writeFile(join(root,'sample.py'),'assert 2+3 == 5\n');
    const env={...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'};delete env.NODE_TEST_CONTEXT;
    const options={executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,env,
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--','serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',config]};
    let client=new CoreClient(options);let events=[];let owner;let foreign;
    const listen=()=>client.onNotification(event=>events.push(event));listen();
    const query=(action,args={})=>client.request('testing/query',{session_id:owner,action,...args});
    async function job(job_id){let result;await until(async()=>{result=await client.request('testing/job',{session_id:owner,job_id});return result.status!=='running';});return result;}
    async function start(action,args={},approve=false){const baseline=events.length;const operation=await client.request('testing/start',{session_id:owner,action,...args});
        if(approve){await until(()=>events.slice(baseline).some(event=>event.params?.kind==='permission_request'));
            const request=events.slice(baseline).find(event=>event.params?.kind==='permission_request').params.payload;
            assert.equal(request.tool,'testing.history');assert.equal(request.category,'persistence');
            await client.request('permissions/respond',{session_id:owner,request_id:request.id,decision:'once'});}
        return job(operation.job_id);}
    try{
        const hello=await client.start();assert.equal(hello.capabilities.project_testing.saved_history_survives_restart,true);
        owner=(await client.request('sessions/create')).id;foreign=(await client.request('sessions/create')).id;
        const code='from pathlib import Path;p=Path("execution-count.txt");p.write_text(str(int(p.read_text())+1) if p.exists() else "1");print("sample.py:1:1: observed failure");raise SystemExit(1)';
        const executed=await start('custom',{argv:['python3','-c',code],label:'Observed failure'});
        assert.equal(executed.result.outcome,'command_failed');const report=executed.result;
        const saved=await start('history_save',{run_id:report.run_id,expected_revision:0},true);
        assert.equal(saved.status,'complete');assert.equal(saved.result.publication_committed,true);assert.equal(saved.committed_effects[0].kind,'testing.history');
        await assert.rejects(client.request('testing/query',{session_id:foreign,action:'history_get',run_id:report.run_id}),/absent/);
        await client.dispose();events=[];client=new CoreClient(options);listen();await client.start();
        assert.equal((await query('reports')).reports.length,0);
        const list=await query('history_list');assert.equal(list.total,1);assert.equal(list.revision,1);
        const loaded=await query('history_get',{run_id:report.run_id});assert.deepEqual(loaded.report,report);assert.equal(loaded.automatic_replay,false);
        const source=await query('history_source',{run_id:report.run_id,frame_id:report.parsed.frames[0].id});
        assert.equal(source.path,'sample.py');assert.equal(source.saved_history_revision,1);assert.equal(source.execution_source_snapshot_verified,false);
        const renamed=await start('history_label',{run_id:report.run_id,label:'Before repair',expected_revision:1},true);assert.equal(renamed.result.revision,2);
        const conflict=await start('history_delete',{run_id:report.run_id,expected_revision:1},true);assert.equal(conflict.error_code,'conflict');assert.deepEqual(conflict.committed_effects,[]);
        assert.equal((await query('history_get',{run_id:report.run_id})).entry.label,'Before repair');
        const deleted=await start('history_delete',{run_id:report.run_id,expected_revision:2},true);assert.equal(deleted.result.total,0);
        assert.equal(await readFile(join(root,'execution-count.txt'),'utf8'),'1');
    }finally{await client.dispose();await rm(root,{recursive:true,force:true});}
});
