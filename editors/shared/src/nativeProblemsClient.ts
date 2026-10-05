export interface ProblemPosition { line: number; character: number }
export interface ProblemMarker {
    id: string; message: string; severity: 'error' | 'warning' | 'information' | 'hint';
    source: string; code: string | number | null;
    range: {start: ProblemPosition; end: ProblemPosition};
}
export interface ProblemFile { path: string; source_sha256: string; markers: ProblemMarker[] }
export interface ProblemsReference { session_id: string; snapshot_id?: string; backend?: string }
export interface ProblemsAdapter {
    readSource(path: string): Promise<string>;
    replace(files: ProblemFile[]): void;
    remove(path?: string): void;
}
export interface ProblemsTransport {
    request(method: string, params: Record<string, unknown>): Promise<any>;
}

export async function problemSourceHash(text: string): Promise<string> {
    const bytes = new TextEncoder().encode(text);
    if (bytes.length > 8 * 1024 * 1024) { throw new Error('Source is too large for editor diagnostics.'); }
    const value = await globalThis.crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(value), byte => byte.toString(16).padStart(2, '0')).join('');
}

export function problemRelativePath(path: unknown): string {
    if (typeof path !== 'string' || !path.length || path.length > 4096 || /[\\:\0]/.test(path) || path.startsWith('/')) {
        throw new Error('Invalid diagnostic workspace path.');
    }
    const parts = path.split('/');
    if (parts.some(part => !part || part === '.' || part === '..') || ['.git', '.agents', '.codex'].includes(parts[0])) {
        throw new Error('Diagnostic path is outside the supported workspace.');
    }
    return path;
}

function problemPosition(value: any): ProblemPosition {
    if (!Number.isSafeInteger(value?.line) || value.line < 0 || value.line > 8 * 1024 * 1024 ||
        !Number.isSafeInteger(value?.character) || value.character < 0 || value.character > 8 * 1024 * 1024) {
        throw new Error('Invalid diagnostic position.');
    }
    return {line: value.line, character: value.character};
}

export function validateProblemProjection(value: any, session: string, rootHash: string, snapshot: string): ProblemFile[] {
    if (value?.schema !== 'shenscope.editor-problems/1' || value.session_id !== session ||
        value.root_sha256 !== rootHash || value.snapshot_id !== snapshot || !/^[a-f0-9]{64}$/.test(value.snapshot_sha256) ||
        value.column_unit !== 'utf16' || value.line_base !== 0 || value.requires_editor_buffer_hash_check !== true ||
        !Array.isArray(value.files) || value.files.length > 512) { throw new Error('Diagnostic snapshot does not match this editor.'); }
    const files: ProblemFile[] = []; const paths = new Set<string>(); let count = 0;
    for (const row of value.files) {
        const path = problemRelativePath(row.path);
        if (paths.has(path) || typeof row.source_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(row.source_sha256) ||
            !Array.isArray(row.markers) || row.markers.length > 256) { throw new Error('Invalid diagnostic source identity.'); }
        paths.add(path);
        if (value.configuration_current !== true || row.publishable !== true || row.freshness !== 'current') { continue; }
        const markers: ProblemMarker[] = [];
        for (const item of row.markers) {
            if (++count > 4096 || typeof item.id !== 'string' || !/^[a-f0-9]{64}$/.test(item.id) ||
                typeof item.message !== 'string' || !item.message.length || item.message.length > 16 * 1024 ||
                typeof item.source !== 'string' || item.source.length > 256 ||
                !['error', 'warning', 'information', 'hint'].includes(item.severity) ||
                !(item.code == null || typeof item.code === 'string' && item.code.length <= 256 || Number.isSafeInteger(item.code))) {
                throw new Error('Invalid diagnostic marker.');
            }
            const start = problemPosition(item.range?.start); const end = problemPosition(item.range?.end);
            if (start.line > end.line || start.line === end.line && start.character > end.character) { throw new Error('Reversed diagnostic range.'); }
            markers.push({id: item.id, message: item.message, source: item.source, severity: item.severity,
                code: item.code ?? null, range: {start, end}});
        }
        files.push({path, source_sha256: row.source_sha256, markers});
    }
    return files;
}

export function validateProblemSource(file: ProblemFile, text: string): void {
    const lines = text.split(/\r\n|\r|\n/);
    for (const item of file.markers) {
        for (const position of [item.range.start, item.range.end]) {
            const line = lines[position.line]; const column = position.character;
            if (line === undefined || column > line.length || column > 0 &&
                line.charCodeAt(column) >= 0xdc00 && line.charCodeAt(column) <= 0xdfff &&
                line.charCodeAt(column - 1) >= 0xd800 && line.charCodeAt(column - 1) <= 0xdbff) {
                throw new Error('Diagnostic range does not match the editor source.');
            }
        }
    }
}

