mutable struct Session
    id::String
    root::String
    title::String
    status::Symbol
    messages::Vector{Message}
    usage::Vector{Usage}
    metadata::Dict{String,Any}
    revision::Int
    journal::Journal
    mutex::ReentrantLock
end

function new_session(ctx::RuntimeContext;title="New conversation",parent=nothing)
    path = joinpath(ctx.state_dir,"sessions",valid_id(ctx.session_id)*".jsonl")
    isfile(path) && throw(ShenScopeError(:conflict,"Session already exists"))
    j = Journal(path)
    record = Dict("kind"=>"created","id"=>ctx.session_id,"root"=>ctx.root,
        "title"=>String(title),"timestamp"=>utcstamp(),"parent"=>parent)
    rev = append_record!(j,record;expected_revision=0)
    return Session(ctx.session_id,ctx.root,String(title),:idle,Message[],Usage[],
        Dict("created"=>record["timestamp"],"parent"=>parent),rev,j,ReentrantLock())
end

function load_session(state_dir::AbstractString,id::AbstractString)
    j = Journal(joinpath(state_dir,"sessions",valid_id(id)*".jsonl"))
    records = journal_records(j)
    isempty(records) && throw(ShenScopeError(:session,"Session not found"))
    firstrec = first(records)
    get(firstrec,"kind",nothing)=="created" || throw(ShenScopeError(:storage,"Missing session header"))
    session = Session(String(id),firstrec["root"],firstrec["title"],:idle,Message[],Usage[],
        Dict("created"=>firstrec["timestamp"],"parent"=>get(firstrec,"parent",nothing)),
        length(records),j,ReentrantLock())
    for rec in records[2:end]
        kind = rec["kind"]
        if kind=="message"
            push!(session.messages,message_from_dict(rec["value"]))
        elseif kind=="usage"
            d = rec["value"]
            push!(session.usage,Usage(;input_tokens=d["input_tokens"],output_tokens=d["output_tokens"],
                cached_tokens=d["cached_tokens"],cost=d["cost"],source=Symbol(d["source"])))
        elseif kind=="status"
            session.status = Symbol(rec["value"])
        elseif kind=="rename"
            session.title = rec["value"]
        elseif kind=="metadata"
            merge!(session.metadata,rec["value"])
        else
            throw(ShenScopeError(:storage,"Unsupported session event"))
        end
        session.metadata["updated"]=rec["timestamp"]
    end
    session.status==:running && (session.status=:interrupted)
    return session
end

function session_record!(s::Session,kind::String,value)
    lock(s.mutex) do
        s.revision = append_record!(s.journal,Dict("kind"=>kind,"value"=>value,
            "timestamp"=>utcstamp());expected_revision=s.revision)
        s.metadata["updated"]=utcstamp()
        kind=="metadata" && merge!(s.metadata,value)
    end
end

function add_message!(s::Session,m::Message)
    lock(s.mutex) do
        session_record!(s,"message",message_dict(m))
        push!(s.messages,m)
    end
    return m
end
function set_status!(s::Session,status::Symbol)
    lock(s.mutex) do
        session_record!(s,"status",String(status));s.status=status
    end
end
function record_usage!(s::Session,u::Usage)
    lock(s.mutex) do
        session_record!(s,"usage",Dict("input_tokens"=>u.input_tokens,"output_tokens"=>u.output_tokens,
            "cached_tokens"=>u.cached_tokens,"cost"=>u.cost,"source"=>String(u.source)))
        push!(s.usage,u)
    end
end
function rename_session!(s::Session,title::AbstractString)
    isempty(strip(title)) && throw(ShenScopeError(:input,"Empty title"))
    ncodeunits(title)<=512 || throw(ShenScopeError(:input,"Title too long"))
    lock(s.mutex) do
        session_record!(s,"rename",String(title));s.title=String(title)
    end
end

function list_sessions(state_dir::AbstractString;search="",include_archived=false)
    path = joinpath(state_dir,"sessions")
    isdir(path) || return Dict{String,Any}[]
    result = Dict{String,Any}[]
    for f in readdir(path)
        endswith(f,".jsonl") || continue
        s = load_session(state_dir,first(splitext(f)))
        !include_archived && get(s.metadata,"archived",false) && continue
        occursin(lowercase(search),lowercase(s.title)) || continue
        push!(result,Dict("id"=>s.id,"title"=>s.title,"root"=>s.root,"status"=>String(s.status),
            "created"=>s.metadata["created"],"updated"=>get(s.metadata,"updated",s.metadata["created"]),
            "pinned"=>get(s.metadata,"pinned",false),"archived"=>get(s.metadata,"archived",false),
            "revision"=>s.revision,"messages"=>length(s.messages)))
    end
    return sort!(result;by=r->(r["pinned"],r["updated"]),rev=true)
end

function recover_tool_pairs!(s::Session)
    answered = Set(m.call_id for m in s.messages if m.role==:tool)
    for m in copy(s.messages), c in m.calls
        if !(c.id in answered)
            add_message!(s,Message(:tool,canonical(Dict("ok"=>false,"error"=>
                "Execution interrupted; effects unknown. Inspect state before retrying."));call_id=c.id))
            push!(answered,c.id)
        end
    end
end

function branch_session(s::Session,ctx::RuntimeContext; through=length(s.messages))
    0<=through<=length(s.messages) || throw(ShenScopeError(:input,"Invalid branch boundary"))
    child = new_session(ctx;title=s.title * " (branch)",parent=s.id)
    for m in s.messages[1:through]
        add_message!(child,m)
    end
    recover_tool_pairs!(child)
    return child
end
