struct MemoryTool <: AbstractTool
    manager::MemoryManager
end
MemoryTool()=MemoryTool(MemoryManager())
tool_name(::MemoryTool)="memory"
tool_description(::MemoryTool)="Retrieve bounded lexical memory with source/hash/version evidence, or explicitly persist CAS-guarded facts in independent scoped namespaces. Declared provenance does not establish truth."
execution_mode(::MemoryTool)=:exclusive

function tool_schema(::MemoryTool)
    strings=Dict("type"=>"array","maxItems"=>32,"items"=>string_schema(;max=128))
    object_schema(Dict("action"=>Dict("type"=>"string","enum"=>
        ["get","search","retrieve","list","status","namespaces","put","delete","history","export","import"]),
        "scope"=>Dict("type"=>"string","enum"=>["workspace","session","user"]),
        "namespace"=>string_schema(;max=64),"key"=>string_schema(;max=256),
        "query"=>string_schema(;max=4096),"content"=>string_schema(;max=65536),"title"=>string_schema(;max=512),
        "tags"=>strings,"source_reference"=>string_schema(;max=512),
        "expires"=>Dict("type"=>"number","minimum"=>0),"expected_version"=>integer_schema(0),
        "limit"=>integer_schema(1,100),"offset"=>integer_schema(0,100000),
        "tags_all"=>strings,"tags_any"=>strings,"sources"=>Dict("type"=>"array","maxItems"=>4,
            "items"=>Dict("type"=>"string","enum"=>["user","agent","tool","import"])),
        "include_expired"=>Dict("type"=>"boolean"),"include_deleted"=>Dict("type"=>"boolean"),
        "updated_after"=>string_schema(;max=32),"updated_before"=>string_schema(;max=32),
        "match"=>Dict("type"=>"string","enum"=>["any","all"]),
        "sort"=>Dict("type"=>"string","enum"=>["relevance","key","updated"]),
        "snippet_chars"=>integer_schema(40,2000),"expected_snapshot"=>string_schema(;max=64),
        "cursor"=>string_schema(;max=2048),"document"=>Dict("type"=>"object","additionalProperties"=>true));required=["action"])
end

function memory_action_arguments(args::AbstractDict)
    action=get(args,"action",nothing)
    actions=Dict(
        "get"=>("key",),"history"=>("key","limit"),"delete"=>("key","expected_version"),
        "put"=>("key","content","title","tags","source_reference","expires","expected_version"),
        "status"=>(),"namespaces"=>(),"export"=>(),"import"=>("document",),
        "search"=>("query","limit"),
        "retrieve"=>("query","limit","offset","tags_all","tags_any","sources","include_expired","include_deleted",
            "updated_after","updated_before","match","sort","snippet_chars","expected_snapshot","cursor"),
        "list"=>("limit","offset","tags_all","tags_any","sources","include_expired","include_deleted",
            "updated_after","updated_before","sort","snippet_chars","expected_snapshot","cursor"))
    haskey(actions,action) || throw(ShenScopeError(:arguments,"Unknown memory action"))
    allowed=Set(vcat(["action","scope","namespace"],collect(actions[action])))
    all(key->key in allowed,keys(args)) || throw(ShenScopeError(:arguments,"Unexpected parameter for this memory action"))
    if action in ("get","history","put","delete")
        get(args,"key",nothing) isa AbstractString || throw(ShenScopeError(:arguments,"Memory key required"))
        object_key(args["key"])
    end
    if action in ("put","delete")
        memory_version(get(args,"expected_version",nothing);allow_zero=true)
    end
    action=="put" && !(get(args,"content",nothing) isa AbstractString) &&
        throw(ShenScopeError(:arguments,"Memory content required"))
    action in ("search","retrieve") && !(get(args,"query",nothing) isa AbstractString) &&
        throw(ShenScopeError(:arguments,"Memory query required"))
    action=="import" && !(get(args,"document",nothing) isa AbstractDict) &&
        throw(ShenScopeError(:arguments,"Memory import document required"))
    action
end

function execute(tool::MemoryTool,args::AbstractDict,ctx::RuntimeContext;user_requested=false)
    user_requested isa Bool || throw(ShenScopeError(:arguments,"Invalid memory caller mode"))
    validate_schema(args,tool_schema(tool));action=memory_action_arguments(args)
    lock(tool.manager.mutex) do
        tool.manager.closed && throw(ShenScopeError(:runtime,"Memory manager is closed"))
    end
    store=memory_store(ctx,Symbol(get(args,"scope","workspace"));namespace=get(args,"namespace",MEMORY_DEFAULT_NAMESPACE))
    if action=="get"
        return memory_get(store,args["key"],ctx)
    elseif action=="history"
        return memory_history(store,args["key"],ctx;limit=get(args,"limit",8))
    elseif action=="search"
        return memory_search(store,args["query"],ctx;limit=get(args,"limit",8))
    elseif action in ("retrieve","list")
        options=memory_options_from_arguments(args)
        return memory_retrieve(store,action=="list" ? "" : args["query"],ctx;options,manager=tool.manager)
    elseif action=="status"
        return memory_inventory(store,ctx)
    elseif action=="namespaces"
        return memory_namespaces(ctx;scope=store.scope)
    elseif action=="export"
        return memory_export(store,ctx)
    elseif action=="import"
        result=memory_import!(store,args["document"],ctx)
        memory_retire_index!(tool.manager,store,ctx)
        return Dict("keys"=>result,"count"=>length(result),"namespace"=>store.namespace)
    end
    result=if action=="delete"
        memory_delete!(store,args["key"],ctx;expected_version=args["expected_version"])
    else
        memory_put!(store,args["key"],args["content"],ctx;expected_version=args["expected_version"],
            title=get(args,"title",args["key"]),tags=get(args,"tags",String[]),expires=get(args,"expires",nothing),
            source=user_requested ? "user" : "agent",source_reference=get(args,"source_reference",""))
    end
    memory_retire_index!(tool.manager,store,ctx)
    result
end
