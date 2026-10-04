function observe_project_watch!(watch::ProjectWatch,snapshot::ProjectWatchSnapshot;now=time_ns()/1e9)
    lock(watch.mutex) do
        watch.scans+=1;watch.checked_at=utcstamp()
        if watch.observed===nothing || watch.observed.sha256!=snapshot.sha256
            watch.changed_at=Float64(now)
        end
        watch.observed=snapshot
        if watch.applied.sha256==snapshot.sha256
            # The persisted inventory digest covers all compiler inputs,
            # including approved documents outside the current root program.
            watch.applied=snapshot;watch.dirty=ProjectWatchChanges()
        else
            watch.dirty=watch_snapshot_changes(watch.applied,snapshot)
        end
        if isempty(watch.dirty)
            watch.phase=:watching;watch.last_error=nothing;watch.failed_fingerprint=nothing
            watch.refresh_requested=false
            return :clean
        end
        if now-watch.changed_at<watch.options.quiet_seconds
            watch.phase=:pending
            return :pending
        end
        watch.phase=:dirty
        :stable
    end
end

function watch_publish_changes!(watch::ProjectWatch)
    publish=lock(watch.mutex) do
        watch.observed===nothing && return false
        hash=watch.observed.sha256
        watch.published_fingerprint==hash && return false
        watch.published_fingerprint=hash
        true
    end
    publish && emit!(watch.context,:project_watch_changed,project_watch_status(watch))
    nothing
end

function watch_update_failure!(watch::ProjectWatch,error,snapshot::ProjectWatchSnapshot)
    lock(watch.mutex) do
        watch.failed_updates+=1;watch.phase=:dirty
        watch.last_error=watch_error(error);watch.failed_fingerprint=snapshot.sha256
    end
    emit!(watch.context,:project_watch_error,project_watch_status(watch))
    nothing
end

function apply_project_watch_batch!(watch::ProjectWatch)
    batch=lock(watch.mutex) do
        snapshot=watch.observed
        snapshot===nothing && return nothing
        isempty(watch.dirty) && return nothing
        explicit=watch.refresh_requested
        watch.options.automatic || explicit || return nothing
        watch.failed_fingerprint==snapshot.sha256 && !explicit && return nothing
        watch.refresh_requested=false;watch.phase=:updating
        (snapshot,watch_source_paths(watch.dirty))
    end
    batch===nothing && return false
    snapshot,paths=batch
    emit!(watch.context,:project_watch_updating,project_watch_status(watch))
    try
        watch_read_checkpoint(watch)
        delta=update!(watch.backend,watch.state,paths,watch.context)
        lock(watch.mutex) do
            watch.applied=snapshot;watch.dirty=ProjectWatchChanges();watch.updates+=1
            watch.phase=:watching;watch.last_error=nothing;watch.failed_fingerprint=nothing
        end
        view=project_watch_status(watch)
        view["revision"]=delta.revision
        view["delta"]=Dict("changed_files"=>first(delta.changed_files,100),"changed_count"=>length(delta.changed_files),
            "relinked_count"=>length(delta.relinked_files),"added_symbols"=>delta.added_symbols,
            "removed_symbols"=>delta.removed_symbols,"added_relations"=>delta.added_relations,
            "removed_relations"=>delta.removed_relations,"timings"=>delta.timings)
        emit!(watch.context,:project_watch_updated,view)
        true
    catch error
        error isa ShenScopeError && error.code in (:cancelled,:permission,:budget) && rethrow()
        watch_update_failure!(watch,error,snapshot)
        false
    end
end

function refresh_project_watch!(watch::ProjectWatch)
    lock(watch.mutex) do
        watch.phase in (:starting,:watching,:pending,:dirty,:updating) ||
            throw(ShenScopeError(:watch,"Stopped watcher cannot refresh; start watching again"))
        watch.refresh_requested=true
    end
    wake_project_watch!(watch)
    project_watch_status(watch)
end
