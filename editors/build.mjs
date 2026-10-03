import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
await mkdir('vscode/dist', { recursive: true });
await build({ entryPoints: ['vscode/src/extension.ts'], outfile: 'vscode/dist/extension.js', bundle: true, platform: 'node', format: 'cjs', target: 'node20', external: ['vscode'], sourcemap: false });
await build({ entryPoints: ['vscode/src/webview.ts'], outfile: 'vscode/dist/panel.js', bundle: true, platform: 'browser', format: 'iife', target: 'es2022', sourcemap: false });
await build({ entryPoints: ['shared/src/rpcClient.ts'], outfile: 'dist/rpcClient.mjs', bundle: true, platform: 'node', format: 'esm', target: 'node20' });
await copyFile('shared/panel.css', 'vscode/dist/panel.css');
