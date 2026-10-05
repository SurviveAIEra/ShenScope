# Disposable high-frequency Core workload. No process/model/network/user sources.
using ShenScope

mktempdir(;prefix="shenscope-image-workload-") do root
    config=joinpath(root,"config.toml")
    write(config,"[provider]\nendpoint='https://example.invalid'\nmodel='image-fixture'\n[permissions]\nread='allow'\nedit='allow'\npersistence='allow'\nprocess='deny'\nnetwork='deny'\ndynamic='deny'\n")
    server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
    try
        ShenScope.dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
        ShenScope.dispatch_rpc(server,"health",Dict())
        ShenScope.dispatch_rpc(server,"config/get",Dict())
        session=ShenScope.dispatch_rpc(server,"sessions/create",Dict("title"=>"Image metadata"))
        for method in ("models/query","memory/query","security/query","extensions/query")
            ShenScope.dispatch_rpc(server,method,Dict("session_id"=>session["id"]))
        end
        ShenScope.dispatch_rpc(server,"terminal/query",Dict("session_id"=>session["id"],"action"=>"list"))
        ctx=RuntimeContext(root;state_dir=joinpath(root,"agent-state"),permissions=PermissionPolicy(;
            rules=Dict(:read=>Allow,:edit=>Allow,:persistence=>Allow,:process=>Deny,:network=>Deny,:dynamic=>Deny)))
        scripted=MockProvider([ShenScope.response("";calls=[ToolCall("write",Dict("path"=>"fixture.txt","content"=>"precompile 中文"))]),ShenScope.response("Done.")])
        session=new_session(ctx)
        run_agent!(scripted,"Write the disposable fixture",ctx;session,tools=[WriteTool(),ReadTool()])
        write(joinpath(root,"methods.jl"),"module Fixture\nf(x::Int)=x\nf(x::String)=length(x)\nend\n")
        state=build!(JuliaSyntaxBackend(),ctx)
        for action in ("julia_methods","julia_dispatch","julia_structure")
            ShenScope.julia_project_query(state,Dict{String,Any}("action"=>action,"limit"=>20,"offset"=>0,"max_pairs"=>1000),ctx)
        end
        ShenScope.contract_report(TerminalTool)
    finally
        ShenScope.stop_server!(server)
    end
end
