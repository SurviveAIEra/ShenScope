const TERMINAL_MAX_INPUT = 64 * 1024
const TERMINAL_MAX_PAGE = 64 * 1024
const TERMINAL_MAX_RETAINED = 4 * 1024 * 1024

struct TerminalSize
    rows::UInt16
    columns::UInt16
    function TerminalSize(rows::Integer=24,columns::Integer=80)
        !(rows isa Bool) && !(columns isa Bool) && 2<=rows<=500 && 2<=columns<=500 ||
            throw(ShenScopeError(:arguments,"Terminal dimensions must be between 2 and 500"))
        new(UInt16(rows),UInt16(columns))
    end
end

mutable struct TerminalEndpoint
    descriptor::Cint
    size::TerminalSize
    mutex::ReentrantLock
end

mutable struct TerminalJournal
    data::Vector{UInt8}
    first_offset::Int
    next_offset::Int
    observed_bytes::Int
    limit::Int
    mutex::ReentrantLock
    function TerminalJournal(limit::Int=256*1024)
        1024<=limit<=TERMINAL_MAX_RETAINED || throw(ShenScopeError(:arguments,"Invalid terminal retention limit"))
        new(UInt8[],0,0,0,limit,ReentrantLock())
    end
end

mutable struct TerminalFilter
    state::Symbol
    sequence::Vector{UInt8}
    discarded_bytes::Int
    decoder::UTF8StreamDecoder
end
TerminalFilter()=TerminalFilter(:text,UInt8[],0,UTF8StreamDecoder())

mutable struct TerminalHandle
    id::String
    owner::String
    root::String
    argv::Vector{String}
    cwd::String
    process::Base.Process
    process_id::Int
    endpoint::TerminalEndpoint
    journal::TerminalJournal
    context::RuntimeContext
    permission_target::String
    phase::Symbol
    started::Float64
    deadline::Float64
    ready_nonce::String
    ready::Bool
    reader::Union{Nothing,Task}
    monitor::Union{Nothing,Task}
    timed_out::Bool
    permission_revoked::Bool
    error::Union{Nothing,String}
    terminated::Bool
    mutex::ReentrantLock
end

mutable struct TerminalManager
    handles::Dict{String,TerminalHandle}
    operations::OperationManager
    root::Union{Nothing,String}
    closed::Bool
    max_handles::Int
    mutex::ReentrantLock
    function TerminalManager(;max_handles::Int=32)
        1<=max_handles<=128 || throw(ArgumentError("Invalid terminal handle capacity"))
        new(Dict{String,TerminalHandle}(),OperationManager(;event_prefix="terminal",max_running=4),
            nothing,false,max_handles,ReentrantLock())
    end
end

terminal_size_view(size::TerminalSize)=Dict("rows"=>Int(size.rows),"columns"=>Int(size.columns))
function terminal_platform_view()
    Dict("platform"=>string(Sys.KERNEL),"backend"=>Sys.islinux() ? "linux-openpty-v1" : "unsupported",
        "host_pty_implemented"=>Sys.islinux(),"restricted_pty_implemented"=>false,
        "controlling_terminal_checked_per_child"=>true,"merged_output"=>true,
        "osc_dcs_apc_pm_sos_removed"=>true,"persistence"=>false)
end
