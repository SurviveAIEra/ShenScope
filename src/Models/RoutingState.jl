function model_route_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    nothing
end

function begin_model_route!(fleet::ModelFleet,ctx::RuntimeContext)
    model_route_checkpoint(ctx)
    lock(fleet.mutex) do
        fleet.closed && throw(ShenScopeError(:runtime,"Model routing runtime is closed"))
        length(fleet.active) < fleet.max_active || throw(ShenScopeError(:capacity,"Model route concurrency capacity reached"))
        id = string(uuid4());fleet.active[id] = model_route_owner(ctx)
        id
    end
end

function finish_model_route!(fleet::ModelFleet,id::String,ctx::RuntimeContext,receipt::AbstractDict)
    encoded = bounded_canonical_json(receipt;maximum=16*1024,max_depth=8,max_nodes=1024)
    lock(fleet.mutex) do
        owner = get(fleet.active,id,nothing)
        owner === nothing && return nothing
        owner == model_route_owner(ctx) || throw(ShenScopeError(:runtime,"Model route completion owner mismatch"))
        delete!(fleet.active,id)
        fleet.closed && return nothing
        push!(fleet.history,Dict("owner"=>owner,"receipt"=>parsejson(encoded)))
        length(fleet.history) <= fleet.max_history || deleteat!(fleet.history,1:length(fleet.history)-fleet.max_history)
    end
    nothing
end

function model_fleet_metadata(fleet::ModelFleet,ctx::RuntimeContext)
    lock(fleet.mutex) do
        fleet.closed && throw(ShenScopeError(:runtime,"Model routing runtime is closed"))
        owner = model_route_owner(ctx)
        Dict("enabled"=>true,"routing_revision"=>fleet.revision,"default_role"=>fleet.default_role,
            "providers"=>[Dict("id"=>id,"name"=>provider_name(source),"protocol"=>String(source.config.protocol),
                "source_id"=>catalog_source_id(source),"key_env"=>source.config.key_env)
                for (id,source) in sort!(collect(fleet.providers);by=first)],
            "profiles"=>[Dict("id"=>id,"description"=>profile.description,"provider"=>profile.selection.provider_id,
                "model"=>profile.selection.model,"options"=>parsejson(profile.selection.options_json),
                "capabilities"=>Dict(String(field)=>getfield(profile.capabilities,field) for field in fieldnames(ModelCapabilities)))
                for (id,profile) in sort!(collect(fleet.profiles);by=first)],
            "roles"=>[Dict("role"=>role,"profiles"=>collect(route.profiles),"fallback_codes"=>String.(collect(route.fallback_codes)))
                for (role,route) in sort!(collect(fleet.roles);by=first)],
            "in_flight"=>count(value->value == owner,values(fleet.active)),
            "recent_requests"=>[deepcopy(value["receipt"]) for value in fleet.history if value["owner"] == owner],
            "history_lifetime"=>"Core process","background_network_probe"=>false,
            "capacity_policy"=>"minimum context/output limits; request-specific feature eligibility",
            "price_admission"=>"maximum configured input/output prices; zero configured prices are not proof of free usage")
    end
end

model_fleet_metadata(::Nothing,ctx::RuntimeContext) = Dict("enabled"=>false,"background_network_probe"=>false)

function close_model_fleet!(fleet::ModelFleet)
    lock(fleet.mutex) do
        isempty(fleet.active) || throw(ShenScopeError(:runtime,"Drain model route owners before closing the fleet"))
        fleet.closed = true;empty!(fleet.history)
    end
    close_model_circuits!(fleet.circuits)
    nothing
end
close_model_fleet!(::Nothing) = nothing

function invalidate_model_fleet_credentials!(fleet::ModelFleet)
    invalidate_model_circuits!(fleet.circuits)
    nothing
end
invalidate_model_fleet_credentials!(::Nothing) = nothing
