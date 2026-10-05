export interface ProjectTestingState {
    scopes: string;
    argv: string;
    framework: string;
    catalog?: any;
    report?: any;
    source?: any;
    recent?: any;
    caseLimit: number;
    frameLimit: number;
}
export function newProjectTestingState(): ProjectTestingState {
    return {scopes: '.', argv: '', framework: 'raw', caseLimit: 40, frameLimit: 16};
}
export interface ProjectTestingActions {
    button(label: string, action: () => Promise<void>): HTMLButtonElement;
    start(action: string, args?: Record<string, unknown>): Promise<void>;
    cancel(): Promise<void>;
    recent(): Promise<void>;
    showReport(id: string): Promise<void>;
    openSource(source: any): Promise<void>;
    render(): Promise<void>;
}
function node<K extends keyof HTMLElementTagNameMap>(tag: K, text = '', className = ''): HTMLElementTagNameMap[K] {
    const result = document.createElement(tag); result.textContent = text; result.className = className; return result;
}
function commandText(candidate: any): string { return candidate.argv.map((argument: string) => JSON.stringify(argument)).join(' '); }
const outcomeNames: Record<string, string> = {command_succeeded: 'Command completed', command_failed: 'Command failed',
    reported_failure: 'Framework reported failures', timed_out: 'Timed out', permission_revoked: 'Permission revoked', cancelled: 'Cancelled', signalled: 'Stopped by signal'};
const frameworkNames: Record<string, string> = {raw: 'Plain output', unittest: 'Python unittest', pytest: 'Pytest', tap: 'TAP', go_json: 'Go JSON', ctest: 'CTest'};

