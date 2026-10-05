function project_testing_context(root;kwargs...)
    RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=
        Dict(category=>Allow for category in (:read,:edit,:process,:network,:persistence,:dynamic,:mcp))),kwargs...)
end

function project_testing_fixture(root,language)
    mkpath(root)
    if language=="python"
        path="calc.py";broken="def add(a, b): return a-b\n"
        write(joinpath(root,"pyproject.toml"),"[project]\nname='calc'\nversion='0.1.0'\n")
        write(joinpath(root,"test_calc.py"),"import unittest\nfrom calc import add\nclass Addition(unittest.TestCase):\n    def test_add(self): self.assertEqual(add(2, 3), 5)\n")
        command=["python3","-m","unittest","discover","-v"];framework="unittest";compile=String[]
    elseif language=="javascript"
        path="calc.mjs";broken="export function add(a,b) { return a-b; }\n"
        write(joinpath(root,"package.json"),canonical(Dict("scripts"=>Dict("test"=>"node --test --test-reporter=tap test_calc.mjs"))))
        write(joinpath(root,"test_calc.mjs"),"import {test} from 'node:test';\nimport assert from 'node:assert/strict';\nimport {add} from './calc.mjs';\ntest('addition',()=>assert.equal(add(2,3),5));\n")
        command=["node","--test","--test-reporter=tap","test_calc.mjs"];framework="tap";compile=String[]
    elseif language=="go"
        path="calc.go";broken="package calc\nfunc Add(a,b int) int { return a-b }\n"
        write(joinpath(root,"go.mod"),"module example.invalid/calc\n\ngo 1.18\n")
        write(joinpath(root,"calc_test.go"),"package calc\nimport \"testing\"\nfunc TestAdd(t *testing.T) {\n    if got:=Add(2,3); got!=5 {\n        t.Fatalf(\"addition: got %d, want 5\",got)\n    }\n}\n")
        command=[get(ENV,"SHENSCOPE_TEST_GO","go"),"test","-json","-count=1","./..."];framework="go_json";compile=String[]
    elseif language in ("c","cpp")
        path=language=="c" ? "calc.h" : "calc.hpp"
        broken="static int add(int a,int b) { return a-b; }\n"
        source=language=="c" ? "calc_test.c" : "calc_test.cpp"
        write(joinpath(root,source),"#include <stdio.h>\n#include \""*path*"\"\nint main(void) {\n    if(add(2,3)!=5) { puts(\""*source*":4:5: addition assertion failed\"); return 1; }\n    puts(\"addition passed\"); return 0;\n}\n")
        mkpath(joinpath(root,"build"));command=[joinpath(root,"build","calc-tests")];framework="raw"
        compile=[language=="c" ? "gcc" : "g++",source,"-o",command[1]]
    else
        error("Unknown fixture language")
    end
    write(joinpath(root,path),broken)
    (;path,broken,command,framework,compile)
end

function project_testing_job(server,id,job_id;timeout=90)
    context=ShenScope.server_context(server,id)
    manager=ShenScope.server_testing_tool(server).operations
    ready=timedwait(()->ShenScope.owned_operation(manager,job_id,context)["status"]!="running",timeout;pollint=0.025)
    ready==:ok || error("Test controller job did not complete")
    dispatch_rpc(server,"testing/job",Dict("session_id"=>id,"job_id"=>job_id))
end
