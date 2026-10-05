import { Disposable, DisposableStore } from '../../../../base/common/lifecycle.js';
import { URI } from '../../../../base/common/uri.js';
import { IMarkerService, MarkerSeverity } from '../../../../platform/markers/common/markers.js';
import { IFileService } from '../../../../platform/files/common/files.js';
import { IModelService } from '../../../../editor/common/services/model.js';
import { ITextModel } from '../../../../editor/common/model.js';
import { CoreProblemsPublisher, problemRelativePath, problemSourceHash, type ProblemsReference,
    type ProblemsTransport, type ProblemFile } from '../browser/nativeProblemsClient.js';

export class ShenScopeProblemsController extends Disposable {
    private readonly owner = 'shenscope.core.problems';
    private readonly published = new Map<string, URI>();
    private readonly reading = new Map<string, URI>();
    private readonly listeners = new Map<string, DisposableStore>();
    private constructor(private readonly root: URI, private readonly publisher: CoreProblemsPublisher,
        private readonly markers: IMarkerService, models: IModelService, files: IFileService) {
        super();
        const observe = (model: ITextModel) => {
            const store = new DisposableStore(); this.listeners.get(model.uri.toString())?.dispose();
            this.listeners.set(model.uri.toString(), store);
            store.add(model.onDidChangeContent(() => this.changed(model.uri)));
        };
        for (const model of models.getModels()) { observe(model); }
        this._register(models.onModelAdded(model => { this.changed(model.uri); observe(model); }));
        this._register(models.onModelRemoved(model => {
            this.changed(model.uri); this.listeners.get(model.uri.toString())?.dispose(); this.listeners.delete(model.uri.toString());
        }));
        this._register(files.onDidFilesChange(event => {
            for (const uri of [...this.published.values(), ...this.reading.values()]) { if (event.contains(uri)) { this.changed(uri); } }
        }));
    }
    static async create(root: URI, transport: ProblemsTransport, markers: IMarkerService,
        models: IModelService, files: IFileService): Promise<ShenScopeProblemsController> {
        let controller: ShenScopeProblemsController;
        const publisher = new CoreProblemsPublisher(transport, {
            readSource: async path => {
                const uri = URI.joinPath(root, problemRelativePath(path)); const model = models.getModel(uri);
                controller.reading.set(path, uri);
                if (model) { return model.getValue(undefined, true); }
                const stat = await files.resolve(uri);
                if (stat.isSymbolicLink || stat.isDirectory || stat.size !== undefined && stat.size > 8 * 1024 * 1024) {
                    throw new Error('Diagnostic source is unavailable.');
                }
                return (await files.readFile(uri, {limits: {size: 8 * 1024 * 1024}})).value.toString();
            }, replace: values => controller.replace(values), remove: path => controller.remove(path)
        }, await problemSourceHash(root.fsPath));
        controller = new ShenScopeProblemsController(root, publisher, markers, models, files); return controller;
    }
    private changed(uri: URI): void {
        if (uri.scheme === this.root.scheme && uri.path.startsWith(this.root.path + '/')) {
            this.publisher.invalidate(uri.path.slice(this.root.path.length + 1));
        }
    }
    private remove(path?: string): void {
        if (path === undefined) { this.reading.clear(); } else { this.reading.delete(path); }
        const paths = path === undefined ? [...this.published.keys()] : [path];
        for (const key of paths) {
            const uri = this.published.get(key); if (uri) { this.markers.remove(this.owner, [uri]); this.published.delete(key); }
        }
    }
    private replace(files: ProblemFile[]): void {
        this.remove();
        const severity = {error: MarkerSeverity.Error, warning: MarkerSeverity.Warning,
            information: MarkerSeverity.Info, hint: MarkerSeverity.Hint};
        for (const file of files) {
            const resource = URI.joinPath(this.root, file.path); this.published.set(file.path, resource);
            this.markers.changeOne(this.owner, resource, file.markers.map(marker => ({severity: severity[marker.severity],
                message: marker.message, source: `ShenScope · ${marker.source}`, code: marker.code === null ? undefined : String(marker.code),
                startLineNumber: marker.range.start.line + 1, startColumn: marker.range.start.character + 1,
                endLineNumber: marker.range.end.line + 1, endColumn: marker.range.end.character + 1})));
        }
    }
    async publish(reference: ProblemsReference): Promise<void> { await this.publisher.publish(reference); }
    clear(): void { this.publisher.invalidate(); }
    override dispose(): void {
        this.publisher.dispose(); for (const listener of this.listeners.values()) { listener.dispose(); } this.listeners.clear(); super.dispose();
    }
}
