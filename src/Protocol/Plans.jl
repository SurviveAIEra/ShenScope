function plan_controller_context(server::CoreServer,id::String)
    prior=get(server.contexts,id,nothing)
    prior===nothing || iscancelled(prior.cancellation) ? server_context(server,id) : child_context(prior)
end

function plans_rpc(server::CoreServer,method::String,params::AbstractDict)
    if method=="sessions/mode"
        action=get(params,"action","get")
        action in ("get","set") || throw(RPCFault(-32602,"Mode action must be get or set"))
        fields=action=="set" ? ["session_id","action","mode","expected_revision"] :
            (haskey(params,"action") ? ["session_id","action"] : ["session_id"])
        agent_control_fields(params,fields,"mode controller")
        session=action=="get" ? server_session(server,params) : idle_session(server,params)
        action=="get" && return agent_mode_view(session)
        return set_agent_mode!(session,plan_controller_context(server,session.id),params["mode"];expected_revision=params["expected_revision"])
    end
    method in ("plans/query","plans/history") || throw(RPCFault(-32601,"Unknown conversation plan method"))
    fields=method=="plans/history" && haskey(params,"limit") ? ["session_id","limit"] : ["session_id"]
    agent_control_fields(params,fields,"plan controller")
    session=server_session(server,params);ctx=plan_controller_context(server,session.id)
    # Queries never block the RPC reader waiting for an approval it must itself
    # deliver. Ask/Deny requires a separate explicit policy choice by the user.
    request=PermissionRequest("plan-controller-read",:read,"agent.plan","session:"*session.id,"Read reported conversation plan")
    permission_decision(ctx.permissions,request)==Allow || throw(ShenScopeError(:permission,"Conversation plan queries require current Read Allow"))
    method=="plans/query" ? read_agent_plan(session,ctx) : agent_plan_history(session,ctx;limit=get(params,"limit",8))
end
