mutable struct CancellationToken
    cancelled::Threads.Atomic{Bool}
    parent::Union{Nothing,CancellationToken}
    reason::String
    mutex::ReentrantLock
end
CancellationToken(parent=nothing) = CancellationToken(Threads.Atomic{Bool}(false), parent, "", ReentrantLock())

function cancel!(token::CancellationToken, reason="cancelled")
    lock(token.mutex) do
        token.reason = String(reason)
        token.cancelled[] = true
    end
    return nothing
end
iscancelled(t::CancellationToken) = t.cancelled[] || (t.parent !== nothing && iscancelled(t.parent))
function check_cancelled(t::CancellationToken)
    iscancelled(t) && throw(ShenScopeError(:cancelled, "Execution was cancelled"))
end
function cancellable_wait(t::CancellationToken, seconds::Real)
    finish = time() + seconds
    while time() < finish
        check_cancelled(t)
        sleep(min(0.025, max(0.0, finish-time())))
    end
    check_cancelled(t)
end
