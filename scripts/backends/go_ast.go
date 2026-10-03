// ShenScope helper: expose Go standard-library parser facts, without executing project code.
package main

import (
    "bufio"
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "go/ast"
    "go/parser"
    "go/token"
    "os"
    "strconv"
    "strings"
)
type document struct { Path string `json:"path"`; Source string `json:"source"`; SHA string `json:"sha256"`; Language string `json:"language"` }
type request struct { ID int `json:"id"`; Operation string `json:"operation"`; Documents []document `json:"documents"` }
type record = map[string]interface{}
func parse(d document) (record,error) {
    hash:=sha256.Sum256([]byte(d.Source));if hex.EncodeToString(hash[:])!=d.SHA { return nil,fmt.Errorf("source checksum mismatch") }
    if d.Language!="go" {return nil,fmt.Errorf("unsupported language")}
    set:=token.NewFileSet();file,err:=parser.ParseFile(set,d.Path,d.Source,parser.AllErrors);if err!=nil {return nil,err}
    symbols:=[]record{};references:=[]record{};edges:=[]record{}
    span:=func(node ast.Node) record { start:=set.Position(node.Pos());end:=set.Position(node.End());return record{"start_line":start.Line,"end_line":end.Line,"start_column":start.Column,"end_column":end.Column} }
    symbol:=func(node ast.Node,name,kind,signature string) string {
        key:=strconv.Itoa(set.Position(node.Pos()).Offset);r:=span(node);r["key"]=key;r["name"]=name;r["kind"]=kind;r["qualified_name"]=name;r["signature"]=signature;symbols=append(symbols,r);return key
    }
    for _,declaration:=range file.Decls {
        owner:="__file__"
        if function,ok:=declaration.(*ast.FuncDecl);ok {
            name:=function.Name.Name;kind:="function"
            if function.Recv!=nil {kind="method";name=d.Source[set.Position(function.Recv.Pos()).Offset:set.Position(function.Recv.End()).Offset]+"."+name}
            start:=set.Position(function.Pos()).Offset;end:=set.Position(function.Type.End()).Offset
            owner=symbol(function,name,kind,strings.TrimSpace(d.Source[start:end]))
        }
        ast.Inspect(declaration,func(node ast.Node) bool {
            if node==nil {return true}
            if spec,ok:=node.(*ast.TypeSpec);ok {symbol(spec,spec.Name.Name,"type",spec.Name.Name)}
            if call,ok:=node.(*ast.CallExpr);ok {
                name:="";qualified:=false
                switch f:=call.Fun.(type) {case *ast.Ident:name=f.Name;case *ast.SelectorExpr:name=f.Sel.Name;qualified=true}
                if name!="" {r:=span(call);r["src"]=owner;r["name"]=name;r["qualified"]=qualified;references=append(references,r)}
            }
            return true
        })
    }
    return record{"path":d.Path,"sha256":d.SHA,"language":"go","symbols":symbols,"references":references,"edges":edges},nil
}
func main() {
    scanner:=bufio.NewScanner(os.Stdin);scanner.Buffer(make([]byte,64*1024),32*1024*1024);output:=bufio.NewWriter(os.Stdout)
    for scanner.Scan() {
        var input request;response:=record{}
        err:=json.Unmarshal(scanner.Bytes(),&input);response["id"]=input.ID
        results:=[]record{}
        if err==nil && input.Operation!="syntax" {err=fmt.Errorf("unknown operation")}
        if err==nil {for _,doc:=range input.Documents {var result record;result,err=parse(doc);if err!=nil {break};results=append(results,result)}}
        if err!=nil {response["error"]=record{"type":"GoParser","message":err.Error()}} else {response["result"]=results}
        encoded,_:=json.Marshal(response);output.Write(encoded);output.WriteByte('\n');output.Flush()
    }
}
