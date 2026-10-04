function wake_project_watch!(watch::ProjectWatch)
    lock(watch.signal_mutex) do
        isopen(watch.signal) && !isready(watch.signal) && put!(watch.signal,nothing)
    end
    nothing
end

function open_project_watch_monitor!(watch::ProjectWatch)
    watch.options.native_hints || return
    try
        watch.monitor=FileWatching.FolderMonitor(watch.context.root)
        monitor=watch.monitor
        watch.monitor_task=@async begin
            try
                while !iscancelled(watch.context.cancellation)
                    wait(monitor)
                    lock(watch.mutex) do;watch.native_events+=1;end
                    wake_project_watch!(watch)
                end
            catch error
                if !iscancelled(watch.context.cancellation)
                    lock(watch.mutex) do;watch.native_error="Native hints unavailable; periodic recursive checks remain active";end
                    wake_project_watch!(watch)
                end
            end
        end
    catch error
        lock(watch.mutex) do;watch.native_error="Native hints failed to start; periodic recursive checks remain active";end
    end
    nothing
end

function close_project_watch_resources!(watch::ProjectWatch)
    watch.timer!==nothing && close(watch.timer)
    watch.settle_timer!==nothing && close(watch.settle_timer)
    watch.monitor!==nothing && close(watch.monitor)
    monitor_task=watch.monitor_task
    monitor_task!==nothing && monitor_task!==current_task() && wait(monitor_task)
    nothing
end

function schedule_project_watch_settle!(watch::ProjectWatch,state::Symbol)
    watch.settle_timer!==nothing && close(watch.settle_timer)
    if state==:pending
        remaining=lock(watch.mutex) do
            max(0.001,watch.options.quiet_seconds-(time_ns()/1e9-watch.changed_at))
        end
        watch.settle_timer=Timer(_->wake_project_watch!(watch),remaining)
    else
        watch.settle_timer=nothing
    end
    nothing
end

function project_watch_loop!(watch::ProjectWatch)
    context=watch.context
    try
        authorize!(context,:read,"project.watch",context.root;reason="Continuously observe bounded project source and configuration changes")
        watch_read_checkpoint(watch)
        open_project_watch_monitor!(watch)
        watch.timer=Timer(_->wake_project_watch!(watch),0.0;interval=watch.options.poll_seconds)
        emit!(context,:project_watch_started,project_watch_status(watch))
        while true
            take!(watch.signal)
            watch_read_checkpoint(watch)
            snapshot=try
                scan_project_watch(watch)
            catch error
                if error isa ShenScopeError && error.code in (:conflict,:path)
                    lock(watch.mutex) do
                        watch.last_error=watch_error(error);watch.phase=:pending;watch.changed_at=time_ns()/1e9
                    end
                    continue
                end
                rethrow()
            end
            previous=lock(watch.mutex) do;watch.phase;end
            state=observe_project_watch!(watch,snapshot)
            schedule_project_watch_settle!(watch,state)
            if state==:clean && previous!=:watching
                emit!(context,:project_watch_ready,project_watch_status(watch))
            elseif state==:pending && previous!=:pending
                emit!(context,:project_watch_pending,project_watch_status(watch))
            end
            if state==:stable
                watch_publish_changes!(watch)
                apply_project_watch_batch!(watch)
            end
        end
    catch error
        lock(watch.mutex) do
            watch.phase=iscancelled(context.cancellation) ? :stopped : :failed
            watch.phase==:failed && (watch.last_error=watch_error(error))
        end
    finally
        cancel!(context.cancellation,"project watcher finished")
        close_project_watch_resources!(watch)
        try
            emit!(context,:project_watch_stopped,project_watch_status(watch))
        catch error
            lock(watch.mutex) do
                watch.phase=:failed;watch.last_error=Dict{String,Any}("code"=>"watch_delivery","message"=>"Watcher stopped; final status delivery failed")
            end
        end
    end
    nothing
end

function start_project_watch(backend::AbstractProjectDataBackend,state::ProjectState,context::RuntimeContext;
        options=ProjectWatchOptions())
    watch=ProjectWatch(backend,state,context;options)
    watch.task=@async with_context(()->project_watch_loop!(watch),watch.context)
    watch
end

function stop_project_watch!(watch::ProjectWatch;wait_for_completion=true)
    lock(watch.mutex) do
        watch.phase in (:starting,:watching,:pending,:dirty,:updating) && (watch.phase=:stopping)
    end
    cancel!(watch.context.cancellation,"project watcher stopped")
    wake_project_watch!(watch)
    if watch.task===nothing
        lock(watch.mutex) do;watch.phase=:stopped;end
    end
    if wait_for_completion && watch.task!==nothing && watch.task!==current_task()
        wait(watch.task)
    end
    project_watch_status(watch)
end
