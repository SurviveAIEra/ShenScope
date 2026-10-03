mutable struct SSEDecoder
    bytes::Vector{UInt8}
    data::Vector{String}
    event::String
    max_bytes::Int
end
SSEDecoder(;max_bytes=1024*1024) = SSEDecoder(UInt8[],String[],"message",max_bytes)

function sse_line!(sink::Function,d::SSEDecoder,line::String)
    if isempty(line)
        if !isempty(d.data)
            sink(d.event,join(d.data,"\n"))
        end
        empty!(d.data);d.event="message"
        return
    end
    startswith(line,":") && return
    pair=split(line,':';limit=2)
    field=first(pair);value=length(pair)==2 ? pair[2] : ""
    startswith(value," ") && (value=value[2:end])
    field=="data" && push!(d.data,value)
    field=="event" && (d.event=value)
    sum(ncodeunits,d.data;init=0)<=d.max_bytes || throw(ShenScopeError(:protocol,"SSE event exceeds limit"))
end

function feed_sse!(sink::Function,d::SSEDecoder,chunk::AbstractVector{UInt8})
    append!(d.bytes,chunk)
    start=1
    for i in eachindex(d.bytes)
        d.bytes[i]==0x0a || continue
        bytes=d.bytes[start:i-1]
        !isempty(bytes) && last(bytes)==0x0d && pop!(bytes)
        line=String(bytes)
        isvalid(line) || throw(ShenScopeError(:protocol,"Invalid UTF-8 in SSE"))
        sse_line!(sink,d,line)
        start=i+1
    end
    start>1 && deleteat!(d.bytes,1:start-1)
    length(d.bytes)<=d.max_bytes || throw(ShenScopeError(:protocol,"SSE line exceeds limit"))
end

function finish_sse!(sink::Function,d::SSEDecoder)
    !isempty(d.bytes) && sse_line!(sink,d,String(copy(d.bytes)))
    empty!(d.bytes)
    sse_line!(sink,d,"")
end

mutable struct StreamCollector
    text::IOBuffer
    calls::Dict{Int,Dict{String,Any}}
    blocks::Dict{Int,Dict{String,Any}}
    native::Dict{String,Any}
    usage::Usage
    finish::Symbol
    terminal::Bool
    max_output_bytes::Int
    max_argument_bytes::Int
end
StreamCollector(identity::String;max_output_bytes=8*1024*1024,max_argument_bytes=1024*1024) =
    StreamCollector(IOBuffer(),Dict{Int,Dict{String,Any}}(),Dict{Int,Dict{String,Any}}(),
        Dict("identity"=>identity),Usage(),:unknown,false,max_output_bytes,max_argument_bytes)

function collect_text!(c::StreamCollector,text::AbstractString,sink::Function)
    position(c.text)+ncodeunits(text)<=c.max_output_bytes || throw(ShenScopeError(:protocol,"Model output exceeds limit"))
    write(c.text,text)
    !isempty(text) && sink(:text_delta,String(text))
end
function call_slot!(c::StreamCollector,index::Int)
    0<=index<64 || throw(ShenScopeError(:protocol,"Tool call index exceeds limit"))
    get!(c.calls,index) do
        Dict{String,Any}("id"=>"","name"=>"","arguments"=>"")
    end
end
function append_arguments!(c::StreamCollector,slot::Dict,delta::AbstractString)
    args=slot["arguments"] * delta
    ncodeunits(args)<=c.max_argument_bytes || throw(ShenScopeError(:protocol,"Tool arguments exceed limit"))
    slot["arguments"]=args
end

function openai_usage(d::AbstractDict)
    input=get(d,"prompt_tokens",get(d,"input_tokens",0))
    output=get(d,"completion_tokens",get(d,"output_tokens",0))
    cached=get(get(d,"prompt_tokens_details",get(d,"input_tokens_details",Dict())),"cached_tokens",0)
    return Usage(;input_tokens=input,output_tokens=output,cached_tokens=cached)
end

