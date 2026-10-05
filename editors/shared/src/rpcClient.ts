import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { setTimeout, clearTimeout } from 'node:timers';

export type RPCValue = null | boolean | number | string | RPCValue[] | { [key: string]: RPCValue };
export type Notification = { method: string; params: any };
export type CoreLaunch = { executable: string; args: string[]; cwd: string; env?: NodeJS.ProcessEnv };
type Pending = { resolve: (value: any) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> };
const compilerBoundStarts = new Set([
    'agent/start', 'project/start', 'diagnostics/start', 'extensions/start', 'terminal/start',
    'analyzers/start', 'models/start', 'memory/start', 'security/start',
    'context/start', 'skills/start', 'hooks/start', 'mcp/start',
]);

export class CoreClient {
    private child?: ChildProcessWithoutNullStreams;
    private bytes = Buffer.alloc(0);
    private expected?: number;
    private nextId = 1;
    private pending = new Map<number, Pending>();
    private listeners = new Set<(event: Notification) => void>();
    private closed = false;
    private stderrTail = '';
    private termination?: Promise<void>;
    private killTimer?: ReturnType<typeof setTimeout>;

    constructor(private readonly launch: CoreLaunch) {}

    async start(): Promise<any> {
        if (this.child || this.closed) { throw new Error('Core client already started or closed'); }
        this.child = spawn(this.launch.executable, this.launch.args, {
            cwd: this.launch.cwd, env: this.launch.env ?? process.env, shell: false,
            stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
        });
        this.termination = new Promise(resolve => this.child!.once('close', () => {
            if (this.killTimer) { clearTimeout(this.killTimer); this.killTimer = undefined; }
            resolve();
        }));
        this.child.stdout.on('data', (chunk: Buffer) => {
            try { this.accept(chunk); } catch (error) { this.fail(error instanceof Error ? error : new Error('Invalid Core frame')); }
        });
        this.child.stderr.on('data', (chunk: Buffer) => {
            this.stderrTail = (this.stderrTail + chunk.toString('utf8')).slice(-8192);
        });
        this.child.on('error', () => this.fail(new Error('Unable to launch Julia Core')));
        this.child.on('close', () => this.fail(new Error('Julia Core stopped')));
        return this.request('initialize', { protocol_version: '1.0', client: 'ShenScope editor' }, 120_000);
    }

    onNotification(listener: (event: Notification) => void): () => void {
        this.listeners.add(listener);
        return () => this.listeners.delete(listener);
    }

    request(method: string, params: Record<string, unknown> = {}, timeoutMs = compilerBoundStarts.has(method) ? 120_000 : 30_000): Promise<any> {
        if (!this.child || this.closed) { return Promise.reject(new Error('Core is unavailable')); }
        if (this.pending.size >= 128) { return Promise.reject(new Error('Too many pending Core requests')); }
        const id = this.nextId++;
        const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, method, params }), 'utf8');
        if (body.length > 8 * 1024 * 1024) { return Promise.reject(new Error('Core request exceeds limit')); }
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error('Core request timed out'));
            }, timeoutMs);
            this.pending.set(id, { resolve, reject, timer });
            this.child!.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]), error => {
                if (error) { this.fail(new Error('Unable to write to Core')); }
            });
        });
    }

    private accept(chunk: Buffer): void {
        this.bytes = Buffer.concat([this.bytes, chunk]);
        while (true) {
            if (this.expected === undefined) {
                const end = this.bytes.indexOf('\r\n\r\n');
                if (end < 0) {
                    if (this.bytes.length > 32768) { throw new Error('Core header exceeds limit'); }
                    return;
                }
                if (end > 32768) { throw new Error('Core header exceeds limit'); }
                const lines = this.bytes.subarray(0, end).toString('ascii').split('\r\n');
                const lengths = lines.filter(line => /^content-length:/i.test(line));
                if (lengths.length !== 1) { throw new Error('Invalid Core Content-Length'); }
                const value = lengths[0].slice(lengths[0].indexOf(':') + 1).trim();
                if (!/^[1-9][0-9]*$/.test(value)) { throw new Error('Invalid Core frame length'); }
                this.expected = Number(value);
                if (this.expected > 8 * 1024 * 1024) { throw new Error('Core frame exceeds limit'); }
                this.bytes = this.bytes.subarray(end + 4);
            }
            if (this.bytes.length < this.expected) { return; }
            const body = this.bytes.subarray(0, this.expected);
            this.bytes = this.bytes.subarray(this.expected);
            this.expected = undefined;
            const decoder = new TextDecoder('utf-8', { fatal: true });
            const message = JSON.parse(decoder.decode(body));
            if (message.jsonrpc !== '2.0' || typeof message !== 'object') { throw new Error('Invalid Core envelope'); }
            if (message.id !== undefined) {
                const pending = this.pending.get(message.id);
                if (!pending) { continue; }
                this.pending.delete(message.id); clearTimeout(pending.timer);
                if (message.error) { pending.reject(new Error(message.error.message ?? 'Core request failed')); }
                else { pending.resolve(message.result); }
            } else if (typeof message.method === 'string') {
                for (const listener of this.listeners) { listener({ method: message.method, params: message.params }); }
            }
        }
    }

    private fail(error: Error): void {
        if (this.closed) { return; }
        this.closed = true;
        for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
        this.pending.clear(); this.bytes = Buffer.alloc(0);
        const child = this.child;
        if (child && child.exitCode === null && child.signalCode === null) {
            child.stdin.destroy(); child.kill();
            this.killTimer = setTimeout(() => { child.kill('SIGKILL'); }, 2000);
        }
        for (const listener of this.listeners) { listener({ method: 'transport/closed', params: { message: error.message } }); }
    }

    async dispose(): Promise<void> {
        if (!this.closed && this.child) {
            try { await this.request('shutdown', {}, 2000); } catch { /* child may already have exited */ }
        }
        this.fail(new Error('Core client closed'));
        await this.termination;
        this.listeners.clear(); this.stderrTail = '';
    }
}
