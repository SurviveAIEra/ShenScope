import './shenscope.css';
import { localize, localize2 } from '../../../../nls.js';
import { URI } from '../../../../base/common/uri.js';
import { Codicon } from '../../../../base/common/codicons.js';
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

class ShenScopeViewPane extends ViewPane {
    private panel?: ShenScopePanel;
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
                    state: URI.joinPath(this.environment.userRoamingDataHome, 'shenscope').fsPath,
                    project: this.configurationService.getValue<string>('shenscope.launcher.corePath'),
                    executable: this.configurationService.getValue<string>('shenscope.launcher.juliaPath') });
                const config: any = await channel.call('request', { method: 'config/get', params: {} });
                const variable = config.value.provider.key_env;
                const secret = await this.secrets.get(`shenscope:model:${variable}`);
                if (secret) { await channel.call('request', { method: 'credentials/set', params: { variable, value: secret } }); }
                return hello;
            })();
            try { return await starting; } catch (error) { starting = undefined; throw error; }
        };
        const host = document.createElement('div'); container.append(host);
        this.panel = new ShenScopePanel(host, {
            request: async (method, params = {}) => {
                await connect();
                return method === 'editor/hello' ? hello : channel.call('request', { method, params });
            },
            onEvent: listener => {
                const subscription = channel.listen<any>('notification')(event => listener(event.method, event.params));
                return () => subscription.dispose();
            },
            setCredential: async variable => {
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
    }
});
Registry.as<IConfigurationRegistry>(ConfigExtensions.Configuration).registerDefaultConfigurations([{
    overrides: { 'chat.disableAIFeatures': true, 'workbench.startupEditor': 'none' }
}]);
