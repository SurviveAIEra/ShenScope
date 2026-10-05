import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {transform} from 'esbuild';
import {CoreClient} from '../dist/rpcClient.mjs';

const code=await transform(await readFile(new URL('../shared/src/nativeProblemsClient.ts',import.meta.url),'utf8'),{loader:'ts',format:'esm'});
const {CoreProblemsPublisher}=await import('data:text/javascript;base64,'+Buffer.from(code.code).toString('base64'));
const sha=value=>createHash('sha256').update(value).digest('hex');
async function waitJob(client,owner,id){
    const deadline=Date.now()+120_000;
    while(Date.now()<deadline){
        const job=await client.request('validation/job',{session_id:owner,job_id:id});
        if(job.status!=='running'){return job;}
        await new Promise(resolve=>setTimeout(resolve,25));
    }
    throw new Error('SARIF import did not complete');
}

test('Actual Core SARIF import publishes owned Problems and withdraws changed buffers and revoked reads',{timeout:240_000},async()=>{
    const root=await mkdtemp(join(tmpdir(),'shenscope-problems-'));const project=resolve(new URL('../../',import.meta.url).pathname);
    const text='a😀中b\r\n';const config=join(root,'config.toml');
    await writeFile(config,"[permissions]\nread='allow'\nprocess='deny'\nnetwork='deny'\ndynamic='deny'\npersistence='deny'\n");
    await writeFile(join(root,'sample.py'),text);
    const report=JSON.stringify({version:'2.1.0',runs:[{tool:{driver:{name:'fixture-checker',rules:[{id:'R1'}]}},results:[
        {ruleId:'R1',level:'warning',message:{text:'Check this Unicode range'},locations:[{physicalLocation:{artifactLocation:{uri:'sample.py'},
            region:{startLine:1,startColumn:2,endColumn:5}}}],fixes:[{description:{text:'Do not execute this fix'}}]}]}]});
    await writeFile(join(root,'check.sarif'),report);
    const env={...process.env,JULIA_DEPOT_PATH:process.env.JULIA_DEPOT_PATH||'/workspace/julia-depot'};delete env.NODE_TEST_CONTEXT;
    const client=new CoreClient({executable:process.env.SHENSCOPE_JULIA||'/workspace/toolchains/julia-1.11.7/bin/julia',cwd:root,env,
        args:['--startup-file=no','--threads=4',`--project=${project}`,'-e','using ShenScope;exit(ShenScope.main())','--','serve','--stdio','--root',root,'--state-dir',join(root,'state'),'--config',config]});
    let publisher;let displayed=[];let buffer=text;const methods=[];
    try{
        const hello=await client.start();const owner=(await client.request('sessions/create')).id;const foreign=(await client.request('sessions/create')).id;
        const started=await client.request('validation/start',{session_id:owner,action:'import_sarif',path:'check.sarif',expected_report_sha256:sha(report),
            source_versions:[{path:'sample.py',expected_sha256:sha(text)}]});
        const imported=await waitJob(client,owner,started.job_id);assert.equal(imported.status,'complete',JSON.stringify(imported));
        assert.equal(imported.metadata.explicit_command_execution,false);assert.equal(imported.result.commands_executed,false);
        assert.equal(imported.result.automatic_fix_execution,false);const snapshot=imported.result.problem_snapshot_id;
        const transport={request:(method,params)=>{methods.push(method);return client.request(method,params);}};
        publisher=new CoreProblemsPublisher(transport,{readSource:async()=>buffer,replace:files=>{displayed=files;},
            remove:path=>{displayed=path===undefined?[]:displayed.filter(file=>file.path!==path);}},sha(hello.root));
        assert.deepEqual(await publisher.publish({session_id:owner,snapshot_id:snapshot}),{files:1,markers:1,withheld_files:0});
        assert.equal(displayed[0].markers[0].range.end.character,4);
        await assert.rejects(publisher.publish({session_id:foreign,snapshot_id:snapshot}));assert.deepEqual(displayed,[]);
        await publisher.publish({session_id:owner,snapshot_id:snapshot});buffer+='unsaved';publisher.invalidate('sample.py');assert.deepEqual(displayed,[]);
        assert.equal((await publisher.publish({session_id:owner,snapshot_id:snapshot})).markers,0);
        buffer=text;await publisher.publish({session_id:owner,snapshot_id:snapshot});
        await writeFile(join(root,'sample.py'),'disk changed\n');publisher.invalidate('sample.py');assert.deepEqual(displayed,[]);
        assert.equal((await publisher.publish({session_id:owner,snapshot_id:snapshot})).markers,0);
        await writeFile(join(root,'sample.py'),text);await publisher.publish({session_id:owner,snapshot_id:snapshot});
        const before=await client.request('config/get');before.value.permissions.read='deny';
        await client.request('config/set',{value:before.value,expected_sha256:before.sha256});
        await assert.rejects(publisher.publish({session_id:owner,snapshot_id:snapshot}),/permission|approval/i);assert.deepEqual(displayed,[]);
        assert.ok(methods.every(method=>method==='problems/query'));assert.equal(await readFile(join(root,'check.sarif'),'utf8'),report);
    }finally{publisher?.dispose();await client.dispose();await rm(root,{recursive:true,force:true});}
});
