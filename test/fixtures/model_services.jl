using HTTP, Sockets

function model_service_fixture(f::Function,handler::Function;stream=false)
    listener = listen(ip"127.0.0.1",0)
    server = HTTP.serve!(handler,listener;verbose=false,stream)
    endpoint = "http://127.0.0.1:"*string(getsockname(listener)[2])
    try f(endpoint) finally close(server) end
end
