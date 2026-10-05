import { CancellationToken } from '../../../../base/common/cancellation.js';
import { VSBuffer } from '../../../../base/common/buffer.js';
import { Disposable } from '../../../../base/common/lifecycle.js';
import { observableValue } from '../../../../base/common/observable.js';
import { IMainThreadTestController, ITestService } from '../../testing/common/testService.js';
import { ITestProfileService } from '../../testing/common/testProfileService.js';
import { ITestResultService } from '../../testing/common/testResultService.js';
import { LiveTestResult } from '../../testing/common/testResult.js';
import { IStartControllerTests, ITestItem, ITestRunProfile, ITestErrorMessage, TestControllerCapability, TestDiffOpType,
    TestItemExpandState, TestMessageType, TestResultState, TestRunProfileBitset, namespaceTestTag } from '../../testing/common/testTypes.js';
import { CoreNativeTestingRunner, NativeTestingTransport, nativeTestingOutput } from '../browser/nativeTestingClient.js';

export class ShenScopeTestingController extends Disposable {
    private readonly runner: CoreNativeTestingRunner;
    private readonly commands = new Map<string, ITestItem>();
    private readonly cases = new Map<string, string[]>();
    private readonly root: ITestItem;
    private readonly id: string;
    private readonly controller: IMainThreadTestController;
    private closed = false;
    get busy(): boolean { return this.runner.running; }
    constructor(catalog: any, transport: NativeTestingTransport, private readonly tests: ITestService,
        private readonly profiles: ITestProfileService, private readonly results: ITestResultService) {
        super(); this.runner = new CoreNativeTestingRunner(transport, catalog); this.id = `shenscope.commands.${catalog.collection_id}`;
        const tag = namespaceTestTag(this.id, 'command');
        this.root = this.item(this.id, `ShenScope project commands · ${catalog.session_id.slice(0, 8)}`, 'Published project commands; child case results are framework reports.');
        for (const command of catalog.commands) {
            const item = this.item(`${this.id}\0${command.id}`, command.label, `${command.language} · ${command.cwd} · ${command.confidence}`);
            item.tags = [tag]; this.commands.set(command.id, item);
        }
        this.controller = {id: this.id, label: observableValue(this, 'ShenScope project commands'),
            capabilities: observableValue(this, 0 as TestControllerCapability), syncTests: async () => undefined,
            refreshTests: async () => undefined, configureRunProfile: () => undefined, expandTest: async () => undefined,
            getRelatedCode: async () => [], startContinuousRun: async () => [{error: 'Continuous testing is not available.'}],
            runTests: async (requests, token) => {
                const outcomes: {error?: string}[] = [];
                for (const request of requests) { outcomes.push(await this.run(request, token)); } return outcomes;
            }};
        this._register(tests.registerTestController(this.id, this.controller));
        const profile: ITestRunProfile = {controllerId: this.id, profileId: 1, label: 'Run project commands with ShenScope Core',
            group: TestRunProfileBitset.Run, isDefault: true, tag, hasConfigurationHandler: false, supportsContinuousRun: false};
        profiles.addProfile(this.controller, profile);
        tests.publishDiff(this.id, [{op: TestDiffOpType.AddTag, tag: {id: tag}},
            {op: TestDiffOpType.Add, item: {controllerId: this.id, expand: TestItemExpandState.Expanded, item: this.root}},
            ...[...this.commands.values()].map(item => ({op: TestDiffOpType.Add as const,
                item: {controllerId: this.id, expand: TestItemExpandState.NotExpandable, item}}))]);
    }
    private item(extId: string, label: string, description: string): ITestItem {
        return {extId, label, description, tags: [], busy: false, uri: undefined, range: null, error: null, sortText: null};
    }
    private state(value: string): TestResultState {
        return ({passed: TestResultState.Passed, failed: TestResultState.Failed, errored: TestResultState.Errored,
            skipped: TestResultState.Skipped} as Record<string, TestResultState>)[value] ?? TestResultState.Errored;
    }
    private message(text: string): ITestErrorMessage {
        return {type: TestMessageType.Error, message: text, expected: undefined, actual: undefined,
            contextValue: undefined, location: undefined, stackTrace: undefined};
    }
    private async run(request: IStartControllerTests, token: CancellationToken): Promise<{error?: string}> {
        if (this.closed) { return {error: 'This published collection is closed.'}; }
        const selected = [...this.commands].filter(([, item]) => request.testIds.includes(this.id) || request.testIds.includes(item.extId))
            .filter(([, item]) => !request.excludeExtIds.some(id => id === this.id || id === item.extId)).map(([id]) => id);
        if (!selected.length || selected.length > 16) { return {error: 'Select between one and sixteen project command entries.'}; }
        const result = this.results.getResult(request.runId);
        if (!(result instanceof LiveTestResult)) { return {error: 'The editor test result is no longer active.'}; }
        const taskId = globalThis.crypto.randomUUID(); result.addTask({id: taskId, ctrlId: this.id, name: 'ShenScope Core commands', running: true});
        for (const id of selected) {
            const item = this.commands.get(id)!;
            for (const caseId of this.cases.get(id) ?? []) { this.tests.publishDiff(this.id, [{op: TestDiffOpType.Remove, itemId: caseId}]); }
            this.cases.set(id, []); result.addTestChainToRun(this.id, [this.root, item]); result.updateState(item.extId, taskId, TestResultState.Queued);
        }
        try {
            await this.runner.run(selected, token, {notice: text => result.appendOutput(VSBuffer.fromString(text + '\r\n'), taskId),
                command: (id, row) => {
                    const item = this.commands.get(id)!; const projection = row.result;
                    if (!projection) {
                        const skipped = ['not_started', 'cancelled'].includes(row.error?.code);
                        result.updateState(item.extId, taskId, skipped ? TestResultState.Skipped : TestResultState.Errored);
                        result.appendMessage(item.extId, taskId, this.message(row.error?.message ?? 'No execution receipt available. No automatic replay.')); return;
                    }
                    result.updateState(item.extId, taskId, this.state(projection.state), projection.duration_seconds * 1000);
                    result.appendOutput(VSBuffer.fromString(nativeTestingOutput(`${projection.label} · ${projection.outcome}\n${projection.stdout}\n${projection.stderr}\n`)), taskId, undefined, item.extId);
                    if (projection.state !== 'passed') { result.appendMessage(item.extId, taskId, this.message(`${projection.outcome} · exit ${projection.exit_code}. Case results are framework reports.`)); }
                    for (const observed of projection.cases) {
                        const child = this.item(`${item.extId}\0${observed.id}`, `Reported: ${observed.label}`, observed.suite || 'Observed case; run the parent command to test again.');
                        this.cases.get(id)!.push(child.extId);
                        this.tests.publishDiff(this.id, [{op: TestDiffOpType.Add, item: {controllerId: this.id, expand: TestItemExpandState.NotExpandable, item: child}}]);
                        result.addTestChainToRun(this.id, [this.root, item, child]); result.updateState(child.extId, taskId, this.state(observed.state), observed.duration_seconds == null ? undefined : observed.duration_seconds * 1000);
                        if (observed.state !== 'passed' && observed.details) { result.appendMessage(child.extId, taskId, this.message(observed.details)); }
                    }
                    if (projection.projection_truncated) { result.appendOutput(VSBuffer.fromString('Editor projection is partial; inspect the retained Core receipt.\r\n'), taskId, undefined, item.extId); }
                }});
            return {};
        } catch (error) { return {error: error instanceof Error ? error.message : 'Core testing failed; no automatic replay.'}; }
        finally { result.markTaskComplete(taskId); }
    }
    override dispose(): void {
        if (this.closed) { return; } this.closed = true; this.runner.dispose(); this.profiles.removeProfile(this.id);
        this.tests.publishDiff(this.id, [{op: TestDiffOpType.Remove, itemId: this.id}]); super.dispose();
    }
}