export function renderProjectTests(container: HTMLElement, state: ProjectTestingState, actions: ProjectTestingActions, busy: boolean, running: boolean): void {
    const button = (label: string, action: () => Promise<void>, primary = false): HTMLButtonElement => {
        const value = actions.button(label, action); value.disabled = busy; if (primary) { value.classList.add('primary-button'); } return value;
    };
    const heading = node('div', '', 'view-heading'); heading.append(node('h2', 'Project tests'));
    if (running) { const stop = actions.button('Stop test operation', actions.cancel); heading.append(stop); }
    container.append(heading, node('p', 'Find this project’s test commands, choose one to run, and inspect its results.', 'view-description'));
    if (running) { container.append(node('p', 'Working… Approvals and cancellation remain available.', 'testing-running')); }
    const discovery = node('section', '', 'info-card testing-discovery'); discovery.append(node('h3', 'Find test commands'));
    const scopeLabel = node('label', 'Project directories · one per line', 'field'); const scopes = node('textarea'); scopes.rows = 2; scopes.value = state.scopes;
    scopes.setAttribute('aria-label', 'Test discovery directories'); scopes.disabled = busy; scopes.addEventListener('input', () => { state.scopes = scopes.value; }); scopeLabel.append(scopes);
    discovery.append(scopeLabel, button('Find test commands', () => actions.start('discover', {scopes: state.scopes.split('\n').map(value => value.trim()).filter(Boolean)}), true),
        node('small', 'Discovery reads project files and does not execute commands.', 'testing-muted')); container.append(discovery);
    if (state.catalog) {
        const candidates = state.catalog.candidates ?? []; const list = node('section', '', 'testing-candidates'); list.setAttribute('aria-label', 'Discovered test commands');
        list.append(node('h3', `${candidates.length} ${candidates.length === 1 ? 'command' : 'commands'} found`));
        if (!candidates.length) { list.append(node('p', 'No candidate found in this scan. You can enter a command below.', 'testing-muted')); }
        for (const candidate of candidates) {
            const card = node('article', '', 'info-card testing-candidate'); const title = node('div', '', 'testing-candidate-heading');
            title.append(node('strong', candidate.label), node('span', candidate.confidence === 'declared' ? 'Declared' : 'Suggested', 'badge'));
            card.append(title, node('small', `${candidate.language} · ${candidate.cwd}`, 'testing-muted'), node('pre', commandText(candidate), 'testing-command'));
            for (const note of candidate.notes ?? []) { card.append(node('small', note, 'testing-muted')); }
            card.append(button(`Run ${candidate.label}`, () => actions.start('run', {catalog_id: state.catalog.catalog_id, candidate_id: candidate.id}), true)); list.append(card);
        }
        const coverage = state.catalog.coverage; const omissions = coverage?.limits_hit ?? [];
        list.append(node('small', `Scan: ${coverage?.files_examined ?? 0} files examined; ${coverage?.pruned_directories ?? 0} directories excluded.${omissions.length ? ` Limits reached: ${omissions.join(', ')}.` : ''} This is a bounded scan, not a complete project inventory.`, 'testing-muted'));
        for (const issue of coverage?.invalid_markers ?? []) { list.append(node('small', `Declaration unavailable: ${issue.path} · ${issue.code}`, 'testing-muted')); }
        container.append(list);
    }
    const custom = node('details', '', 'info-card testing-custom'); custom.append(node('summary', 'Run another test command'));
    const argvLabel = node('label', 'Command arguments · JSON array', 'field'); const argv = node('textarea'); argv.rows = 3; argv.value = state.argv;
    argv.placeholder = '["runner", "argument"]'; argv.setAttribute('aria-label', 'Test command arguments'); argv.disabled = busy; argv.addEventListener('input', () => { state.argv = argv.value; }); argvLabel.append(argv);
    const formatLabel = node('label', 'Output format', 'field'); const format = node('select'); format.setAttribute('aria-label', 'Test output format'); format.disabled = busy;
    for (const [value, name] of Object.entries(frameworkNames)) { const option = node('option', name); option.value = value; format.append(option); }
    format.value = state.framework; format.addEventListener('change', () => { state.framework = format.value; }); formatLabel.append(format);
    custom.append(argvLabel, formatLabel, button('Run selected command', async () => { const command = JSON.parse(state.argv); if (!Array.isArray(command) || !command.length || command.some(value => typeof value !== 'string')) { throw new Error('Enter a nonempty JSON array of command arguments.'); } await actions.start('custom', {argv: command, framework: state.framework}); }, true),
        node('small', 'Commands execute project code and use your process permissions. Choose Plain output when the format is unknown.', 'testing-muted')); container.append(custom);
    if (state.report) { renderReport(container, state, actions, button); }
    if (state.source) {
        const source = node('section', '', 'info-card testing-source'); source.setAttribute('aria-label', 'Current test source preview');
        source.append(node('h3', state.source.path), node('small', 'Current source · not a snapshot from the test run', 'testing-muted'));
        const excerpt = node('pre', '', 'testing-source-lines');
        for (const line of state.source.lines ?? []) { excerpt.append(node('span', `${line.line}  ${line.text}\n`, line.reported ? 'testing-source-focus' : '')); }
        source.append(excerpt, button('Open referenced file', () => actions.openSource(state.source)), button('Close test source preview', async () => { state.source = undefined; await actions.render(); })); container.append(source);
    }
    const history = node('section', '', 'testing-history'); history.append(button('Recent test runs', actions.recent));
    if (state.recent) {
        history.append(node('small', 'Recent controller results are kept in memory and may be retired. They do not survive a Core restart.', 'testing-muted'));
        for (const report of state.recent.reports ?? []) { history.append(button(`${report.label} · ${outcomeNames[report.outcome] ?? report.outcome}`, () => actions.showReport(report.run_id))); }
        if (!state.recent.reports?.length) { history.append(node('p', 'No retained test executions in this conversation.', 'testing-muted')); }
    }
    container.append(history);
}

