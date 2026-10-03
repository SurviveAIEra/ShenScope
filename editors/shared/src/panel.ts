import { renderMarkdown } from './markdown.js';
export interface PanelBridge {
    request(method: string, params?: Record<string, unknown>): Promise<any>;
    onEvent(listener: (method: string, params: any) => void): () => void;
    setCredential(variable: string): Promise<void>;
    openFile(path: string, line?: number): Promise<void>;
}
function el<K extends keyof HTMLElementTagNameMap>(tag: K, text = '', className = ''): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag); node.textContent = text; node.className = className; return node;
}
function icon(name: string): SVGSVGElement {
    const paths: Record<string, string> = {
        scope: 'M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4M8 12l3 3 5-6',
        plus: 'M12 5v14M5 12h14', send: 'M12 19V5M5 12l7-7 7 7', stop: 'M6 6h12v12H6z',
        chat: 'M4 4h16v12H9l-5 4z', history: 'M4 6v5h5M4 11a8 8 0 1 1 2 7M12 7v5l3 2',
        graph: 'M8 7l8 10M16 7 8 17M8 7h8M8 17h8M5 4h6v6H5zM13 14h6v6h-6z',
        shield: 'M12 3l8 3v6c0 5-8 9-8 9s-8-4-8-9V6zM8 12l3 3 5-6',
        check: 'M5 12l4 4L19 6', arrow: 'M5 12h14M13 6l6 6-6 6', tool: 'M14 5a5 5 0 0 0-6 6L3 16l5 5 5-5a5 5 0 0 0 6-6l-4 3-4-4z',
    };
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    for (const [key, value] of Object.entries({viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true'})) { svg.setAttribute(key, value); }
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path'); path.setAttribute('d', paths[name] ?? paths.scope); svg.append(path); return svg;
}
export class ShenScopePanel {
    private sessionId?: string;
    private configRevision = '';
    private config: any;
    private capabilities: any = {};
    private status = el('div', 'Connecting…', 'status');
    private content = el('main', '', 'panel-content');
    private transcript = el('div', '', 'transcript');
    private composer = el('textarea');
    private approvals = el('div', '', 'approvals');
    private notice = el('div', '', 'notice');
    private welcome = el('section', '', 'welcome');
    private sendButton?: HTMLButtonElement;
    private cancelButton?: HTMLButtonElement;
    private tab = 'Chat';
    private disposeEvent: () => void;
    private active = false;
    private assistant?: HTMLElement;
    private assistantText = '';
    private animation?: number;
    private navigation = new Map<string, HTMLButtonElement>();
    private toolCards = new Map<string, HTMLDetailsElement>();
    private renderRevision = 0;
    private disposed = false;
    constructor(private readonly root: HTMLElement, private readonly bridge: PanelBridge) {
        root.classList.add('shenscope-panel');
        const header = el('header', '', 'panel-header'); const brand = el('div', '', 'brand'); const mark = el('span', '', 'brand-mark'); mark.append(icon('scope')); brand.append(mark, el('strong', 'ShenScope'));
        header.append(brand, this.button('New conversation', () => this.newConversation(), 'icon-button', 'plus'));
        const nav = el('nav', '', 'primary-nav'); nav.setAttribute('aria-label', 'ShenScope views');
        for (const [name, label, glyph] of [['Chat', 'Chat', 'chat'], ['History', 'History', 'history'], ['Intelligence', 'Project', 'graph']]) {
            const button = this.button(label, () => this.selectTab(name), 'nav-button', glyph); this.navigation.set(name, button); nav.append(button);
        }
        const more = el('select', '', 'more-views'); more.setAttribute('aria-label', 'More views');
        for (const name of ['More', 'Settings', 'Tools', 'Runtime', 'Security', 'MCP', 'Skills', 'Hooks']) { const option = el('option', name); option.value = name; more.append(option); }
        more.addEventListener('change', () => { if (more.value !== 'More') { void this.guard(() => this.selectTab(more.value)); } more.value = 'More'; }); nav.append(more);
        this.status.setAttribute('role', 'status'); this.status.setAttribute('aria-live', 'polite'); this.notice.setAttribute('role', 'alert'); this.notice.hidden = true;
        root.append(header, nav, this.notice, this.approvals, this.content, this.status);
        this.disposeEvent = bridge.onEvent((method, params) => this.event(method, params));
        this.composer.placeholder = 'Ask, plan, or build something…'; this.composer.rows = 3; this.composer.setAttribute('aria-label', 'Message ShenScope');
        this.composer.addEventListener('keydown', event => { if (!event.isComposing && event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); void this.send(); } });
        this.composer.addEventListener('input', () => this.updateActions());
        const welcomeMark = el('div', '', 'welcome-mark'); welcomeMark.append(icon('scope'));
        this.welcome.append(welcomeMark, el('h1', 'What are we building?'), el('p', 'Understand your code. Make a change. See it through.'));
        const prompts = el('div', '', 'starter-prompts');
        for (const [title, detail, prompt] of [
            ['Explore the project', 'Find the entry points and architecture', 'Explore this project and explain its architecture and entry points.'],
            ['Fix a failing test', 'Trace the failure and verify a change', 'Help me find and fix a failing test in this project.'],
            ['Review changes', 'Check the current diff for issues', 'Review my current local changes for bugs and missing tests.'],
        ]) { const button = this.button(title, async () => { this.composer.value = prompt; this.updateActions(); this.composer.focus(); }, 'starter'); button.append(el('small', detail), icon('arrow')); prompts.append(button); }
        this.welcome.append(prompts);
    }
    async initialize(): Promise<void> {
        await this.guard(async () => {
            const hello = await this.bridge.request('editor/hello'); this.capabilities = hello.capabilities;
            const snapshot = await this.bridge.request('config/get'); this.config = snapshot.value; this.configRevision = snapshot.sha256;
            this.setStatus(`Ready · ${this.config.provider.model}`); await this.renderTab();
        });
    }
    private button(label: string, action: () => Promise<void>, className = 'secondary-button', glyph?: string): HTMLButtonElement {
        const button = el('button', '', className); button.type = 'button'; button.title = label; button.setAttribute('aria-label', label);
        if (glyph) { button.append(icon(glyph)); } if (className !== 'icon-button') { button.append(el('span', label)); }
        button.addEventListener('click', () => { void this.guard(action); }); return button;
    }
    private async guard(action: () => Promise<void>): Promise<void> {
        try { await action(); } catch (error) { if (!this.disposed) { this.notice.textContent = error instanceof Error ? error.message : 'Operation failed'; this.notice.hidden = false; } }
    }
    private setStatus(text: string): void { this.status.textContent = text; this.status.classList.toggle('running', this.active); }
    private async selectTab(name: string): Promise<void> { this.tab = name; await this.renderTab(); }
    private async newConversation(): Promise<void> {
        if (this.active) { throw new Error('Cancel or finish the current task before starting another conversation.'); }
        this.sessionId = undefined; this.assistant = undefined; this.assistantText = ''; this.toolCards.clear(); this.transcript.replaceChildren(); this.notice.hidden = true; await this.selectTab('Chat'); this.composer.focus();
    }
    private scrollToEnd(force = false): void {
        const distance = this.transcript.scrollHeight - this.transcript.scrollTop - this.transcript.clientHeight;
        if (force || distance < 140) { this.transcript.scrollTop = this.transcript.scrollHeight; }
    }
    private trimTranscript(): void {
        while (this.transcript.childElementCount > 200) {
            const first = this.transcript.firstElementChild;
            for (const [id, card] of this.toolCards) { if (card === first || first?.contains(card)) { this.toolCards.delete(id); } }
            first?.remove();
        }
    }
    private addMessage(role: string, text: string): HTMLElement {
        this.welcome.hidden = true; const row = el('article', '', `message message-${role}`);
        row.append(el('div', role === 'assistant' ? 'ShenScope' : role === 'user' ? 'You' : role === 'steering' ? 'Your guidance' : role, 'message-label'));
        const body = el('div', '', 'message-body'); row.append(body);
        if (role === 'assistant') { renderMarkdown(body, text, (path, line) => this.bridge.openFile(path, line)); } else { body.textContent = text; }
        this.transcript.append(row); this.trimTranscript(); this.scrollToEnd(); return body;
    }
    private updateActions(): void {
        if (!this.sendButton || !this.cancelButton) { return; } const label = this.active ? 'Send guidance' : 'Send message';
        this.sendButton.setAttribute('aria-label', label); this.sendButton.title = `${label} (Ctrl / ⌘ Enter)`;
        this.sendButton.disabled = !this.config || !this.composer.value.trim(); this.cancelButton.hidden = !this.active;
        this.composer.placeholder = this.active ? 'Guide the running task…' : 'Ask, plan, or build something…';
    }
    private async send(): Promise<void> {
        await this.guard(async () => {
            const prompt = this.composer.value.trim(); if (!prompt || !this.config) { return; } this.notice.hidden = true;
            if (this.active && this.sessionId) { await this.bridge.request('agent/steer', { session_id: this.sessionId, prompt }); this.addMessage('steering', prompt); this.composer.value = ''; this.updateActions(); return; }
            if (!this.sessionId) { const session = await this.bridge.request('sessions/create', { title: prompt.slice(0, 100) }); this.sessionId = session.id; }
            this.addMessage('user', prompt); this.assistant = undefined; this.assistantText = ''; this.active = true; this.composer.value = ''; this.setStatus('Working…'); this.updateActions(); this.scrollToEnd(true);
            try { await this.bridge.request('agent/start', { session_id: this.sessionId, prompt }); }
            catch (error) { this.active = false; this.setStatus('Task could not start'); this.updateActions(); throw error; }
        });
    }
    private async renderTab(): Promise<void> {
        const revision = ++this.renderRevision; this.content.replaceChildren();
        for (const [name, button] of this.navigation) { button.classList.toggle('selected', name === this.tab); button.setAttribute('aria-current', name === this.tab ? 'page' : 'false'); }
        this.content.classList.toggle('chat-view', this.tab === 'Chat');
        if (this.tab === 'Chat') {
            this.welcome.hidden = this.transcript.childElementCount > 0; const conversation = el('div', '', 'conversation'); conversation.append(this.welcome, this.transcript);
            const box = el('section', '', 'composer-box'); const toolbar = el('div', '', 'composer-toolbar'); const actions = el('div', '', 'composer-actions');
            this.cancelButton = this.button('Stop', async () => { if (this.sessionId && this.active) { await this.bridge.request('agent/cancel', { session_id: this.sessionId }); this.setStatus('Cancelling…'); } }, 'stop-button', 'stop');
            this.sendButton = this.button('Send message', () => this.send(), 'send-button', 'send'); actions.append(this.cancelButton, this.sendButton);
            toolbar.append(this.button(this.config?.provider.model ?? 'Choose model', () => this.selectTab('Settings'), 'model-button'), actions);
            box.append(this.composer, toolbar); this.content.append(conversation, box, el('div', 'Ctrl / ⌘ Enter to send · Changes require your permission', 'composer-hint')); this.updateActions(); return;
        }
        if (this.tab === 'History') { await this.history(revision); return; }
        if (this.tab === 'Settings') { await this.settings(revision); return; }
        this.content.append(el('h2', this.tab === 'Intelligence' ? 'Project intelligence' : this.tab, 'view-title'));
        if (this.tab === 'Tools') {
            const tools = await this.bridge.request('tools/list'); if (revision !== this.renderRevision) { return; }
            for (const tool of tools) { const card = el('section', '', 'info-card'); card.append(el('h3', tool.name), el('p', tool.description)); this.content.append(card); } return;
        }
        if (this.tab === 'Runtime' || this.tab === 'Security') {
            const runtime = await this.bridge.request('runtime/status'); if (revision !== this.renderRevision) { return; }
            if (this.tab === 'Security') {
                this.content.append(el('p', 'Choose which actions can run and which need your approval.', 'view-description'));
                for (const [category, value] of Object.entries(this.config.permissions)) { const row = el('div', '', 'property-row'); row.append(el('span', category), el('span', String(value), `badge badge-${value}`)); this.content.append(row); }
                this.content.append(this.button('Edit permissions', () => this.selectTab('Settings')));
            }
            const details = el('details', '', 'diagnostics'); details.append(el('summary', 'Runtime details'), el('pre', JSON.stringify(runtime, null, 2))); this.content.append(details); return;
        }
        const capability: Record<string, string> = { Intelligence: 'project_intelligence', MCP: 'mcp', Skills: 'skills', Hooks: 'hooks' };
        const card = el('section', '', 'empty-state'); card.append(icon(this.tab === 'Intelligence' ? 'graph' : 'tool'), el('h3', this.capabilities[capability[this.tab]] ? 'Available' : 'Coming together'), el('p', this.capabilities[capability[this.tab]] ? 'Connected to this workspace.' : 'This capability is still in development. You can keep working in Chat.')); this.content.append(card);
    }
    private async history(revision: number): Promise<void> {
        const heading = el('div', '', 'view-heading'); heading.append(el('h2', 'Conversations'), this.button('New', () => this.newConversation(), 'secondary-button', 'plus'));
        const search = el('input', '', 'history-search'); search.placeholder = 'Search conversations…'; search.setAttribute('aria-label', 'Search conversations'); const list = el('div', '', 'history-list'); this.content.append(heading, search, list);
        let request = 0; let timer: ReturnType<typeof setTimeout> | undefined;
        const refresh = async () => {
            const current = ++request; const sessions = await this.bridge.request('sessions/list', { include_archived: true, search: search.value }); if (revision !== this.renderRevision || current !== request) { return; } list.replaceChildren();
            if (!sessions.length) { list.append(el('p', 'Your conversations will appear here.', 'empty-text')); }
            for (const session of sessions) {
                const row = el('article', '', 'session-card'); const open = this.button(session.title, async () => {
                    if (this.active) { throw new Error('Finish the current task before switching conversations.'); }
                    const full = await this.bridge.request('sessions/get', { session_id: session.id }); this.sessionId = full.id; this.assistant = undefined; this.assistantText = ''; this.toolCards.clear(); this.transcript.replaceChildren();
                    for (const message of full.messages) { this.addMessage(message.role, message.text); } await this.selectTab('Chat'); this.scrollToEnd(true); this.composer.focus();
                }, 'session-open');
                row.append(open, el('small', `${session.pinned ? 'Pinned · ' : ''}${session.archived ? 'Archived · ' : ''}${session.status} · ${session.updated ?? ''}`, 'session-meta'));
                const controls = el('details', '', 'session-controls'); controls.append(el('summary', 'Manage')); const rename = el('input'); rename.value = session.title; rename.setAttribute('aria-label', 'Conversation title');
                controls.append(rename, this.button('Rename', async () => { await this.bridge.request('sessions/rename', { session_id: session.id, title: rename.value }); await refresh(); }), this.button(session.pinned ? 'Unpin' : 'Pin', async () => { await this.bridge.request('sessions/pin', { session_id: session.id, value: !session.pinned }); await refresh(); }), this.button('Branch', async () => { await this.bridge.request('sessions/branch', { session_id: session.id }); await refresh(); }), this.button(session.archived ? 'Restore' : 'Archive', async () => { await this.bridge.request('sessions/archive', { session_id: session.id, value: !session.archived }); await refresh(); })); row.append(controls); list.append(row);
            }
        };
        search.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { void this.guard(refresh); }, 180); }); await refresh();
    }
    private field(label: string, value: string, parent: HTMLElement, type = 'text'): HTMLInputElement {
        const wrapper = el('label', '', 'field'); wrapper.append(el('span', label)); const input = el('input'); input.value = value; input.type = type; wrapper.append(input); parent.append(wrapper); return input;
    }
    private async settings(revision: number): Promise<void> {
        const snapshot = await this.bridge.request('config/get'); if (revision !== this.renderRevision) { return; } this.config = snapshot.value; this.configRevision = snapshot.sha256;
        this.content.append(el('h2', 'Settings', 'view-title'), el('p', 'One configuration for your workspace and conversations.', 'view-description'));
        const form = el('section', '', 'settings-form'); const provider = el('fieldset'); provider.append(el('legend', 'Model connection')); const protocol = el('select');
        for (const [value, label] of [['openai_chat', 'OpenAI compatible'], ['openai_responses', 'OpenAI Responses'], ['anthropic', 'Anthropic'], ['gemini', 'Google Gemini'], ['ollama', 'Ollama']]) { const option = el('option', label); option.value = value; option.selected = this.config.provider.protocol === value; protocol.append(option); }
        const protocolLabel = el('label', 'Provider protocol', 'field'); protocolLabel.append(protocol); provider.append(protocolLabel);
        const name = this.field('Provider name', this.config.provider.name, provider); const endpoint = this.field('API endpoint', this.config.provider.endpoint, provider); const model = this.field('Model', this.config.provider.model, provider);
        const credential = el('details', '', 'advanced-settings'); credential.append(el('summary', 'Credential options')); const keyVariable = this.field('Environment variable', this.config.provider.key_env, credential); provider.append(credential);
        const secretStatus = el('small', 'Checking credential…', 'credential-status');
        const refreshSecret = async () => { const result = await this.bridge.request('credentials/status', { variable: keyVariable.value }); secretStatus.textContent = result.configured ? 'API key configured · stored securely' : 'No API key configured'; };
        provider.append(this.button('Set API key', async () => { await this.bridge.setCredential(keyVariable.value); await refreshSecret(); }), secretStatus);
        const budget = el('details', '', 'settings-group'); budget.append(el('summary', 'Usage & budgets')); const limits = new Map<string, HTMLInputElement>();
        for (const [key, value] of Object.entries(this.config.budget)) { limits.set(key, this.field(key.replaceAll('_', ' '), String(value), budget, 'number')); }
        const permissionGroup = el('details', '', 'settings-group'); permissionGroup.append(el('summary', 'Permissions')); const permissions = new Map<string, HTMLSelectElement>();
        for (const [category, value] of Object.entries(this.config.permissions)) {
            const label = el('label', category === 'dynamic' ? 'Dynamic analysis' : category, 'field'); const select = el('select');
            for (const [decision, title] of [['allow', 'Allow'], ['ask', 'Ask me'], ['deny', 'Deny']]) { const option = el('option', title); option.value = decision; option.selected = value === decision; select.append(option); } label.append(select); permissionGroup.append(label); permissions.set(category, select);
        }
        const save = this.button('Save settings', async () => {
            const next = structuredClone(this.config); Object.assign(next.provider, { protocol: protocol.value, name: name.value, endpoint: endpoint.value, model: model.value, key_env: keyVariable.value });
            for (const [key, input] of limits) { const value = Number(input.value); if (!input.value.trim() || !Number.isFinite(value)) { throw new Error('Enter finite budget values.'); } next.budget[key] = value; }
            for (const [category, select] of permissions) { next.permissions[category] = select.value; }
            const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision }); this.configRevision = result.sha256; this.config = next; this.notice.hidden = true; this.setStatus('Settings saved');
        }, 'primary-button', 'check'); form.append(provider, budget, permissionGroup, save); this.content.append(form); await refreshSecret();
    }
    private addTool(payload: any): HTMLDetailsElement {
        let card = this.toolCards.get(payload.id); if (card) { return card; } this.welcome.hidden = true; card = el('details', '', 'tool-card'); const summary = el('summary'); const glyph = el('span', '', 'tool-glyph'); glyph.append(icon('tool'));
        summary.append(glyph, el('span', payload.name, 'tool-name'), el('span', 'Running', 'tool-status')); card.append(summary, el('pre', '', 'tool-output')); this.transcript.append(card); this.toolCards.set(payload.id, card); this.trimTranscript(); this.scrollToEnd(); return card;
    }
    private flushAssistant(): void {
        if (this.animation !== undefined) { cancelAnimationFrame(this.animation); this.animation = undefined; }
        if (this.assistant) { renderMarkdown(this.assistant, this.assistantText, (path, line) => this.bridge.openFile(path, line)); this.scrollToEnd(); }
    }
    private event(method: string, params: any): void {
        if (this.disposed) { return; }
        if (method === 'transport/closed') { this.active = false; this.setStatus('Disconnected'); this.notice.textContent = params.message; this.notice.hidden = false; this.approvals.replaceChildren(); this.updateActions(); return; }
        if (method !== 'agent/event' || params.session_id !== this.sessionId) { return; } const payload = params.payload;
        if (params.kind === 'model_request') { this.flushAssistant(); this.assistant = undefined; this.assistantText = ''; }
        else if (params.kind === 'text_delta') {
            if (!this.assistant) { this.assistant = this.addMessage('assistant', ''); } this.assistantText = (this.assistantText + payload.text).slice(0, 1_000_000);
            if (this.animation === undefined) { this.animation = requestAnimationFrame(() => { this.animation = undefined; this.flushAssistant(); }); }
        } else if (params.kind === 'tool_started') { this.addTool(payload); }
        else if (params.kind === 'tool_completed') { const card = this.addTool(payload); card.classList.add(payload.ok ? 'succeeded' : 'failed'); card.querySelector('.tool-status')!.textContent = payload.ok ? 'Complete' : 'Failed'; card.querySelector('pre')!.textContent = JSON.stringify(payload, null, 2).slice(0, 32000); if (!payload.ok) { card.open = true; } }
        else if (params.kind === 'permission_request') {
            const card = el('section', '', 'permission-card'); const heading = el('div', '', 'permission-heading'); heading.append(icon('shield'), el('strong', 'Approval needed'));
            card.append(heading, el('p', `${payload.tool} · ${payload.category}`, 'permission-action'), el('code', payload.target, 'permission-target'), el('p', payload.reason, 'permission-reason')); const actions = el('div', '', 'permission-actions');
            for (const [label, decision, style] of [['Allow once', 'once', 'primary-button'], ['Allow session', 'session', 'secondary-button'], ['Deny', 'deny', 'deny-button']]) { actions.append(this.button(label, async () => { await this.bridge.request('permissions/respond', { session_id: params.session_id, request_id: payload.id, decision }); card.remove(); }, style)); } card.append(actions); this.approvals.append(card);
        } else if (params.kind === 'session_completed' || params.kind === 'session_error') {
            this.flushAssistant(); this.active = false; this.assistant = undefined; this.approvals.replaceChildren(); this.updateActions();
            this.setStatus(params.kind === 'session_completed' ? `Complete · ${payload.budget.tokens.toLocaleString()} tokens · $${payload.budget.cost.toFixed(4)}` : 'Task stopped'); if (params.kind === 'session_error') { this.notice.textContent = payload.message; this.notice.hidden = false; }
        } else if (params.kind === 'usage') { this.setStatus(`Working · ${(payload.input_tokens + payload.output_tokens).toLocaleString()} tokens`); }
    }
    dispose(): void { this.disposed = true; this.renderRevision++; if (this.animation !== undefined) { cancelAnimationFrame(this.animation); } this.disposeEvent(); this.root.replaceChildren(); }
}
