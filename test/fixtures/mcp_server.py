"""Small independent MCP fixture. No agent or MCP SDK code is used."""
import json
import os
import sys
import threading
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
log_path = sys.argv[2] if len(sys.argv) > 2 else ""
write_lock = threading.Lock()
waiting_roots = {}


def send(value):
    with write_lock:
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def reply(request, result):
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


def notify(method, params=None):
    send({"jsonrpc": "2.0", "method": method, "params": params or {}})


def tool_result(request, value):
    reply(request, {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}],
                    "structuredContent": {"echo": value}})


schema = {"type": "object", "properties": {"value": {"$ref": "#/$defs/value"},
           "mode": {"type": "string"}}, "required": ["value"], "additionalProperties": False,
          "$defs": {"value": {"anyOf": [{"type": "string", "minLength": 1},
                                        {"type": "integer", "minimum": 0}]}}}
echo = {"name": "echo/input", "description": "Echo with structured content", "inputSchema": schema,
        "outputSchema": {"type": "object", "properties": {"echo": {}}, "required": ["echo"]}}

for raw in sys.stdin:
    request = json.loads(raw)
    method = request.get("method")
    if method is None:
        origin = waiting_roots.pop(request.get("id"), None)
        if origin is not None:
            tool_result(origin, request.get("result", request.get("error")))
        continue
    if log_path:
        with open(log_path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps({"method": method, "pid": os.getpid()}) + "\n")
    if "id" not in request:
        if method == "notifications/initialized" and mode == "flap":
            threading.Timer(0.06, lambda: os._exit(0)).start()
        continue
    params = request.get("params", {})
    if method == "initialize":
        version = "2099-01-01" if mode == "version" else request["params"]["protocolVersion"]
        caps = {"tools": {"listChanged": True}, "resources": {"listChanged": True, "subscribe": True},
                "prompts": {"listChanged": True}, "completions": {}}
        if mode == "bad_caps":
            caps["tools"]["listChanged"] = "yes"
        reply(request, {"protocolVersion": version, "serverInfo": {"name": "independent-fixture", "version": "1"},
                        "capabilities": caps, "instructions": "Fixture instructions are server content."})
    elif method == "ping":
        reply(request, {})
    elif method == "tools/list":
        if mode == "catalog_race":
            notify("notifications/tools/list_changed")
        if mode == "bad_schema":
            reply(request, {"tools": [{"name": "bad", "inputSchema": {"type": "object", "unevaluatedProperties": False}}]})
        elif mode == "oversize":
            sys.stdout.write("x" * (9 * 1024 * 1024))
            sys.stdout.flush()
        elif mode == "malformed":
            sys.stdout.write("this is not JSON\n")
            sys.stdout.flush()
        elif "cursor" not in params:
            reply(request, {"tools": [echo], "nextCursor": "second"})
        elif mode == "cursor_cycle":
            reply(request, {"tools": [], "nextCursor": "second"})
        else:
            reply(request, {"tools": [{"name": "other", "inputSchema": {"type": "object", "additionalProperties": False}}]})
    elif method == "tools/call":
        arguments = params["arguments"]
        behavior = arguments.get("mode", "echo")
        if behavior == "drop":
            os._exit(0)
        elif behavior == "slow":
            threading.Timer(2.0, lambda req=request: tool_result(req, "late")).start()
        elif behavior == "error":
            reply(request, {"isError": True, "content": [{"type": "text", "text": "Tool failed"}]})
        elif behavior == "rpc_error":
            send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32602, "message": "FAKE_SECRET", "data": "FAKE_SECRET"}})
        elif behavior == "roots":
            waiting_roots["root-request"] = request
            send({"jsonrpc": "2.0", "id": "root-request", "method": "roots/list"})
        elif behavior == "unsupported":
            waiting_roots["sampling-request"] = request
            send({"jsonrpc": "2.0", "id": "sampling-request", "method": "sampling/createMessage", "params": {}})
        elif behavior == "environment":
            tool_result(request, {"explicit": os.getenv("FIXTURE_BINDING"), "ambient": os.getenv("SHENSCOPE_TEST_AMBIENT")})
        elif behavior == "bad_output":
            reply(request, {"content": [{"type": "text", "text": "no structured value"}]})
        else:
            if behavior == "progress":
                token = params["_meta"]["progressToken"]
                for amount in [1, 0, 2]:
                    notify("notifications/progress", {"progressToken": token, "progress": amount, "total": 2})
            if behavior == "changed":
                notify("notifications/tools/list_changed")
            tool_result(request, arguments["value"])
    elif method == "resources/list":
        reply(request, {"resources": [{"name": "sample", "uri": "fixture://sample", "mimeType": "text/plain"}]})
    elif method == "resources/templates/list":
        reply(request, {"resourceTemplates": [{"name": "parameter", "uriTemplate": "fixture://{name}"}]})
    elif method == "resources/read":
        reply(request, {"contents": [{"uri": params["uri"], "text": "资源内容"}]})
    elif method in ["resources/subscribe", "resources/unsubscribe"]:
        reply(request, {})
        if method == "resources/subscribe":
            notify("notifications/resources/updated", {"uri": params["uri"]})
    elif method == "prompts/list":
        reply(request, {"prompts": [{"name": "review", "arguments": [{"name": "file", "required": True}]}]})
    elif method == "prompts/get":
        reply(request, {"messages": [{"role": "user", "content": {"type": "text", "text": "Review " + params["arguments"]["file"]}}]})
    elif method == "completion/complete":
        reply(request, {"completion": {"values": ["alpha", "beta"], "total": 2, "hasMore": False}})
    else:
        send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Unsupported"}})
