export interface PanelBridge {
    request(method: string, params?: Record<string, unknown>): Promise<any>;
    onEvent(listener: (method: string, params: any) => void): () => void;
    setCredential(variable: string): Promise<void>;
    openFile(path: string, line?: number): Promise<void>;
}

function element<K extends keyof HTMLElementTagNameMap>(tag: K, text = '', className = ''): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag); node.textContent = text; node.className = className; return node;
}

export class ShenScopePanel {
    private sessionId?: string;
    private configRevision = '';
    private config: any;
    private capabilities: any = {};
    private status = element('div', 'Connecting…', 'status');
    private content = element('main');
    private transcript = element('div', '', 'transcript');
    private composer = element('textarea');
    private approvals = element('div', '', 'approvals');
    private tab = 'Chat';
    private disposeEvent: () => void;
    private active = false;
    private assistant?: HTMLElement;
    private maxTranscript = 200;

    constructor(private readonly root: HTMLElement, private readonly bridge: PanelBridge) {
        root.classList.add('shenscope-panel');
        const header = element('header', 'ShenScope');
        header.append(element('small', 'Open coding intelligence'));
        const nav = element('nav');
        for (const name of ['Chat', 'History', 'Settings', 'Tools', 'Runtime', 'Security', 'Intelligence', 'MCP', 'Skills', 'Hooks']) {
            nav.append(this.button(name, async () => { this.tab = name; await this.renderTab(); }));
        }
        root.append(header, this.status, nav, this.approvals, this.content);
        this.disposeEvent = bridge.onEvent((method, params) => this.event(method, params));
        this.composer.placeholder = 'Describe a coding task…'; this.composer.rows = 4;
        this.composer.addEventListener('keydown', event => {
            if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); void this.send(); }
        });
    }

    async initialize(): Promise<void> {
        await this.guard(async () => {
            const hello = await this.bridge.request('editor/hello');
            this.capabilities = hello.capabilities;
            const configuration = await this.bridge.request('config/get');
            this.config = configuration.value; this.configRevision = configuration.sha256;
            this.status.textContent = `Ready · ${this.config.provider.model}`;
            await this.renderTab();
        });
    }

    private button(text: string, action: () => Promise<void>): HTMLButtonElement {
        const button = element('button', text);
        button.addEventListener('click', () => { void this.guard(action); });
        return button;
    }

    private async guard(action: () => Promise<void>): Promise<void> {
        try { await action(); } catch (error) { this.status.textContent = error instanceof Error ? error.message : 'Operation failed'; }
    }

    private addMessage(role: string, text: string): HTMLElement {
        const row = element('article', '', role);
        row.append(element('strong', role), element('pre', text));
        this.transcript.append(row);
        while (this.transcript.childElementCount > this.maxTranscript) { this.transcript.firstElementChild?.remove(); }
        this.transcript.scrollTop = this.transcript.scrollHeight;
        return row.lastElementChild as HTMLElement;
    }

    private async send(): Promise<void> {
        await this.guard(async () => {
            const prompt = this.composer.value.trim(); if (!prompt) { return; }
            if (this.active && this.sessionId) {
                await this.bridge.request('agent/steer', { session_id: this.sessionId, prompt });
                this.addMessage('steering', prompt); this.composer.value = ''; return;
            }
            if (!this.sessionId) {
                const session = await this.bridge.request('sessions/create', { title: prompt.slice(0, 100) });
                this.sessionId = session.id;
            }
            this.addMessage('user', prompt); this.assistant = undefined;
            this.active = true; this.composer.value = ''; this.status.textContent = 'Running…';
            try { await this.bridge.request('agent/start', { session_id: this.sessionId, prompt }); }
            catch (error) { this.active = false; throw error; }
        });
    }

    private async renderTab(): Promise<void> {
        this.content.replaceChildren();
        if (this.tab === 'Chat') {
            const actions = element('div', '', 'actions');
            actions.append(this.button('Send / steer', () => this.send()), this.button('Cancel', async () => {
                if (this.sessionId && this.active) { await this.bridge.request('agent/cancel', { session_id: this.sessionId }); }
            }), this.button('New', async () => {
                if (this.active) { throw new Error('Finish or cancel the active task first'); }
                this.sessionId = undefined; this.assistant = undefined; this.transcript.replaceChildren();
            }));
            this.content.append(this.transcript, this.composer, actions); return;
        }
        if (this.tab === 'History') { await this.history(); return; }
        if (this.tab === 'Settings') { await this.settings(); return; }
        if (this.tab === 'Tools') {
            const tools = await this.bridge.request('tools/list');
            for (const tool of tools) { this.content.append(element('h3', tool.name), element('p', tool.description)); }
            return;
        }
        if (this.tab === 'Runtime' || this.tab === 'Security') {
            const runtime = await this.bridge.request('runtime/status');
            const data = this.tab === 'Security' ? { permissions: this.config.permissions, ...runtime.security } : runtime;
            this.content.append(element('pre', JSON.stringify(data, null, 2))); return;
        }
        const capability: Record<string, string> = { Intelligence: 'project_intelligence', MCP: 'mcp', Skills: 'skills', Hooks: 'hooks' };
        this.content.append(element('p', this.capabilities[capability[this.tab]] ? 'Available' : 'This feature is in development.'));
    }

    private async history(): Promise<void> {
        const sessions = await this.bridge.request('sessions/list', { include_archived: true });
        for (const session of sessions) {
            const row = element('article'); row.append(element('strong', session.title), element('small', session.status));
            row.append(this.button('Open', async () => {
                if (this.active) { throw new Error('Finish the active task before switching conversations'); }
                const full = await this.bridge.request('sessions/get', { session_id: session.id });
                this.sessionId = full.id; this.transcript.replaceChildren();
                for (const message of full.messages) {
                    if (message.role === 'tool') { this.addMessage('tool', message.text); }
                    else { this.addMessage(message.role, message.text); }
                }
                this.tab = 'Chat'; await this.renderTab();
            }));
            row.append(this.button('Branch', async () => {
                const child = await this.bridge.request('sessions/branch', { session_id: session.id });
                this.status.textContent = `Created ${child.title}`; await this.historyRefresh();
            }));
            row.append(this.button('Archive', async () => {
                await this.bridge.request('sessions/archive', { session_id: session.id }); await this.historyRefresh();
            }));
            this.content.append(row);
        }
    }
    private async historyRefresh(): Promise<void> { this.content.replaceChildren(); await this.history(); }

    private field(label: string, value: string, parent: HTMLElement): HTMLInputElement {
        const wrapper = element('label', label); const input = element('input'); input.value = value;
        wrapper.append(input); parent.append(wrapper); return input;
    }

    private async settings(): Promise<void> {
        const snapshot = await this.bridge.request('config/get'); this.config = snapshot.value; this.configRevision = snapshot.sha256;
        const form = element('section');
        const protocol = element('select');
        for (const name of ['openai_chat', 'openai_responses', 'anthropic', 'gemini', 'ollama']) {
            const option = element('option', name); option.value = name; option.selected = this.config.provider.protocol === name; protocol.append(option);
        }
        const protocolLabel = element('label', 'Protocol'); protocolLabel.append(protocol); form.append(protocolLabel);
        const name = this.field('Provider name', this.config.provider.name, form);
        const endpoint = this.field('API endpoint', this.config.provider.endpoint, form);
        const model = this.field('Model', this.config.provider.model, form);
        const keyVariable = this.field('Key variable', this.config.provider.key_env, form);
        form.append(this.button('Set API key securely', () => this.bridge.setCredential(keyVariable.value)));
        const limitFields = new Map<string, HTMLInputElement>();
        for (const [key, value] of Object.entries(this.config.budget)) { limitFields.set(key, this.field(key.replaceAll('_', ' '), String(value), form)); }
        const permissions = new Map<string, HTMLSelectElement>();
        for (const [category, value] of Object.entries(this.config.permissions)) {
            const label = element('label', `Permission: ${category}`); const select = element('select');
            for (const decision of ['allow', 'ask', 'deny']) {
                const option = element('option', decision); option.value = decision; option.selected = value === decision; select.append(option);
            }
            label.append(select); form.append(label); permissions.set(category, select);
        }
        form.append(this.button('Save settings', async () => {
            const next = structuredClone(this.config);
            Object.assign(next.provider, { protocol: protocol.value, name: name.value, endpoint: endpoint.value, model: model.value, key_env: keyVariable.value });
            for (const [key, input] of limitFields) {
                const value = Number(input.value); if (!Number.isFinite(value)) { throw new Error('Budget values must be finite'); } next.budget[key] = value;
            }
            for (const [category, select] of permissions) { next.permissions[category] = select.value; }
            const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision });
            this.configRevision = result.sha256; this.config = next; this.status.textContent = 'Settings saved';
        }));
        this.content.append(form);
    }

    private event(method: string, params: any): void {
        if (method === 'transport/closed') { this.active = false; this.status.textContent = params.message; return; }
        if (method !== 'agent/event' || params.session_id !== this.sessionId) { return; }
        const payload = params.payload;
        if (params.kind === 'model_request') {
            this.assistant = undefined;
        } else if (params.kind === 'text_delta') {
            if (!this.assistant) { this.assistant = this.addMessage('assistant', ''); }
            this.assistant.textContent = (this.assistant.textContent ?? '') + payload.text;
            this.transcript.scrollTop = this.transcript.scrollHeight;
        } else if (params.kind === 'tool_started') {
            this.addMessage('tool', payload.name);
        } else if (params.kind === 'tool_completed') {
            this.addMessage('result', JSON.stringify(payload, null, 2).slice(0, 32000));
        } else if (params.kind === 'permission_request') {
            const card = element('article', `${payload.category}: ${payload.target}`, 'permission');
            for (const [label, decision] of [['Allow once', 'once'], ['Allow session', 'session'], ['Deny', 'deny']]) {
                card.append(this.button(label, async () => {
                    await this.bridge.request('permissions/respond', { session_id: params.session_id, request_id: payload.id, decision }); card.remove();
                }));
            }
            this.approvals.append(card);
        } else if (params.kind === 'session_completed' || params.kind === 'session_error') {
            this.active = false; this.assistant = undefined; this.approvals.replaceChildren();
            this.status.textContent = params.kind === 'session_completed' ? `Complete · ${payload.budget.tokens} tokens · $${payload.budget.cost.toFixed(4)}` : payload.message;
        } else if (params.kind === 'usage') {
            this.status.textContent = `Running · ${payload.input_tokens + payload.output_tokens} tokens`;
        }
    }

    dispose(): void { this.disposeEvent(); this.root.replaceChildren(); }
}
