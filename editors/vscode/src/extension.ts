import * as vscode from 'vscode';
import { randomBytes } from 'node:crypto';
import { resolve, relative, isAbsolute } from 'node:path';
import { CoreClient } from '../../shared/src/rpcClient.js';
import { PANEL_RPC_METHODS } from '../../shared/src/rpcMethods.js';
import { CoreTerminalConnection } from '../../shared/src/terminalClient.js';

const methods = new Set<string>(PANEL_RPC_METHODS);

class ShenScopeView implements vscode.WebviewViewProvider, vscode.Disposable {
    private client?: CoreClient;
    private starting?: Promise<any>;
    private hello?: any;
    private view?: vscode.WebviewView;
    private eventListener?: () => void;
    private readonly log = vscode.window.createOutputChannel('ShenScope');
    private readonly terminals = new Map<string,vscode.Terminal>();

    constructor(private readonly context: vscode.ExtensionContext) {}

    private async connect(): Promise<any> {
        if (this.starting) { return this.starting; }
        if (!vscode.workspace.isTrusted) { throw new Error('Trust this workspace before starting ShenScope'); }
        const folder = vscode.workspace.workspaceFolders?.[0];
        if (!folder || folder.uri.scheme !== 'file') { throw new Error('Open a local workspace folder'); }
        const launcher = vscode.workspace.getConfiguration('shenscope');
        const project = launcher.get<string>('corePath') || this.context.asAbsolutePath('core');
        const executable = launcher.get<string>('juliaPath') || 'julia';
        const state = launcher.get<string>('statePath') || this.context.globalStorageUri.fsPath;
        this.client = new CoreClient({ executable, args: ['--startup-file=no', '--threads=4', `--project=${project}`, '-e',
            'using ShenScope; exit(ShenScope.main())', '--', 'serve', '--stdio', '--root', folder.uri.fsPath, '--state-dir', state], cwd: folder.uri.fsPath });
        this.eventListener = this.client.onNotification(event => {
            void this.view?.webview.postMessage({ kind: 'event', method: event.method, params: event.params });
            if (event.method === 'transport/closed') { this.starting = undefined; this.log.appendLine(event.params.message); }
        });
        this.starting = (async () => {
            this.hello = await this.client!.start();
            const config = await this.client!.request('config/get');
            const variables = new Set<string>([config.value.provider.key_env]);
            for (const provider of Object.values(config.value.model_routing?.providers ?? {}) as any[]) {
                variables.add(provider.key_env);
            }
            for (const server of Object.values(config.value.mcp?.servers ?? {}) as any[]) {
                for (const binding of [...(server.environment_env ?? []), ...(server.header_env ?? [])]) { variables.add(binding.env); }
            }
            for (const variable of variables) {
                const secret = await this.context.secrets.get(`model:${variable}`);
                if (secret) { await this.client!.request('credentials/set', { variable, value: secret }); }
            }
            return this.hello;
        })();
        try { return await this.starting; }
        catch (error) { this.starting = undefined; throw error; }
    }

