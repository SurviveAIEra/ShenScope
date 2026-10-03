// Update only authored panel modules after the initial full client transpilation.
import { readFile, writeFile, copyFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const project = resolve(dirname(new URL(import.meta.url).pathname), '..');
const checkout = process.argv[2] ?? '/workspace/references/vscode';
if (execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() !== '7f20cdad4f4ab923272e91e330a7701c52706fc7') { throw new Error('Pinned Code-OSS revision mismatch'); }
const require = createRequire(resolve(project, 'editors/package.json')); const { transform } = require('esbuild');
for (const name of ['panel', 'markdown']) {
    const source = await readFile(resolve(project, `editors/shared/src/${name}.ts`), 'utf8');
    const output = await transform(source, { loader: 'ts', target: 'es2022', format: 'esm', sourcemap: false });
    await writeFile(resolve(checkout, `out/vs/workbench/contrib/shenscope/browser/${name}.js`), output.code);
}
for (const [input, module] of [
    ['ide/overlay/src/vs/platform/shenscope/node/shenscopeChannel.ts', 'vs/platform/shenscope/node/shenscopeChannel'],
    ['editors/shared/src/rpcClient.ts', 'vs/platform/shenscope/common/rpcClient'],
]) {
    const source = await readFile(resolve(project, input), 'utf8');
    const output = await transform(source, { loader: 'ts', target: 'es2022', format: 'esm', sourcemap: false });
    await writeFile(resolve(checkout, `out/${module}.js`), output.code);
}
const contribution = 'vs/workbench/contrib/shenscope/electron-browser/shenscope.contribution';
const contributionSource = await readFile(resolve(project, `ide/overlay/src/${contribution}.ts`), 'utf8');
const ts = require('typescript');
const contributionOutput = ts.transpileModule(contributionSource, { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022, experimentalDecorators: true, useDefineForClassFields: false,
} });
await writeFile(resolve(checkout, `out/${contribution}.js`), contributionOutput.outputText);
await copyFile(resolve(project, 'editors/shared/panel.css'), resolve(checkout, 'out/vs/workbench/contrib/shenscope/electron-browser/shenscope.css'));
console.log('Updated authored panel, channel and CSS modules; no full client rebuild.');
