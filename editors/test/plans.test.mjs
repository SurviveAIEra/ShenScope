import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {CoreClient} from '../dist/rpcClient.mjs';

async function until(predicate,timeout=120_000){const deadline=Date.now()+timeout;while(!predicate()){if(Date.now()>=deadline){throw new Error('Agent mode fixture timed out');}await new Promise(resolve=>setTimeout(resolve,25));}}
test('Persisted chat modes and reported plans remain owning and language independent',{timeout:240_000},async()=>{
    const root=await mkdtemp(join(tmpdir(),'shenscope-plan-client-'));const project=resolve(new URL('../../',import.meta.url).pathname);
    const config=join(root,'config.toml');const script=join(root,'script.json');
    await writeFile(config,"[permissions]\nread='allow'\nedit='allow'\npersistence='allow'\nnetwork='deny'\n");
    await writeFile(join(root,'calc.py'),'def add(a,b): return a+b\n');
    const step=(id,dependencies=[])=>({id,text:id,status:'pending',dependencies,note:'',citations:[]});
    await writeFile(script,JSON.stringify([
        {calls:[{name:'read',arguments:{path:'calc.py'}},{name:'plan',arguments:{action:'replace',title:'Review Python project',expected_revision:0,steps:[step('inspect'),step('verify',['inspect'])]}},{name:'write',arguments:{path:'forbidden.txt',content:'no'}}]},
        {text:'Review ready'},
        {calls:[{name:'write',arguments:{path:'approved.txt',content:'Approved change'}}]},
        {text:'Change recorded'}]));
    const start=()=>new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,
        env:{...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'},
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--','serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',config,'--script',script]});
    let client=start();const events=[];client.onNotification(event=>events.push(event));
    try{
        const hello=await client.start();assert.equal(hello.capabilities.conversation_plans,true);
        const owner=await client.request('sessions/create',{title:'Python review'});const other=await client.request('sessions/create',{title:'Other project'});
        const selected=await client.request('sessions/mode',{session_id:owner.id,action:'set',mode:'plan',expected_revision:0});assert.equal(selected.committed,true);
        await assert.rejects(client.request('sessions/mode',{session_id:owner.id,action:'set',mode:'act',expected_revision:0}),/revision changed/);
        await client.request('agent/start',{session_id:owner.id,prompt:'Inspect and plan'});
        await until(()=>events.some(event=>['session_completed','session_error'].includes(event.params?.kind)));
        assert.equal(events.find(event=>['session_completed','session_error'].includes(event.params?.kind)).params.kind,'session_completed');
        const plan=await client.request('plans/query',{session_id:owner.id});assert.equal(plan.revision,1);assert.equal(plan.plan.title,'Review Python project');
        assert.equal(plan.summary.progress_independently_verified,false);assert.equal(plan.summary.automatic_execution,false);
        assert.equal((await client.request('plans/query',{session_id:other.id})).plan,null);assert.equal((await client.request('sessions/mode',{session_id:other.id})).mode,'act');
        await assert.rejects(readFile(join(root,'forbidden.txt')),{code:'ENOENT'});
        await writeFile(script,JSON.stringify([{calls:[{name:'write',arguments:{path:'approved.txt',content:'Approved change'}}]},{text:'Change recorded'}]));
        const mark=events.length;await client.request('sessions/mode',{session_id:owner.id,action:'set',mode:'act',expected_revision:1});
        await client.request('agent/start',{session_id:owner.id,prompt:'Apply the approved change'});
        await until(()=>events.slice(mark).some(event=>['session_completed','session_error'].includes(event.params?.kind)));
        assert.equal(events.slice(mark).find(event=>['session_completed','session_error'].includes(event.params?.kind)).params.kind,'session_completed');
        assert.equal(await readFile(join(root,'approved.txt'),'utf8'),'Approved change');
        await client.dispose();client=start();await client.start();
        assert.equal((await client.request('sessions/mode',{session_id:owner.id})).mode,'act');
        assert.equal((await client.request('plans/query',{session_id:owner.id})).plan.sha256,plan.plan.sha256);
        assert.equal((await client.request('plans/history',{session_id:owner.id})).items.length,1);
        const snapshot=await client.request('config/get');snapshot.value.permissions.read='deny';await client.request('config/set',{value:snapshot.value,expected_sha256:snapshot.sha256});
        await assert.rejects(client.request('plans/query',{session_id:owner.id}),/Read Allow/);
        assert.ok(!(await client.request('sessions/get',{session_id:owner.id})).metadata.work_plan);
    }finally{await client.dispose();await rm(root,{recursive:true,force:true});}
});