function renderReport(container: HTMLElement, state: ProjectTestingState, actions: ProjectTestingActions, button: (label: string, action: () => Promise<void>, primary?: boolean) => HTMLButtonElement): void {
    const report = state.report; const parsed = report.parsed; const process = report.process;
    const card = node('section', '', `info-card testing-report testing-outcome-${report.outcome}`); card.setAttribute('aria-label', 'Captured project test result');
    card.append(node('h3', outcomeNames[report.outcome] ?? report.outcome), node('p', report.command.label, 'testing-result-label'),
        node('small', `Exit ${report.exit_code} · ${Number(process.elapsed_seconds).toFixed(2)} s · ${frameworkNames[parsed.framework]}`, 'testing-muted'),
        node('pre', commandText(report.command), 'testing-command'));
    const counts = Object.entries(parsed.observed_case_counts).filter(([, count]) => Number(count) > 0).map(([status, count]) => `${count} ${status.replaceAll('_', ' ')}`);
    card.append(node('p', counts.length ? `Framework reported: ${counts.join(' · ')}` : 'No individual test cases were captured.', 'testing-case-summary'));
    card.append(node('small', 'Command completion does not prove tests were collected or the whole project was tested. Case results are reported by the framework.', 'testing-muted'));
    if (!parsed.interpretation_complete || report.receipt_trimmed_for_transport) { card.append(node('p', 'Output or interpretation is incomplete. Inspect the retained output and limits before relying on the case list.', 'testing-warning')); }
    if (parsed.cases.length) {
        const rank: Record<string, number> = {failed: 0, error: 0, unexpected_success: 0, unknown: 1, skipped: 2, expected_failure: 2, passed: 3};
        const ordered = [...parsed.cases].sort((left, right) => (rank[left.status] ?? 1) - (rank[right.status] ?? 1));
        const cases = node('ul', '', 'testing-cases');
        for (const test of ordered.slice(0, state.caseLimit)) {
            const row = node('li', '', `testing-case testing-case-${test.status}`); row.append(node('span', test.status.replaceAll('_', ' '), 'testing-case-status'), node('strong', test.name));
            if (test.suite) { row.append(node('small', test.suite, 'testing-muted')); } if (test.details) { row.append(node('small', test.details, 'testing-muted')); } cases.append(row);
        }
        card.append(cases);
        if (ordered.length > state.caseLimit) { card.append(button('Show more test cases', async () => { state.caseLimit += 40; await actions.render(); })); }
    }
    if (parsed.frames.length) {
        const references = node('section', '', 'testing-references'); references.append(node('h4', 'Files referenced by the output'));
        references.append(node('small', 'References are reported locations. Preview verifies the current workspace file; it does not tie a file to a specific case.', 'testing-muted'));
        for (const frame of parsed.frames.slice(0, state.frameLimit)) { references.append(button(`Preview ${frame.path}:${frame.line}`, () => actions.start('source', {run_id: report.run_id, frame_id: frame.id}))); }
        if (parsed.frames.length > state.frameLimit) { references.append(button('Show more source references', async () => { state.frameLimit += 16; await actions.render(); })); } card.append(references);
    }
    if (Object.keys(parsed.framework_summary).length) { const summary = node('details', '', 'testing-output'); summary.append(node('summary', 'Framework summary'), node('pre', JSON.stringify(parsed.framework_summary, null, 2))); card.append(summary); }
    for (const stream of ['stdout', 'stderr']) {
        const output = node('details', '', 'testing-output'); output.append(node('summary', `${stream} · ${process[`${stream}_bytes`]} bytes${process[`${stream}_truncated`] ? ' · truncated' : ''}`), node('pre', process[stream] || '(empty)')); card.append(output);
    }
    for (const note of parsed.notes ?? []) { card.append(node('small', note, 'testing-muted')); }
    const identity = node('details', '', 'testing-output'); identity.append(node('summary', 'Execution receipt'), node('code', `${report.run_id}\n${report.sha256}`)); card.append(identity); container.append(card);
}
