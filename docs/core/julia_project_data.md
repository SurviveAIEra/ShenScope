# Julia source evidence

The `julia_syntax` project backend indexes Julia declarations in Core using the
pinned JuliaSyntax 0.4.10 package. It implements the existing backend interface;
project persistence, incremental graph installation, watchers and analyzers use
the same fact model as the other backends. There is no parser helper process.

## Recorded facts

Files, modules, types, fields, assignments, macros and long/short method
declarations have stable source IDs and UTF-8 byte ranges. Method metadata records
positional annotations, defaults, keywords, varargs and `where` constraints.
Nested methods retain a lexical qualification. Qualified declarations such as
`Base.show` retain the declared name; this does not prove binding resolution.

IDs include path, declaration kind, qualification, positional type syntax,
optional/vararg shape, constraint syntax and same-signature occurrence ordinal.
Body edits, moved lines and type trivia preserve identity. Parameter names and
keyword defaults do not select positional dispatch. Constraint/type-variable
renaming, path changes and duplicate reordering may change identity.

Call expressions retain owning declarations, locations, qualification, splats
and keyword text. Existing graph relinking can supply unique unqualified syntax
candidates. Overloaded/dynamic calls stay unresolved. A unique local supertype
declaration can supply an inheritance candidate with reduced confidence.

Import/export text and module scope are retained. Literal relative `include`
targets are lexical path candidates; they are not opened, followed or executed.
Dynamic and escaping targets stay unresolved. Quoted code is data. Macro call
arguments are not interpreted as generated declarations. Malformed files retain
bounded parser diagnostics and a file fact, without partial declarations.

## Queries and clients

`project julia_methods FILTER --backend julia_syntax` lists declared methods.
`julia_dispatch` groups textual names and compares arity/signature patterns.
`julia_structure` exposes declarations, calls, imports, exports and includes.
The actions use `project/query` in JSON-RPC and the ordinary `project` tool.
Native Workbench and VSIX have the same source evidence cards, links and pages.

Dispatch results distinguish same syntax signatures, crossed annotation patterns
and unresolved annotation overlap. They never assert a runtime ambiguity,
overwrite or selected method. Familiar names such as `Int`, `Number` and `Any`
can be shadowed; annotations are not evaluated and subtype comparisons are not
performed. Names shared by separate module instances may be grouped together.
Generated methods, runtime loading and world age require another evidence source.

Each query checks the project revision, permissions, shared budget, cancellation
and selected source hashes. Changed source returns `stale_index`. Pages carry the
index revision and source hashes. Whole-file structure entries or dispatch groups
that exceed the existing 3 MiB result limit are refused, not silently truncated.
References, cursor resolution, inferred hover and implementation navigation are
not advertised by this syntax backend. Existing TypeScript compiler navigation
remains available through its own backend.

## Bounds and execution

Indexing requires independent Read and Persistence authorization; it requires no
Process, Network or Dynamic grant. The parser never calls project `eval`, loads
a project package, expands macros, or executes `include`/generated functions.
JuliaSyntax itself is a trusted installed dependency, not user project code.

Julia parsing accepts at most 2 MiB per source, 200,000 lexer tokens/tree nodes,
128 estimated lexical nesting levels and 256 tree levels. Signature/expression
text is bounded at 16 KiB; declarations and calls are bounded at 20,000 and
50,000 per file. Dispatch pair consideration defaults to 10,000 and is capped
at 20,000; a narrower filter is required when the limit is exceeded.

The streaming raw lexer precedes recursive parsing. The package's public
`tokenize` API itself invokes parsing and is unsuitable for this guard. The
dependency is pinned because Core uses that raw lexer seam. Comprehensions do
not accumulate unmatched block estimates. Residual parser stack exhaustion is
converted to an explicit capacity failure. These bounds are not an OS sandbox
or a hard CPU deadline. Cancellation is checked between lexer/tree/file steps;
the synchronous parser call itself cannot be interrupted cooperatively.

A small disposable method fixture precompiles extraction and the three query
paths. It has its own Read/Persistence grants and denies Process/Network/Dynamic;
it never accesses a user's project. This addresses an observed first synchronous
query timeout. It does not produce a PackageCompiler system image or eliminate
all initial agent/project-job compilation.

## Validation scope

Targeted tests cover declaration identity, Unicode/CRLF ranges, no project
execution, invalid/deep source, conservative dispatch patterns, revision/hash
guards, permission/cancellation/budget failures and independent persistence.
The 1/5/20-file oracle compares incremental facts/relations with full extraction,
then verifies replay, compaction and deletion. Real RPC, Node transport and both
development editor GUIs verify the client boundary. Installed distribution,
compiler-confirmed Julia semantics and cross-backend fact fusion remain open.
