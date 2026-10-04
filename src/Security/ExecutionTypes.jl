const EXECUTION_MAX_ROOTS = 32
const EXECUTION_MAX_MASKS = 256
const EXECUTION_MAX_SCAN_ENTRIES = 100000
const EXECUTION_MAX_ENVIRONMENT_BYTES = 32768
const EXECUTION_MAX_PROBE_BYTES = 16384
const EXECUTION_PROBE_SECONDS = 5.0

struct ExecutionLimits
    cpu_seconds::Int
    file_bytes::Int
    open_files::Int
    address_space_bytes::Int
end

function ExecutionLimits(;cpu_seconds=120,file_bytes=64*1024^2,open_files=256,address_space_bytes=0)
    for (name,value,lo,hi) in (("CPU seconds",cpu_seconds,1,3600),
            ("file bytes",file_bytes,1024,1024^3),("open files",open_files,32,4096),
            ("address space",address_space_bytes,0,64*1024^3))
        value isa Integer && !(value isa Bool) && lo<=value<=hi ||
            throw(ShenScopeError(:config,"Invalid execution "*name*" limit"))
    end
    address_space_bytes==0 || address_space_bytes>=512*1024^2 ||
        throw(ShenScopeError(:config,"Execution address-space limit is too small"))
    ExecutionLimits(Int(cpu_seconds),Int(file_bytes),Int(open_files),Int(address_space_bytes))
end

struct ExecutionPolicy
    filesystem::Symbol
    network::Symbol
    runtime_roots::Tuple{Vararg{String}}
    environment_keys::Tuple{Vararg{String}}
    limits::ExecutionLimits
end

struct BubblewrapSandbox <: AbstractSandbox
    policy::ExecutionPolicy
end

struct ExecutionMount
    source::String
    destination::String
    writable::Bool
    kind::Symbol
    identity::Tuple{UInt64,UInt64}
end

struct ExecutionMask
    path::String
    kind::Symbol
end

struct ExecutionPlan
    backend::Symbol
    workspace::String
    cwd::String
    argv::Tuple{Vararg{String}}
    mounts::Tuple{Vararg{ExecutionMount}}
    masks::Tuple{Vararg{ExecutionMask}}
    environment::Tuple{Vararg{Pair{String,String}}}
    policy::ExecutionPolicy
    policy_sha256::String
    nonce::String
    command::Tuple{Vararg{String}}
end

mutable struct ExecutionEvidence
    backend::Symbol
    policy_sha256::Union{Nothing,String}
    phase::Symbol
    network::Symbol
    filesystem::Symbol
    nonce::Union{Nothing,String}
    retained::Vector{UInt8}
    marker_checked::Bool
    mutex::ReentrantLock
end

ExecutionEvidence()=ExecutionEvidence(:host,nothing,:host,:host,:host,nothing,UInt8[],true,ReentrantLock())
ExecutionEvidence(plan::ExecutionPlan)=ExecutionEvidence(plan.backend,plan.policy_sha256,:starting,
    plan.policy.network,plan.policy.filesystem,plan.nonce,UInt8[],false,ReentrantLock())

struct ExecutionProbe
    backend::Symbol
    state::Symbol
    reason::String
    checked_at::String
    elapsed_seconds::Float64
    executable_sha256::Union{Nothing,String}
    exit_code::Union{Nothing,Int}
end

mutable struct ExecutionManager
    operations::OperationManager
    probes::Dict{String,ExecutionProbe}
    mutex::ReentrantLock
    closed::Bool
end
ExecutionManager()=ExecutionManager(OperationManager(;event_prefix="security"),
    Dict{String,ExecutionProbe}(),ReentrantLock(),false)