function collect_chat!(c::StreamCollector,d::AbstractDict,sink::Function)
    haskey(d,"error") && throw(model_stream_error(d))
    usage=get(d,"usage",nothing)
    usage!==nothing && (c.usage=openai_usage(usage);sink(:usage,c.usage))
    for choice in get(d,"choices",[])
        get(choice,"index",0)==0 || continue
        delta=get(choice,"delta",get(choice,"message",Dict()))
        text=get(delta,"content",nothing)
        text isa AbstractString && collect_text!(c,text,sink)
        reasoning=get(delta,"reasoning_content",nothing)
        if reasoning isa AbstractString
            old=get(c.native,"reasoning_content","")
            ncodeunits(old)+ncodeunits(reasoning)<=c.max_output_bytes || throw(ShenScopeError(:protocol,"Reasoning exceeds limit"))
            c.native["reasoning_content"]=old * reasoning
            !isempty(reasoning) && sink(:model_progress,Dict("channel"=>"reasoning","bytes"=>ncodeunits(reasoning)))
        end
        for call in get(delta,"tool_calls",[])
            slot=call_slot!(c,get(call,"index",0))
            get(call,"id",nothing)!==nothing && (slot["id"]=call["id"])
            f=get(call,"function",Dict())
            slot["name"] *= get(f,"name","")
            append_arguments!(c,slot,get(f,"arguments",""))
            sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(get(f,"arguments",""))))
        end
        finish=get(choice,"finish_reason",nothing)
        if finish!==nothing
            c.finish=finish=="tool_calls" ? :tools : finish=="stop" ? :stop : Symbol(finish)
            c.terminal=true
        end
    end
end

function collect_responses!(c::StreamCollector,d::AbstractDict,sink::Function)
    kind=get(d,"type","")
    if kind=="response.output_text.delta"
        collect_text!(c,get(d,"delta",""),sink)
    elseif kind=="response.output_item.added"
        item=d["item"]
        if item["type"]=="function_call"
            slot=call_slot!(c,get(d,"output_index",0))
            slot["id"]=item["call_id"];slot["name"]=item["name"]
            slot["arguments"]=get(item,"arguments","")
            sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(slot["arguments"])))
        end
    elseif kind=="response.function_call_arguments.delta"
        append_arguments!(c,call_slot!(c,d["output_index"]),d["delta"])
        sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(d["delta"])))
    elseif kind=="response.output_item.done" && d["item"]["type"]=="reasoning"
        push!(get!(c.native,"reasoning_items",Any[]),d["item"])
        sink(:model_progress,Dict("channel"=>"reasoning","bytes"=>ncodeunits(canonical(d["item"]))))
    elseif kind=="response.completed"
        r=d["response"]
        c.usage=openai_usage(get(r,"usage",Dict()));sink(:usage,c.usage)
        c.terminal=true;c.finish=isempty(c.calls) ? :stop : :tools
    elseif kind in ("response.failed","response.incomplete","error")
        throw(model_stream_error(d;message="Responses stream failed or was incomplete"))
    end
end

function collect_anthropic!(c::StreamCollector,d::AbstractDict,sink::Function)
    kind=get(d,"type","")
    if kind=="message_start"
        u=get(d["message"],"usage",Dict())
        c.usage=Usage(;input_tokens=get(u,"input_tokens",0),output_tokens=get(u,"output_tokens",0),
            cached_tokens=get(u,"cache_read_input_tokens",0))
    elseif kind=="content_block_start"
        index=d["index"];block=d["content_block"]
        c.blocks[index]=deepcopy(block)
        if block["type"]=="tool_use"
            slot=call_slot!(c,index);slot["id"]=block["id"];slot["name"]=block["name"]
            initial=get(block,"input",Dict())
            !isempty(initial) && (slot["arguments"]=canonical(initial))
            sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(slot["arguments"])))
        elseif block["type"]=="text"
            collect_text!(c,get(block,"text",""),sink)
        elseif block["type"] in ("thinking","redacted_thinking")
            sink(:model_progress,Dict("channel"=>"reasoning","bytes"=>ncodeunits(canonical(block))))
        end
    elseif kind=="content_block_delta"
        delta=d["delta"];t=delta["type"];index=d["index"]
        haskey(c.blocks,index) || throw(ShenScopeError(:protocol,"Delta before Anthropic block start"))
        if t=="text_delta"
            collect_text!(c,delta["text"],sink)
        elseif t=="input_json_delta"
            append_arguments!(c,call_slot!(c,index),delta["partial_json"])
            sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(delta["partial_json"])))
        elseif t in ("thinking_delta","signature_delta")
            key=t=="thinking_delta" ? "thinking" : "signature"
            value=get(c.blocks[index],key,"") * delta[key]
            ncodeunits(value)<=c.max_output_bytes || throw(ShenScopeError(:protocol,"Thinking block exceeds limit"))
            c.blocks[index][key]=value
            sink(:model_progress,Dict("channel"=>"reasoning","bytes"=>ncodeunits(delta[key])))
        end
    elseif kind=="message_delta"
        u=get(d,"usage",Dict());old=c.usage
        c.usage=Usage(;input_tokens=old.input_tokens,output_tokens=get(u,"output_tokens",old.output_tokens),cached_tokens=old.cached_tokens)
        reason=get(d["delta"],"stop_reason",nothing)
        reason!==nothing && (c.finish=reason=="tool_use" ? :tools : reason=="end_turn" ? :stop : Symbol(reason))
        sink(:usage,c.usage)
    elseif kind=="message_stop"
        c.terminal=true
        c.native["thinking_blocks"]=[b for (_,b) in sort!(collect(c.blocks);by=first)
            if b["type"] in ("thinking","redacted_thinking")]
    elseif kind=="error"
        throw(model_stream_error(d;message="Anthropic stream returned an error"))
    end
