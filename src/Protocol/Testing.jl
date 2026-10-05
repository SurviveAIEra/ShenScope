server_testing_tool(server::CoreServer)=only(tool for tool in server.tools if tool isa TestingTool)

function testing_event_payload(server::CoreServer,event::AgentEvent,payload)
    job=event.kind in (:testing_job_completed,:testing_job_failed)
    tool=event.kind==:tool_completed && payload isa AbstractDict && get(payload,"name",nothing)=="testing"
    committed=event.kind==:testing_history_committed
    job || tool || committed || return payload
    owner=get(server.contexts,event.session_id,nothing)
    policy=owner===nothing ? permissions_from_config(server.config) : owner.permissions
    permission_decision(policy,PermissionRequest("testing-delivery",:read,"testing",server.root,"Deliver captured project test data"))==Deny || return payload
    committed && return Dict("evidence_hidden_by_permission"=>true)
    hidden=deepcopy(payload)
    if job
        hidden["result_hidden_by_permission"]=get(hidden,"result",nothing)!==nothing;hidden["result"]=nothing
        hidden["committed_effects"]=Any[];hidden["commit_evidence_hidden_by_permission"]=true
    else
        hidden["value"]=nothing;hidden["result_hidden_by_permission"]=true
    end
    hidden
end

function testing_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("testing/start","testing/query","testing/job","testing/cancel_job") || throw(RPCFault(-32601,"Unknown project testing method"))
    session=server_session(server,params);tool=server_testing_tool(server)
    prior=get(server.contexts,session.id,nothing)
    owner=prior===nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    if method in ("testing/job","testing/cancel_job")
        project_test_fields(params,["session_id","job_id"],"test job controller")
        view=owned_operation(tool.operations,params["job_id"],owner;cancel=method=="testing/cancel_job")
        if permission_decision(owner.permissions,PermissionRequest(
                "testing-job-read",:read,"testing",server.root,"Read test operation result"))!=Allow
            view["result_hidden_by_permission"]=view["result"]!==nothing;view["result"]=nothing
            view["committed_effects"]=Any[];view["commit_evidence_hidden_by_permission"]=true
        end
        return view
    end
    args=Dict{String,Any}(key=>value for (key,value) in params if key!="session_id")
    validate_tool_arguments(tool,args)
    if method=="testing/query"
        args["action"] in ("catalog","report","reports","source","history_list","history_get","history_source") || throw(RPCFault(-32602,"Use testing/start for discovery, execution or saved-history changes"))
        permission_decision(owner.permissions,PermissionRequest("testing-controller-read",:read,"testing",server.root,"Read owned test data"))==Allow ||
            throw(ShenScopeError(:permission,"Project test queries require current Read Allow"))
        query=child_context(owner)
        query.sink=event->event.kind in (:permission_request,:permission_resolved) ? nothing : owner.sink(event)
        query.approve=request->:deny
        if args["action"]=="catalog"
            catalog=owned_project_test_catalog(tool.manager,get(args,"catalog_id",""),owner)
            for marker in catalog.markers
                permission_decision(owner.permissions,PermissionRequest("testing-marker-read",:read,"testing",joinpath(server.root,marker.path),"Read retained test declaration"))==Allow ||
                    throw(ShenScopeError(:permission,"Use testing/start for a permissioned test catalog read"))
            end
        end
        # Source previews can have more specific path rules. Ask must use a job,
        # keeping the RPC reader available to deliver an approval response.
        if startswith(args["action"],"history_")
            store=project_test_history_store(owner)
            permission_decision(owner.permissions,PermissionRequest("testing-history-query",:read,"testing.history",
                project_test_history_target(store),"Read saved project test records"))==Allow ||
                throw(ShenScopeError(:permission,"Use testing/start for a permissioned saved test read"))
        end
        if args["action"] in ("source","history_source")
            report=args["action"]=="source" ? owned_project_test_report(tool.manager,get(args,"run_id",""),owner) :
                read_project_test_history(project_test_history_store(query),get(args,"run_id",""),query)["report"]
            frame=findfirst(value->value["id"]==get(args,"frame_id",""),report["parsed"]["frames"])
            frame===nothing && throw(ShenScopeError(:testing,"Unknown reported test frame"))
            path=joinpath(server.root,report["parsed"]["frames"][frame]["path"])
            permission_decision(owner.permissions,PermissionRequest("testing-source-read",:read,"testing",path,"Read referenced test source"))==Allow ||
                throw(ShenScopeError(:permission,"Use testing/start for a permissioned test source preview"))
        end
        return execute(tool,args,query)
    end
    idle_session(server,params)
    start_operation!(tool.operations,owner;kind=String(args["action"]),metadata=Dict(
        "explicit_command_execution"=>args["action"] in ("run","custom"),"automatic_replay"=>false)) do context
        execute(tool,args,context)
    end
end
