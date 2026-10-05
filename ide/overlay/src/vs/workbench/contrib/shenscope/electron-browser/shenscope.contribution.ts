import './shenscope.css';
import { localize, localize2 } from '../../../../nls.js';
import { URI } from '../../../../base/common/uri.js';
import { Codicon } from '../../../../base/common/codicons.js';
import { CancellationTokenSource } from '../../../../base/common/cancellation.js';
import { Registry } from '../../../../platform/registry/common/platform.js';
import { SyncDescriptor } from '../../../../platform/instantiation/common/descriptors.js';
import { IInstantiationService } from '../../../../platform/instantiation/common/instantiation.js';
import { IKeybindingService } from '../../../../platform/keybinding/common/keybinding.js';
import { IContextMenuService } from '../../../../platform/contextview/browser/contextView.js';
import { IConfigurationService } from '../../../../platform/configuration/common/configuration.js';
import { IConfigurationRegistry, Extensions as ConfigExtensions } from '../../../../platform/configuration/common/configurationRegistry.js';
import { IContextKeyService } from '../../../../platform/contextkey/common/contextkey.js';
import { IOpenerService } from '../../../../platform/opener/common/opener.js';
import { IThemeService } from '../../../../platform/theme/common/themeService.js';
import { IHoverService } from '../../../../platform/hover/browser/hover.js';
import { ISharedProcessService } from '../../../../platform/ipc/electron-browser/services.js';
import { IWorkspaceContextService } from '../../../../platform/workspace/common/workspace.js';
import { IWorkspaceTrustManagementService } from '../../../../platform/workspace/common/workspaceTrust.js';
import { ISecretStorageService } from '../../../../platform/secrets/common/secrets.js';
import { IQuickInputService } from '../../../../platform/quickinput/common/quickInput.js';
import { IEnvironmentService } from '../../../../platform/environment/common/environment.js';
import { IEditorService } from '../../../services/editor/common/editorService.js';
import { IViewDescriptorService, IViewContainersRegistry, IViewsRegistry, Extensions as ViewExtensions, ViewContainerLocation } from '../../../common/views.js';
import { ViewPane, IViewPaneOptions } from '../../../browser/parts/views/viewPane.js';
import { ViewPaneContainer } from '../../../browser/parts/views/viewPaneContainer.js';
import { ShenScopePanel } from '../browser/panel.js';
import { ITerminalService, ITerminalGroupService } from '../../terminal/browser/terminal.js';
import { ShenScopeTerminalProcess } from './shenscopeTerminal.js';
import { ShenScopeTestingController } from './shenscopeTesting.js';
import { ITestService } from '../../testing/common/testService.js';
import { ITestProfileService } from '../../testing/common/testProfileService.js';
import { ITestResultService } from '../../testing/common/testResultService.js';
import { IViewsService } from '../../../services/views/common/viewsService.js';
import { IMarkerService } from '../../../../platform/markers/common/markers.js';
import { IModelService } from '../../../../editor/common/services/model.js';
import { IFileService } from '../../../../platform/files/common/files.js';
import { ShenScopeProblemsController } from './shenscopeProblems.js';

class ShenScopeViewPane extends ViewPane {
    private panel?: ShenScopePanel;
    private testing?: ShenScopeTestingController;
    private problems?: ShenScopeProblemsController;
    constructor(
        options: IViewPaneOptions,
        @IKeybindingService keybinding: IKeybindingService,
        @IContextMenuService contextMenu: IContextMenuService,
        @IConfigurationService configuration: IConfigurationService,
        @IContextKeyService contextKeys: IContextKeyService,
        @IViewDescriptorService descriptors: IViewDescriptorService,
        @IInstantiationService instantiation: IInstantiationService,
        @IOpenerService opener: IOpenerService,
        @IThemeService theme: IThemeService,
        @IHoverService hover: IHoverService,
        @ISharedProcessService private readonly shared: ISharedProcessService,
        @IWorkspaceContextService private readonly workspace: IWorkspaceContextService,
        @IWorkspaceTrustManagementService private readonly trust: IWorkspaceTrustManagementService,
        @ISecretStorageService private readonly secrets: ISecretStorageService,
        @IQuickInputService private readonly quickInput: IQuickInputService,
        @IEnvironmentService private readonly environment: IEnvironmentService,
        @IEditorService private readonly editors: IEditorService,
        @ITerminalService private readonly terminals: ITerminalService,
        @ITerminalGroupService private readonly terminalGroups: ITerminalGroupService,
        @ITestService private readonly testService: ITestService,
        @ITestProfileService private readonly testProfiles: ITestProfileService,
        @ITestResultService private readonly testResults: ITestResultService,
        @IViewsService private readonly views: IViewsService,
        @IMarkerService private readonly markers: IMarkerService,
        @IModelService private readonly models: IModelService,
        @IFileService private readonly files: IFileService,
    ) { super(options, keybinding, contextMenu, configuration, contextKeys, descriptors, instantiation, opener, theme, hover); }

