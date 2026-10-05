import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {CoreClient} from '../dist/rpcClient.mjs';
import {CoreNativeTestingRunner} from '../dist/nativeTestingClient.mjs';

async function wait(check){const deadline=Date.now()+120_000;while(!await check()){if(Date.now()>deadline){throw new Error('Native testing fixture timed out');}await new Promise(resolve=>setTimeout(resolve,25));}}
class Cancellation {
    isCancellationRequested=false;listeners=new Set();
    onCancellationRequested(listener){this.listeners.add(listener);return {dispose:()=>this.listeners.delete(listener)};}
    cancel(){this.isCancellationRequested=true;for(const listener of this.listeners){listener();}}
}
test('Native testing adapter recovers a dropped start response and cancels pending approvals without replay',{timeout:360_000},async()=>{
    const root=await mkdtemp(join(tmpdir(),'shenscope-native-testing-client-'));const project=resolve(new URL('../../',import.meta.url).pathname);const config=join(root,'config.toml');
    await writeFile(config,"[permissions]\nread='allow'\nprocess='ask'\npersistence='allow'\nnetwork='deny'\n");
    await writeFile(join(root,'package.json'),JSON.stringify({scripts:{test:'node test-command.mjs'}}));
    await writeFile(join(root,'test-command.mjs'),"import {existsSync,readFileSync,writeFileSync} from 'node:fs';const path='execution-count.txt';writeFileSync(path,existsSync(path)?String(Number(readFileSync(path,'utf8'))+1):'1');console.log('observed command');\n");
    const env={...process.env,JULIA_DEPOT_PATH:'/workspace/julia-depot'};delete env.NODE_TEST_CONTEXT;
    const client=new CoreClient({executable:'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,env,
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--','serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',config]});
    try{
        await client.start();const session_id=(await client.request('sessions/create')).id;
        const discovery=await client.request('testing/start',{session_id,action:'discover'});let job;
        await wait(async()=>{job=await client.request('testing/job',{session_id,job_id:discovery.job_id});return job.status!=='running';});
        const catalog=await client.request('testing/query',{session_id,action:'editor_catalog',catalog_id:job.result.catalog_id});
        const ids=catalog.commands.map(command=>command.id);let starts=0;let lookups=0;const rows=[];const notices=[];
        const transport={createRequestId:randomUUID,observe:listener=>client.onNotification(event=>{
            if(event.method==='agent/event'&&event.params.kind==='testing_job_started'){return;}
            listener(event.method,event.params);
        }),
            request:async(method,params)=>{if(method==='testing/find_job'){lookups++;}const response=await client.request(method,params,120_000);if(method==='testing/start'&&++starts===1){throw new Error('Injected lost start response after Core admission');}return response;},
            approve:async request=>{assert.equal(request.category,'process');return 'once';}};
        const runner=new CoreNativeTestingRunner(transport,catalog);
        await runner.run(ids,new Cancellation(),{command:(id,row)=>rows.push(row),notice:text=>notices.push(text)});
        assert.equal(starts,1);assert.equal(lookups,1);assert.equal(rows.length,1);assert.equal(rows[0].result.state,'passed');assert.equal(await readFile(join(root,'execution-count.txt'),'utf8'),'1');
        assert.ok(notices.some(text=>text.includes('no command was replayed')));
        const token=new Cancellation();let approvalSeen=false;
        const cancelling=new CoreNativeTestingRunner({...transport,request:(method,params)=>client.request(method,params,120_000),approve:async(_request,signal)=>{
            approvalSeen=true;token.cancel();if(!signal.aborted){await new Promise(resolve=>signal.addEventListener('abort',resolve,{once:true}));}return 'deny';}},catalog);
        const cancelled=[];await cancelling.run(ids,token,{command:(id,row)=>cancelled.push(row),notice:()=>undefined});
        assert.ok(approvalSeen);assert.equal(await readFile(join(root,'execution-count.txt'),'utf8'),'1');assert.equal((await client.request('health')).pending_approvals,0);
        assert.equal(cancelled.length,1);assert.equal(cancelled[0].execution_receipt_available,false);
        let closedNotify;const uncertain=[];
        const closing=new CoreNativeTestingRunner({...transport,request:(method,params)=>client.request(method,params,120_000),
            observe:listener=>{closedNotify=listener;return transport.observe(listener);},approve:async()=>{
                closedNotify('transport/closed',{message:'Injected disconnect notification'});return 'deny';}},catalog);
        await closing.run(ids,new Cancellation(),{command:(_id,row)=>uncertain.push(row),notice:()=>undefined}).catch(()=>undefined);
        assert.equal(uncertain.length,1);assert.equal(uncertain[0].error.code,'unconfirmed');
        assert.equal(await readFile(join(root,'execution-count.txt'),'utf8'),'1');
        await wait(async()=>{const health=await client.request('health');return health.pending_approvals===0;});
        runner.dispose();cancelling.dispose();closing.dispose();
    }finally{await client.dispose();await rm(root,{recursive:true,force:true});}
});