end

function collect_gemini!(c::StreamCollector,d::AbstractDict,sink::Function)
    haskey(d,"error") && throw(model_stream_error(d;message="Gemini stream returned an error"))
    for candidate in get(d,"candidates",[])
        get(candidate,"index",0)==0 || continue
        parts=get(get(candidate,"content",Dict()),"parts",[])
        for part in parts
            push!(get!(c.native,"parts",Any[]),part)
            if haskey(part,"text") && !get(part,"thought",false)
                collect_text!(c,part["text"],sink)
            elseif haskey(part,"functionCall")
                f=part["functionCall"];index=length(c.calls)
                slot=call_slot!(c,index);slot["id"]=get(f,"id",string(uuid4()))
                slot["name"]=f["name"];slot["arguments"]=canonical(get(f,"args",Dict()))
                sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(slot["arguments"])))
            elseif get(part,"thought",false) || haskey(part,"thoughtSignature")
                sink(:model_progress,Dict("channel"=>"reasoning","bytes"=>ncodeunits(canonical(part))))
            end
        end
        if haskey(candidate,"finishReason")
            reason=candidate["finishReason"]
            c.finish=reason=="STOP" ? (isempty(c.calls) ? :stop : :tools) : Symbol(reason)
            c.terminal=true
        end
    end
    if haskey(d,"usageMetadata")
        u=d["usageMetadata"]
        c.usage=Usage(;input_tokens=get(u,"promptTokenCount",0),output_tokens=get(u,"candidatesTokenCount",0),
            cached_tokens=get(u,"cachedContentTokenCount",0));sink(:usage,c.usage)
    end
end

function collect_ollama!(c::StreamCollector,d::AbstractDict,sink::Function)
    haskey(d,"error") && throw(model_stream_error(d;message="Ollama stream returned an error"))
    message=get(d,"message",Dict())
    collect_text!(c,get(message,"content",""),sink)
    thought=get(message,"thinking",nothing)
    thought isa AbstractString && !isempty(thought) && sink(:model_progress,Dict("channel"=>"reasoning","bytes"=>ncodeunits(thought)))
    for call in get(message,"tool_calls",[])
        f=call["function"];slot=call_slot!(c,length(c.calls))
        slot["id"]=get(call,"id",string(uuid4()));slot["name"]=f["name"]
        args=get(f,"arguments",Dict());slot["arguments"]=args isa String ? args : canonical(args)
        sink(:model_progress,Dict("channel"=>"tool_arguments","bytes"=>ncodeunits(slot["arguments"])))
    end
    if get(d,"done",false)
        c.terminal=true;c.finish=isempty(c.calls) ? :stop : :tools
        c.usage=Usage(;input_tokens=get(d,"prompt_eval_count",0),output_tokens=get(d,"eval_count",0))
        sink(:usage,c.usage)
    end
end

function finish_collection!(c::StreamCollector,sink::Function,config::ProviderConfig)
    c.terminal || throw(ShenScopeError(:stream_interrupted,"Model stream ended before a terminal event",true))
    c.finish in (:length,:max_tokens,:MAX_TOKENS,:content_filter,:SAFETY,:unknown) &&
        throw(ShenScopeError(:incomplete,"Model output is incomplete; tool calls are not executable"))
    calls=ToolCall[];seen=Set{String}()
    for (_,slot) in sort!(collect(c.calls);by=first)
        id=slot["id"];name=slot["name"]
        isempty(id) && throw(ShenScopeError(:protocol,"Missing tool call ID"))
        id in seen && throw(ShenScopeError(:protocol,"Duplicate tool call ID"))
        isempty(name) && throw(ShenScopeError(:protocol,"Missing tool name"))
        args=try parsejson(isempty(slot["arguments"]) ? "{}" : slot["arguments"]) catch
            throw(ShenScopeError(:protocol,"Malformed tool arguments; refusing execution"))
        end
        args isa AbstractDict || throw(ShenScopeError(:protocol,"Tool arguments must be an object"))
        call=ToolCall(id,name,Dict{String,Any}(args));push!(calls,call);push!(seen,id);sink(:tool_call,call)
    end
    u=c.usage
    cost=(u.input_tokens*config.input_price+u.output_tokens*config.output_price)/1_000_000
    u=Usage(;input_tokens=u.input_tokens,output_tokens=u.output_tokens,cached_tokens=u.cached_tokens,cost)
    return ModelResponse(Message(:assistant,String(take!(c.text));calls,native=c.native),u,c.finish)
end
