"""Exercise the actual CLI TUI through a pseudo terminal, including approval."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import sys

root_project = Path(__file__).resolve().parents[2]
plans = '--plans' in sys.argv
testing = '--testing' in sys.argv
with tempfile.TemporaryDirectory(prefix='shenscope-tui-') as directory:
    root = Path(directory)
    script = root / 'script.json'
    if testing:
        (root / 'pyproject.toml').write_text("[project]\nname='calc'\nversion='0.1.0'\n")
        (root / 'test_calc.py').write_text('import unittest\nclass Addition(unittest.TestCase):\n    def test_add(self): self.assertEqual(2+3,5)\n')
        candidate_argv = [str(root_project / 'bin/shenscope'), 'tests', 'discover', '--root', str(root), '--config', str(root / 'config.toml')]
        candidate = json.loads(subprocess.check_output(candidate_argv, cwd=root_project, env=dict(os.environ, JULIA_DEPOT_PATH=os.environ.get('JULIA_DEPOT_PATH','/workspace/julia-depot'))))['candidates'][0]['id']
    script.write_text(json.dumps([
        {'calls': [{'name': 'write', 'arguments': {'path': 'approved.txt', 'content': '中文'}}]},
        {'text': 'TUI completed'},
    ]))
    if plans:
        script.write_text(json.dumps([
            {'calls': [
                {'name': 'plan', 'arguments': {'action': 'replace', 'title': 'Project review', 'expected_revision': 0,
                    'steps': [{'id': 'inspect', 'text': 'Inspect the project', 'status': 'pending', 'dependencies': [], 'note': '', 'citations': []}]}},
                {'name': 'write', 'arguments': {'path': 'forbidden.txt', 'content': 'blocked'}},
            ]},
            {'text': 'Plan prepared'},
            {'calls': [{'name': 'write', 'arguments': {'path': 'approved.txt', 'content': '中文'}}]},
            {'text': 'Act change finished'},
        ]))
    master, slave = pty.openpty()
    environment = dict(os.environ, JULIA_DEPOT_PATH=os.environ.get('JULIA_DEPOT_PATH','/workspace/julia-depot'), TERM='xterm')
    arguments = [str(root_project / 'bin/shenscope'), 'tui', '--root', str(root),
        '--state-dir', str(root / 'state'), '--config', str(root / 'config.toml'), '--script', str(script)]
    if plans:
        arguments += ['--agent-mode', 'plan']
    process = subprocess.Popen(arguments,
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
        if testing:
            os.write(master, b'/tests\r')
            wait_for(b'none executed')
            os.write(master, ('/test ' + candidate + '\r').encode())
            wait_for(b'Approve process')
            os.write(master, b'a')
            wait_for(b'command_succeeded')
            wait_for(b'framework reports')
            os.write(master, b'\x04')
            assert process.wait(timeout=10) == 0
            assert b'\x1b[?1049h' in received
            print('PASS: real TUI test discovery, explicit command selection, responsive process approval, Python unittest result and clean exit')
        elif plans:
            os.write(master, b'/mode\r')
            wait_for(b'Agent mode: plan')
            os.write(master, b'Inspect and plan\r')
            wait_for(b'Approve persistence')
            assert not (root / 'forbidden.txt').exists()
            os.write(master, b's')
            wait_for(b'Plan prepared')
            wait_for(b'Complete')
            assert not (root / 'forbidden.txt').exists()
            os.write(master, b'/plan\r')
            wait_for(b'reported progress')
            os.write(master, b'/mode act\r')
            wait_for(b'Agent mode: act')
            os.write(master, b'Apply the approved change\r')
        else:
            os.write(master, '创建文件\r'.encode())
        if not testing:
            wait_for(b'Approve edit')
            assert not (root / 'approved.txt').exists()
            os.write(master, b'a')
            wait_for(b'Act change finished' if plans else b'Complete')
            assert (root / 'approved.txt').read_text() == '中文'
            os.write(master, b'\x04')
            assert process.wait(timeout=10) == 0
            assert b'\x1b[?1049h' in received
            print('PASS: real TUI Plan/Act control, responsive persistence approval, saved plan, blocked mutation, approved Unicode Act edit and clean exit' if plans else 'PASS: real TUI task, scoped approval, Unicode edit, clean exit')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        os.close(master)
