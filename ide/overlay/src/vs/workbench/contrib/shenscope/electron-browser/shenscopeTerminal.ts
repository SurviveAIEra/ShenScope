import { Emitter } from '../../../../base/common/event.js';
import { Disposable } from '../../../../base/common/lifecycle.js';
import { IProcessDataEvent, IProcessProperty, IProcessPropertyMap, IProcessReadyEvent, ITerminalChildProcess, ProcessPropertyType } from '../../../../platform/terminal/common/terminal.js';
import { CoreTerminalConnection, TerminalRequest } from '../browser/terminalClient.js';

export class ShenScopeTerminalProcess extends Disposable implements ITerminalChildProcess {
    readonly id = 0;
    readonly shouldPersist = false;
    private readonly data = this._register(new Emitter<IProcessDataEvent | string>());
    readonly onProcessData = this.data.event;
    private readonly ready = this._register(new Emitter<IProcessReadyEvent>());
    readonly onProcessReady = this.ready.event;
    private readonly property = this._register(new Emitter<IProcessProperty>());
    readonly onDidChangeProperty = this.property.event;
    private readonly ended = this._register(new Emitter<number | undefined>());
    readonly onProcessExit = this.ended.event;
    private readonly connection: CoreTerminalConnection;
    constructor(request: TerminalRequest, session: string, handle: string, private readonly cwd: string,
        private readonly columns: number, private readonly rows: number) {
        super();
        this.connection = new CoreTerminalConnection(request,session,handle,text=>this.data.fire(text),
            code=>this.ended.fire(code),message=>this.data.fire(`\r\n[ShenScope: ${message.replace(/[\x00-\x1f\x7f]/g,' ')}]\r\n`));
    }
    async start(): Promise<undefined> {
        this.ready.fire({pid:0,cwd:this.cwd,windowsPty:undefined});
        await this.connection.open(); this.connection.resize(this.columns,this.rows); return undefined;
    }
    shutdown(_immediate: boolean): void { this.connection.dispose(); }
    input(data: string): void { this.connection.input(data); }
    sendSignal(signal: string): void { if(signal==='SIGINT'){this.connection.interrupt();} }
    async processBinary(_data: string): Promise<void> { throw new Error('Binary terminal input is unsupported; use UTF-8 input.'); }
    resize(columns: number,rows: number): void { this.connection.resize(columns,rows); }
    clearBuffer(): void { this.data.fire('\x1b[2J\x1b[H'); }
    acknowledgeDataEvent(_count: number): void {}
    async setUnicodeVersion(_version: '6' | '11'): Promise<void> {}
    async getInitialCwd(): Promise<string> { return this.cwd; }
    async getCwd(): Promise<string> { return this.cwd; }
    async refreshProperty<T extends ProcessPropertyType>(type: T): Promise<IProcessPropertyMap[T]> {
        let value: unknown;
        if(type===ProcessPropertyType.Cwd || type===ProcessPropertyType.InitialCwd){value=this.cwd;}
        else if(type===ProcessPropertyType.Title){value='ShenScope Core';}
        else if(type===ProcessPropertyType.HasChildProcesses){value=true;}
        else { throw new Error('This Core terminal property is unsupported.'); }
        return value as IProcessPropertyMap[T];
    }
    async updateProperty<T extends ProcessPropertyType>(_type: T,_value: IProcessPropertyMap[T]): Promise<void> {
        throw new Error('Core terminal properties are read-only.');
    }
    override dispose(): void { this.connection.dispose();super.dispose(); }
}