    protected override renderBody(container: HTMLElement): void {
        super.renderBody(container);
        const channel = this.shared.getChannel('shenscope');
        let hello: any;
        let starting: Promise<any> | undefined;
        const connect = async () => {
            if (starting) { return starting; }
            if (!this.trust.isWorkspaceTrusted()) { throw new Error('Trust this workspace before starting ShenScope'); }
            const root = this.workspace.getWorkspace().folders[0]?.uri;
            if (!root || root.scheme !== 'file') { throw new Error('Open a local workspace folder'); }
            starting = (async () => {
                hello = await channel.call('start', { root: root.fsPath,
                    state: this.configurationService.getValue<string>('shenscope.launcher.statePath') || URI.joinPath(this.environment.userRoamingDataHome, 'shenscope').fsPath,
                    project: this.configurationService.getValue<string>('shenscope.launcher.corePath'),
                    executable: this.configurationService.getValue<string>('shenscope.launcher.juliaPath') });
                const config: any = await channel.call('request', { method: 'config/get', params: {} });
                const variables = new Set<string>([config.value.provider.key_env]);
                for (const provider of Object.values(config.value.model_routing?.providers ?? {}) as any[]) {
                    variables.add(provider.key_env);
                }
                for (const server of Object.values(config.value.mcp?.servers ?? {}) as any[]) {
                    for (const binding of [...(server.environment_env ?? []), ...(server.header_env ?? [])]) { variables.add(binding.env); }
                }
                for (const variable of variables) {
                    const secret = await this.secrets.get(`shenscope:model:${variable}`);
                    if (secret) { await channel.call('request', { method: 'credentials/set', params: { variable, value: secret } }); }
                }
                this.problems?.dispose();
                this.problems = await ShenScopeProblemsController.create(URI.file(hello.root), {
                    request: (method, params) => channel.call('request', {method, params, timeout: 120_000})
                }, this.markers, this.models, this.files);
                this._register(this.problems);
                return hello;
            })();
            try { return await starting; } catch (error) { starting = undefined; throw error; }
        };
        const host = document.createElement('div'); host.style.height = '100%'; container.append(host);
        this.panel = new ShenScopePanel(host, {
            publishProblems: async reference => {
                await connect(); await this.problems!.publish(reference); await this.views.openView('workbench.panel.markers.view', true);
            },
            clearProblems: async () => { this.problems?.clear(); },
            publishTests: async (catalog_id, session_id) => {
                if (this.testing?.busy) { throw new Error('Finish or cancel the native Testing run before publishing another collection.'); }
                await connect(); const catalog: any = await channel.call('request', {method: 'testing/query', params: {session_id, action: 'editor_catalog', catalog_id}, timeout: 120_000});
                this.testing?.dispose();
                this.testing = new ShenScopeTestingController(catalog, {
                    request: (method, params) => channel.call('request', {method, params, timeout: 120_000}), createRequestId: () => globalThis.crypto.randomUUID(),
                    observe: listener => { const disposable = channel.listen<any>('notification')(event => listener(event.method, event.params)); return () => disposable.dispose(); },
                    approve: async (request, signal) => {
                        const cancellation = new CancellationTokenSource(); const cancel = () => cancellation.cancel(); signal.addEventListener('abort', cancel);
                        if (signal.aborted) { cancellation.cancel(); }
                        try {
                            const choice = await this.quickInput.pick([{label: 'Allow once', decision: 'once' as const},
                                {label: 'Allow for this session', decision: 'session' as const}, {label: 'Deny', decision: 'deny' as const}],
                                {title: `ShenScope testing · ${request.category}`, placeHolder: request.reason, ignoreFocusLost: true}, cancellation.token);
                            return choice?.decision ?? 'deny';
                        } finally { signal.removeEventListener('abort', cancel); cancellation.dispose(); }
                    }}, this.testService, this.testProfiles, this.testResults);
                this._register(this.testing); await this.views.openView('workbench.view.testing', true);
            },
            request: async (method, params = {}) => {
                await connect();
                if (['sessions/create', 'sessions/get', 'sessions/branch', 'config/set'].includes(method)) { this.problems?.clear(); }
                return method === 'editor/hello' ? hello : channel.call('request', { method, params });
            },
            onEvent: listener => {
                const subscription = channel.listen<any>('notification')(event => {
                    if (event.method === 'config/changed' || event.method === 'transport/closed') { this.problems?.clear(); }
                    listener(event.method, event.params);
                });
                return () => subscription.dispose();
            },
            setCredential: async variable => {
                if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(variable)) { throw new Error('Invalid credential variable'); }
                const value = await this.quickInput.input({ title: 'ShenScope API key', password: true, prompt: 'Stored securely by the IDE. Leave empty to remove.' });
                if (value === undefined) { return; }
                if (value) { await this.secrets.set(`shenscope:model:${variable}`, value); }
                else { await this.secrets.delete(`shenscope:model:${variable}`); }
                await channel.call('request', { method: 'credentials/set', params: { variable, value } });
            },
            openFile: async (path, line = 1) => {
                const root = this.workspace.getWorkspace().folders[0]?.uri;
                if (!root || path.split(/[\\/]/).includes('..') || /^[/\\]/.test(path)) { throw new Error('Invalid workspace file'); }
                await this.editors.openEditor({ resource: URI.joinPath(root, path), options: { selection: { startLineNumber: line, startColumn: 1 } } });
            },
            openTerminal: async (handle,session_id) => {
                await connect();
                const request = (method: string,params: Record<string,unknown>) => channel.call<any>('request',{method,params});
                await request('terminal/query',{session_id,action:'poll',handle,max_bytes:4,format:'terminal'});
                const cwd=this.workspace.getWorkspace().folders[0]!.uri.fsPath;
                const instance=await this.terminals.createTerminal({config:{name:'ShenScope Core',cwd,
                    customPtyImplementation:(_id,columns,rows)=>new ShenScopeTerminalProcess(request,session_id,handle,cwd,columns,rows)}});
                this.terminals.setActiveInstance(instance);await this.terminalGroups.showPanel(true);
            },
            openSkillSource: async (job_id, session_id) => {
                const source: any = await channel.call('request', { method: 'skills/source_path', params: { job_id, session_id } });
                await this.editors.openEditor({ resource: URI.file(source.path) });
            },
            openHookSource: async (job_id, session_id) => {
                const source: any = await channel.call('request', { method: 'hooks/source_path', params: { job_id, session_id } });
                await this.editors.openEditor({ resource: URI.file(source.path) });
            }
        });
        void this.panel.initialize();
        this._register({ dispose: () => { this.panel?.dispose(); void channel.call('stop'); } });
    }
}