    resolveWebviewView(view: vscode.WebviewView): void {
        this.view = view;
        const dist = vscode.Uri.joinPath(this.context.extensionUri, 'dist');
        view.webview.options = { enableScripts: true, localResourceRoots: [dist] };
        const nonce = randomBytes(18).toString('base64');
        const script = view.webview.asWebviewUri(vscode.Uri.joinPath(dist, 'panel.js'));
        const style = view.webview.asWebviewUri(vscode.Uri.joinPath(dist, 'panel.css'));
        view.webview.html = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src ${view.webview.cspSource}; script-src 'nonce-${nonce}';"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="${style}"></head><body><div id="app"></div><script nonce="${nonce}" src="${script}"></script></body></html>`;
        view.webview.onDidReceiveMessage(async message => {
            if (!message || message.kind !== 'request' || !Number.isSafeInteger(message.id) || typeof message.method !== 'string') { return; }
            try {
                await this.connect();
                let result: any;
                if (message.method === 'editor/hello') { result = this.hello; }
                else if (message.method === 'editor/setCredential') {
                    const variable = message.params?.variable;
                    if (typeof variable !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(variable)) { throw new Error('Invalid key variable'); }
                    const value = await vscode.window.showInputBox({ title: 'ShenScope API key', password: true, ignoreFocusOut: true, prompt: 'Stored in VS Code secure storage. Leave empty to remove.' });
                    if (value !== undefined) {
                        if (value) { await this.context.secrets.store(`model:${variable}`, value); }
                        else { await this.context.secrets.delete(`model:${variable}`); }
                        await this.client!.request('credentials/set', { variable, value });
                    }
                    result = null;
                } else if (message.method === 'editor/openSkillSource' || message.method === 'editor/openHookSource') {
                    const source = await this.client!.request(message.method === 'editor/openSkillSource' ? 'skills/source_path' : 'hooks/source_path', message.params ?? {});
                    await vscode.window.showTextDocument(vscode.Uri.file(source.path)); result = null;
                } else if (message.method === 'editor/openTerminal') {
                    const handle=String(message.params?.handle??'');const session_id=String(message.params?.session_id??'');
                    await this.client!.request('terminal/query',{session_id,action:'poll',handle,max_bytes:4,format:'terminal'});
                    const key=session_id+':'+handle;
                    const existing=this.terminals.get(key);
                    if(existing){existing.show();}else{
                        const write=new vscode.EventEmitter<string>();const close=new vscode.EventEmitter<number>();
                        const connection=new CoreTerminalConnection((method,params)=>this.client!.request(method,params),session_id,handle,
                            text=>write.fire(text),code=>close.fire(Math.max(0,Math.min(255,code??0))),
                            error=>write.fire(`\r\n[ShenScope: ${error.replace(/[\x00-\x1f\x7f]/g,' ')}]\r\n`));
                        const pty:vscode.Pseudoterminal={onDidWrite:write.event,onDidClose:close.event,
                            open:dimensions=>{void connection.open();if(dimensions){connection.resize(dimensions.columns,dimensions.rows);}},
                            close:()=>{connection.dispose();this.terminals.delete(key);write.dispose();close.dispose();},
                            handleInput:text=>connection.input(text),setDimensions:dimensions=>connection.resize(dimensions.columns,dimensions.rows)};
                        const terminal=vscode.window.createTerminal({name:'ShenScope Core',pty});this.terminals.set(key,terminal);terminal.show();
                    }
                    result=null;
                } else if (message.method === 'editor/openFile') {
                    const root = vscode.workspace.workspaceFolders![0].uri.fsPath;
                    const path = resolve(root, String(message.params?.path));
                    const rel = relative(root, path);
                    if (isAbsolute(rel) || rel.startsWith('..')) { throw new Error('File escapes workspace'); }
                    const line = Math.max(1, Math.min(10_000_000, Number(message.params?.line) || 1));
                    await vscode.window.showTextDocument(vscode.Uri.file(path), { selection: new vscode.Range(line - 1, 0, line - 1, 0) }); result = null;
                } else {
                    if (!methods.has(message.method)) { throw new Error('Unknown editor operation'); }
                    result = await this.client!.request(message.method, message.params ?? {});
                }
                await view.webview.postMessage({ kind: 'response', id: message.id, result });
            } catch (error) {
                await view.webview.postMessage({ kind: 'response', id: message.id, error: error instanceof Error ? error.message : 'Editor operation failed' });
            }
        }, undefined, this.context.subscriptions);
    }

    async restart(): Promise<void> { for(const terminal of this.terminals.values()){terminal.dispose();}this.terminals.clear();this.eventListener?.(); await this.client?.dispose(); this.client = undefined; this.starting = undefined; await this.connect(); }
    dispose(): void { for(const terminal of this.terminals.values()){terminal.dispose();}this.terminals.clear();this.eventListener?.(); void this.client?.dispose(); this.log.dispose(); }
}

export function activate(context: vscode.ExtensionContext): void {
    const view = new ShenScopeView(context);
    context.subscriptions.push(view, vscode.window.registerWebviewViewProvider('shenscope.chat', view),
        vscode.commands.registerCommand('shenscope.restart', () => view.restart()));
}
