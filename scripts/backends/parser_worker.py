#!/usr/bin/env python3
"""Bounded SDK transport. Project identities, graph policy and analysis live in Julia."""
import asyncio
import contextlib
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import tempfile
import shutil

MAX_FRAME = 32 * 1024 * 1024
cache = Path(os.environ['SHENSCOPE_PARSER_CACHE']).resolve()
cache.mkdir(parents=True, exist_ok=True)
os.environ['XDG_CACHE_HOME'] = str(cache)
os.environ['CGC_EMBEDDED_BUFFER_POOL_MB'] = '128'
from tree_sitter_language_pack import get_parser, downloaded_languages

PARSERS = {}
DEFINITIONS = {
    'function_definition': 'function', 'function_declaration': 'function', 'function_item': 'function',
    'method_definition': 'method', 'method_declaration': 'method', 'class_definition': 'class',
    'class_declaration': 'class', 'struct_item': 'struct', 'struct_specifier': 'struct',
    'interface_declaration': 'interface', 'type_spec': 'type', 'enum_item': 'enum',
    'module_definition': 'module', 'struct_definition': 'struct', 'short_function_definition': 'function',
}
CALLS = {'call', 'call_expression', 'function_call_expression'}

def parser_for(language):
    if language not in downloaded_languages():
        raise ValueError('Grammar is not installed; run the backend setup first: ' + language)
    if language not in PARSERS:
        PARSERS[language] = get_parser(language)
    return PARSERS[language]

def syntax_file(document):
    source = document['source'].encode('utf-8')
    if hashlib.sha256(source).hexdigest() != document['sha256']:
        raise ValueError('Source checksum mismatch')
    tree = parser_for(document['language']).parse(source)
    if tree.root_node.has_error:
        raise ValueError('Source contains a parse error: ' + document['path'])
    symbols, references, edges = [], [], []
    def text(node):
        return source[node.start_byte:node.end_byte].decode('utf-8') if node else ''
    def span(node):
        return {'start_line': node.start_point.row + 1, 'end_line': node.end_point.row + 1,
                'start_column': node.start_point.column + 1, 'end_column': node.end_point.column + 1}
    def walk(node, owner=None, qualified=''):
        current = owner
        if node.type in DEFINITIONS:
            name_node = node.child_by_field_name('name')
            if name_node is None and document['language'] == 'julia':
                signature = next((n for n in node.named_children if n.type in ('signature', 'call_expression')), None)
                if signature:
                    todo = [signature]
                    while todo and name_node is None:
                        candidate = todo.pop(0)
                        if candidate.type == 'identifier': name_node = candidate
                        else: todo.extend(candidate.named_children)
            if name_node:
                name = text(name_node); label = qualified + '.' + name if qualified else name
                key = str(node.start_byte); current = key
                symbols.append({'key': key, 'kind': DEFINITIONS[node.type], 'name': name, 'qualified_name': label,
                                **span(node), 'signature': source[node.start_byte:source.find(b'\n', node.start_byte) if b'\n' in source[node.start_byte:] else node.end_byte].decode('utf-8')[:1024]})
                if owner is not None: edges.append({'src': owner, 'dst': key, 'kind': 'contains', **span(node)})
                qualified = label
        if node.type in CALLS:
            function = node.child_by_field_name('function') or node.child_by_field_name('name')
            if function is None and node.named_children: function = node.named_children[0]
            value = text(function)
            if value and value not in {'new', 'super'}:
                simple = value.replace('::', '.').split('.')[-1]
                references.append({'src': current or '__file__', 'name': simple, 'qualified': value != simple, **span(node)})
        for child in node.named_children: walk(child, current, qualified)
    walk(tree.root_node)
    return {'path': document['path'], 'sha256': document['sha256'], 'language': document['language'],
            'symbols': symbols, 'references': references, 'edges': edges}

