function validate_schema(value,schema::AbstractDict;path="arguments")
    if haskey(schema,"enum") && !(value in schema["enum"])
        throw(ShenScopeError(:arguments,path * " has an unsupported value"))
    end
    kind=get(schema,"type",nothing)
    good=kind===nothing || kind=="object" && value isa AbstractDict ||
        kind=="array" && value isa AbstractVector || kind=="string" && value isa AbstractString ||
        kind=="integer" && value isa Integer && !(value isa Bool) ||
        kind=="number" && value isa Real && !(value isa Bool) && isfinite(value) ||
        kind=="boolean" && value isa Bool || kind=="null" && value===nothing
    good || throw(ShenScopeError(:arguments,path * " has the wrong type"))
    if value isa AbstractDict
        props=get(schema,"properties",Dict())
        for key in get(schema,"required",[])
            haskey(value,key) || throw(ShenScopeError(:arguments,path * "." * key * " is required"))
        end
        for (key,item) in value
            if haskey(props,key)
                validate_schema(item,props[key];path=path * "." * String(key))
            elseif get(schema,"additionalProperties",true)==false
                throw(ShenScopeError(:arguments,path * " contains an unknown field"))
            end
        end
    elseif value isa AbstractVector
        length(value)<=get(schema,"maxItems",typemax(Int)) || throw(ShenScopeError(:arguments,path * " has too many items"))
        length(value)>=get(schema,"minItems",0) || throw(ShenScopeError(:arguments,path * " has too few items"))
        if haskey(schema,"items")
            for (i,item) in enumerate(value);validate_schema(item,schema["items"];path=path * "[" * string(i) * "]");end
        end
    elseif value isa AbstractString
        ncodeunits(value)<=get(schema,"maxLength",1024*1024) || throw(ShenScopeError(:arguments,path * " is too long"))
        length(value)>=get(schema,"minLength",0) || throw(ShenScopeError(:arguments,path * " is too short"))
    elseif value isa Real && !(value isa Bool)
        value>=get(schema,"minimum",-Inf) && value<=get(schema,"maximum",Inf) ||
            throw(ShenScopeError(:arguments,path * " is out of range"))
    end
    return value
end

function object_schema(properties::AbstractDict;required=collect(keys(properties)))
    Dict{String,Any}("type"=>"object","properties"=>properties,"required"=>required,"additionalProperties"=>false)
end
string_schema(;max=1024*1024) = Dict("type"=>"string","maxLength"=>max)
integer_schema(min=0,max=typemax(Int)) = Dict("type"=>"integer","minimum"=>min,"maximum"=>max)

tool_name(t::AbstractTool) = throw(ShenScopeError(:extension,"Tool must implement tool_name"))
tool_schema(t::AbstractTool) = throw(ShenScopeError(:extension,"Tool must implement tool_schema"))
tool_description(t::AbstractTool) = tool_name(t)
execution_mode(::AbstractTool) = :exclusive
validate_tool_arguments(tool::AbstractTool, arguments) = validate_schema(arguments, tool_schema(tool))
is_successful_tool_result(::AbstractTool, value) = true
tool_failure_message(::AbstractTool, value) = nothing
additional_tools(::AbstractTool, ::RuntimeContext) = AbstractTool[]
extra_context(::AbstractTool, ::Session, ::RuntimeContext) = ""
filter_tools(::AbstractTool, tools::AbstractVector{<:AbstractTool}, ::RuntimeContext) = tools

function active_tools(tools::AbstractVector{<:AbstractTool}, ctx::RuntimeContext)
    result = AbstractTool[]
    names = Set{String}()
    for tool in tools
        name = tool_name(tool)
        name in names && throw(ShenScopeError(:extension, "Duplicate tool names"))
        push!(names, name)
        push!(result, tool)
    end
    for tool in tools, extra in additional_tools(tool, ctx)
        name = tool_name(extra)
        name in names && throw(ShenScopeError(:extension, "Dynamic tool name conflicts with another declaration"))
        push!(names, name)
        push!(result, extra)
    end
    for tool in tools; result = filter_tools(tool, result, ctx); end
    plan_mode_toolset(result)
end

function declaration(t::AbstractTool)
    Dict{String,Any}("name"=>tool_name(t),"description"=>tool_description(t),"parameters"=>tool_schema(t))
end

function execute_call(t::AbstractTool,call::ToolCall,ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    validate_tool_arguments(t,call.arguments)
    emit!(ctx,:tool_started,Dict("id"=>call.id,"name"=>call.name))
    result=try
        guard_agent_tool(t,call.arguments)
        before_tool_hooks!(call,ctx)
        value=with_context(()->execute(t,call.arguments,ctx),ctx)
        ToolResult(call.id,is_successful_tool_result(t,value),value,tool_failure_message(t,value))
    catch e
        e isa InterruptException && rethrow()
        # Error text is controlled: foreign exception details may contain credentials.
        message=e isa ShenScopeError ? sprint(showerror,e) : "Tool execution failed: " * string(nameof(typeof(e)))
        ToolResult(call.id,false,nothing,message)
    end
    emit!(ctx,:tool_completed,Dict("id"=>call.id,"name"=>call.name,"ok"=>result.ok,
        "value"=>result.value,"error"=>result.error))
    testing=t isa ProcessTool && get(call.arguments,"purpose","")=="test" && get(call.arguments,"action","")=="run" ||
        t isa TestingTool && get(call.arguments,"action","") in ("run","custom","run_set")
    after_tool_hooks!(call,result,ctx;testing)
    return result
end
