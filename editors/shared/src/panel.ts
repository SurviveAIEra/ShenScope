import { renderMarkdown } from './markdown.js';
export interface PanelBridge {
    request(method: string, params?: Record<string, unknown>): Promise<any>;
    onEvent(listener: (method: string, params: any) => void): () => void;
    setCredential(variable: string): Promise<void>;
    openFile(path: string, line?: number): Promise<void>;
    openSkillSource(jobId: string, sessionId: string): Promise<void>;
    openHookSource(jobId: string, sessionId: string): Promise<void>;
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
        check: 'M5 12l4 4L19 6', close: 'M6 6l12 12M18 6 6 18', arrow: 'M5 12h14M13 6l6 6-6 6', tool: 'M14 5a5 5 0 0 0-6 6L3 16l5 5 5-5a5 5 0 0 0 6-6l-4 3-4-4z',
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
    private projectWatch: any;
    private projectWatchAutomatic = false;
    private projectWatchViews = new Map<string, any>();
    private projectWatchEventRevision = 0;
    private completedProjectJobs = new Set<string>();
    private mcpJob?: string;
    private mcpResult?: { server: string; action: string; result: any };
    private completedMCPJobs = new Set<string>();
    private skillsJob?: string;
    private skillsStarting = false;
    private skillsResult?: { action: string; result: any };
    private completedSkillsJobs = new Set<string>();
    private hooksJob?: string;
    private hooksStarting = false;
    private hooksResult?: { action: string; result: any };
    private completedHooksJobs = new Set<string>();
    private contextJob?: string;
    private contextStarting = false;
    private contextResult?: { action: string; result: any };
    private completedContextJobs = new Set<string>();
    constructor(private readonly root: HTMLElement, private readonly bridge: PanelBridge) {
        root.classList.add('shenscope-panel');
        const header = el('header', '', 'panel-header'); const brand = el('div', '', 'brand'); const mark = el('span', '', 'brand-mark'); mark.append(icon('scope')); brand.append(mark, el('strong', 'ShenScope'));
        header.append(brand, this.button('New conversation', () => this.newConversation(), 'icon-button', 'plus'));
        const nav = el('nav', '', 'primary-nav'); nav.setAttribute('aria-label', 'ShenScope views');
        for (const [name, label, glyph] of [['Chat', 'Chat', 'chat'], ['History', 'History', 'history'], ['Intelligence', 'Project', 'graph']]) {
            const button = this.button(label, () => this.selectTab(name), 'nav-button', glyph); this.navigation.set(name, button); nav.append(button);
        }
        const more = el('select', '', 'more-views'); more.setAttribute('aria-label', 'More views');
        for (const name of ['More', 'Settings', 'Tools', 'Runtime', 'Security', 'MCP', 'Skills', 'Hooks', 'Context']) { const option = el('option', name); option.value = name; more.append(option); }
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
        if (this.active || this.projectJob || this.mcpJob || this.skillsJob || this.skillsStarting || this.hooksJob || this.hooksStarting || this.contextBusy()) { throw new Error('Cancel or finish the current task before starting another conversation.'); }
        this.sessionId = undefined; this.contextResult = undefined; this.assistant = undefined; this.assistantText = ''; this.toolCards.clear(); this.transcript.replaceChildren(); this.notice.hidden = true; await this.selectTab('Chat'); this.composer.focus();
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
        this.sendButton.disabled = !this.config || !this.composer.value.trim() || !!this.hooksJob || this.hooksStarting || !!this.contextJob || this.contextStarting; this.cancelButton.hidden = !this.active;
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
        if (this.tab === 'Skills' && this.capabilities.skills) { await this.skills(revision); return; }
        if (this.tab === 'Hooks' && this.capabilities.hooks) { await this.hooks(revision); return; }
        if (this.tab === 'Context' && this.capabilities.context_checkpoints) { await this.contextView(revision); return; }
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
                    if (this.active || this.projectJob || this.mcpJob || this.skillsJob || this.skillsStarting || this.hooksJob || this.hooksStarting || this.contextBusy()) { throw new Error('Finish the current task before switching conversations.'); }
                    const openingRevision = this.renderRevision; this.sessionId = session.id; this.contextResult = undefined;
                    const full = await this.bridge.request('sessions/get', { session_id: session.id });
                    if (this.sessionId !== full.id) { return; }
                    this.assistant = undefined; this.assistantText = ''; this.toolCards.clear(); this.transcript.replaceChildren();
                    for (const message of full.messages) { this.addMessage(message.role, message.text); }
                    if (this.tab === 'History' && this.renderRevision === openingRevision) { await this.selectTab('Chat'); this.scrollToEnd(true); this.composer.focus(); }
                    else { await this.renderTab(); }
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
    private async startSkills(action: string, args: Record<string, unknown> = {}): Promise<void> {
        if (this.skillsJob || this.skillsStarting || this.hooksJob || this.hooksStarting) { throw new Error('Finish or cancel the current Skills operation.'); }
        this.skillsStarting = true;
        try {
            const session_id = await this.ensureSession('Workspace skills'); this.skillsResult = undefined;
            const result = await this.bridge.request('skills/start', { session_id, action, ...args });
            if (!this.completedSkillsJobs.has(result.job_id)) { this.skillsJob = result.job_id; this.setStatus('Loading skills…'); }
        } finally { this.skillsStarting = false; }
        if (this.tab === 'Skills') { await this.renderTab(); }
    }
    private async skills(revision: number): Promise<void> {
        const configuration = await this.bridge.request('config/get');
        if (revision !== this.renderRevision) { return; }
        this.config = configuration.value; this.configRevision = configuration.sha256;
        const session_id = await this.ensureSession('Workspace skills');
        const heading = el('div', '', 'view-heading'); heading.append(el('h2', 'Skills'));
        const reload = this.button('Reload skills', () => this.startSkills('reload')); reload.disabled = !!this.skillsJob; heading.append(reload);
        this.content.append(heading, el('p', 'Load reusable instructions for this conversation. Review the source and choose which skills to activate.', 'view-description'));
        if (this.skillsJob) { this.content.append(el('p', 'Waiting for the source or your approval…', 'empty-text'), this.button('Cancel operation', async () => {
            await this.bridge.request('skills/cancel_job', { session_id, job_id: this.skillsJob });
        })); }
        let snapshot: any;
        try { snapshot = await this.bridge.request('skills/query', { session_id }); }
        catch { snapshot = ['list', 'reload'].includes(this.skillsResult?.action ?? '') ? this.skillsResult?.result : undefined; }
        if (revision !== this.renderRevision) { return; }
        if (snapshot && !snapshot.indexed && !snapshot.skills && !this.skillsJob && !this.skillsStarting) { await this.startSkills('list'); return; }
        if (!snapshot?.skills) { this.content.append(el('p', 'Load the catalog to inspect available skills.', 'empty-text')); }
        else {
            for (const [scope, label] of [['project', 'Project skills'], ['user', 'User skills']]) {
                const section = el('section', '', 'skills-group'); section.append(el('h3', label));
                const rows = snapshot.skills.filter((skill: any) => skill.scope === scope);
                if (!rows.length) { section.append(el('p', 'No skills found in this source.', 'empty-text')); }
                for (const skill of rows) {
                    const card = el('article', '', 'info-card skill-card'); card.dataset.skillId = skill.id;
                    const title = el('div', '', 'view-heading'); title.append(el('h4', skill.name), el('span', skill.loaded ? 'Active' : skill.enabled ? 'Available' : 'Disabled', `badge badge-${skill.loaded ? 'allow' : 'ask'}`));
                    card.append(title, el('p', skill.description), el('small', skill.path, 'skill-source'));
                    if (!skill.selected) { card.append(el('small', 'Another source has priority for this name. You can choose this source explicitly.')); }
                    const enabled = el('input'); enabled.type = 'checkbox'; enabled.checked = skill.enabled; enabled.setAttribute('aria-label', `Enabled ${skill.name}`);
                    enabled.disabled = this.active || !!this.skillsJob || !!this.mcpJob || !!this.projectJob || !!this.hooksJob || this.hooksStarting;
                    const label = el('label', '', 'checkbox-field'); label.append(enabled, el('span', 'Enabled')); card.append(label);
                    enabled.addEventListener('change', () => { enabled.disabled = true; void this.guard(async () => {
                        const next = structuredClone(this.config); next.skills ??= {};
                        next.skills.disabled = (next.skills.disabled ?? []).filter((id: string) => id !== skill.id && (enabled.checked ? id !== skill.name : true));
                        if (!enabled.checked) { next.skills.disabled.push(skill.id); }
                        const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision });
                        this.config = next; this.configRevision = result.sha256; this.skillsResult = undefined; await this.renderTab();
                    }); });
                    const actions = el('div', '', 'analysis-actions');
                    if (skill.loaded) { actions.append(this.button('Deactivate', () => this.startSkills('deactivate', { name: skill.id }))); }
                    else if (skill.enabled && skill.user_invocable) {
                        const argumentsInput = this.field('Skill arguments', '', card);
                        actions.append(this.button('Activate', () => this.startSkills('activate', { name: skill.id, arguments: argumentsInput.value, expected_sha256: skill.sha256 }), 'primary-button'));
                    }
                    actions.append(this.button('Open source', () => this.startSkills('source', { name: skill.id })));
                    for (const button of Array.from(actions.querySelectorAll('button'))) { button.disabled = !!this.skillsJob || this.active; }
                    card.append(actions);
                    const details = el('details', '', 'advanced-settings'); details.append(el('summary', 'Metadata'), el('pre', JSON.stringify(skill.metadata, null, 2))); card.append(details); section.append(card);
                }
                this.content.append(section);
            }
            if (snapshot.truncated) { this.content.append(el('p', 'The catalog reached its configured capacity. Review source roots and limits.', 'error-text')); }
            for (const diagnostic of snapshot.diagnostics ?? []) { this.content.append(el('p', `${diagnostic.code} · ${diagnostic.path}`, 'skill-diagnostic')); }
        }
        if (this.skillsResult && !['list', 'reload'].includes(this.skillsResult.action)) {
            const result = el('details', '', 'skill-result'); result.append(el('summary', 'Operation result'), el('pre', JSON.stringify(this.skillsResult.result, null, 2).slice(0, 128000))); this.content.append(result);
        }
        const roots = el('details', '', 'settings-group'); roots.append(el('summary', 'Skill sources'));
        const inputs = new Map<string, HTMLTextAreaElement>();
        for (const [key, label, defaults] of [['project_roots', 'Project roots · one per line', ['.shenscope/skills', '.agents/skills', '.claude/skills']], ['user_roots', 'User roots · absolute paths, one per line', []]] as const) {
            const field = el('label', label, 'field'); const input = el('textarea'); input.rows = 3; input.value = (this.config.skills?.[key] ?? snapshot?.roots?.[key === 'project_roots' ? 'project' : 'user'] ?? defaults).join('\n'); field.append(input); roots.append(field); inputs.set(key, input);
        }
        const save = this.button('Save skill sources', async () => {
            const next = structuredClone(this.config); next.skills ??= {};
            for (const [key, input] of inputs) { next.skills[key] = input.value.split('\n').map(line => line.trim()).filter(Boolean); }
            const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision }); this.config = next; this.configRevision = result.sha256; this.skillsResult = undefined; await this.renderTab();
        }, 'primary-button'); save.disabled = this.active || !!this.skillsJob || !!this.mcpJob || !!this.projectJob || !!this.hooksJob || this.hooksStarting; roots.append(save); this.content.append(roots);
    }
    private contextBusy(): boolean { return this.active || !!this.contextJob || this.contextStarting || !!this.hooksJob || this.hooksStarting || !!this.skillsJob || this.skillsStarting || !!this.mcpJob || !!this.projectJob; }
    private async startContext(action: string, args: Record<string, unknown> = {}): Promise<void> {
        if (this.contextBusy()) { throw new Error('Finish or cancel the current operation before working with context.'); }
        this.contextStarting = true; this.contextResult = undefined;
        if (this.tab === 'Context') { for (const button of Array.from(this.content.querySelectorAll('button'))) { button.disabled = true; } }
        this.updateActions();
        try {
            const session_id = await this.ensureSession('Conversation context');
            const result = await this.bridge.request('context/start', { session_id, action, ...args });
            if (!this.completedContextJobs.has(result.job_id)) { this.contextJob = result.job_id; this.setStatus('Preparing conversation context…'); }
        } finally { this.contextStarting = false; this.updateActions(); }
        if (this.tab === 'Context') { await this.renderTab(); }
    }
    private async contextView(revision: number): Promise<void> {
        const configuration = await this.bridge.request('config/get');
        if (revision !== this.renderRevision) { return; }
        this.config = configuration.value; this.configRevision = configuration.sha256;
        const session_id = await this.ensureSession('Conversation context');
        const heading = el('div', '', 'view-heading'); heading.append(el('h2', 'Conversation context'));
        const refresh = this.button('Refresh context', async () => { this.contextResult = undefined; await this.renderTab(); }); refresh.disabled = this.contextBusy(); heading.append(refresh);
        this.content.append(heading, el('p', 'Keep your current goal and recent work in view. Original messages stay available when older context is compacted.', 'view-description'));
        let snapshot: any;
        try { snapshot = await this.bridge.request('context/query', { session_id }); }
        catch { if (this.contextResult?.action === 'status') { snapshot = this.contextResult.result; } }
        if (revision !== this.renderRevision) { return; }
        if (this.contextJob) {
            this.content.append(el('p', 'Working or waiting for your approval…', 'empty-text'), this.button('Cancel context operation', async () => { await this.bridge.request('context/cancel_job', { session_id, job_id: this.contextJob }); }));
        }
        if (!snapshot) {
            const load = this.button('Load context status', () => this.startContext('status')); load.disabled = this.contextBusy(); this.content.append(load);
        } else {
            const metrics = el('div', '', 'context-metrics');
            const latest = snapshot.latest; const measure = latest?.measure;
            for (const [label, value] of [['Original messages', snapshot.messages], ['Request messages', latest?.projected_messages ?? '—'], ['Estimated input tokens', measure?.estimated_tokens?.toLocaleString() ?? '—'], ['Input token allowance', measure?.input_limit?.toLocaleString() ?? '—']]) {
                const item = el('div'); item.append(el('strong', String(value)), el('small', String(label))); metrics.append(item);
            }
            this.content.append(metrics);
            if (measure) {
                const usage = el('div', '', 'context-usage'); const meter = el('progress'); meter.max = Math.max(1, measure.input_limit); meter.value = Math.min(meter.max, measure.estimated_tokens);
                meter.setAttribute('aria-label', 'Estimated context usage'); usage.append(meter, el('small', `${Math.round(measure.estimated_tokens / meter.max * 100)}% of input allowance · estimate`)); this.content.append(usage);
            } else { this.content.append(el('p', 'Usage appears after the first model request.', 'empty-text')); }
            const checkpoint = snapshot.checkpoint;
            const card = el('section', '', 'info-card context-checkpoint');
            card.append(el('h3', checkpoint ? 'Saved context checkpoint' : 'Complete conversation in view'));
            card.append(el('p', checkpoint ? `Messages 1–${checkpoint.covered} · ${checkpoint.method === 'model' ? 'Model summary' : 'Evidence excerpts'} · ${checkpoint.bytes.toLocaleString()} bytes` : 'No older messages have been compacted.'));
            if (checkpoint) {
                card.append(el('small', `Saved ${checkpoint.created_at}`));
                const sources = el('div', '', 'context-references');
                for (const source of (checkpoint.sources ?? []).slice(0, 24)) {
                    const read = this.button(`Read message ${source.message}`, () => this.startContext('source', { message: source.message, sha256: source.sha256 })); read.disabled = this.contextBusy(); sources.append(read);
                }
                card.append(sources);
                const provenance = el('details'); provenance.append(el('summary', 'Source integrity'), el('code', checkpoint.prefix_sha256)); card.append(provenance);
            }
            this.content.append(card);
            const actions = el('div', '', 'analysis-actions context-actions');
            const compact = this.button('Compact older context', () => this.startContext('compact', { mode: 'extractive' }), 'primary-button'); compact.disabled = this.contextBusy() || snapshot.messages < 3;
            const summarize = this.button('Summarize with model', () => this.startContext('compact', { mode: 'model' })); summarize.disabled = this.contextBusy() || snapshot.messages < 3;
            actions.append(compact, summarize); this.content.append(actions, el('p', 'Model summaries use your configured model and usage budget.', 'context-footnote'));
        }
        const instructions = el('section', '', 'context-instructions'); const load = this.button('Inspect project instructions', () => this.startContext('instructions')); load.disabled = this.contextBusy();
        instructions.append(el('h3', 'Applicable instructions'), el('p', 'Root instructions and directories touched by this conversation are loaded when a request is prepared.', 'empty-text'), load);
        const sources = this.contextResult?.action === 'instructions' ? this.contextResult.result.instructions : snapshot?.latest?.instructions;
        for (const source of sources ?? []) {
            const card = el('details', '', 'info-card context-source'); card.append(el('summary', source.path.split(/[\\/]/).pop() ?? source.path), el('small', `${source.scope} · ${source.directory}`), el('code', source.sha256));
            if (source.text !== undefined) { card.append(el('pre', source.text)); }
            instructions.append(card);
        }
        this.content.append(instructions);
        if (this.contextResult?.action === 'source' || this.contextResult?.action === 'artifact') {
            const result = this.contextResult.result; const card = el('section', '', 'info-card context-evidence'); card.append(el('h3', this.contextResult.action === 'source' ? `Original message ${result.source.message}` : 'Original tool output'), el('pre', result.text));
            if (this.contextResult.action === 'source' && !result.complete) {
                const next = this.button('Read next page', () => this.startContext('source', { message: result.source.message, sha256: result.source.sha256, start_byte: result.next_byte })); next.disabled = this.contextBusy(); card.append(next);
            }
            this.content.append(card);
        }
        const recovery = el('details', '', 'settings-group'); recovery.append(el('summary', 'Context settings'));
        const toggle = el('label', '', 'toggle-field'); const enabled = el('input'); enabled.type = 'checkbox'; enabled.checked = this.config.context?.auto_compact ?? true; enabled.setAttribute('aria-label', 'Automatically compact context'); toggle.append(enabled, el('span', 'Automatically compact context')); recovery.append(toggle);
        const sourcesInput = el('textarea'); sourcesInput.rows = 2; sourcesInput.value = (this.config.context?.user_files ?? []).join('\n'); sourcesInput.setAttribute('aria-label', 'User instruction files'); const sourceLabel = el('label', 'User instruction files · absolute paths, one per line', 'field'); sourceLabel.append(sourcesInput); recovery.append(sourceLabel);
        const save = this.button('Save context settings', async () => {
            const next = structuredClone(this.config); next.context ??= {}; next.context.auto_compact = enabled.checked; next.context.user_files = sourcesInput.value.split('\n').map(path => path.trim()).filter(Boolean);
            const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision }); this.config = next; this.configRevision = result.sha256; await this.renderTab();
        }); save.disabled = this.contextBusy(); recovery.append(save); this.content.append(recovery);
    }
    private hooksBusy(): boolean { return this.active || !!this.hooksJob || this.hooksStarting || !!this.skillsJob || !!this.mcpJob || !!this.projectJob || !!this.contextJob || this.contextStarting; }
    private async startHooks(action: string, args: Record<string, unknown> = {}): Promise<void> {
        if (this.hooksJob || this.hooksStarting) { throw new Error('Finish or cancel the current Hook operation.'); }
        this.hooksStarting = true;
        if (this.tab === 'Hooks') { for (const control of Array.from(this.content.querySelectorAll<HTMLButtonElement | HTMLInputElement>('button, input[type="checkbox"]'))) { control.disabled = true; } }
        this.updateActions();
        try {
            const session_id = await this.ensureSession('Workspace hooks'); this.hooksResult = undefined;
            const result = await this.bridge.request('hooks/start', { session_id, action, ...args });
            if (!this.completedHooksJobs.has(result.job_id)) { this.hooksJob = result.job_id; this.setStatus('Working with Hooks…'); }
        } finally { this.hooksStarting = false; }
        if (this.tab === 'Hooks') { await this.renderTab(); }
    }
    private async hooks(revision: number): Promise<void> {
        const configuration = await this.bridge.request('config/get');
        if (revision !== this.renderRevision) { return; }
        this.config = configuration.value; this.configRevision = configuration.sha256;
        const session_id = await this.ensureSession('Workspace hooks');
        const heading = el('div', '', 'view-heading'); heading.append(el('h2', 'Lifecycle Hooks'));
        const reload = this.button('Reload hooks', () => this.startHooks('reload')); reload.disabled = this.hooksBusy(); heading.append(reload);
        this.content.append(heading, el('p', 'Run your configured checks at specific stages. Each command uses your process permissions.', 'view-description'));
        const globalLabel = el('label', '', 'toggle-field'); const global = el('input'); global.type = 'checkbox'; global.checked = this.config.hooks?.enabled ?? true;
        global.setAttribute('aria-label', 'Enable lifecycle Hooks'); global.disabled = this.hooksBusy(); globalLabel.append(global, el('span', 'Enable lifecycle Hooks')); this.content.append(globalLabel);
        global.addEventListener('change', () => { void this.guard(async () => { const next = structuredClone(this.config); next.hooks ??= {}; next.hooks.enabled = global.checked; await this.saveHooksConfig(next); }); });
        if (this.hooksJob) { this.content.append(el('p', 'Waiting for the command or your approval…', 'empty-text'), this.button('Cancel hook operation', async () => { await this.bridge.request('hooks/cancel_job', { session_id, job_id: this.hooksJob }); })); }
        let snapshot: any;
        try { snapshot = await this.bridge.request('hooks/query', { session_id }); }
        catch { snapshot = ['list', 'reload'].includes(this.hooksResult?.action ?? '') ? this.hooksResult?.result : undefined; }
        if (revision !== this.renderRevision) { return; }
        if (snapshot && !snapshot.indexed && !this.hooksJob && !this.hooksStarting) { await this.startHooks('list'); return; }
        if (!snapshot?.hooks?.length) { this.content.append(el('p', 'No configured hooks. Add a command or select a project configuration file.', 'empty-text')); }
        for (const hook of snapshot?.hooks ?? []) {
            const card = el('section', '', 'info-card hook-card'); const title = el('div', '', 'view-heading');
            title.append(el('h3', hook.name), el('span', hook.enabled ? 'Enabled' : 'Disabled', `badge badge-${hook.enabled ? 'allow' : 'deny'}`)); card.append(title);
            card.append(el('p', hook.point.replaceAll('_', ' '), 'hook-point'), el('small', `${hook.scope} · ${hook.source ?? 'Inline configuration'}`, 'hook-source'));
            const toggleLabel = el('label', '', 'toggle-field'); const enabled = el('input'); enabled.type = 'checkbox'; enabled.checked = hook.enabled;
            enabled.setAttribute('aria-label', `Enabled ${hook.name}`); enabled.disabled = this.hooksBusy() || !snapshot.enabled || (!hook.declared_enabled && hook.scope !== 'config'); toggleLabel.append(enabled, el('span', 'Enabled')); card.append(toggleLabel);
            enabled.addEventListener('change', () => { void this.guard(async () => {
                const next = structuredClone(this.config); next.hooks ??= {};
                next.hooks.disabled = (next.hooks.disabled ?? []).filter((id: string) => id !== hook.id && (enabled.checked ? id !== hook.name : true));
                if (!enabled.checked) { next.hooks.disabled.push(hook.id); }
                // A declaration-level disabled state is edited in its own configuration source.
                if (enabled.checked && next.hooks.entries) { for (const entry of next.hooks.entries) { if (entry.name === hook.name && hook.scope === 'config') { entry.enabled = true; } } }
                await this.saveHooksConfig(next);
            }); });
            if (hook.recent) {
                const recent = el('div', '', 'hook-recent'); recent.append(el('strong', `Last run · ${hook.recent.status}`), el('small', `${Math.round(hook.recent.duration_seconds * 1000)} ms · ${hook.recent.timestamp}`));
                if (hook.recent.error) { recent.append(el('p', hook.recent.error, 'hook-error')); }
                if (hook.recent.reason) { recent.append(el('p', hook.recent.reason)); }
                card.append(recent);
            } else { card.append(el('p', 'No runs in this conversation', 'empty-text')); }
            const details = el('details'); details.append(el('summary', 'Command and behavior'), el('pre', hook.argv.map((arg: string) => JSON.stringify(arg)).join(' ')), el('small', `${hook.cwd} · ${hook.timeout}s · errors ${hook.on_failure} · context ${hook.allow_context ? 'enabled' : 'disabled'}`)); card.append(details);
            const actions = el('div', '', 'button-row'); const test = this.button('Test hook', () => this.startHooks('test', { name: hook.id })); test.disabled = !hook.enabled || this.hooksBusy(); actions.append(test);
            if (hook.source) { const open = this.button('Open configuration', () => this.startHooks('source', { name: hook.id })); open.disabled = this.hooksBusy(); actions.append(open); }
            card.append(actions); this.content.append(card);
        }
        this.hookConfigurationForm();
    }
    private async saveHooksConfig(next: any): Promise<void> {
        const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision });
        this.config = next; this.configRevision = result.sha256; this.hooksResult = undefined; await this.renderTab();
    }
    private hookConfigurationForm(): void {
        const sources = el('details', '', 'settings-group'); sources.append(el('summary', 'Configuration sources'));
        const project = el('textarea'); project.rows = 2; project.value = (this.config.hooks?.project_files ?? ['.shenscope/hooks.toml']).join('\n'); project.setAttribute('aria-label', 'Project Hook configuration files');
        const user = el('textarea'); user.rows = 2; user.value = (this.config.hooks?.user_files ?? []).join('\n'); user.setAttribute('aria-label', 'User Hook configuration files');
        for (const [label, input] of [['Project files · one per line', project], ['User files · absolute paths', user]] as const) { const field = el('label', label, 'field'); field.append(input); sources.append(field); }
        const saveSources = this.button('Save hook sources', async () => {
            const next = structuredClone(this.config); next.hooks ??= {}; next.hooks.project_files = project.value.split('\n').map(value => value.trim()).filter(Boolean); next.hooks.user_files = user.value.split('\n').map(value => value.trim()).filter(Boolean); await this.saveHooksConfig(next);
        }); saveSources.disabled = this.hooksBusy(); sources.append(saveSources); this.content.append(sources);
        const form = el('details', '', 'settings-group'); form.append(el('summary', 'Add command hook'));
        const name = this.field('Hook name', '', form); const point = el('select'); point.setAttribute('aria-label', 'Hook lifecycle point');
        for (const value of ['session_start', 'before_model', 'after_model', 'before_tool', 'after_tool', 'after_edit', 'after_test', 'session_end']) { const option = el('option', value.replaceAll('_', ' ')); option.value = value; point.append(option); }
        const pointField = el('label', 'Lifecycle point', 'field'); pointField.append(point); form.append(pointField);
        const executable = this.field('Hook executable', '', form); const argumentsInput = el('textarea'); argumentsInput.rows = 3; argumentsInput.setAttribute('aria-label', 'Hook arguments · one per line'); const argumentsField = el('label', 'Arguments · one per line', 'field'); argumentsField.append(argumentsInput); form.append(argumentsField);
        const save = this.button('Add hook', async () => {
            const next = structuredClone(this.config); next.hooks ??= {}; next.hooks.entries ??= [];
            next.hooks.entries.push({ name: name.value.trim(), point: point.value, argv: [executable.value.trim(), ...argumentsInput.value.split('\n').filter(value => value.length > 0)], enabled: true }); await this.saveHooksConfig(next);
        }, 'primary-button'); save.disabled = this.hooksBusy(); form.append(save); this.content.append(form);
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
            enabled.setAttribute('aria-label', `Enabled ${server.name}`); enabled.disabled = !!this.mcpJob || this.active || !!this.projectJob || !!this.hooksJob || this.hooksStarting;
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
        }, 'primary-button'); save.disabled = !!this.mcpJob || this.active || !!this.projectJob || !!this.hooksJob || this.hooksStarting; parent.append(save);
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
        for (const [value, label] of [['tree_sitter', 'Tree-sitter'], ['go_ast', 'Go AST'], ['codegraph', 'CodeGraph'], ['typescript', 'TypeScript compiler']]) {
            const option = el('option', label); option.value = value; option.selected = value === this.projectBackend; backend.append(option);
        }
        backend.disabled = !!this.projectJob;
        backend.addEventListener('change', () => { this.projectBackend = backend.value; this.projectResult = undefined; void this.guard(() => this.renderTab()); });
        this.content.append(heading, el('p', 'Explore symbols and trace the evidence behind affected code and test candidates.', 'view-description'), backend);
        if (this.projectJob) {
            this.content.append(el('p', 'Working on the project index…', 'empty-text'), this.button('Cancel indexing', async () => { await this.bridge.request('project/cancel', { job_id: this.projectJob, session_id: this.sessionId }); })); return;
        }
        const index = this.button('Index project', async () => {
            if (this.projectWatchLive(this.projectWatch)) { await this.requestProjectWatchRefresh(); }
            else { await this.startProject('build'); }
        }, 'primary-button', 'graph'); this.content.append(index);
        const status = await this.bridge.request('project/query', { backend: this.projectBackend, action: 'status', ...(this.sessionId ? { session_id: this.sessionId } : {}) });
        if (revision !== this.renderRevision) { return; }
        const watchEventRevision = this.projectWatchEventRevision;
        const watches = this.sessionId ? await this.bridge.request('project/watch_list', { session_id: this.sessionId }) : [];
        if (revision !== this.renderRevision) { return; }
        const candidates = watches.filter((watch: any) => watch.backend === this.projectBackend);
        this.projectWatch = candidates.find((watch: any) => this.projectWatchLive(watch)) ?? candidates[candidates.length - 1];
        if (this.projectWatch && watchEventRevision !== this.projectWatchEventRevision) { this.projectWatch = this.projectWatchViews.get(this.projectWatch.id) ?? this.projectWatch; }
        if (status.indexed) { index.querySelector('span')!.textContent = 'Refresh index'; index.setAttribute('aria-label', 'Refresh index'); }
        if (!status.indexed) { this.content.append(el('p', 'Index source files to search declarations and compute dependency candidates. Your approval controls parsing and storage.', 'view-description')); return; }
        const metrics = el('div', '', 'project-metrics');
        for (const [label, value] of [['Files', status.files], ['Symbols', status.symbols], ['Relations', status.relations], ['Revision', status.revision]]) {
            const metric = el('div'); metric.append(el('strong', Number(value).toLocaleString()), el('small', String(label))); metrics.append(metric);
        }
        const semantic = status.capabilities?.calls === 'semantic';
        this.content.append(metrics, el('p', semantic ? 'Compiler snapshot. Refresh after edits. Static resolution does not prove the target of every runtime call.' : 'Last indexed snapshot. Refresh after changes. Call links use syntax evidence and may miss dynamic or unresolved calls.', 'view-description'));
        const watchPanel = el('section', '', 'project-watch'); this.renderProjectWatch(watchPanel, this.projectWatch); this.content.append(watchPanel);
        const compact = this.button('Compact index history', () => this.startProject('compact'), 'secondary-button');
        compact.disabled = this.projectWatchLive(this.projectWatch); if (compact.disabled) { compact.title = 'Stop watching before compacting the index.'; }
        const cache = el('details', '', 'project-cache'); cache.append(el('summary', 'Index storage · ' + this.formatBytes(status.persistent_bytes ?? 0)),
            el('p', 'Store current index facts to reclaim space used by older index revisions.', 'view-description'),
            compact);
        if (this.projectResult?.compacted !== undefined) { cache.open = true; cache.append(el('p', this.projectResult.compacted ? 'Reclaimed ' + this.formatBytes(this.projectResult.saved_bytes) + '.' : 'The current index already uses less space than a replacement snapshot.', 'view-description')); }
        this.content.append(cache);
        if (semantic) {
            const quality = el('div', '', 'compiler-status'); quality.append(el('span', 'TypeScript 5.9.2', 'badge'),
                el('span', String(status.diagnostics ?? 0) + ' diagnostics'), el('span', String(status.unresolved_semantic_calls ?? 0) + ' unresolved calls'));
            this.content.append(quality);
        }
        const query = el('input', '', 'history-search'); query.placeholder = 'Search a symbol…'; query.setAttribute('aria-label', 'Search project symbols');
        const results = el('div', '', 'symbol-results'); const inspection = el('section', '', 'project-inspection'); inspection.hidden = true;
        this.content.append(query, results, inspection); let request = 0; let inspectionRequest = 0; let timer: ReturnType<typeof setTimeout> | undefined;
        const inspect = async (symbol: any | undefined, action: string, offset = 0): Promise<void> => {
            const current = ++inspectionRequest; const selectedBackend = this.projectBackend; inspection.hidden = false;
            inspection.replaceChildren(el('p', 'Reading indexed evidence…', 'view-description'));
            const result = await this.bridge.request('project/query', { backend: selectedBackend, action, revision: status.revision, offset, limit: 30,
                ...(symbol ? { symbol_id: symbol.id } : {}), ...(this.sessionId ? { session_id: this.sessionId } : {}) });
            if (current !== inspectionRequest || revision !== this.renderRevision || selectedBackend !== this.projectBackend) { return; }
            const header = el('div', '', 'view-heading'); header.append(el('h3', symbol?.qualified_name ?? 'Compiler diagnostics'),
                this.button('Close inspection', async () => { inspectionRequest++; inspection.hidden = true; inspection.replaceChildren(); }, 'icon-button', 'close'));
            inspection.replaceChildren(header);
            if (symbol) {
                const source = el('div', '', 'inspection-source');
                source.append(el('small', symbol.kind + ' · ' + symbol.location.file + ':' + symbol.location.start_line),
                    this.button('Open declaration', () => this.bridge.openFile(symbol.location.file, symbol.location.start_line), 'source-link'));
                inspection.append(source);
                const actions = el('div', '', 'navigation-actions');
                for (const [label, value, enabled] of [
                    ['Type', 'hover', status.capabilities?.types], ['Definitions', 'definitions', status.capabilities?.definitions],
                    ['References', 'references', status.capabilities?.references], ['Callers', 'incoming_calls', status.capabilities?.calls !== 'none'],
                    ['Calls', 'outgoing_calls', status.capabilities?.calls !== 'none'], ['Implementations', 'implementations', status.capabilities?.implementations],
                ] as const) {
                    if (enabled) { actions.append(this.button(label, () => inspect(symbol, value), value === action ? 'primary-button' : 'secondary-button')); }
                }
                inspection.append(actions);
            }
            if (action === 'hover') {
                inspection.append(el('pre', result.type || 'No inferred type is available.', 'semantic-type'));
                for (const item of result.symbols ?? []) { if (item.metadata?.signature) { inspection.append(el('code', item.metadata.signature, 'semantic-signature')); } }
                return;
            }
            for (const item of result.items ?? []) {
                const target = item.symbol ?? (action === 'incoming_calls' ? item.source : item.target) ?? (item.name ? item : undefined);
                const location = item.location ?? item.relation?.location ?? target?.location;
                const row = el('div', '', 'navigation-entry');
                if (location) { row.append(this.button(location.file + ':' + location.start_line, () => this.bridge.openFile(location.file, location.start_line), 'source-link')); }
                if (target) { row.append(el('strong', target.qualified_name ?? target.name)); }
                if (item.message) { row.append(el('span', item.category + ' · ' + item.code, 'badge'), el('p', item.message, 'diagnostic-message')); }
                else { row.append(el('small', item.role ?? item.resolution ?? item.relation?.kind ?? item.kind ?? 'definition')); }
                inspection.append(row);
            }
            if (!result.items?.length) { inspection.append(el('p', 'No entries in this indexed snapshot.', 'view-description')); }
            if (result.next_offset !== null && result.next_offset !== undefined) {
                inspection.append(this.button('Next evidence page', () => inspect(symbol, action, result.next_offset)));
            }
        };
        if (status.capabilities?.diagnostics) { this.content.append(this.button('Show diagnostics', () => inspect(undefined, 'diagnostics'))); }
        const search = async () => {
            const current = ++request; const result = await this.bridge.request('project/query', { backend: this.projectBackend, action: 'search', query: query.value, limit: 30, ...(this.sessionId ? { session_id: this.sessionId } : {}) });
            if (current !== request || revision !== this.renderRevision) { return; } results.replaceChildren();
            for (const symbol of result.symbols) {
                const row = el('div', '', 'symbol-row');
                row.append(this.button(symbol.name, () => this.bridge.openFile(symbol.location.file, symbol.location.start_line), 'source-link'), el('small', symbol.kind + ' · ' + symbol.location.file + ':' + symbol.location.start_line));
                if (semantic) { const button = this.button('Inspect', () => inspect(symbol, 'hover'), 'secondary-button symbol-inspect'); button.setAttribute('aria-label', 'Inspect ' + symbol.qualified_name); row.append(button); }
                results.append(row);
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
    private formatBytes(value: unknown): string {
        const bytes = typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : 0;
        if (bytes < 1024) { return Math.round(bytes) + ' B'; }
        if (bytes < 1024 * 1024) { return (bytes / 1024).toFixed(1) + ' KiB'; }
        return (bytes / (1024 * 1024)).toFixed(1) + ' MiB';
    }
    private async startProject(action: string, paths = ''): Promise<void> {
        if (!this.sessionId) { const session = await this.bridge.request('sessions/create', { title: 'Project analysis' }); this.sessionId = session.id; }
        const result = await this.bridge.request('project/start', { session_id: this.sessionId, backend: this.projectBackend, action, paths: paths.split(/[\n,]/).map(path => path.trim()).filter(Boolean) });
        if (!this.completedProjectJobs.has(result.job_id)) { this.projectJob = result.job_id; this.setStatus('Analyzing project…'); }
        await this.renderTab();
    }
    private projectWatchLive(watch: any): boolean { return !!watch && ['starting', 'watching', 'pending', 'dirty', 'updating', 'stopping'].includes(watch.phase); }
    private renderProjectWatch(parent: HTMLElement, watch: any): void {
        const live = this.projectWatchLive(watch); const heading = el('div', '', 'project-watch-heading');
        const phase = watch?.phase ?? 'off'; const labels: Record<string, string> = { off: 'Off', starting: 'Starting…', watching: 'Watching', pending: 'Waiting for saves', dirty: 'Changes pending', updating: 'Updating…', stopping: 'Stopping…', stopped: 'Stopped', failed: 'Stopped with error' };
        heading.append(el('h3', 'File changes'), el('span', labels[phase] ?? phase, 'watch-state watch-' + phase));
        parent.replaceChildren(heading);
        if (!live) {
            const label = el('label', '', 'watch-option'); const automatic = el('input'); automatic.type = 'checkbox'; automatic.checked = this.projectWatchAutomatic;
            automatic.setAttribute('aria-label', 'Update index automatically'); automatic.addEventListener('change', () => { this.projectWatchAutomatic = automatic.checked; });
            label.append(automatic, el('span', 'Update index automatically')); parent.append(label,
                el('p', 'Watch saved files and configuration. Approvals still apply to index updates.', 'view-description'),
                this.button('Watch file changes', () => this.startProjectWatch(), 'secondary-button'));
        } else {
            parent.append(el('p', watch.automatic ? 'Saved changes update the index after they settle.' : 'Saved changes stay pending until you refresh the index.', 'view-description'));
            const actions = el('div', '', 'watch-actions');
            if (watch.changes?.total && phase !== 'updating' && phase !== 'stopping') { actions.append(this.button(watch.error ? 'Retry index update' : 'Update pending changes', () => this.requestProjectWatchRefresh(), 'primary-button')); }
            const stop = this.button('Stop watching', async () => {
                this.projectWatch = await this.bridge.request('project/watch_stop', { session_id: this.sessionId, watch_id: watch.id });
                this.renderProjectWatch(parent, this.projectWatch);
            }, 'secondary-button'); stop.disabled = phase === 'stopping'; actions.append(stop); parent.append(actions);
        }
        if (watch?.changes?.total) {
            const changes = el('details', '', 'watch-changes'); changes.append(el('summary', watch.changes.total + ' pending changes'));
            if (watch.changes.inventory_changed) { changes.append(el('p', 'The saved source input inventory changed.', 'view-description')); }
            for (const entry of watch.changes.entries ?? []) {
                const row = el('div', '', 'watch-file'); const source = this.button(entry.path, () => this.bridge.openFile(entry.path), 'source-link'); source.disabled = entry.kind === 'deleted';
                row.append(el('small', entry.kind), source); changes.append(row);
            }
            const page = async (offset: number): Promise<void> => {
                const result = await this.bridge.request('project/watch_status', { session_id: this.sessionId, watch_id: watch.id, offset, limit: 100 });
                if (this.projectWatch?.id === result.id) { this.projectWatch = result; this.renderProjectWatch(parent, result); }
            };
            if (watch.changes.offset > 0) { changes.append(this.button('Previous changes', () => page(Math.max(0, watch.changes.offset - 100)), 'secondary-button')); }
            if (watch.changes.has_more) { changes.append(this.button('More changes', () => page(watch.changes.offset + watch.changes.entries.length), 'secondary-button')); } parent.append(changes);
        }
        if (watch?.error) { parent.append(el('p', watch.error.message, 'watch-error')); }
        if (watch?.updates) { parent.append(el('small', watch.updates + (watch.updates === 1 ? ' batch indexed' : ' batches indexed'), 'watch-count')); }
    }
    private async startProjectWatch(): Promise<void> {
        if (!this.sessionId) { const session = await this.bridge.request('sessions/create', { title: 'Project changes' }); this.sessionId = session.id; }
        const watch = await this.bridge.request('project/watch_start', { session_id: this.sessionId, backend: this.projectBackend, automatic: this.projectWatchAutomatic });
        this.projectWatch = this.projectWatchViews.get(watch.id) ?? watch; await this.renderTab();
    }
    private async requestProjectWatchRefresh(): Promise<void> {
        if (!this.projectWatch) { return; }
        const revision = this.projectWatchEventRevision;
        const watch = await this.bridge.request('project/watch_refresh', { session_id: this.sessionId, watch_id: this.projectWatch.id });
        this.projectWatch = revision === this.projectWatchEventRevision ? watch : this.projectWatchViews.get(watch.id) ?? watch;
        const panel = this.content.querySelector<HTMLElement>('.project-watch'); if (panel) { this.renderProjectWatch(panel, this.projectWatch); }
    }
    private async settings(revision: number): Promise<void> {
        const snapshot = await this.bridge.request('config/get'); if (revision !== this.renderRevision) { return; } this.config = snapshot.value; this.configRevision = snapshot.sha256;
        this.content.append(el('h2', 'Settings', 'view-title'), el('p', 'One configuration for your workspace and conversations.', 'view-description'));
        const form = el('section', '', 'settings-form'); const provider = el('fieldset'); provider.append(el('legend', 'Model connection')); const protocol = el('select');
        for (const [value, label] of [['openai_chat', 'OpenAI compatible'], ['openai_responses', 'OpenAI Responses'], ['anthropic', 'Anthropic'], ['gemini', 'Google Gemini'], ['ollama', 'Ollama']]) { const option = el('option', label); option.value = value; option.selected = this.config.provider.protocol === value; protocol.append(option); }
        const protocolLabel = el('label', 'Provider protocol', 'field'); protocolLabel.append(protocol); provider.append(protocolLabel);
        const name = this.field('Provider name', this.config.provider.name, provider); const endpoint = this.field('API endpoint', this.config.provider.endpoint, provider); const model = this.field('Model', this.config.provider.model, provider);
        const modelLimits = el('details', '', 'advanced-settings'); modelLimits.append(el('summary', 'Model limits'));
        const contextWindow = this.field('Context window · tokens', String(this.config.provider.capabilities?.context_window ?? 128000), modelLimits, 'number');
        const maxOutput = this.field('Maximum output · tokens', String(this.config.provider.capabilities?.max_output ?? 8192), modelLimits, 'number'); provider.append(modelLimits);
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
            const windowValue = Number(contextWindow.value); const outputValue = Number(maxOutput.value);
            if (!Number.isSafeInteger(windowValue) || !Number.isSafeInteger(outputValue) || outputValue < 1 || outputValue >= windowValue) { throw new Error('Set a positive output limit below the context window.'); }
            next.provider.capabilities ??= {}; Object.assign(next.provider.capabilities, { context_window: windowValue, max_output: outputValue });
            for (const [key, input] of limits) { const value = Number(input.value); if (!input.value.trim() || !Number.isFinite(value)) { throw new Error('Enter finite budget values.'); } next.budget[key] = value; }
            for (const [category, select] of permissions) { next.permissions[category] = select.value; }
            const result = await this.bridge.request('config/set', { value: next, expected_sha256: this.configRevision }); this.configRevision = result.sha256; this.config = next; this.notice.hidden = true; this.setStatus('Settings saved');
        }, 'primary-button', 'check'); save.disabled = this.contextBusy(); form.append(provider, budget, permissionGroup, save); this.content.append(form); await refreshSecret();
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
        if (params.kind.startsWith('project_watch_')) {
            this.projectWatchEventRevision++;
            this.projectWatchViews.set(payload.id, payload); while (this.projectWatchViews.size > 32) { this.projectWatchViews.delete(this.projectWatchViews.keys().next().value!); }
            if (payload.backend === this.projectBackend) {
                this.projectWatch = payload;
                const panel = this.content.querySelector<HTMLElement>('.project-watch'); if (panel) { this.renderProjectWatch(panel, payload); }
                if ((params.kind === 'project_watch_updated' || params.kind === 'project_watch_stopped') && this.tab === 'Intelligence') { void this.guard(() => this.renderTab()); }
            }
            if (params.kind === 'project_watch_stopped') { for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } } }
            if (params.kind === 'project_watch_updated') { this.setStatus('Project index updated'); }
            else if (params.kind === 'project_watch_error') { this.setStatus('Index update needs attention'); }
            return;
        }
        if (params.kind === 'context_job_completed' || params.kind === 'context_job_failed') {
            this.completedContextJobs.add(payload.job_id); while (this.completedContextJobs.size > 64) { this.completedContextJobs.delete(this.completedContextJobs.values().next().value!); }
            if (this.contextJob === payload.job_id) { this.contextJob = undefined; }
            for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } }
            if (params.kind === 'context_job_completed') { this.contextResult = { action: payload.action, result: payload.result }; this.setStatus('Context operation complete'); }
            else { this.notice.textContent = payload.error; this.notice.hidden = false; this.setStatus('Context operation stopped'); }
            this.updateActions(); if (this.tab === 'Context') { void this.guard(() => this.renderTab()); } return;
        }
        if (params.kind === 'context_recovery') { this.setStatus('Reducing context after model input limit…'); return; }
        if (params.kind === 'hooks_job_completed' || params.kind === 'hooks_job_failed') {
            this.completedHooksJobs.add(payload.job_id); while (this.completedHooksJobs.size > 64) { this.completedHooksJobs.delete(this.completedHooksJobs.values().next().value!); }
            if (this.hooksJob === payload.job_id) { this.hooksJob = undefined; }
            for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } }
            if (params.kind === 'hooks_job_completed') {
                this.hooksResult = { action: payload.action, result: payload.result }; this.setStatus('Hook operation complete');
                if (payload.action === 'source' && this.sessionId) { void this.guard(() => this.bridge.openHookSource(payload.job_id, this.sessionId!)); }
            } else { this.notice.textContent = payload.error; this.notice.hidden = false; this.setStatus('Hook operation stopped'); }
            this.updateActions(); if (this.tab === 'Hooks') { void this.guard(() => this.renderTab()); } return;
        }
        if (params.kind === 'hook_result') { if (this.tab === 'Hooks' && !this.hooksJob && !this.hooksStarting) { void this.guard(() => this.renderTab()); } return; }
        if (params.kind === 'skills_job_completed' || params.kind === 'skills_job_failed') {
            this.completedSkillsJobs.add(payload.job_id); while (this.completedSkillsJobs.size > 64) { this.completedSkillsJobs.delete(this.completedSkillsJobs.values().next().value!); }
            if (this.skillsJob === payload.job_id) { this.skillsJob = undefined; }
            for (const card of Array.from(this.approvals.children)) { if ((card as HTMLElement).dataset.traceId === params.trace_id) { card.remove(); } }
            if (params.kind === 'skills_job_completed') {
                this.skillsResult = { action: payload.action, result: payload.result }; this.setStatus('Skills operation complete');
                if (payload.action === 'source') { void this.guard(() => this.bridge.openSkillSource(payload.job_id, params.session_id)); }
            } else { this.notice.textContent = payload.error; this.notice.hidden = false; this.setStatus('Skills operation stopped'); }
            if (this.tab === 'Skills') { void this.guard(() => this.renderTab()); } return;
        }
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
            const card = el('section', '', 'permission-card'); card.dataset.traceId = params.trace_id; card.dataset.requestId = payload.id; const heading = el('div', '', 'permission-heading'); heading.append(icon('shield'), el('strong', 'Approval needed'));
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
