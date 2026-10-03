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
const channel = 'vs/platform/shenscope/node/shenscopeChannel';
const source = await readFile(resolve(project, `ide/overlay/src/${channel}.ts`), 'utf8');
const output = await transform(source, { loader: 'ts', target: 'es2022', format: 'esm', sourcemap: false });
await writeFile(resolve(checkout, `out/${channel}.js`), output.code);
await copyFile(resolve(project, 'editors/shared/panel.css'), resolve(checkout, 'out/vs/workbench/contrib/shenscope/electron-browser/shenscope.css'));
console.log('Updated authored panel, channel and CSS modules; no full client rebuild.');