const containerId = 'workbench.view.shenscope';
const viewContainer = Registry.as<IViewContainersRegistry>(ViewExtensions.ViewContainersRegistry).registerViewContainer({
    id: containerId, title: localize2('shenscope', 'ShenScope'), icon: Codicon.code,
    ctorDescriptor: new SyncDescriptor(ViewPaneContainer, [containerId, { mergeViewWithContainerWhenSingleView: true }]),
    storageId: containerId, hideIfEmpty: false, order: 0,
}, ViewContainerLocation.Sidebar);
Registry.as<IViewsRegistry>(ViewExtensions.ViewsRegistry).registerViews([{
    id: 'shenscope.native', name: localize2('shenscope.native', 'ShenScope'),
    ctorDescriptor: new SyncDescriptor(ShenScopeViewPane), canToggleVisibility: true, canMoveView: true,
    containerIcon: Codicon.code, hideByDefault: false,
}], viewContainer);
Registry.as<IConfigurationRegistry>(ConfigExtensions.Configuration).registerConfiguration({
    id: 'shenscope.launcher', title: localize('shenscope.launcher', 'ShenScope launcher'), type: 'object',
    properties: {
        'shenscope.launcher.juliaPath': { type: 'string', default: '', description: 'Julia executable; empty uses the bundled runtime or PATH.' },
        'shenscope.launcher.corePath': { type: 'string', default: '', description: 'Core project; empty uses the bundled source.' },
        'shenscope.launcher.statePath': { type: 'string', default: '', description: 'Core state directory; empty uses the IDE user-data directory.' },
    }
});
Registry.as<IConfigurationRegistry>(ConfigExtensions.Configuration).registerDefaultConfigurations([{
    overrides: { 'chat.disableAIFeatures': true, 'workbench.startupEditor': 'none' }
}]);
