#!/usr/bin/env python3
"""Install only authored overlay files into the single pinned Code-OSS checkout."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

PIN = '7f20cdad4f4ab923272e91e330a7701c52706fc7'
REPO = Path(__file__).resolve().parents[1]

def install(checkout):
    checkout = checkout.resolve()
    observed = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if observed != PIN:
        raise SystemExit(f'Expected Code-OSS {PIN}, found {observed}')
    overlay = REPO / 'ide' / 'overlay'
    paths = list(overlay.rglob('*.ts'))
    for source in paths:
        destination = checkout / source.relative_to(overlay)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    shared = {
        'editors/shared/src/rpcClient.ts': 'src/vs/platform/shenscope/common/rpcClient.ts',
        'editors/shared/src/rpcMethods.ts': 'src/vs/platform/shenscope/common/rpcMethods.ts',
        'editors/shared/src/panel.ts': 'src/vs/workbench/contrib/shenscope/browser/panel.ts',
        'editors/shared/src/markdown.ts': 'src/vs/workbench/contrib/shenscope/browser/markdown.ts',
        'editors/shared/src/terminalClient.ts': 'src/vs/workbench/contrib/shenscope/browser/terminalClient.ts',
        'editors/shared/src/projectTests.ts': 'src/vs/workbench/contrib/shenscope/browser/projectTests.ts',
        'editors/shared/src/nativeTestingClient.ts': 'src/vs/workbench/contrib/shenscope/browser/nativeTestingClient.ts',
        'editors/shared/panel.css': 'src/vs/workbench/contrib/shenscope/electron-browser/shenscope.css',
    }
    for source, relative in shared.items():
        destination = checkout / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / source, destination)
    desktop = checkout / 'src/vs/workbench/workbench.desktop.main.ts'
    contribution = "import './contrib/shenscope/electron-browser/shenscope.contribution.js';"
    content = desktop.read_text()
    if contribution not in content:
        desktop.write_text(content + '\n' + contribution + '\n')
    shared_main = checkout / 'src/vs/code/electron-utility/sharedProcess/sharedProcessMain.ts'
    content = shared_main.read_text()
    channel_import = "import { ShenScopeChannel } from '../../../platform/shenscope/node/shenscopeChannel.js';"
    channel_registration = "\t\tthis.server.registerChannel('shenscope', this._register(new ShenScopeChannel()));"
    if channel_import not in content:
        content = channel_import + '\n' + content
    if channel_registration not in content:
        anchor = '\tprivate initChannels(accessor: ServicesAccessor): void {'
        if content.count(anchor) != 1:
            raise SystemExit('Pinned shared-process registration anchor changed')
        content = content.replace(anchor, anchor + '\n' + channel_registration)
    shared_main.write_text(content)
    product_path = checkout / 'product.json'
    product = json.loads(product_path.read_text())
    product.update(nameShort='ShenScope', nameLong='ShenScope IDE', applicationName='shenscope-ide',
                   dataFolderName='.shenscope-ide', urlProtocol='shenscope',
                   win32AppUserModelId='SurviveAIEra.ShenScope', licenseName='MIT (Code-OSS); Apache-2.0 (ShenScope)',
                   extensionsGallery={'serviceUrl': 'https://open-vsx.org/vscode/gallery', 'itemUrl': 'https://open-vsx.org/vscode/item', 'resourceUrlTemplate': 'https://open-vsx.org/vscode/unpkg/{publisher}/{name}/{version}/{path}'})
    product_path.write_text(json.dumps(product, indent=2) + '\n')
    print('Installed minimal native overlay; no checkout duplication.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('checkout', type=Path, nargs='?', default=Path('/workspace/references/vscode'))
    install(parser.parse_args().checkout)
