@testset "Real PTY confirms controlling terminal, Unicode input, resize and scoped lifecycle" begin
    mktempdir() do root
        ctx=terminal_fixture(root);manager=TerminalManager()
        try
            handle=terminal_start!(manager,[TERMINAL_PYTHON,"-u","-c",TERMINAL_ECHO_PROGRAM],ctx;
                timeout=30,size=TerminalSize(25,91))
            @test terminal_wait_ready!(handle,ctx)["controlling_terminal_confirmed"]
            @test terminal_await_output(handle,"TTY_READY 19005b00")
            @test ShenScope.terminal_write!(handle,"中文🙂\n",ctx)["written_bytes"]==11
            @test terminal_await_output(handle,"ECHO:中文🙂")
            @test ShenScope.terminal_resize!(handle,TerminalSize(31,107),ctx)["rows"]==31
            @test terminal_await_output(handle,"RESIZED 1f006b00")
            foreign=terminal_fixture(root;owner="foreign")
            @test_throws ShenScopeError ShenScope.terminal_owned(manager,handle.id,foreign)
            @test_throws ShenScopeError execute(TerminalTool(manager),Dict("action"=>"poll","handle"=>handle.id),foreign)
            @test_throws ShenScopeError ShenScope.terminal_remove!(manager,handle.id,ctx)
            ShenScope.terminal_write!(handle,"exit\n",ctx)
            @test timedwait(()->istaskdone(handle.monitor),5;pollint=0.01)==:ok
            @test terminal_status(handle)["exit_code"]==0
            @test ShenScope.terminal_remove!(manager,handle.id,ctx)["removed"]
            @test isempty(manager.handles)
        finally
            cleanup_terminals!(manager;close_manager=true)
        end
        @test_throws ShenScopeError terminal_start!(manager,[TERMINAL_PYTHON,"-c","pass"],ctx)
    end
end

@testset "PTY foreground interrupt, inherited descriptors and grouped descendants are real" begin
    mktempdir() do root
        manager=TerminalManager();ctx=terminal_fixture(root)
        try
            checked=terminal_start!(manager,[TERMINAL_PYTHON,"-u","-c",
                "import os,time,signal;assert not signal.pthread_sigmask(signal.SIG_BLOCK,[]);print('FDS:'+','.join(sorted(os.listdir('/proc/self/fd'))),flush=True);time.sleep(30)"],ctx;timeout=20)
            terminal_wait_ready!(checked,ctx)
            @test terminal_await_output(checked,"FDS:0,1,2,3")
            @test ShenScope.terminal_interrupt!(checked,ctx)["foreground_group_verified"]
            @test timedwait(()->istaskdone(checked.monitor),5;pollint=0.01)==:ok
            @test terminal_status(checked)["exit_code"]!=0 && checked.endpoint.descriptor==-1
            forked=terminal_start!(manager,[TERMINAL_PYTHON,"-u","-c",
                "import os,time;child=os.fork();print('GROUP_CHILD:'+str(os.getpid()) if child==0 else 'GROUP_PARENT',flush=True);time.sleep(30)"],ctx;timeout=20)
            terminal_wait_ready!(forked,ctx)
            @test terminal_await_output(forked,"GROUP_CHILD:")
            output=terminal_page(forked.journal)["text"]
            pid=parse(Int,match(r"GROUP_CHILD:(\d+)",output).captures[1])
            cancel!(ctx.cancellation)
            @test timedwait(()->istaskdone(forked.monitor),5;pollint=0.01)==:ok
            @test !isfile("/proc/$pid/stat") || split(read("/proc/$pid/stat",String))[3]=="Z"
            @test forked.endpoint.descriptor==-1
        finally
            cleanup_terminals!(manager;close_manager=true)
        end
    end
end

@testset "Terminal capacity, restricted sandbox refusal and CLI use the owned runtime" begin
    mktempdir() do root
        ctx=terminal_fixture(root);manager=TerminalManager(;max_handles=1)
        try
            one=terminal_start!(manager,[TERMINAL_PYTHON,"-c","pass"],ctx;timeout=20)
            terminal_wait_ready!(one,ctx);wait(one.monitor)
            @test_throws ShenScopeError terminal_start!(manager,[TERMINAL_PYTHON],ctx)
            @test_throws ShenScopeError terminal_start!(manager,[TERMINAL_PYTHON],ctx;cwd="../")
            restricted=terminal_fixture(root;sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy()))
            @test_throws ShenScopeError terminal_start!(TerminalManager(),[TERMINAL_PYTHON],restricted)
            @test terminal_status(one)["sandbox"]=="host"
            config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\nprocess='allow'\npersistence='deny'\nnetwork='deny'\n")
            @test ShenScope.main(["terminal","run","--argv",canonical([TERMINAL_PYTHON,"-c","print('CLI PTY 中文')"]),
                "--root",root,"--config",config,"--state-dir",ctx.state_dir,"--json"] )==0
        finally
            cleanup_terminals!(manager;close_manager=true)
        end
    end
end

@testset "PTY short output, missing executable, live denial and timeout close descriptors" begin
    mktempdir() do root
        manager=TerminalManager();ctx=terminal_fixture(root)
        try
            quick=terminal_start!(manager,[TERMINAL_PYTHON,"-c","print('quick 中文')"],ctx;timeout=20)
            @test terminal_wait_ready!(quick,ctx)["controlling_terminal_confirmed"]
            wait(quick.monitor)
            @test occursin("quick 中文",terminal_page(quick.journal)["text"])
            @test quick.endpoint.descriptor==-1
            missing=terminal_start!(manager,["/no-such-shenscope-executable"],ctx;timeout=20)
            terminal_wait_ready!(missing,ctx);wait(missing.monitor)
            @test terminal_status(missing)["exit_code"]==127
            live=terminal_start!(manager,[TERMINAL_PYTHON,"-u","-c","import time;print('live',flush=True);time.sleep(30)"],ctx;timeout=20)
            terminal_wait_ready!(live,ctx);@test terminal_await_output(live,"live")
            ctx.permissions.rules[:process]=Deny
            @test timedwait(()->istaskdone(live.monitor),5;pollint=0.01)==:ok
            @test terminal_status(live)["permission_revoked"] && live.endpoint.descriptor==-1
            ctx.permissions.rules[:process]=Allow
            limited=terminal_start!(manager,[TERMINAL_PYTHON,"-c","import time;time.sleep(30)"],ctx;timeout=1.5)
            terminal_wait_ready!(limited,ctx);wait(limited.monitor)
            @test terminal_status(limited)["timed_out"] && limited.endpoint.descriptor==-1
            @test_throws ShenScopeError terminal_start!(manager,[TERMINAL_PYTHON],terminal_fixture(root;process=Deny))
        finally
            cleanup_terminals!(manager;close_manager=true)
        end
    end
end
