const PROTOCOL_VERSION = "1.0"
const MAX_RPC_BYTES = 8*1024*1024

struct RPCFault <: Exception
    code::Int
    message::String
    data::Any
end
RPCFault(code,message)=RPCFault(code,String(message),nothing)

function bounded_line(io::IO;max_bytes=8192)
    data=UInt8[]
    while !eof(io)
        byte=read(io,UInt8)
        byte==0x0a && return String(data)
        push!(data,byte)
        length(data)<=max_bytes || throw(RPCFault(-32700,"Header exceeds limit"))
    end
    isempty(data) && return nothing
    throw(RPCFault(-32700,"Truncated header"))
end

function read_rpc(io::IO;max_bytes=MAX_RPC_BYTES)
    length_header=nothing;header_bytes=0
    while true
        line=bounded_line(io)
        line===nothing && (header_bytes==0 ? (return nothing) : throw(RPCFault(-32700,"Truncated headers")))
        header_bytes+=ncodeunits(line)+1
        header_bytes<=32768 || throw(RPCFault(-32700,"Headers exceed limit"))
        line=strip(line)
        isempty(line) && break
        parts=split(line,':';limit=2)
        length(parts)==2 || throw(RPCFault(-32700,"Malformed header"))
        if lowercase(strip(parts[1]))=="content-length"
            length_header===nothing || throw(RPCFault(-32700,"Duplicate Content-Length"))
            length_header=tryparse(Int,strip(parts[2]))
            length_header!==nothing && 0<length_header<=max_bytes || throw(RPCFault(-32700,"Invalid Content-Length"))
        end
    end
    length_header===nothing && throw(RPCFault(-32700,"Content-Length required"))
    bytes=read(io,length_header)
    length(bytes)==length_header || throw(RPCFault(-32700,"Truncated body"))
    text=String(bytes)
    isvalid(text) || throw(RPCFault(-32700,"Body must be UTF-8"))
    value=try parsejson(text) catch;throw(RPCFault(-32700,"Invalid JSON"));end
    value isa AbstractDict || throw(RPCFault(-32600,"Expected one JSON-RPC object"))
    return value
end

function write_rpc(io::IO,value::AbstractDict,mutex::ReentrantLock=ReentrantLock())
    body=canonical(value)
    ncodeunits(body)<=MAX_RPC_BYTES || throw(RPCFault(-32603,"Response exceeds limit"))
    lock(mutex) do
        write(io,"Content-Length: ",string(ncodeunits(body)),"\r\n\r\n",body)
        flush(io)
    end
end

function validate_rpc(message::AbstractDict)
    get(message,"jsonrpc",nothing)=="2.0" || throw(RPCFault(-32600,"JSON-RPC 2.0 required"))
    get(message,"method",nothing) isa String || throw(RPCFault(-32600,"Method required"))
    if haskey(message,"id")
        id=message["id"]
        (id isa String && ncodeunits(id)<=128) || (id isa Integer && !(id isa Bool)) ||
            throw(RPCFault(-32600,"ID must be a bounded string or integer"))
    end
    params=get(message,"params",Dict{String,Any}())
    params isa AbstractDict || throw(RPCFault(-32602,"Named parameters required"))
    return params
end

function rpc_string(params::AbstractDict,key::String;default=nothing,max_bytes=65536)
    value=get(params,key,default)
    value isa AbstractString && ncodeunits(value)<=max_bytes || throw(RPCFault(-32602,"Invalid " * key))
    return String(value)
end
