export type TerminalRequest = (method: string, params: Record<string, unknown>) => Promise<any>;
export class CoreTerminalConnection {
    private offset = 0;
    private closed = false;
    private timer?: ReturnType<typeof setTimeout>;
    private queue = Promise.resolve();
    private bufferedInput = '';
    private inputScheduled = false;
    private pendingDimensions?: { columns: number; rows: number };
    private resizeScheduled = false;
    private currentJob?: string;
    constructor(private readonly request: TerminalRequest, readonly sessionId: string, readonly handle: string,
        private readonly data: (text: string) => void, private readonly exit: (code?: number) => void,
        private readonly failure: (message: string) => void) {}

    async open(): Promise<void> { await this.poll(); }
    private async poll(): Promise<void> {
        if (this.closed) { return; }
        try {
            const result = await this.request('terminal/query', { session_id: this.sessionId, action: 'poll',
                handle: this.handle, offset: this.offset, max_bytes: 65536, format: 'terminal' });
            if (this.closed) { return; }
            const output = result.output;
            if (output.lost_bytes) { this.data(`\r\n[${output.lost_bytes} bytes no longer retained]\r\n`); }
            if (output.text) { this.data(output.text); }
            this.offset = output.next_offset;
            if (!result.running && !output.more && ['exited','failed'].includes(result.phase)) {
                this.closed = true; this.exit(result.exit_code ?? undefined); return;
            }
            this.timer = setTimeout(() => void this.poll(), output.more ? 0 : 100);
        } catch (cause) {
            this.closed = true; this.failure(cause instanceof Error ? cause.message : 'Terminal output failed'); this.exit();
        }
    }
    private schedule(work: () => Promise<void>): void {
        this.queue = this.queue.then(async () => { if (!this.closed) { await work(); } }).catch(cause => {
            this.failure(cause instanceof Error ? cause.message : 'Terminal operation failed');
        });
    }
    private async mutate(action: string, args: Record<string, unknown> = {}): Promise<void> {
        const started = await this.request('terminal/start', { session_id: this.sessionId, action, handle: this.handle, ...args });
        this.currentJob = started.job_id;
        try {
            while (!this.closed) {
                const job = await this.request('terminal/job', { session_id: this.sessionId, job_id: started.job_id });
                if (job.status !== 'running') {
                    if (job.status !== 'complete') { throw new Error(job.error ?? 'Terminal operation stopped'); }
                    return;
                }
                await new Promise(resolve => setTimeout(resolve, 50));
            }
        } finally { this.currentJob = undefined; }
    }
    input(text: string): void {
        if (this.closed) { return; }
        if (new TextEncoder().encode(this.bufferedInput + text).byteLength > 65536) {
            this.failure('Terminal input queue exceeds 64 KiB'); return;
        }
        this.bufferedInput += text;
        if (this.inputScheduled) { return; }
        this.inputScheduled = true;
        this.schedule(async () => {
            try {
                while (this.bufferedInput && !this.closed) {
                    const input = this.bufferedInput; this.bufferedInput = '';
                    await this.mutate('write', { input });
                }
            } finally { this.inputScheduled = false; }
        });
    }
    resize(columns: number, rows: number): void {
        if (this.closed || columns < 2 || rows < 2) { return; }
        this.pendingDimensions = { columns: Math.min(500,columns), rows: Math.min(500,rows) };
        if (this.resizeScheduled) { return; }
        this.resizeScheduled = true;
        this.schedule(async () => {
            try {
                while (this.pendingDimensions && !this.closed) {
                    const dimensions = this.pendingDimensions; this.pendingDimensions = undefined;
                    await this.mutate('resize', dimensions);
                }
            } finally { this.resizeScheduled = false; }
        });
    }
    interrupt(): void { this.schedule(() => this.mutate('interrupt')); }
    dispose(stop = true): void {
        if (this.closed) { return; }
        this.closed = true;
        if (this.timer) { clearTimeout(this.timer); }
        this.bufferedInput = ''; this.pendingDimensions = undefined;
        const cancel = this.currentJob;
        void (async () => {
            try {
                if (cancel) {
                    await this.request('terminal/cancel_job', { session_id: this.sessionId, job_id: cancel });
                    for(let attempt=0;attempt<100;attempt++){
                        const job=await this.request('terminal/job',{session_id:this.sessionId,job_id:cancel});
                        if(job.status!=='running'){break;}
                        await new Promise(resolve=>setTimeout(resolve,50));
                    }
                }
                if(stop){await this.request('terminal/start',{session_id:this.sessionId,action:'stop',handle:this.handle});}
            }catch(cause){this.failure(cause instanceof Error ? cause.message : 'Terminal shutdown failed');}
        })();
    }
}
