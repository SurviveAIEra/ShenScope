function agent_mode_document(session::Session;mode=AgentAct,revision=0,origin="default",created_at=nothing,parent_setting_sha256=nothing)
    body=Dict{String,Any}("schema"=>AGENT_MODE_SCHEMA,"session_id"=>session.id,"root_sha256"=>digest(session.root),
        "mode"=>agent_mode_name(parse_agent_mode(mode)),"revision"=>revision,"origin"=>origin,
        "created_at"=>created_at,"parent_setting_sha256"=>parent_setting_sha256)
    merge(body,Dict("sha256"=>digest(canonical(body))))
end

function agent_mode_setting(session::Session)
    lock(session.mutex) do
        value=get(session.metadata,"agent_mode",nothing)
        value===nothing && return agent_mode_document(session)
        agent_control_fields(value,["schema","session_id","root_sha256","mode","revision","origin",
            "created_at","parent_setting_sha256","sha256"],"agent mode setting")
        value["schema"]==AGENT_MODE_SCHEMA && value["session_id"]==session.id && value["root_sha256"]==digest(session.root) ||
            throw(ShenScopeError(:agent_mode,"Agent mode setting belongs to another conversation or schema"))
        parse_agent_mode(value["mode"])
        agent_control_integer(value["revision"],"mode revision",1,1_000_000)
        value["origin"] in ("controller","branch") || throw(ShenScopeError(:agent_mode,"Unknown mode-setting origin"))
        agent_control_text(value["created_at"],"mode timestamp",64)
        parent=value["parent_setting_sha256"]
        parent===nothing || agent_control_hash(parent,"parent mode setting")
        (value["origin"]=="branch")===(parent!==nothing) || throw(ShenScopeError(:agent_mode,"Mode ancestry changed"))
        agent_control_hash(value["sha256"],"mode setting hash")==digest(canonical(Dict(key=>item for (key,item) in value if key!="sha256"))) ||
            throw(ShenScopeError(:agent_mode,"Mode setting digest changed"))
        deepcopy(value)
    end
end

function agent_mode_view(session::Session)
    value=agent_mode_setting(session)
    merge(value,Dict("workspace_edit_tools_eligible"=>value["mode"]=="act","mode_relaxes_permissions"=>false,
        "plan_scope"=>"agent and inherited tasks; not an OS sandbox",
        "plan_disabled_categories"=>String.(AGENT_PLAN_DENIED_CATEGORIES)))
end

function set_agent_mode!(session::Session,ctx::RuntimeContext,mode;expected_revision)
    selected=parse_agent_mode(mode)
    expected=agent_control_integer(expected_revision,"expected mode revision",0,999_999)
    with_session_run_fence(session,ctx) do
        lock(session.mutex) do
            session.status==:running && throw(ShenScopeError(:session_busy,"Finish the active agent run before changing its mode"))
            previous=agent_mode_setting(session)
            previous["revision"]==expected || throw(ShenScopeError(:conflict,"Agent mode revision changed"))
            value=agent_mode_document(session;mode=selected,revision=expected+1,origin="controller",created_at=utcstamp())
            session_record!(session,"metadata",Dict("agent_mode"=>value))
            result=merge(agent_mode_view(session),Dict("committed"=>true,"notification_disrupted"=>false))
            try
                emit!(ctx,:agent_mode_changed,Dict("mode"=>value["mode"],"revision"=>value["revision"],"sha256"=>value["sha256"]))
            catch
                result["notification_disrupted"]=true
            end
            result
        end
    end
end

function branch_agent_mode!(parent::Session,child::Session)
    setting=agent_mode_setting(parent)
    setting["revision"]==0 && return
    value=agent_mode_document(child;mode=parse_agent_mode(setting["mode"]),revision=1,origin="branch",
        created_at=utcstamp(),parent_setting_sha256=setting["sha256"])
    session_record!(child,"metadata",Dict("agent_mode"=>value))
    nothing
end
