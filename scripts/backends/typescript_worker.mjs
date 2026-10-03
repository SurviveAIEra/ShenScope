// This helper exposes compiler facts only. Julia owns graph identity, queries,
// ownership, permissions, persistence and analysis. Indexed source is never run.
import { createRequire } from 'node:module';
import { resolve, dirname, basename, relative, sep } from 'node:path';
import { readFileSync, realpathSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const compilerPath = resolve(process.argv[2]);
const ts = require(compilerPath);
if (ts.version !== '5.9.2') { throw new Error('Expected pinned TypeScript 5.9.2'); }
const libraryRoot = dirname(realpathSync(compilerPath)).replaceAll(sep, '/');
const MAX_FRAME = 32 * 1024 * 1024;
const MAX_LIBRARY_BYTES = 32 * 1024 * 1024;
let libraryBytes = 0;
const libraries = new Map();
let currentRoot;
let documents = new Map();
let rootFiles = [];
let options;
let optionKey;
let service;
let projectVersion = 0;
const hash = text => createHash('sha256').update(text, 'utf8').digest('hex');
const canonicalPath = path => resolve(path).replaceAll(sep, '/');
const bounded = (text, maximum = 4096) => {
    text = String(text);
    if (Buffer.byteLength(text) <= maximum) { return text; }
    let result = ''; let bytes = 0;
    for (const character of text) {
        const size = Buffer.byteLength(character);
        if (bytes + size > maximum - 3) { break; }
        result += character; bytes += size;
    }
    return result + '…';
};

function trustedLibrary(path) {
    path = canonicalPath(path);
    if (dirname(path) !== libraryRoot || !/^lib[.a-z0-9-]*\.d\.ts$/.test(basename(path))) { return undefined; }
    if (libraries.has(path)) { return libraries.get(path); }
    try {
        if (realpathSync(path).replaceAll(sep, '/') !== path || statSync(path).size > 4 * 1024 * 1024) { return undefined; }
        const source = readFileSync(path, 'utf8');
        libraryBytes += Buffer.byteLength(source);
        if (libraryBytes > MAX_LIBRARY_BYTES) { throw new Error('Compiler library capacity exceeded'); }
        libraries.set(path, source);
        return source;
    } catch (error) {
        if (libraryBytes > MAX_LIBRARY_BYTES) { throw error; }
        return undefined;
    }
}

function sourceText(path) {
    path = canonicalPath(path);
    return documents.get(path)?.source ?? trustedLibrary(path);
}

function createService() {
    const host = {
        getScriptFileNames: () => rootFiles,
        getScriptVersion: path => documents.get(canonicalPath(path))?.sha256 ?? 'trusted-library-5.9.2',
        getScriptSnapshot: path => {
            const source = sourceText(path);
            return source === undefined ? undefined : ts.ScriptSnapshot.fromString(source);
        },
        getCompilationSettings: () => options,
        getCurrentDirectory: () => currentRoot,
        getDefaultLibFileName: settings => ts.getDefaultLibFilePath(settings),
        getProjectVersion: () => String(projectVersion),
        useCaseSensitiveFileNames: () => process.platform !== 'win32',
        readFile: path => sourceText(path),
        fileExists: path => sourceText(path) !== undefined,
        directoryExists: path => {
            const directory = canonicalPath(path);
            return directory === currentRoot || directory === libraryRoot ||
                [...documents.keys()].some(file => file.startsWith(directory + '/'));
        },
        getDirectories: path => {
            const directory = canonicalPath(path);
            const names = new Set();
            for (const file of documents.keys()) {
                if (!file.startsWith(directory + '/')) { continue; }
                const suffix = file.slice(directory.length + 1).split('/');
                if (suffix.length > 1) { names.add(suffix[0]); }
            }
            return [...names].sort();
        },
        readDirectory: () => [],
        realpath: path => canonicalPath(path),
    };
    return ts.createLanguageService(host, ts.createDocumentRegistry(process.platform !== 'win32', currentRoot));
}

function prepare(request) {
    if (request.version !== 1 || !Array.isArray(request.documents) || request.documents.length > 10000) {
        throw new Error('Invalid compiler snapshot');
    }
    const root = canonicalPath(request.root);
    const nextDocuments = new Map();
    let bytes = 0;
    for (const document of request.documents) {
        if (typeof document.path !== 'string' || typeof document.source !== 'string') { throw new Error('Invalid source document'); }
        const path = canonicalPath(resolve(root, document.path));
        if (path === root || !path.startsWith(root + '/') || nextDocuments.has(path) ||
            hash(document.source) !== document.sha256) { throw new Error('Invalid source ownership or digest'); }
        bytes += Buffer.byteLength(document.source);
        if (bytes > 24 * 1024 * 1024) { throw new Error('Compiler snapshot capacity exceeded'); }
        nextDocuments.set(path, document);
    }
    const converted = ts.convertCompilerOptionsFromJson(request.options, root);
    if (converted.errors.length) { throw new Error('Compiler rejected configuration options'); }
    converted.options.noEmit = true;
    const key = JSON.stringify(converted.options);
    const roots = request.roots.map(path => canonicalPath(resolve(root, path)));
    if (roots.some(path => !nextDocuments.has(path)) || new Set(roots).size !== roots.length) { throw new Error('Invalid compiler root files'); }
    if (currentRoot !== root || optionKey !== key) { service?.dispose(); service = undefined; }
    currentRoot = root; documents = nextDocuments; options = converted.options; optionKey = key; rootFiles = roots;
    projectVersion++;
    service ??= createService();
    const program = service.getProgram();
    if (!program) { throw new Error('Compiler did not produce a program'); }
    if (program.getOptionsDiagnostics().some(item => item.category === ts.DiagnosticCategory.Error)) {
        throw new Error('Compiler option combination is invalid');
    }
    return program;
}

function position(source, offset) {
    const value = source.getLineAndCharacterOfPosition(offset);
    return { line: value.line, character: value.character };
}

function range(source, start, ending) {
    return { start: position(source, start), end: position(source, ending) };
}

function nodeRange(source, node) {
    return range(source, node.getStart(source), node.end);
}

function declarationKind(node) {
    if (ts.isFunctionDeclaration(node)) { return 'function'; }
    if (ts.isMethodDeclaration(node) || ts.isMethodSignature(node) || ts.isGetAccessorDeclaration(node) || ts.isSetAccessorDeclaration(node)) { return 'method'; }
    if (ts.isClassDeclaration(node) || ts.isClassExpression(node)) { return 'class'; }
    if (ts.isInterfaceDeclaration(node)) { return 'interface'; }
    if (ts.isTypeAliasDeclaration(node)) { return 'type'; }
    if (ts.isEnumDeclaration(node)) { return 'enum'; }
    if (ts.isEnumMember(node)) { return 'enum_member'; }
    if (ts.isModuleDeclaration(node)) { return 'module'; }
    if (ts.isParameter(node)) { return 'parameter'; }
    if (ts.isPropertyDeclaration(node) || ts.isPropertySignature(node) || ts.isPropertyAssignment(node) || ts.isShorthandPropertyAssignment(node)) { return 'property'; }
    if (ts.isVariableDeclaration(node)) {
        return node.initializer && (ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer)) ? 'function' : 'variable';
    }
    if (ts.isImportSpecifier(node) || ts.isImportClause(node) || ts.isNamespaceImport(node) || ts.isImportEqualsDeclaration(node)) { return 'import'; }
    if (ts.isBindingElement(node)) { return 'variable'; }
    return undefined;
}

