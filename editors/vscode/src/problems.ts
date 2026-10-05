import * as vscode from 'vscode';
import { lstat, readFile } from 'node:fs/promises';
import { join, relative, isAbsolute } from 'node:path';
import { CoreProblemsPublisher, problemRelativePath, problemSourceHash, type ProblemsReference,
    type ProblemsTransport, type ProblemFile } from '../../shared/src/nativeProblemsClient.js';

export class ShenScopeProblemsController implements vscode.Disposable {
    private readonly collection = vscode.languages.createDiagnosticCollection('shenscope.core.problems');
    private readonly subscriptions: vscode.Disposable[] = [];
    private constructor(private readonly root: string, private readonly publisher: CoreProblemsPublisher) {
        const changed = (uri: vscode.Uri) => {
            if (uri.scheme !== 'file') { return; }
            const path = relative(root, uri.fsPath);
            if (!isAbsolute(path) && !path.split(/[\\/]/).includes('..')) { publisher.invalidate(path.replace(/\\/g, '/')); }
        };
        this.subscriptions.push(vscode.workspace.onDidChangeTextDocument(event => changed(event.document.uri)),
            vscode.workspace.onDidCloseTextDocument(document => changed(document.uri)));
        const watcher = vscode.workspace.createFileSystemWatcher('**/*');
        this.subscriptions.push(watcher, watcher.onDidChange(changed), watcher.onDidDelete(changed), watcher.onDidCreate(changed));
    }
    static async create(root: string, transport: ProblemsTransport): Promise<ShenScopeProblemsController> {
        let controller: ShenScopeProblemsController;
        const publisher = new CoreProblemsPublisher(transport, {
            readSource: async path => {
                const safe = problemRelativePath(path); const resource = vscode.Uri.file(join(root, safe));
                const document = vscode.workspace.textDocuments.find(item => item.uri.toString() === resource.toString() && !item.isClosed);
                if (document) { return document.getText(); }
                let current = root;
                for (const part of safe.split('/')) {
                    current = join(current, part);
                    if ((await lstat(current)).isSymbolicLink()) { throw new Error('Diagnostic source is a symlink.'); }
                }
                if ((await lstat(current)).size > 8 * 1024 * 1024) { throw new Error('Diagnostic source is too large.'); }
                return (await readFile(current)).toString('utf8');
            },
            replace: files => controller.replace(files),
            remove: path => path === undefined ? controller.collection.clear() : controller.collection.delete(vscode.Uri.file(join(root, path)))
        }, await problemSourceHash(root));
        controller = new ShenScopeProblemsController(root, publisher); return controller;
    }
    private replace(files: ProblemFile[]): void {
        this.collection.clear();
        const severity = {error: vscode.DiagnosticSeverity.Error, warning: vscode.DiagnosticSeverity.Warning,
            information: vscode.DiagnosticSeverity.Information, hint: vscode.DiagnosticSeverity.Hint};
        for (const file of files) {
            const items = file.markers.map(marker => {
                const value = new vscode.Diagnostic(new vscode.Range(marker.range.start.line, marker.range.start.character,
                    marker.range.end.line, marker.range.end.character), marker.message, severity[marker.severity]);
                value.source = `ShenScope · ${marker.source}`; if (marker.code !== null) { value.code = marker.code; } return value;
            });
            this.collection.set(vscode.Uri.file(join(this.root, file.path)), items);
        }
    }
    async publish(reference: ProblemsReference): Promise<void> {
        await this.publisher.publish(reference); await vscode.commands.executeCommand('workbench.actions.view.problems');
    }
    clear(): void { this.publisher.invalidate(); }
    dispose(): void { this.publisher.dispose(); for (const subscription of this.subscriptions) { subscription.dispose(); } this.collection.dispose(); }
}