class CodeGraphSDK:
    def __init__(self, root, state):
        if importlib.metadata.version('codegraphcontext') != '0.6.13':
            raise ValueError('Unsupported CodeGraphContext version')
        import codegraphcontext.cli.config_manager as config
        config.CONFIG_DIR = Path(state) / 'config'; config.CONFIG_FILE = config.CONFIG_DIR / '.env'
        config.CONTEXT_CONFIG_FILE = config.CONFIG_DIR / 'config.yaml'
        config._LEGACY_CONTEXT_CONFIG_FILE = config.CONFIG_DIR / 'legacy-config.yaml'
        # Project dotenv/config must not choose the private parser database or credentials.
        config.should_apply_project_dotenv = lambda: False
        from codegraphcontext.core.database_ladybug import LadybugDBManager
        from codegraphcontext.core.jobs import JobManager
        from codegraphcontext.tools.graph_builder import GraphBuilder
        self.root = Path(root).resolve(); self.state = Path(state).resolve()
        self.state.mkdir(parents=True, exist_ok=True)
        # The Core journal is durable truth. SDK DB files are disposable derived
        # cache, never copies of a source directory or the authoritative graph.
        for directory in self.state.glob('sdk-db-*'):
            marker = directory / 'owner.json'
            if not directory.is_dir() or directory.is_symlink() or not marker.is_file(): continue
            try:
                owner = json.loads(marker.read_text())
                if owner.get('root') != str(self.root): continue
                os.kill(owner['pid'], 0)
            except ProcessLookupError: shutil.rmtree(directory)
            except (ValueError, KeyError, PermissionError, OSError): pass
        self.cache_dir = Path(tempfile.mkdtemp(prefix='sdk-db-', dir=self.state))
        (self.cache_dir / 'owner.json').write_text(json.dumps({'root': str(self.root), 'pid': os.getpid()}))
        self.database = LadybugDBManager(str(self.cache_dir / 'ladybug'))
        self.loop = asyncio.new_event_loop()
        self.builder = GraphBuilder(self.database, JobManager(), self.loop)
        self.builder.create_schema(); self.data = {}
        self.dirty = True
    def close(self):
        self.database.close_driver(); self.loop.close()
        shutil.rmtree(self.cache_dir)
    def update(self, documents, deleted, full):
        pending = {} if full else dict(self.data)
        for path in deleted: pending.pop(path, None)
        for document in documents:
            absolute = (self.root / document['path']).resolve()
            absolute.relative_to(self.root)
            if absolute.read_bytes() != document['source'].encode('utf-8'):
                raise ValueError('Source changed before SDK extraction')
            parser_for(document['language'])
            tree = parser_for(document['language']).parse(document['source'].encode('utf-8'))
            if tree.root_node.has_error: raise ValueError('Source contains a parse error: ' + document['path'])
            data = self.builder.parse_file(self.root, absolute)
            if data.get('error'): raise ValueError('SDK source extraction failed: ' + document['path'])
            pending[document['path']] = data
        files = [self.root / path for path in sorted(pending)]
        imports = self.builder.pre_scan_imports(files)
        try:
            if full or self.dirty:
                # Only the adapter-owned database is cleared. Source directories are never copied.
                with self.database.get_driver().session() as session: session.run('MATCH (n) DETACH DELETE n')
                self.builder.add_repository_to_graph(self.root)
                for data in pending.values(): self.builder.add_file_to_graph(data, self.root.name, imports, repo_path_str=str(self.root))
            else:
                for path in set(deleted) | {d['path'] for d in documents}:
                    self.builder.delete_file_from_graph(str(self.root / path))
                    if path in pending: self.builder.add_file_to_graph(pending[path], self.root.name, imports, repo_path_str=str(self.root))
            # This upstream path still performs global call/inheritance resolution.
            self.builder.delete_relationship_links(self.root)
            self.builder.link_function_calls(list(pending.values()), imports)
            self.builder.link_inheritance(list(pending.values()), imports)
            nodes, edges = self.export()
            self.data = pending; self.dirty = False
            return {'nodes': nodes, 'edges': edges, 'diagnostics': self.builder.last_call_resolution_diagnostics,
                    'sdk': 'codegraphcontext-0.6.13', 'global_relink': True}
        except Exception:
            self.dirty = True; raise
    def export(self):
        def compact(value): return {key: item for key, item in value.items() if item is not None and key not in ('source', 'embedding', 'indexed_at', 'commit_hash')}
        with self.database.get_driver().session() as session:
            nodes = [compact(row['n']) for row in session.run('MATCH (n) RETURN n').data()]
            edges = [compact(row['r']) for row in session.run('MATCH (a)-[r]->(b) RETURN r').data()]
        return nodes, edges

sdk = None
try:
    while True:
        frame = sys.stdin.buffer.readline(MAX_FRAME + 1)
        if not frame: break
        if len(frame) > MAX_FRAME or not frame.endswith(b'\n'): raise ValueError('Oversized or incomplete backend frame')
        identifier = None
        try:
            request = json.loads(frame); identifier = request['id']; operation = request['operation']
            # The SDK sometimes prints configuration diagnostics; never mix these with protocol stdout.
            with contextlib.redirect_stdout(sys.stderr):
                if operation == 'syntax': result = [syntax_file(document) for document in request['documents']]
                elif operation == 'codegraph':
                    if sdk is None: sdk = CodeGraphSDK(request['root'], request['state'])
                    if str(sdk.root) != request['root']: raise ValueError('Backend worker workspace changed')
                    result = sdk.update(request['documents'], request['deleted'], request['full'])
                else: raise ValueError('Unknown backend operation')
            response = {'id': identifier, 'result': result}
        except Exception as error:
            response = {'id': identifier, 'error': {'type': type(error).__name__, 'message': str(error)[:2000]}}
        encoded = json.dumps(response, ensure_ascii=False, separators=(',', ':')).encode('utf-8') + b'\n'
        if len(encoded) > MAX_FRAME: encoded = json.dumps({'id': identifier, 'error': {'type': 'Capacity', 'message': 'Backend result exceeds limit'}}).encode() + b'\n'
        sys.stdout.buffer.write(encoded); sys.stdout.buffer.flush()
finally:
    if sdk: sdk.close()
