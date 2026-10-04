function execution_marker(evidence::ExecutionEvidence)
    "SHENSCOPE_EXEC_READY:"*evidence.nonce*":"*evidence.policy_sha256*":"*String(evidence.backend)*"\n"
end

function execution_stderr!(evidence::ExecutionEvidence,bytes::Vector{UInt8};final=false)
    lock(evidence.mutex) do
        evidence.marker_checked && return bytes
        marker=Vector{UInt8}(codeunits(execution_marker(evidence)))
        append!(evidence.retained,bytes)
        compared=min(length(marker),length(evidence.retained))
        if evidence.retained[1:compared]!=marker[1:compared]
            evidence.marker_checked=true;evidence.phase=:unconfirmed
            output=copy(evidence.retained);empty!(evidence.retained);return output
        elseif length(evidence.retained)>=length(marker)
            evidence.marker_checked=true;evidence.phase=:enforced
            output=copy(evidence.retained[length(marker)+1:end]);empty!(evidence.retained);return output
        elseif final
            evidence.marker_checked=true;evidence.phase=:unconfirmed
            output=copy(evidence.retained);empty!(evidence.retained);return output
        end
        UInt8[]
    end
end

function execution_evidence_view(evidence::ExecutionEvidence;exited=false)
    lock(evidence.mutex) do
        phase=exited && evidence.phase==:starting ? :unconfirmed : evidence.phase
        Dict("backend"=>String(evidence.backend),"phase"=>String(phase),"os_isolation"=>phase==:enforced,
            "policy_sha256"=>evidence.policy_sha256,"filesystem"=>String(evidence.filesystem),
            "network"=>String(evidence.network),"host_fallback"=>false,
            "isolation_setup_confirmed"=>phase==:enforced,"payload_exec_verified"=>false)
    end
end
