import { ShenScopePanel, type PanelBridge } from '../../shared/src/panel.js';
declare function acquireVsCodeApi(): { postMessage(message: unknown): void };
const host = acquireVsCodeApi();
let nextId = 1;
const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }>();
const listeners = new Set<(method: string, params: any) => void>();
const bridge: PanelBridge = {
    request(method, params = {}) {
        if (pending.size >= 128) { return Promise.reject(new Error('Too many pending editor operations')); }
        return new Promise((resolve, reject) => {
            const id = nextId++;
            const timer = setTimeout(() => { pending.delete(id); reject(new Error('Editor operation timed out')); }, 120_000);
            pending.set(id, { resolve, reject, timer }); host.postMessage({ kind: 'request', id, method, params });
        });
    },
    onEvent(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    async setCredential(variable) { await bridge.request('editor/setCredential', { variable }); },
    async openFile(path, line) { await bridge.request('editor/openFile', { path, line }); },
    async openSkillSource(job_id, session_id) { await bridge.request('editor/openSkillSource', { job_id, session_id }); },
    async openHookSource(job_id, session_id) { await bridge.request('editor/openHookSource', { job_id, session_id }); },
};
window.addEventListener('message', event => {
    const message = event.data;
    if (message.kind === 'response') {
        const request = pending.get(message.id); if (!request) { return; }
        pending.delete(message.id); clearTimeout(request.timer);
        if (message.error) { request.reject(new Error(message.error)); } else { request.resolve(message.result); }
    } else if (message.kind === 'event') { for (const listener of listeners) { listener(message.method, message.params); } }
});
const panel = new ShenScopePanel(document.getElementById('app')!, bridge);
void panel.initialize();
