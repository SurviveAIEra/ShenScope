function capabilities(provider::RoutedProvider)
    route = provider.fleet.roles[provider.role]
    declarations = [provider.fleet.profiles[id].capabilities for id in route.profiles]
    values = Dict{Symbol,Any}()
    for field in fieldnames(ModelCapabilities)
        values[field] = field in (:context_window,:max_output) ? minimum(getfield(value,field) for value in declarations) :
            field == :parallel_tools ? all(value->!value.tools || value.parallel_tools,declarations) :
            any(value->getfield(value,field),declarations)
    end
    ModelCapabilities(;values...)
end

model_price_bound(::AbstractModelProvider) = (0.0,0.0)
model_price_bound(provider::HTTPProvider) = (provider.config.input_price,provider.config.output_price)
function model_price_bound(provider::RoutedProvider)
    sources = [provider.fleet.providers[provider.fleet.profiles[id].selection.provider_id]
        for id in provider.fleet.roles[provider.role].profiles]
    (maximum(source.config.input_price for source in sources),maximum(source.config.output_price for source in sources))
end

model_measurement_wires(provider::AbstractModelProvider,request::ModelRequest) =
    (canonical(Dict("messages"=>message_dict.(request.messages),"tools"=>request.tools,
        "options"=>request.options,"max_output"=>request.max_output)),)
model_measurement_wires(provider::HTTPProvider,request::ModelRequest) = (canonical(model_body(provider,request)),)
function model_measurement_wires(provider::RoutedProvider,request::ModelRequest)
    plan = model_route_plan(provider,request)
    isempty(plan.candidates) && throw(ShenScopeError(:route_ineligible,"No configured model profile can accept this request"))
    Tuple(canonical(model_body(candidate.provider,candidate.request)) for candidate in plan.candidates)
end

function summary_model_identity(provider::RoutedProvider)
    Dict{String,Any}("provider"=>provider_name(provider),"model"=>"configured role route",
        "protocol"=>"core-routing","routing_revision"=>provider.fleet.revision,"role"=>provider.role)
end
