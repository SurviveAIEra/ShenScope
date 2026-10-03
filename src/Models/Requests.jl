function openai_messages(messages::Vector{Message},identity::String)
    result=Dict{String,Any}[]
    for m in messages
        d=Dict{String,Any}("role"=>String(m.role),"content"=>m.text)
        if m.role==:assistant && !isempty(m.calls)
            d["tool_calls"]=[Dict("id"=>c.id,"type"=>"function","function"=>
                Dict("name"=>c.name,"arguments"=>canonical(c.arguments))) for c in m.calls]
        elseif m.role==:tool
            d["tool_call_id"]=m.call_id
        end
        if get(m.native,"identity",nothing)==identity
            reasoning=get(m.native,"reasoning_content",nothing)
            reasoning !== nothing && (d["reasoning_content"]=reasoning)
        end
        push!(result,d)
    end
    return result
end

function responses_input(messages::Vector{Message},identity::String)
    input=Any[]
    for m in messages
        if m.role==:system
            push!(input,Dict("role"=>"system","content"=>m.text))
        elseif m.role==:tool
            push!(input,Dict("type"=>"function_call_output","call_id"=>m.call_id,"output"=>m.text))
        else
            if get(m.native,"identity",nothing)==identity
                append!(input,get(m.native,"reasoning_items",[]))
            end
            !isempty(m.text) && push!(input,Dict("role"=>String(m.role),"content"=>m.text))
            for c in m.calls
                push!(input,Dict("type"=>"function_call","call_id"=>c.id,"name"=>c.name,
                    "arguments"=>canonical(c.arguments)))
            end
        end
    end
    return input
end

function anthropic_messages(messages::Vector{Message},identity::String)
    result=Any[]; system=String[]
    for m in messages
        if m.role==:system
            push!(system,m.text);continue
        end
        role=m.role==:assistant ? "assistant" : "user"
        content=Any[]
        if m.role==:assistant && get(m.native,"identity",nothing)==identity
            append!(content,get(m.native,"thinking_blocks",[]))
        end
        if m.role==:tool
            push!(content,Dict("type"=>"tool_result","tool_use_id"=>m.call_id,"content"=>m.text))
        else
            !isempty(m.text) && push!(content,Dict("type"=>"text","text"=>m.text))
            for c in m.calls
                push!(content,Dict("type"=>"tool_use","id"=>c.id,"name"=>c.name,"input"=>c.arguments))
            end
        end
        isempty(content) && continue
        if !isempty(result) && result[end]["role"]==role
            append!(result[end]["content"],content)
        else
            push!(result,Dict("role"=>role,"content"=>content))
        end
    end
    return result,join(system,"\n\n")
end

function gemini_contents(messages::Vector{Message},identity::String)
    contents=Any[];system=String[];call_names=Dict{String,String}()
    for m in messages
        if m.role==:system
            push!(system,m.text);continue
        end
        parts=Any[]
        if m.role==:assistant && get(m.native,"identity",nothing)==identity && haskey(m.native,"parts")
            append!(parts,m.native["parts"])
        elseif m.role==:tool
            push!(parts,Dict("functionResponse"=>Dict("name"=>get(call_names,m.call_id,"unknown"),
                "response"=>parsejson(m.text))))
        else
            !isempty(m.text) && push!(parts,Dict("text"=>m.text))
            for c in m.calls
                push!(parts,Dict("functionCall"=>Dict("name"=>c.name,"args"=>c.arguments)))
            end
        end
        for c in m.calls;call_names[c.id]=c.name;end
        isempty(parts) && continue
        role=m.role==:assistant ? "model" : "user"
        if !isempty(contents) && contents[end]["role"]==role
            append!(contents[end]["parts"],parts)
        else
            push!(contents,Dict("role"=>role,"parts"=>parts))
        end
    end
    return contents,join(system,"\n\n")
end

function prepare_request(p::HTTPProvider,request::ModelRequest; accounting=false)
    validate_config(p.config)
    accounting || validate_request(p,request)
    c=p.config
    key=CredentialSnapshot(accounting ? "" : p.credential_lookup(c.key_env))
    identity=string(c.protocol,":",c.name,":",c.model,":",digest(c.endpoint))
    endpoint=rstrip(c.endpoint,'/')
    headers=Pair{String,String}["Content-Type"=>"application/json"]
    options=deepcopy(request.options)
    protected=Set(["model","messages","input","tools","stream","contents","system",
        "max_tokens","max_output_tokens","max_completion_tokens","generationConfig","options"])
    any(k->k in protected,keys(options)) && throw(ShenScopeError(:config,"Request options override a protected field"))
    if c.protocol==:openai_chat
        endpoint *= "/chat/completions"
        body=Dict{String,Any}("model"=>c.model,"messages"=>openai_messages(request.messages,identity),
            "stream"=>true,"stream_options"=>Dict("include_usage"=>true),"max_tokens"=>request.max_output)
        !isempty(request.tools) && (body["tools"]=[Dict("type"=>"function","function"=>t) for t in request.tools])
    elseif c.protocol==:openai_responses
        endpoint *= "/responses"
        body=Dict{String,Any}("model"=>c.model,"input"=>responses_input(request.messages,identity),
            "stream"=>true,"max_output_tokens"=>request.max_output,"store"=>false,
            "include"=>["reasoning.encrypted_content"])
        !isempty(request.tools) && (body["tools"]=[merge(Dict("type"=>"function"),t) for t in request.tools])
    elseif c.protocol==:anthropic
        endpoint *= "/messages"
        messages,system=anthropic_messages(request.messages,identity)
        body=Dict{String,Any}("model"=>c.model,"messages"=>messages,"stream"=>true,"max_tokens"=>request.max_output)
        !isempty(system) && (body["system"]=system)
        !isempty(request.tools) && (body["tools"]=[Dict("name"=>t["name"],"description"=>t["description"],
            "input_schema"=>t["parameters"]) for t in request.tools])
        push!(headers,"anthropic-version"=>"2023-06-01")
        !isempty(key.value) && push!(headers,"x-api-key"=>key.value)
    elseif c.protocol==:gemini
        occursin(r"^[A-Za-z0-9_.-]+$",c.model) || throw(ShenScopeError(:config,"Invalid Gemini model ID"))
        endpoint *= "/models/" * c.model * ":streamGenerateContent?alt=sse"
        contents,system=gemini_contents(request.messages,identity)
        body=Dict{String,Any}("contents"=>contents,"generationConfig"=>Dict("maxOutputTokens"=>request.max_output))
        !isempty(system) && (body["systemInstruction"]=Dict("parts"=>[Dict("text"=>system)]))
        !isempty(request.tools) && (body["tools"]=[Dict("functionDeclarations"=>request.tools)])
        !isempty(key.value) && push!(headers,"x-goog-api-key"=>key.value)
    else
        endpoint *= "/api/chat"
        body=Dict{String,Any}("model"=>c.model,"messages"=>openai_messages(request.messages,identity),"stream"=>true,
            "options"=>Dict("num_predict"=>request.max_output))
        !isempty(request.tools) && (body["tools"]=[Dict("type"=>"function","function"=>t) for t in request.tools])
    end
    c.protocol in (:openai_chat,:openai_responses,:ollama) && !isempty(key.value) &&
        push!(headers,"Authorization"=>"Bearer " * key.value)
    merge!(body,options)
    return PreparedRequest(endpoint,headers,body,c.protocol,identity,key)
end

model_body(provider::HTTPProvider, request::ModelRequest) = prepare_request(provider, request; accounting=true).body
