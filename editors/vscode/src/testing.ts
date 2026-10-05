import * as vscode from 'vscode';
import { CoreNativeTestingRunner, NativeTestingTransport, nativeTestingOutput } from '../../shared/src/nativeTestingClient.js';

export class ShenScopeTestingController implements vscode.Disposable {
    private readonly controller: vscode.TestController;
    private readonly runner: CoreNativeTestingRunner;
    private readonly group: vscode.TestItem;
    private readonly commands = new Map<string, vscode.TestItem>();
    get busy(): boolean { return this.runner.running; }
    constructor(catalog: any, transport: NativeTestingTransport) {
        this.runner = new CoreNativeTestingRunner(transport, catalog);
        this.controller = vscode.tests.createTestController(`shenscope.commands.${catalog.collection_id}`, 'ShenScope project commands');
        const tag = new vscode.TestTag('command');
        this.group = this.controller.createTestItem('project-commands', `Project commands · ${catalog.session_id.slice(0, 8)}`);
        this.group.description = 'Published commands; reported cases appear after execution.'; this.group.tags = [tag]; this.controller.items.add(this.group);
        for (const command of catalog.commands) {
            const item = this.controller.createTestItem(`command:${command.id}`, command.label);
            item.description = `${command.language} · ${command.cwd} · ${command.confidence}`; item.tags = [tag];
            this.commands.set(command.id, item); this.group.children.add(item);
        }
        this.controller.createRunProfile('Run project commands with ShenScope Core', vscode.TestRunProfileKind.Run,
            (request, token) => this.run(request, token), true, tag, false);
    }
    private async run(request: vscode.TestRunRequest, token: vscode.CancellationToken): Promise<void> {
        const included = request.include;
        const selected = [...this.commands].filter(([, item]) => !included || included.includes(this.group) || included.includes(item))
            .filter(([, item]) => !(request.exclude ?? []).includes(this.group) && !(request.exclude ?? []).includes(item)).map(([id]) => id);
        const run = this.controller.createTestRun(request, 'ShenScope Core commands', false);
        if (!selected.length || selected.length > 16) { run.appendOutput('Select between one and sixteen project command entries.\r\n'); run.end(); return; }
        for (const id of selected) { const item = this.commands.get(id)!; item.children.replace([]); run.enqueued(item); }
        try {
            await this.runner.run(selected, token, {notice: text => run.appendOutput(text + '\r\n'), command: (id, row) => {
                const item = this.commands.get(id)!; const projection = row.result;
                if (!projection) {
                    if (['not_started', 'cancelled'].includes(row.error?.code)) { run.skipped(item); }
                    else { run.errored(item, new vscode.TestMessage(row.error?.message ?? 'No execution receipt available. No automatic replay.')); }
                    return;
                }
                const duration = projection.duration_seconds * 1000;
                this.update(run, item, projection.state, `${projection.outcome} · exit ${projection.exit_code}. Case results are framework reports.`, duration);
                run.appendOutput(nativeTestingOutput(`${projection.label} · ${projection.outcome}\n${projection.stdout}\n${projection.stderr}\n`), undefined, item);
                for (const observed of projection.cases) {
                    const child = this.controller.createTestItem(`case:${observed.id}`, `Reported: ${observed.label}`);
                    child.description = observed.suite || 'Observed case; run the parent command to test again.'; item.children.add(child);
                    this.update(run, child, observed.state, observed.details || `Framework reported ${observed.reported_status}.`, observed.duration_seconds == null ? undefined : observed.duration_seconds * 1000);
                }
                if (projection.projection_truncated) { run.appendOutput('Editor projection is partial; inspect the retained Core receipt.\r\n', undefined, item); }
            }});
        } catch (error) { run.appendOutput((error instanceof Error ? error.message : 'Core test operation interrupted.') + ' No automatic replay.\r\n'); }
        finally { run.end(); }
    }
    private update(run: vscode.TestRun, item: vscode.TestItem, state: string, message: string, duration?: number): void {
        if (state === 'passed') { run.passed(item, duration); }
        else if (state === 'failed') { run.failed(item, new vscode.TestMessage(message), duration); }
        else if (state === 'skipped') { run.skipped(item); }
        else { run.errored(item, new vscode.TestMessage(message), duration); }
    }
    dispose(): void { this.runner.dispose(); this.controller.dispose(); }
}
