@testset "Parser transport bounds blocked pipes, failed framing and command approval" begin
    mktempdir() do root
        script=joinpath(root,"parser_fixture.py")
        write(script,raw"""
import json, os, subprocess, sys, time
if sys.argv[1] == 'blocked':
    time.sleep(3600)
for line in sys.stdin:
    req=json.loads(line); op=req['operation']; ident=req['id']
    if op == 'hold':
        open('waiting', 'w').close(); time.sleep(3600)
    elif op == 'bad-id': print(json.dumps({'id':True,'result':None}),flush=True)
    elif op == 'duplicate': print('{"id":%d,"id":%d,"result":null}'%(ident,ident),flush=True)
    elif op == 'deep': print('{"id":%d,"result":'%ident+'['*40+'0'+']'*40+'}',flush=True)
    elif op == 'partial': print('{"id":',end='',flush=True); sys.exit()
    elif op == 'invalid-error': print(json.dumps({'id':ident,'error':'wrong'}),flush=True)
    elif op == 'missing-result': print(json.dumps({'id':ident}),flush=True)
    elif op == 'reject': print(json.dumps({'id':ident,'error':{'message':'invalid source'}}),flush=True)
    elif op == 'stderr':
        sys.stderr.write('x'*200000);sys.stderr.flush()
        print(json.dumps({'id':ident,'result':{'ok':True}}),flush=True)
    elif op == 'descendant':
        child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(3600)'])
        print(json.dumps({'id':ident,'result':{'pid':child.pid}}),flush=True);sys.exit()
    else: print(json.dumps({'id':ident,'result':{'ok':True}}),flush=True)
""")
        make_worker(mode="ready")=ShenScope.BackendWorker(["python3","-u",script,mode])
        ctx=semantic_context(root)
        # Warm the actual transport before applying short I/O deadlines.
        worker=make_worker()
        try
            ShenScope.worker_start!(worker,ctx)
            @test ShenScope.worker_request(worker,"ok",Dict(),ctx)["ok"]
            @test semantic_error_code(()->ShenScope.worker_request(worker,"reject",Dict(),ctx))==:parse
            @test worker.process!==nothing && !process_exited(worker.process)
            @test ShenScope.worker_request(worker,"ok",Dict(),ctx)["ok"]
            @test ShenScope.worker_request(worker,"stderr",Dict(),ctx)["ok"]
            @test length(ShenScope.output_bytes(worker.diagnostics))<=64*1024
            original=copy(worker.argv);worker.argv[end]="changed"
            @test semantic_error_code(()->ShenScope.worker_start!(worker,ctx))==:backend
            @test semantic_error_code(()->ShenScope.worker_request(worker,"ok",Dict(),ctx))==:backend
            worker.argv=original
        finally;ShenScope.worker_close!(worker;force=true);end
        for operation in ("bad-id","duplicate","deep","partial","invalid-error","missing-result")
            worker=make_worker()
            try
                ShenScope.worker_start!(worker,ctx)
                @test semantic_error_code(()->ShenScope.worker_request(worker,operation,Dict(),ctx;timeout=5))==:backend
                @test worker.process===nothing && worker.reader===nothing
            finally;ShenScope.worker_close!(worker;force=true);end
        end
        worker=make_worker("blocked")
        try
            ShenScope.worker_start!(worker,ctx)
            started=time()
            @test semantic_error_code(()->ShenScope.worker_request(worker,"ok",Dict("payload"=>repeat("x",2*1024*1024)),ctx;timeout=0.35))==:timeout
            @test time()-started<5
            @test worker.process===nothing
        finally;ShenScope.worker_close!(worker;force=true);end
        for cause in (:cancel,:deny,:budget)
            isfile(joinpath(root,"waiting")) && rm(joinpath(root,"waiting"))
            attempt=semantic_context(root);worker=make_worker()
            try
                ShenScope.worker_start!(worker,attempt)
                task=@async semantic_error_code(()->ShenScope.worker_request(worker,"hold",Dict(),attempt;timeout=10))
                @test timedwait(()->isfile(joinpath(root,"waiting")),5;pollint=0.01)==:ok
                if cause==:cancel;cancel!(attempt.cancellation)
                elseif cause==:deny
                    lock(attempt.permissions.mutex) do;attempt.permissions.rules[:process]=Deny;end
                else
                    lock(attempt.budget.mutex) do;attempt.budget.started_ns=time_ns()-UInt64(4000*10^9);end
                end
                @test timedwait(()->istaskdone(task),5;pollint=0.01)==:ok
                @test fetch(task)==(cause==:cancel ? :cancelled : cause==:deny ? :permission : :budget)
                @test worker.process===nothing
            finally;ShenScope.worker_close!(worker;force=true);end
        end
        # Revocation or an argv substitution inside approval must precede spawn.
        for action in (:deny,:replace)
            worker=make_worker()
            guarded=RuntimeContext(root;state_dir=ctx.state_dir,approve=request->begin
                if action==:deny
                    lock(guarded.permissions.mutex) do;guarded.permissions.rules[:process]=Deny;end
                else;worker.argv[end]="changed";end
                :once
            end)
            @test semantic_error_code(()->ShenScope.worker_start!(worker,guarded))==:permission
            @test worker.process===nothing
        end
        missing=ShenScope.BackendWorker([joinpath(root,"absent-executable")])
        @test semantic_error_code(()->ShenScope.worker_start!(missing,ctx))==:backend
        if Sys.islinux()
            worker=make_worker();child=nothing
            try
                ShenScope.worker_start!(worker,ctx)
                child=ShenScope.worker_request(worker,"descendant",Dict(),ctx)["pid"]
            finally;ShenScope.worker_close!(worker;force=true);end
            dead()=!isfile("/proc/$child/stat") || occursin(r"\) Z ",read("/proc/$child/stat",String))
            @test timedwait(dead,5;pollint=0.01)==:ok
        end
    end
end