function extract(request) {
    const program = prepare(request);
    const checker = program.getTypeChecker();
    const sourceFiles = program.getSourceFiles().filter(source => documents.has(canonicalPath(source.fileName)));
    for (const source of sourceFiles) {
        if (program.getSyntacticDiagnostics(source).some(item => item.category === ts.DiagnosticCategory.Error)) {
            throw new Error('Source contains a syntax error');
        }
    }
    const declarations = new Map();
    const output = new Map();
    const occurrences = new Map();
    let declarationCount = 0; let occurrenceCount = 0; let edgeCount = 0;
    for (const source of sourceFiles) {
        const absolute = canonicalPath(source.fileName); const document = documents.get(absolute);
        const file = { path: document.path, sha256: document.sha256, symbols: [], edges: [], occurrences: [],
            diagnostics: [], unresolved_calls: 0, external_calls: 0 };
        output.set(absolute, file); occurrences.set(absolute, new Map());
        const ordinals = new Map();
        function collect(node, scope = [], parentKey = '__file__') {
            const kind = declarationKind(node);
            const nameNode = node.name;
            let nested = scope;
            let nestedParent = parentKey;
            if (kind && nameNode && (ts.isIdentifier(nameNode) || ts.isStringLiteralLike(nameNode) || ts.isNumericLiteral(nameNode))) {
                const name = bounded(nameNode.text, 1024); const qualified = [...scope, name].join('.');
                const identity = kind + ':' + qualified; const ordinal = ordinals.get(identity) ?? 0;
                ordinals.set(identity, ordinal + 1);
                const key = identity + ':' + ordinal;
                let type = '';
                try { type = bounded(checker.typeToString(checker.getTypeAtLocation(nameNode)), 2048); } catch { /* unknown type remains explicit */ }
                let signature = '';
                if (ts.isFunctionLike(node)) {
                    const selected = checker.getSignatureFromDeclaration(node);
                    if (selected) { signature = bounded(checker.signatureToString(selected), 2048); }
                }
                const item = { key, kind, name, qualified_name: bounded(qualified), range: nodeRange(source, node),
                    selection: nodeRange(source, nameNode), type, signature, parent_key: parentKey };
                file.symbols.push(item); declarations.set(node, { path: document.path, key });
                declarations.set(nameNode, { path: document.path, key });
                if (kind === 'function' && ts.isVariableDeclaration(node)) { declarations.set(node.initializer, { path: document.path, key }); }
                declarationCount++;
                if (declarationCount > 200000) { throw new Error('Compiler declaration capacity exceeded'); }
                if (!['parameter', 'import'].includes(kind)) { nested = [...scope, name]; nestedParent = key; }
            }
            ts.forEachChild(node, child => collect(child, nested, nestedParent));
        }
        collect(source);
    }

    function targetsFor(node, { followAlias = true } = {}) {
        const symbol = checker.getSymbolAtLocation(node);
        if (!symbol) { return []; }
        let target = symbol;
        if (followAlias && symbol.flags & ts.SymbolFlags.Alias) {
            try { target = checker.getAliasedSymbol(symbol); } catch { return []; }
        }
        const targets = (target.declarations ?? []).map(declaration => {
            if (ts.isSourceFile(declaration)) {
                const document = documents.get(canonicalPath(declaration.fileName));
                return document ? { path: document.path, key: '__file__' } : undefined;
            }
            return declarations.get(declaration);
        }).filter(Boolean);
        const unique = [...new Map(targets.map(item => [item.path + '\0' + item.key, item])).values()];
        return unique.slice(0, 16);
    }

    function owner(node, source) {
        for (let current = node.parent; current && current !== source; current = current.parent) {
            const declaration = declarations.get(current);
            if (declaration && (ts.isFunctionLike(current) || ts.isClassDeclaration(current) || ts.isVariableDeclaration(current) &&
                current.initializer && (ts.isArrowFunction(current.initializer) || ts.isFunctionExpression(current.initializer)))) { return declaration; }
        }
        return { path: documents.get(canonicalPath(source.fileName)).path, key: '__file__' };
    }

    function edge(file, src, dst, kind, location, provenance) {
        file.edges.push({ src, dst, kind, range: location, provenance });
        edgeCount++;
        if (edgeCount > 400000) { throw new Error('Compiler relation capacity exceeded'); }
    }

    for (const source of sourceFiles) {
        const absolute = canonicalPath(source.fileName); const file = output.get(absolute);
        const seen = occurrences.get(absolute);
        function visit(node) {
            if (ts.isIdentifier(node) || ts.isStringLiteralLike(node) && node.parent &&
                (ts.isImportDeclaration(node.parent) || ts.isExportDeclaration(node.parent))) {
                const own = declarations.get(node);
                const targets = own ? [own] : targetsFor(node);
                let type = '';
                try { type = bounded(checker.typeToString(checker.getTypeAtLocation(node)), 2048); } catch { /* unresolved */ }
                const parent = node.parent;
                const role = own ? 'declaration' : parent && (ts.isImportSpecifier(parent) || ts.isImportClause(parent) ||
                    ts.isNamespaceImport(parent)) ? 'import' : parent && ts.isTypeReferenceNode(parent) ? 'type' : 'reference';
                const access = parent && ts.isPropertyAccessExpression(parent) && parent.name === node ? parent : node;
                const use = access.parent;
                const write = use && (ts.isBinaryExpression(use) && use.left === access &&
                    use.operatorToken.kind >= ts.SyntaxKind.FirstAssignment && use.operatorToken.kind <= ts.SyntaxKind.LastAssignment ||
                    (ts.isPrefixUnaryExpression(use) || ts.isPostfixUnaryExpression(use)) &&
                    use.operand === access && [ts.SyntaxKind.PlusPlusToken, ts.SyntaxKind.MinusMinusToken].includes(use.operator));
                const occurrence = { range: nodeRange(source, node), targets, role, type, write: Boolean(write) };
                seen.set(node.pos + ':' + node.end, occurrence);
                occurrenceCount++;
                if (occurrenceCount > 200000) { throw new Error('Compiler occurrence capacity exceeded'); }
                if (!own) {
                    for (const target of targets) { edge(file, owner(node, source), target, 'references', occurrence.range, 'typescript_symbol'); }
                }
            }
            if (ts.isCallExpression(node) || ts.isNewExpression(node)) {
                const signature = checker.getResolvedSignature(node);
                const declaration = signature?.declaration;
                let target = declaration ? declarations.get(declaration) ??
                    (ts.isConstructorDeclaration(declaration) ? declarations.get(declaration.parent) : undefined) : undefined;
                if (!target && signature && ts.isNewExpression(node)) {
                    const type = checker.getTypeAtLocation(node.expression);
                    if (type.symbol?.flags & ts.SymbolFlags.Class) {
                        target = (type.symbol.declarations ?? []).map(item => declarations.get(item) ??
                            (ts.isClassExpression(item) && ts.isVariableDeclaration(item.parent) ? declarations.get(item.parent) : undefined)).find(Boolean);
                    }
                }
                if (target) { edge(file, owner(node, source), target, 'calls', nodeRange(source, node.expression), 'typescript_signature'); }
                else if (signature?.declaration) { file.external_calls++; }
                else { file.unresolved_calls++; }
            }
            if ((ts.isClassDeclaration(node) || ts.isInterfaceDeclaration(node)) && declarations.has(node)) {
                for (const clause of node.heritageClauses ?? []) {
                    for (const type of clause.types) {
                        for (const target of targetsFor(type.expression)) {
                            edge(file, declarations.get(node), target, clause.token === ts.SyntaxKind.ImplementsKeyword ? 'implements' : 'inherits',
                                nodeRange(source, type), 'typescript_heritage');
                        }
                    }
                }
            }
            if (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) {
                const specifier = node.moduleSpecifier;
                const symbol = specifier && checker.getSymbolAtLocation(specifier);
                const declaration = symbol?.declarations?.find(item => ts.isSourceFile(item));
                if (declaration && documents.has(canonicalPath(declaration.fileName))) {
                    const targetFile = documents.get(canonicalPath(declaration.fileName));
                    edge(file, { path: file.path, key: '__file__' }, { path: targetFile.path, key: '__file__' }, 'imports',
                        nodeRange(source, specifier), 'typescript_module');
                }
            }
            ts.forEachChild(node, visit);
        }
        visit(source);
        file.occurrences = [...seen.values()].sort((a, b) => a.range.start.line - b.range.start.line || a.range.start.character - b.range.start.character);
        for (const diagnostic of program.getSemanticDiagnostics(source)) {
            if (file.diagnostics.length >= 10000) { throw new Error('Compiler diagnostics capacity exceeded'); }
            const start = diagnostic.start ?? 0; const ending = start + (diagnostic.length ?? 0);
            file.diagnostics.push({ code: diagnostic.code, category: ts.DiagnosticCategory[diagnostic.category].toLowerCase(),
                message: bounded(ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')),
                range: range(source, start, ending) });
        }
    }
    return { version: 1, compiler: 'typescript', compiler_version: ts.version,
        input_sha256: request.input_sha256, config_sha256: request.config_sha256,
        files: [...output.values()].sort((a, b) => a.path.localeCompare(b.path)),
        statistics: { declarations: declarationCount, occurrences: occurrenceCount, relations: edgeCount, library_bytes: libraryBytes } };
}

function respond(frame) {
    let result;
    try {
        const request = JSON.parse(frame);
        if (!Number.isSafeInteger(request.id) || request.operation !== 'semantic') { throw new Error('Invalid compiler operation'); }
        result = { id: request.id, result: extract(request) };
    } catch {
        const id = (() => { try { return JSON.parse(frame).id; } catch { return null; } })();
        result = { id, error: { message: 'Compiler rejected source, configuration or capacity limits' } };
    }
    let output = JSON.stringify(result) + '\n';
    if (Buffer.byteLength(output) > MAX_FRAME) {
        output = JSON.stringify({ id: result.id, error: { message: 'Compiler result exceeds capacity' } }) + '\n';
    }
    process.stdout.write(output);
}

let pending = Buffer.alloc(0);
process.stdin.on('data', chunk => {
    pending = Buffer.concat([pending, chunk]);
    while (true) {
        const ending = pending.indexOf(0x0a);
        if (ending < 0) { break; }
        if (ending > MAX_FRAME) { process.exitCode = 1; process.stdin.destroy(); return; }
        const frame = new TextDecoder('utf-8', { fatal: true }).decode(pending.subarray(0, ending));
        pending = pending.subarray(ending + 1);
        respond(frame);
    }
    if (pending.length > MAX_FRAME) { process.exitCode = 1; process.stdin.destroy(); }
});
process.stdin.on('end', () => { service?.dispose(); });
