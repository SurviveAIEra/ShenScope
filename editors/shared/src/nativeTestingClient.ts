export interface NativeTestingCancellation {
    readonly isCancellationRequested: boolean;
    onCancellationRequested(listener: () => void): {dispose(): void};
}
export interface NativeTestingTransport {
    request(method: string, params: Record<string, unknown>): Promise<any>;
    observe(listener: (method: string, params: any) => void): () => void;
    createRequestId(): string;
    approve(request: any, signal: AbortSignal): Promise<'once' | 'session' | 'deny'>;
}
export interface NativeTestingCallbacks {
    command(candidate_id: string, row: any): void;
    notice(text: string): void;
}

export function nativeTestingOutput(text: string): string {
    return text.replace(/\r\n|\r|\n/g, '\r\n');
}

// This adapter coordinates editor lifecycle only. Command selection, execution,
// permissions, interpretation and bounded result projections remain in Core.
export class CoreNativeTestingRunner {
    private active = false;
    private closed = false;
    private cancelActive?: () => void;
    constructor(private readonly transport: NativeTestingTransport, readonly catalog: any) {}
    get running(): boolean { return this.active; }

    async run(candidate_ids: string[], token: NativeTestingCancellation, callbacks: NativeTestingCallbacks): Promise<void> {
        if (this.closed || this.active) { throw new Error('Finish or cancel the current ShenScope test run.'); }
        const known = new Set<string>(this.catalog.commands.map((command: any) => command.id));
        if (!candidate_ids.length || candidate_ids.length > 16 || new Set(candidate_ids).size !== candidate_ids.length || candidate_ids.some(id => !known.has(id))) {
            throw new Error('Choose between one and sixteen published project commands. Observed cases cannot run individually.');
        }
        this.active = true;
        const session_id = this.catalog.session_id; const client_request_id = this.transport.createRequestId();
        const selected = new Set(candidate_ids); const delivered = new Set<string>();
        const approvals = new Map<string, AbortController>(); const finishedApprovals = new Set<string>();
        let job_id: string | undefined; let trace_id: string | undefined; let cancelled = token.isCancellationRequested;
        let userCancelled = cancelled; let earlyEvents: any[] = []; let earlyBytes = 0;
        let disposed = false; let approvalQueue = Promise.resolve(); let transportError: string | undefined;
        const deliver = (row: any) => {
            if (!selected.has(row?.candidate_id) || delivered.has(row.candidate_id)) { return; }
            delivered.add(row.candidate_id);
            if (!row.result && row.error?.code === 'cancelled' && !userCancelled) {
                row = {...row, error: {...row.error, code: 'unconfirmed'}};
            }
            callbacks.command(row.candidate_id, row);
        };
        const cancel = () => {
            cancelled = true; for (const controller of approvals.values()) { controller.abort(); }
            if (job_id) { void this.transport.request('testing/cancel_job', {session_id, job_id}).catch(() => undefined); }
        };
        this.cancelActive = () => { userCancelled = true; cancel(); };
        const cancellation = token.onCancellationRequested(() => { userCancelled = true; cancel(); });
        const bind = (identity: any) => {
            job_id = identity.job_id ?? job_id; trace_id = identity.trace_id ?? trace_id;
            if (trace_id) {
                const retained = earlyEvents; earlyEvents = []; earlyBytes = 0;
                for (const event of retained) { handleEvent(event); }
            }
            if (cancelled) { cancel(); }
        };
        const handleEvent = (params: any) => {
            const payload = params.payload;
            if (params.kind === 'testing_job_started') {
                if (payload?.metadata?.client_request_id === client_request_id) { bind({...payload, trace_id: params.trace_id}); }
                return;
            }
            if (!trace_id) {
                if (!['testing_run_set_progress', 'permission_request', 'permission_resolved'].includes(params.kind)) { return; }
                const bytes = JSON.stringify(params).length * 2;
                if (earlyEvents.length >= 64 || earlyBytes + bytes > 512 * 1024) {
                    transportError = 'Early Testing notifications exceeded their buffer; execution state is uncertain. No automatic replay.'; cancel(); return;
                }
                earlyEvents.push(params); earlyBytes += bytes; return;
            }
            if (params.trace_id !== trace_id) { return; }
            if (params.kind === 'testing_run_set_progress' && payload?.command) { deliver(payload.command); return; }
            if (params.kind === 'permission_resolved') {
                finishedApprovals.add(payload.id); approvals.get(payload.id)?.abort(); approvals.delete(payload.id); return;
            }
            if (params.kind !== 'permission_request' || typeof payload?.id !== 'string' || approvals.has(payload.id)) { return; }
            const controller = new AbortController(); approvals.set(payload.id, controller); if (cancelled) { controller.abort(); }
            approvalQueue = approvalQueue.then(async () => {
                if (disposed || finishedApprovals.has(payload.id)) { return; }
                let decision: 'once' | 'session' | 'deny' = 'deny';
                if (!cancelled && !controller.signal.aborted) { decision = await this.transport.approve(payload, controller.signal); }
                if (!disposed && !finishedApprovals.has(payload.id)) {
                    await this.transport.request('permissions/respond', {session_id, request_id: payload.id, decision});
                }
            }).catch(error => callbacks.notice(error instanceof Error ? error.message : 'Test approval could not be delivered.'));
        };
        const observe = this.transport.observe((method, params) => {
            if (disposed || transportError) { return; }
            if (method === 'transport/closed') { transportError = 'Core disconnected; execution state may be uncertain. No automatic replay.'; cancel(); return; }
            if (method === 'agent/event' && params?.session_id === session_id) { handleEvent(params); }
        });
        try {
            if (cancelled) { throw new Error('Test selection cancelled before starting.'); }
            try {
                const started = await this.transport.request('testing/start', {session_id, action: 'run_set', catalog_id: this.catalog.catalog_id,
                    candidate_ids, client_request_id}); bind(started);
            } catch (error) {
                // A timed-out response does not justify a second execution.
                // Recover only the existing owned job with this correlation ID.
                if (!job_id) {
                    const lookup = await this.transport.request('testing/find_job', {session_id, client_request_id});
                    if (!lookup.found) { throw error; } bind(lookup.job);
                }
                callbacks.notice('Recovered the existing Core operation; no command was replayed.');
            }
            if (cancelled) { cancel(); }
            let completed: any;
            while (!disposed) {
                if (transportError) { throw new Error(transportError); }
                const job = await this.transport.request('testing/job', {session_id, job_id});
                if (transportError) { throw new Error(transportError); }
                if (job.status !== 'running') { completed = job; break; }
                await new Promise(resolve => setTimeout(resolve, 80));
            }
            if (completed?.result) {
                for (const row of completed.result.commands ?? []) { deliver(row); }
                for (const id of completed.result.not_started_candidate_ids ?? []) {
                    deliver({candidate_id: id, execution_receipt_available: false, result: undefined,
                        error: {code: 'not_started', message: 'Selected command was not started.', execution_status: 'not_started'}});
                }
            }
            if (!completed || completed.status !== 'complete' || completed.result_hidden_by_permission) {
                const reason = completed?.result_hidden_by_permission ? 'Current Read permission prevents result delivery.' :
                    completed?.error ?? 'The Core operation was interrupted; a missing receipt does not prove that a command had no effects.';
                for (const id of candidate_ids) {
                    if (!delivered.has(id)) { deliver({candidate_id: id, execution_receipt_available: false, result: undefined,
                        error: {code: userCancelled ? 'cancelled' : 'unconfirmed', message: reason, execution_status: 'unconfirmed'}}); }
                }
                callbacks.notice(`${reason} No automatic replay.`);
            }
        } catch (error) {
            cancel();
            for (const id of candidate_ids) {
                if (!delivered.has(id)) { deliver({candidate_id: id, execution_receipt_available: false, result: undefined,
                    error: {code: userCancelled ? 'cancelled' : 'unconfirmed', message: error instanceof Error ? error.message : 'Test operation failed', execution_status: 'unconfirmed'}}); }
            }
            throw error;
        } finally {
            disposed = true; cancellation.dispose(); observe(); for (const controller of approvals.values()) { controller.abort(); }
            this.cancelActive = undefined; this.active = false;
        }
    }
    dispose(): void { this.closed = true; this.cancelActive?.(); }
}
