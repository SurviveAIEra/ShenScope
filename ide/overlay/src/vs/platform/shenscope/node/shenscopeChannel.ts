import { realpathSync } from 'node:fs';
import { join } from 'node:path';
import { Emitter, Event } from '../../../base/common/event.js';
import { Disposable } from '../../../base/common/lifecycle.js';
import { IServerChannel } from '../../../base/parts/ipc/common/ipc.js';
import { CoreClient } from '../common/rpcClient.js';

type Entry = { client?: CoreClient; hello?: unknown; starting?: Promise<unknown>; emitter: Emitter<unknown> };
const methods = new Set(['health', 'config/get', 'config/set', 'credentials/set', 'credentials/status', 'sessions/list',
    'sessions/create', 'sessions/get', 'sessions/export', 'sessions/rename', 'sessions/archive', 'sessions/pin',
    'sessions/branch', 'agent/start', 'agent/cancel', 'agent/steer', 'permissions/respond', 'tools/list', 'runtime/status',
    'project/backends', 'project/start', 'project/job', 'project/cancel', 'project/query']);

// Runs in Code-OSS's shared utility process, independently of extension hosts.
export class ShenScopeChannel extends Disposable implements IServerChannel<string> {
    private readonly entries = new Map<string, Entry>();

    private entry(context: string): Entry {
        let entry = this.entries.get(context);
        if (!entry) {
            if (this.entries.size >= 32) { throw new Error('ShenScope window limit reached'); }
            entry = { emitter: new Emitter<unknown>() }; this.entries.set(context, entry);
        }
        return entry;
    }

    listen<T>(context: string, event: string): Event<T> {
        if (event !== 'notification') { throw new Error('Unknown ShenScope event'); }
        return this.entry(context).emitter.event as Event<T>;
    }

    async call<T>(context: string, command: string, arg?: any): Promise<T> {
        const entry = this.entry(context);
        if (command === 'start') {
            if (entry.starting) { return entry.starting as Promise<T>; }
            if (typeof arg?.root !== 'string' || typeof arg?.state !== 'string') { throw new Error('Invalid ShenScope launch'); }
            const root = realpathSync(arg.root);
            const executable = arg.executable || process.env['SHENSCOPE_JULIA'] || 'julia';
            const resources = (process as NodeJS.Process & { resourcesPath?: string }).resourcesPath ?? process.cwd();
            const project = arg.project || process.env['SHENSCOPE_CORE_DIR'] || join(resources, 'app', 'shenscope', 'core');
            entry.client = new CoreClient({ executable, cwd: root, args: ['--startup-file=no', '--threads=4', `--project=${project}`,
                '-e', 'using ShenScope; exit(ShenScope.main())', '--', 'serve', '--stdio', '--root', root, '--state-dir', arg.state] });
            entry.client.onNotification(notification => entry.emitter.fire(notification));
            entry.starting = entry.client.start().then(hello => { entry.hello = hello; return hello; });
            try { return await entry.starting as T; }
            catch (error) { entry.starting = undefined; throw error; }
        }
        if (command === 'stop') {
            await entry.client?.dispose(); entry.emitter.dispose(); this.entries.delete(context); return undefined as T;
        }
        if (command !== 'request' || !entry.client || !entry.hello) { throw new Error('ShenScope Core is unavailable'); }
        if (!methods.has(arg?.method)) { throw new Error('Unknown ShenScope operation'); }
        return entry.client.request(arg.method, arg.params ?? {}) as Promise<T>;
    }

    override dispose(): void {
        for (const entry of this.entries.values()) { void entry.client?.dispose(); entry.emitter.dispose(); }
        this.entries.clear(); super.dispose();
    }
}
