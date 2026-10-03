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
    private projectBackend = 'tree_sitter';
    private projectJob?: string;
    private projectResult: any;
    private completedProjectJobs = new Set<string>();
    private mcpJob?: string;
    private mcpResult?: { server: string; action: string; result: any };
    private completedMCPJobs = new Set<string>();
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
        if (this.active || this.projectJob || this.mcpJob) { throw new Error('Cancel or finish the current task before starting another conversation.'); }
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
        if (this.tab === 'Intelligence' && this.capabilities.project_intelligence) { await this.project(revision); return; }
        if (this.tab === 'MCP' && this.capabilities.mcp) { await this.mcp(revision); return; }
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
                    if (this.active || this.projectJob || this.mcpJob) { throw new Error('Finish the current task before switching conversations.'); }
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
    private async ensureSession(title: string): Promise<string> {
        if (!this.sessionId) { const session = await this.bridge.request('sessions/create', { title }); this.sessionId = session.id; }
        return this.sessionId!;
    }
    private async startMCP(server: string, action: string, args: Record<string, unknown> = {}): Promise<void> {
        if (this.mcpJob) { throw new Error('Finish or cancel the current MCP operation.'); }
        const session_id = await this.ensureSession('Workspace tools');
        this.mcpResult = undefined;
        const result = await this.bridge.request('mcp/start', { ...args, session_id, server, action });
        if (!this.completedMCPJobs.has(result.job_id)) { this.mcpJob = result.job_id; this.setStatus('Working with MCP…'); }
        if (this.tab === 'MCP') { await this.renderTab(); }
    }
    private referenceBindings(text: string): Array<{ name: string; env: string }> {
        return text.split('\n').map(line => line.trim()).filter(Boolean).map(line => {
            const at = line.indexOf('=');
            if (at < 1 || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(line.slice(at + 1).trim())) { throw new Error('Use NAME=ENVIRONMENT_VARIABLE for each binding.'); }
            return { name: line.slice(0, at).trim(), env: line.slice(at + 1).trim() };
        });
    }
    private async mcp(revision: number): Promise<void> {
        const snapshot = await this.bridge.request('config/get');
        if (revision !== this.renderRevision) { return; }
        this.config = snapshot.value; this.configRevision = snapshot.sha256;
        const heading = el('div', '', 'view-heading'); heading.append(el('h2', 'MCP connections'));
        this.content.append(heading, el('p', 'Connect tools, resources and prompts to this conversation. Each operation follows your permission settings.', 'view-description'));
        if (this.mcpJob) {
            this.content.append(el('p', 'Waiting for the server or your approval…', 'empty-text'), this.button('Cancel operation', async () => {
                await this.bridge.request('mcp/cancel_job', { session_id: this.sessionId, job_id: this.mcpJob });
            }));
        }
        const session_id = await this.ensureSession('Workspace tools');
        const servers = await this.bridge.request('mcp/query', { session_id, action: 'servers' });
        if (revision !== this.renderRevision) { return; }
        if (!servers.length) { this.content.append(el('p', 'Add a connection to bring external tools into your workspace.', 'empty-text')); }
        for (const server of servers) {
            const card = el('section', '', 'info-card mcp-server'); const title = el('div', '', 'view-heading');
            title.append(el('h3', server.name), el('span', server.state, `badge badge-${server.state === 'ready' ? 'allow' : 'ask'}`));
            card.append(title, el('small', `${server.transport === 'stdio' ? 'Local process' : 'HTTP endpoint'}${server.server_info?.name ? ' · ' + server.server_info.name : ''}`, 'session-meta'));
            const enabledLabel = el('label', '', 'checkbox-field'); const enabled = el('input'); enabled.type = 'checkbox'; enabled.checked = server.enabled;
            enabled.setAttribute('aria-label', `Enabled ${server.name}`); enabled.disabled = !!this.mcpJob || this.active || !!this.projectJob;
            enabledLabel.append(enabled, el('span', 'Enabled')); card.append(enabledLabel);
            enabled.addEventListener('change', () => { enabled.disabled = true; void this.guard(async () => {
                const next = structuredClone(this.config); next.mcp.servers[server.name].enabled = enabled.checked;
                const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision });
                this.config = next; this.configRevision = result.sha256; this.mcpResult = undefined; await this.renderTab();
            }); });
            const actions = el('div', '', 'analysis-actions');
            if (server.state === 'ready') {
                actions.append(this.button('Disconnect', () => this.startMCP(server.name, 'disconnect')),
                    this.button('Restart', () => this.startMCP(server.name, 'reconnect')), this.button('Test connection', () => this.startMCP(server.name, 'ping')),
                    this.button('Tools', () => this.startMCP(server.name, 'tools')), this.button('Resources', () => this.startMCP(server.name, 'resources')),
                    this.button('Templates', () => this.startMCP(server.name, 'templates')), this.button('Prompts', () => this.startMCP(server.name, 'prompts')));
            } else if (server.enabled) { actions.append(this.button('Connect', () => this.startMCP(server.name, 'connect'), 'primary-button')); }
            for (const button of Array.from(actions.querySelectorAll('button'))) { button.disabled = !!this.mcpJob; }
            card.append(actions); this.content.append(card);
            if (server.last_error) { card.append(el('p', `${server.last_error.operation}: ${server.last_error.code}`, 'error-text')); }
            const diagnostics = el('details', '', 'advanced-settings'); diagnostics.append(el('summary', 'Connection diagnostics'));
            diagnostics.append(el('p', `Protocol ${server.protocol_version || 'pending'} · generation ${server.generation} · pending ${server.pending_requests ?? 0} · reconnect failures ${server.reconnect_failures ?? 0}`, 'session-meta'));
            for (const notification of (server.notifications ?? []).slice(-10)) { diagnostics.append(el('p', `${notification.timestamp} · ${notification.method}`, 'session-meta')); }
            card.append(diagnostics);
            for (const uri of server.subscriptions ?? []) {
                const subscription = el('div', '', 'mcp-entry'); subscription.append(el('small', uri), this.button('Unsubscribe', () => this.startMCP(server.name, 'unsubscribe', { uri }))); card.append(subscription);
            }
            const output = this.mcpResult;
            if (output && output.server === server.name) { this.renderMCPResult(card, output); }
            const edit = el('details', '', 'advanced-settings'); edit.append(el('summary', 'Connection settings'));
            this.mcpConnectionForm(edit, server.name, this.config.mcp?.servers?.[server.name]); card.append(edit);
        }
        const add = el('details', '', 'settings-group'); add.append(el('summary', 'Add connection')); this.mcpConnectionForm(add); this.content.append(add);
    }
    private mcpConnectionForm(parent: HTMLElement, existingName = '', existing: any = {}): void {
        const name = this.field('Connection name', existingName, parent); name.disabled = !!existingName;
        const transport = el('select'); transport.setAttribute('aria-label', 'MCP transport');
        for (const [value, label] of [['stdio', 'Local process'], ['http', 'HTTP endpoint']]) { const option = el('option', label); option.value = value; option.selected = (existing.transport ?? 'stdio') === value; transport.append(option); }
        const transportLabel = el('label', 'Connection type', 'field'); transportLabel.append(transport); parent.append(transportLabel);
        const local = el('div'); const executable = this.field('Executable', existing.argv?.[0] ?? '', local);
        const argumentLabel = el('label', 'Arguments · one per line', 'field'); const argumentsInput = el('textarea'); argumentsInput.rows = 3; argumentsInput.value = (existing.argv ?? []).slice(1).join('\n'); argumentLabel.append(argumentsInput); local.append(argumentLabel);
        const directory = this.field('Workspace directory', existing.cwd ?? '.', local);
        const remote = el('div'); const endpoint = this.field('HTTP endpoint', existing.endpoint ?? '', remote, 'url');
        const advanced = el('details', '', 'advanced-settings'); advanced.append(el('summary', 'Credentials & environment'));
        const bindingLabel = el('label', 'Variable references · NAME=ENVIRONMENT_VARIABLE', 'field'); const bindings = el('textarea'); bindings.rows = 3;
        const selectedBindings = existing.transport === 'http' ? existing.header_env : existing.environment_env;
        bindings.value = (selectedBindings ?? []).map((binding: any) => `${binding.name}=${binding.env}`).join('\n'); bindingLabel.append(bindings);
        advanced.append(el('p', 'Use environment variables for values. HTTP bindings set headers; local bindings set child process variables.', 'view-description'), bindingLabel);
        for (const binding of selectedBindings ?? []) { advanced.append(this.button(`Set ${binding.env}`, () => this.bridge.setCredential(binding.env))); }
        parent.append(local, remote, advanced); const update = () => { local.hidden = transport.value !== 'stdio'; remote.hidden = transport.value !== 'http'; }; transport.addEventListener('change', update); update();
        const save = this.button('Save connection', async () => {
            if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(name.value.trim())) { throw new Error('Use letters, numbers, dots, underscores or dashes for the connection name.'); }
            const next = structuredClone(this.config); next.mcp ??= { servers: {} }; next.mcp.servers ??= {};
            const spec = { ...existing, transport: transport.value, enabled: existing.enabled ?? true, cwd: directory.value || '.', argv: [], endpoint: '', environment_env: [], header_env: [] } as any;
            if (transport.value === 'stdio') {
                if (!executable.value.trim()) { throw new Error('Enter an executable.'); }
                spec.argv = [executable.value.trim(), ...(argumentsInput.value ? argumentsInput.value.split('\n') : [])]; spec.environment_env = this.referenceBindings(bindings.value);
            } else { spec.endpoint = endpoint.value.trim(); spec.header_env = this.referenceBindings(bindings.value); }
            next.mcp.servers[name.value.trim()] = spec;
            const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision });
            this.config = next; this.configRevision = result.sha256; this.notice.hidden = true; this.setStatus('Connection saved'); await this.renderTab();
        }, 'primary-button'); save.disabled = !!this.mcpJob || this.active || !!this.projectJob; parent.append(save);
        if (existingName) {
            const remove = this.button('Remove connection', async () => {
                const next = structuredClone(this.config); delete next.mcp.servers[existingName];
                const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision }); this.config = next; this.configRevision = result.sha256; this.mcpResult = undefined; await this.renderTab();
            }, 'deny-button'); remove.disabled = save.disabled; parent.append(remove);
        }
    }
    private mcpArgumentForm(parent: HTMLElement, definitions: any[], schema?: any): () => Record<string, unknown> {
        const inputs = new Map<string, { input: HTMLInputElement | HTMLTextAreaElement; type: string; required: boolean }>();
        for (const definition of definitions) {
            const property = schema?.properties?.[definition.name] ?? { type: 'string' };
            const type = typeof property.type === 'string' ? property.type : 'json';
            const label = el('label', definition.name + (definition.required ? ' *' : ''), 'field');
            const input = type === 'object' || type === 'array' || type === 'json' ? el('textarea') : el('input');
            if (input instanceof HTMLInputElement) { input.type = type === 'boolean' ? 'checkbox' : ['number', 'integer'].includes(type) ? 'number' : 'text'; }
            input.setAttribute('aria-label', definition.name); if (definition.description) { label.title = definition.description; }
            label.append(input); parent.append(label); inputs.set(definition.name, { input, type, required: !!definition.required });
        }
        return () => {
            const result: Record<string, unknown> = {};
            for (const [name, field] of inputs) {
                if (field.type === 'boolean') { result[name] = (field.input as HTMLInputElement).checked; }
                else if (!field.input.value && !field.required) { continue; }
                else if (['number', 'integer'].includes(field.type)) { if (!field.input.value || !Number.isFinite(Number(field.input.value))) { throw new Error(`Enter a number for ${name}.`); } result[name] = Number(field.input.value); }
                else if (['object', 'array', 'json'].includes(field.type)) { result[name] = JSON.parse(field.input.value); }
                else { result[name] = field.input.value; }
            }
            return result;
        };
    }
    private renderMCPResult(parent: HTMLElement, result: { server: string; action: string; result: any }): void {
        const values = result.result;
        if (result.action === 'tools' && Array.isArray(values)) {
            for (const tool of values) {
                const details = el('details', '', 'mcp-entry'); details.append(el('summary', tool.name), el('p', tool.description ?? '', 'view-description'));
                const definitions = Object.entries(tool.inputSchema?.properties ?? {}).map(([name, property]: [string, any]) => ({ name, description: property.description, required: tool.inputSchema?.required?.includes(name) }));
                const argumentsValue = this.mcpArgumentForm(details, definitions, tool.inputSchema);
                details.append(this.button('Run tool', () => this.startMCP(result.server, 'call', { name: tool.name, arguments: argumentsValue() }))); parent.append(details);
            }
        } else if (result.action === 'resources' && Array.isArray(values)) {
            for (const resource of values) { const row = el('section', '', 'mcp-entry'); row.append(el('h4', resource.name), el('small', resource.uri), this.button('Read resource', () => this.startMCP(result.server, 'read', { uri: resource.uri })), this.button('Subscribe', () => this.startMCP(result.server, 'subscribe', { uri: resource.uri }))); parent.append(row); }
        } else if (result.action === 'templates' && Array.isArray(values)) {
            for (const template of values) { const row = el('section', '', 'mcp-entry'); row.append(el('h4', template.name), el('small', template.uriTemplate)); const uri = this.field('Resource URI', '', row); row.append(this.button('Read resource', () => this.startMCP(result.server, 'read', { uri: uri.value }))); parent.append(row); }
        } else if (result.action === 'prompts' && Array.isArray(values)) {
            for (const prompt of values) { const row = el('details', '', 'mcp-entry'); row.append(el('summary', prompt.name), el('p', prompt.description ?? '', 'view-description')); const argumentsValue = this.mcpArgumentForm(row, prompt.arguments ?? []); row.append(this.button('Get prompt', () => this.startMCP(result.server, 'prompt', { name: prompt.name, arguments: argumentsValue() }))); parent.append(row); }
        } else {
            const output = el('section', '', 'mcp-result'); output.append(el('h4', 'Result'));
            if (result.action === 'ping' && values?.ok) { output.append(el('p', `Connected · ${Math.round(values.latency_ms)} ms`, 'mcp-connection-test')); }
            const blocks = values?.content ?? values?.contents ?? values?.messages?.map((message: any) => message.content) ?? [];
            for (const block of blocks) { if (typeof block.text === 'string') { output.append(el('pre', block.text.slice(0, 64000), 'tool-output')); } else if (block.type === 'resource_link') { output.append(el('p', `${block.name} · ${block.uri}`)); } else { output.append(el('small', block.mimeType ?? block.type ?? 'Resource')); } }
            const details = el('details', '', 'diagnostics'); details.append(el('summary', 'Structured result'), el('pre', JSON.stringify(values, null, 2).slice(0, 128000))); output.append(details); parent.append(output);
        }
    }
    private async project(revision: number): Promise<void> {
        const heading = el('div', '', 'view-heading'); heading.append(el('h2', 'Project intelligence'));
        const backend = el('select', '', 'backend-select'); backend.setAttribute('aria-label', 'Project backend');
        for (const [value, label] of [['tree_sitter', 'Tree-sitter'], ['go_ast', 'Go AST'], ['codegraph', 'CodeGraph']]) {
            const option = el('option', label); option.value = value; option.selected = value === this.projectBackend; backend.append(option);
        }
        backend.disabled = !!this.projectJob;
        backend.addEventListener('change', () => { this.projectBackend = backend.value; this.projectResult = undefined; void this.guard(() => this.renderTab()); });
        this.content.append(heading, el('p', 'Explore symbols and trace the evidence behind affected code and test candidates.', 'view-description'), backend);
        if (this.projectJob) {
            this.content.append(el('p', 'Working on the project index…', 'empty-text'), this.button('Cancel indexing', async () => { await this.bridge.request('project/cancel', { job_id: this.projectJob }); })); return;
        }
        const index = this.button('Index project', () => this.startProject('build'), 'primary-button', 'graph'); this.content.append(index);
        const status = await this.bridge.request('project/query', { backend: this.projectBackend, action: 'status', ...(this.sessionId ? { session_id: this.sessionId } : {}) });
        if (revision !== this.renderRevision) { return; }
        if (status.indexed) { index.querySelector('span')!.textContent = 'Refresh index'; index.setAttribute('aria-label', 'Refresh index'); }
        if (!status.indexed) { this.content.append(el('p', 'Index source files to search declarations and compute dependency candidates. Your approval controls parsing and storage.', 'view-description')); return; }
        const metrics = el('div', '', 'project-metrics');
        for (const [label, value] of [['Files', status.files], ['Symbols', status.symbols], ['Relations', status.relations], ['Revision', status.revision]]) {
            const metric = el('div'); metric.append(el('strong', Number(value).toLocaleString()), el('small', String(label))); metrics.append(metric);
        }
        this.content.append(metrics, el('p', 'Last indexed snapshot. Refresh after changes. Call links use syntax evidence and may miss dynamic or unresolved calls.', 'view-description'));
        const query = el('input', '', 'history-search'); query.placeholder = 'Search a symbol…'; query.setAttribute('aria-label', 'Search project symbols');
        const results = el('div', '', 'symbol-results'); this.content.append(query, results); let request = 0; let timer: ReturnType<typeof setTimeout> | undefined;
        const search = async () => {
            const current = ++request; const result = await this.bridge.request('project/query', { backend: this.projectBackend, action: 'search', query: query.value, limit: 30, ...(this.sessionId ? { session_id: this.sessionId } : {}) });
            if (current !== request || revision !== this.renderRevision) { return; } results.replaceChildren();
            for (const symbol of result.symbols) {
                const row = el('div', '', 'symbol-row');
                row.append(this.button(symbol.name, () => this.bridge.openFile(symbol.location.file, symbol.location.start_line), 'source-link'), el('small', `${symbol.kind} · ${symbol.location.file}:${symbol.location.start_line}`)); results.append(row);
            }
            if (!result.symbols.length) { results.append(el('p', 'No matching symbols.', 'empty-text')); }
        };
        query.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { void this.guard(search); }, 180); });
        const paths = this.field('Files to analyze (comma separated)', '', this.content); paths.placeholder = 'src/main.go';
        const actions = el('div', '', 'analysis-actions');
        actions.append(this.button('Impact', () => this.startProject('impact', paths.value)), this.button('Test candidates', () => this.startProject('test_selection', paths.value)), this.button('Architecture', () => this.startProject('architecture'))); this.content.append(actions);
        if (this.projectResult?.analyzer) {
            const result = this.projectResult; this.content.append(el('h3', result.analyzer.replaceAll('_', ' '), 'analysis-title'));
            for (const candidate of result.candidates ?? []) {
                const symbol = candidate.symbol; const card = el('section', '', 'info-card');
                card.append(this.button(symbol.name, () => this.bridge.openFile(symbol.location.file, symbol.location.start_line), 'source-link'), el('p', candidate.reason), el('small', `${symbol.location.file}:${symbol.location.start_line} · confidence ${Math.round(candidate.confidence * 100)}%`)); this.content.append(card);
            }
            for (const cycle of result.cycles ?? []) { const card = el('section', '', 'info-card'); card.append(el('h3', 'Dependency cycle')); for (const path of cycle) { card.append(this.button(path, () => this.bridge.openFile(path), 'source-link')); } this.content.append(card); }
            if (result.candidates?.length === 0 || result.cycles?.length === 0) { this.content.append(el('p', 'No candidates found in the recorded relations.', 'empty-text')); }
            for (const limit of result.limitations ?? []) { this.content.append(el('p', limit, 'view-description')); }
        }
        await search();
    }
    private async startProject(action: string, paths = ''): Promise<void> {
        if (!this.sessionId) { const session = await this.bridge.request('sessions/create', { title: 'Project analysis' }); this.sessionId = session.id; }
        const result = await this.bridge.request('project/start', { session_id: this.sessionId, backend: this.projectBackend, action, paths: paths.split(/[\n,]/).map(path => path.trim()).filter(Boolean) });
        if (!this.completedProjectJobs.has(result.job_id)) { this.projectJob = result.job_id; this.setStatus('Analyzing project…'); }
        await this.renderTab();
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
        if (params.kind === 'mcp_job_completed' || params.kind === 'mcp_job_failed') {
            this.completedMCPJobs.add(payload.job_id); while (this.completedMCPJobs.size > 64) { this.completedMCPJobs.delete(this.completedMCPJobs.values().next().value!); }
            if (this.mcpJob === payload.job_id) { this.mcpJob = undefined; }
            for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } }
            if (params.kind === 'mcp_job_completed') { this.mcpResult = { server: payload.server, action: payload.action, result: payload.result }; this.setStatus('MCP operation complete'); }
            else { this.notice.textContent = payload.error; this.notice.hidden = false; this.setStatus('MCP operation stopped'); }
            if (this.tab === 'MCP') { void this.guard(() => this.renderTab()); } return;
        }
        if (params.kind === 'mcp_connected' || params.kind === 'mcp_disconnected') { if (this.tab === 'MCP' && !this.mcpJob) { void this.guard(() => this.renderTab()); } return; }
        if (params.kind === 'mcp_resource_updated') { this.setStatus('MCP resource updated'); return; }
        if (params.kind === 'project_completed' || params.kind === 'project_failed') {
            this.completedProjectJobs.add(payload.job_id);
            while (this.completedProjectJobs.size > 64) { this.completedProjectJobs.delete(this.completedProjectJobs.values().next().value!); }
            this.projectJob = undefined;
            for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } }
            if (params.kind === 'project_completed') { this.projectResult = payload.result; this.setStatus('Project analysis complete'); }
            else { this.notice.textContent = payload.message; this.notice.hidden = false; this.setStatus('Project analysis stopped'); }
            if (this.tab === 'Intelligence') { void this.guard(() => this.renderTab()); } return;
        }
        if (params.kind === 'model_request') { this.flushAssistant(); this.assistant = undefined; this.assistantText = ''; }
        else if (params.kind === 'text_delta') {
            if (!this.assistant) { this.assistant = this.addMessage('assistant', ''); } this.assistantText = (this.assistantText + payload.text).slice(0, 1_000_000);
            if (this.animation === undefined) { this.animation = requestAnimationFrame(() => { this.animation = undefined; this.flushAssistant(); }); }
        } else if (params.kind === 'tool_started') { this.addTool(payload); }
        else if (params.kind === 'tool_completed') { const card = this.addTool(payload); card.classList.add(payload.ok ? 'succeeded' : 'failed'); card.querySelector('.tool-status')!.textContent = payload.ok ? 'Complete' : 'Failed'; card.querySelector('pre')!.textContent = JSON.stringify(payload, null, 2).slice(0, 32000); if (!payload.ok) { card.open = true; } }
        else if (params.kind === 'permission_request') {
            const card = el('section', '', 'permission-card'); card.dataset.traceId = params.trace_id; const heading = el('div', '', 'permission-heading'); heading.append(icon('shield'), el('strong', 'Approval needed'));
            card.append(heading, el('p', `${payload.tool} · ${payload.category}`, 'permission-action'), el('code', payload.target, 'permission-target'), el('p', payload.reason, 'permission-reason')); const actions = el('div', '', 'permission-actions');
            for (const [label, decision, style] of [['Allow once', 'once', 'primary-button'], ['Allow session', 'session', 'secondary-button'], ['Deny', 'deny', 'deny-button']]) {
                actions.append(this.button(label, async () => {
                    for (const button of Array.from(actions.querySelectorAll('button'))) { button.disabled = true; }
                    try { await this.bridge.request('permissions/respond', { session_id: params.session_id, request_id: payload.id, decision }); card.remove(); }
                    catch (error) { for (const button of Array.from(actions.querySelectorAll('button'))) { button.disabled = false; } throw error; }
                }, style));
            } card.append(actions); this.approvals.append(card);
        } else if (params.kind === 'session_completed' || params.kind === 'session_error') {
            this.flushAssistant(); this.active = false; this.assistant = undefined;
            for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } }
            this.updateActions();
            this.setStatus(params.kind === 'session_completed' ? `Complete · ${payload.budget.tokens.toLocaleString()} tokens · $${payload.budget.cost.toFixed(4)}` : 'Task stopped'); if (params.kind === 'session_error') { this.notice.textContent = payload.message; this.notice.hidden = false; }
        } else if (params.kind === 'usage') { this.setStatus(`Working · ${(payload.input_tokens + payload.output_tokens).toLocaleString()} tokens`); }
    }
    dispose(): void { this.disposed = true; this.renderRevision++; if (this.animation !== undefined) { cancelAnimationFrame(this.animation); } this.disposeEvent(); this.root.replaceChildren(); }
}
