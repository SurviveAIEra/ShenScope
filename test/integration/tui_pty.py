"""Exercise the actual CLI TUI through a pseudo terminal, including approval."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time

root_project = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='shenscope-tui-') as directory:
    root = Path(directory)
    script = root / 'script.json'
    script.write_text(json.dumps([
        {'calls': [{'name': 'write', 'arguments': {'path': 'approved.txt', 'content': '中文'}}]},
        {'text': 'TUI completed'},
    ]))
    master, slave = pty.openpty()
    environment = dict(os.environ, JULIA_DEPOT_PATH=os.environ.get('JULIA_DEPOT_PATH','/workspace/julia-depot'), TERM='xterm')
    process = subprocess.Popen([str(root_project / 'bin/shenscope'), 'tui', '--root', str(root),
        '--state-dir', str(root / 'state'), '--config', str(root / 'config.toml'), '--script', str(script)],
        stdin=slave, stdout=slave, stderr=slave, env=environment, cwd=root_project, close_fds=True)
    os.close(slave)
    received = bytearray()
    def wait_for(fragment, timeout=120):
        deadline = time.monotonic() + timeout
        while fragment not in received:
            if time.monotonic() > deadline:
                raise AssertionError(f'TUI did not show {fragment!r}: {bytes(received[-3000:])!r}')
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b''
                if not data:
                    raise AssertionError(f'TUI exited prematurely: {bytes(received[-3000:])!r}')
                received.extend(data)
                if len(received) > 2 * 1024 * 1024:
                    raise AssertionError('TUI output exceeded test cap')
    try:
        wait_for(b'Ready')
        os.write(master, '创建文件\r'.encode())
        wait_for(b'Approve edit')
        assert not (root / 'approved.txt').exists()
        os.write(master, b'a')
        wait_for(b'Complete')
        assert (root / 'approved.txt').read_text() == '中文'
        os.write(master, b'\x04')
        assert process.wait(timeout=10) == 0
        assert b'\x1b[?1049h' in received
        print('PASS: real TUI task, scoped approval, Unicode edit, clean exit')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        os.close(master)