// This class publishes Core-owned reports. The editor supplies current text
// and clears its own markers; it does not interpret compiler output or run fixes.
export class CoreProblemsPublisher {
    private generation = 0;
    private closed = false;
    private active = false;
    private selectedPaths = new Set<string>();
    private job?: {session_id: string; job_id: string};
    constructor(private readonly transport: ProblemsTransport, private readonly adapter: ProblemsAdapter,
        private readonly rootHash: string) {}
    get busy(): boolean { return this.active; }
    invalidate(path?: string): void {
        if (path !== undefined && !this.selectedPaths.has(path)) { return; }
        this.generation++; this.adapter.remove(path);
        if (path === undefined) { this.selectedPaths.clear(); }
        if (this.job) { void this.transport.request('problems/cancel', this.job).catch(() => undefined); }
    }
    async publish(reference: ProblemsReference): Promise<{files: number; markers: number; withheld_files: number}> {
        if (this.closed || this.active) { throw new Error('Finish the current Problems operation first.'); }
        if (typeof reference.session_id !== 'string' || !reference.session_id.length || reference.session_id.length > 128 ||
            (!!reference.backend === !!reference.snapshot_id)) { throw new Error('Choose one diagnostic source.'); }
        this.active = true; this.invalidate(); const ticket = this.generation;
        const current = () => { if (this.closed || ticket !== this.generation) { throw new Error('Diagnostics changed while publishing. Publish them again.'); } };
        try {
            let snapshot = reference.snapshot_id;
            if (reference.backend) {
                const started = await this.transport.request('problems/start', {session_id: reference.session_id, action: 'capture', backend: reference.backend});
                if (typeof started?.job_id !== 'string') { throw new Error('Core did not return a diagnostic job.'); }
                this.job = {session_id: reference.session_id, job_id: started.job_id};
                if (ticket !== this.generation) { await this.transport.request('problems/cancel', this.job); current(); }
                const deadline = Date.now() + 100_000;
                while (!snapshot) {
                    current(); const job = await this.transport.request('problems/job', this.job);
                    if (job.status === 'complete') { snapshot = job.result?.snapshot_id; if (!snapshot) { throw new Error('Diagnostic result is unavailable.'); } break; }
                    if (job.status !== 'running' || Date.now() >= deadline) { throw new Error('Diagnostic capture did not complete.'); }
                    await new Promise(resolve => setTimeout(resolve, 75));
                }
            }
            if (typeof snapshot !== 'string' || !snapshot.length || snapshot.length > 128) { throw new Error('Invalid diagnostic snapshot ID.'); }
            const request = {session_id: reference.session_id, action: 'editor', snapshot_id: snapshot};
            const projection = await this.transport.request('problems/query', request); current();
            const files = validateProblemProjection(projection, reference.session_id, this.rootHash, snapshot);
            this.selectedPaths = new Set(files.map(file => file.path));
            const accepted: ProblemFile[] = []; let bytes = 0;
            for (const file of files) {
                current();
                let text: string;
                try { text = await this.adapter.readSource(file.path); } catch { current(); continue; }
                current();
                bytes += new TextEncoder().encode(text).length;
                if (bytes > 32 * 1024 * 1024) { throw new Error('Diagnostic source reads exceed capacity.'); }
                if (await problemSourceHash(text) !== file.source_sha256) { continue; }
                validateProblemSource(file, text); accepted.push(file);
            }
            // Recheck Core permission/configuration and each editor text after
            // asynchronous reads. A changed buffer withdraws the pending publication.
            const final = await this.transport.request('problems/query', request); current();
            const finalFiles = new Map(validateProblemProjection(final, reference.session_id, this.rootHash, snapshot).map(file => [file.path, file]));
            if (final.snapshot_sha256 !== projection.snapshot_sha256) { throw new Error('Diagnostic snapshot changed.'); }
            const published: ProblemFile[] = [];
            for (const file of accepted) {
                const fresh = finalFiles.get(file.path); if (!fresh || fresh.source_sha256 !== file.source_sha256) { continue; }
                let text: string;
                try { text = await this.adapter.readSource(file.path); } catch { current(); continue; }
                current();
                bytes += new TextEncoder().encode(text).length;
                if (bytes > 64 * 1024 * 1024) { throw new Error('Diagnostic publication reads exceed capacity.'); }
                if (await problemSourceHash(text) === file.source_sha256) { validateProblemSource(file, text); published.push(file); }
            }
            current(); this.adapter.replace(published);
            return {files: published.length, markers: published.reduce((sum, file) => sum + file.markers.length, 0),
                withheld_files: projection.files.length - published.length};
        } catch (error) {
            this.adapter.remove();
            if (this.job) { await this.transport.request('problems/cancel', this.job).catch(() => undefined); }
            throw error;
        } finally { this.job = undefined; this.active = false; }
    }
    dispose(): void { if (!this.closed) { this.closed = true; this.invalidate(); } }
}
