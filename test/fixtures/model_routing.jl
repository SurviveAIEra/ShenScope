function routing_fixture_config(first_endpoint="http://localhost:8101",second_endpoint="http://localhost:8102")
    config = deepcopy(ShenScope.DEFAULT_CONFIG)
    source(name,endpoint,key) = Dict{String,Any}("protocol"=>"openai_chat","name"=>name,
        "endpoint"=>endpoint,"key_env"=>key,"retries"=>0,
        "circuit"=>Dict("failure_threshold"=>1,"cooldown"=>30.0))
    config["model_routing"] = Dict{String,Any}("default_role"=>"main",
        "providers"=>Dict("primary"=>source("first-source",first_endpoint,"FIRST_ROUTE_KEY"),
            "backup"=>source("second-source",second_endpoint,"BACKUP_ROUTE_KEY")),
        "profiles"=>Dict("writer"=>Dict("provider"=>"primary","model"=>"writer-model","options"=>Dict("temperature"=>0.2)),
            "backup"=>Dict{String,Any}("provider"=>"backup","model"=>"backup-model"),
            "worker"=>Dict{String,Any}("provider"=>"primary","model"=>"worker-model")),
        "roles"=>Dict("main"=>Dict("profiles"=>["writer","backup"]),"worker"=>Dict("profiles"=>["worker"])))
    config
end

routing_request(;text="hello 路由 😀",tools=Dict{String,Any}[],max_output=64,options=Dict{String,Any}()) =
    ModelRequest([Message(:user,text)],tools,max_output,options)

function routing_chat_response(text="route success")
    delta = Dict("choices"=>[Dict("delta"=>Dict("content"=>text),"finish_reason"=>"stop")],
        "usage"=>Dict("prompt_tokens"=>5,"completion_tokens"=>3))
    HTTP.Response(200,["Content-Type"=>"text/event-stream"],"data: "*canonical(delta)*"\n\ndata: [DONE]\n\n")
end
