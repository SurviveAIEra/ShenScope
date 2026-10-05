import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {transform} from 'esbuild';
const code = await transform(await readFile(new URL('../shared/src/nativeProblemsClient.ts', import.meta.url),'utf8'), {loader:'ts',format:'esm'});
const {CoreProblemsPublisher,problemSourceHash,validateProblemProjection,validateProblemSource} =
    await import('data:text/javascript;base64,'+Buffer.from(code.code).toString('base64'));
const text='a😀中b\r\n';const sourceHash=await problemSourceHash(text);const rootHash=await problemSourceHash('/workspace/fixture');
function projection() {
    return {schema:'shenscope.editor-problems/1',session_id:'owner',root_sha256:rootHash,snapshot_id:'snapshot',snapshot_sha256:'a'.repeat(64),
        column_unit:'utf16',line_base:0,requires_editor_buffer_hash_check:true,configuration_current:true,files:[
            {path:'sample.py',source_sha256:sourceHash,publishable:true,freshness:'current',markers:[
                {id:'b'.repeat(64),message:'Observed warning',source:'fixture',code:'R1',severity:'warning',
                    range:{start:{line:0,character:1},end:{line:0,character:4}}}]}]};
}
function fixture(request,readSource=async()=>text) {
    const changes=[];const removed=[];
    const publisher=new CoreProblemsPublisher({request}, {readSource,replace:files=>changes.push(files),remove:path=>removed.push(path)},rootHash);
    return {publisher,changes,removed};
}
test('Problems publication checks both Core projections and the current editor text',async()=>{
    const calls=[];const f=fixture(async(method,params)=>{calls.push({method,params});return projection();});
    const result=await f.publisher.publish({session_id:'owner',snapshot_id:'snapshot'});
    assert.deepEqual(result,{files:1,markers:1,withheld_files:0});assert.equal(calls.length,2);
    assert.equal(f.changes.length,1);assert.equal(f.changes[0][0].markers[0].range.start.character,1);
    assert.equal(f.publisher.busy,false);f.publisher.invalidate('sample.py');assert.equal(f.removed.at(-1),'sample.py');f.publisher.dispose();
});
test('Changed buffers withhold diagnostics without changing source or executing a fix',async()=>{
    const calls=[];const f=fixture(async(method)=>{calls.push(method);return projection();},async()=>text+'unsaved');
    assert.deepEqual(await f.publisher.publish({session_id:'owner',snapshot_id:'snapshot'}),{files:0,markers:0,withheld_files:1});
    assert.deepEqual(f.changes,[[]]);assert.deepEqual(calls,['problems/query','problems/query']);f.publisher.dispose();
});
test('Problems source identity, path and UTF-16 bounds are checked independently',()=>{
    for(const value of ['../outside.py','/tmp/a.py','a\\b.py','file:a.py','.git/config']){
        const data=projection();data.files[0].path=value;
        assert.throws(()=>validateProblemProjection(data,'owner',rootHash,'snapshot'));
    }
    assert.throws(()=>validateProblemProjection(projection(),'other',rootHash,'snapshot'));
    assert.throws(()=>validateProblemProjection(projection(),'owner','c'.repeat(64),'snapshot'));
    const data=projection();data.files.push(data.files[0]);assert.throws(()=>validateProblemProjection(data,'owner',rootHash,'snapshot'));
    const file=validateProblemProjection(projection(),'owner',rootHash,'snapshot')[0];
    file.markers[0].range.start.character=2;assert.throws(()=>validateProblemSource(file,text),/range/);
});
test('Read revocation before final publication clears owned markers and never replays capture',async()=>{
    let calls=0;const f=fixture(async()=>{if(++calls===2){throw new Error('read denied');}return projection();});
    await assert.rejects(f.publisher.publish({session_id:'owner',snapshot_id:'snapshot'}),/read denied/);
    assert.equal(calls,2);assert.equal(f.changes.length,0);assert.ok(f.removed.length>=2);f.publisher.dispose();
});
test('Buffer changes during asynchronous reads reject delayed publication',async()=>{
    let f;f=fixture(async()=>projection(),async()=>{f.publisher.invalidate('sample.py');return text;});
    await assert.rejects(f.publisher.publish({session_id:'owner',snapshot_id:'snapshot'}),/changed while publishing/);
    assert.equal(f.changes.length,0);f.publisher.dispose();
});
test('Cancellation before capture acknowledgement cancels the owned job after it arrives',async()=>{
    let resolve;const started=new Promise(done=>{resolve=done;});const calls=[];
    const f=fixture(async(method,params)=>{calls.push({method,params});return method==='problems/start'?started:{};});
    const pending=f.publisher.publish({session_id:'owner',backend:'typescript'});f.publisher.invalidate();resolve({job_id:'job'});
    await assert.rejects(pending,/changed while publishing/);
    assert.ok(calls.some(call=>call.method==='problems/cancel'&&call.params.job_id==='job'));
    assert.equal(calls.filter(call=>call.method==='problems/start').length,1);assert.equal(f.changes.length,0);f.publisher.dispose();
});
test('Unavailable files are withheld while valid diagnostics can still publish',async()=>{
    const data=projection();data.files.push({...structuredClone(data.files[0]),path:'missing.py'});
    const f=fixture(async()=>data,async path=>{if(path==='missing.py'){throw new Error('missing');}return text;});
    assert.deepEqual(await f.publisher.publish({session_id:'owner',snapshot_id:'snapshot'}),{files:1,markers:1,withheld_files:1});f.publisher.dispose();
});
test('Stale configuration and source reports publish an empty owned collection',async()=>{
    const data=projection();data.configuration_current=false;const f=fixture(async()=>data);
    assert.equal((await f.publisher.publish({session_id:'owner',snapshot_id:'snapshot'})).markers,0);assert.deepEqual(f.changes,[[]]);f.publisher.dispose();
});
