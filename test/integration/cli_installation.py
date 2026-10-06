"""Verify command installation, portable launch behavior and actual Core use."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
INSTALLER = REPOSITORY / 'scripts/install_cli.sh'


class CLIInstallation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shenscope cli ')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin = self.directory / 'commands with spaces'
        self.project = self.directory / 'user project'
        self.project.mkdir()
        self.environment = dict(os.environ)
        self.environment['PATH'] = str(self.bin) + os.pathsep + os.environ['PATH']

    def install(self):
        return subprocess.run(['bash', str(INSTALLER), '--bin-dir', str(self.bin)],
                              cwd=self.project, env=self.environment,
                              capture_output=True, text=True, timeout=10)

    def command(self, *arguments, check=True):
        return subprocess.run(['shenscope', *arguments], cwd=self.project,
                              env=self.environment, capture_output=True,
                              text=True, timeout=120, check=check)

    def test_reinstallation_preserves_the_link(self):
        self.assertEqual(self.install().returncode, 0)
        target = self.bin / 'shenscope'
        self.assertTrue(target.is_symlink())
        self.assertEqual(target.resolve(), REPOSITORY / 'bin/shenscope')
        inode = target.lstat().st_ino
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(target.lstat().st_ino, inode)
        self.assertEqual(len(list(self.bin.iterdir())), 1)

    def test_existing_commands_are_not_overwritten(self):
        self.bin.mkdir()
        target = self.bin / 'shenscope'
        target.write_text('existing user command\n')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(target.read_text(), 'existing user command\n')
        target.unlink()
        target.symlink_to(self.directory / 'missing foreign command')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(os.readlink(target), str(self.directory / 'missing foreign command'))

    def test_launcher_respects_julia_choice_environment_and_arguments(self):
        self.assertEqual(self.install().returncode, 0)
        recorder = self.directory / 'Julia executable with spaces'
        recorder.write_text('''#!/usr/bin/env python3
import json, os, sys
print(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd(),
                  'depot': os.environ.get('JULIA_DEPOT_PATH')}))
sys.exit(int(os.environ.get('CLI_FIXTURE_EXIT', '0')))
''')
        recorder.chmod(0o755)
        self.environment['SHENSCOPE_JULIA'] = str(recorder)
        self.environment['JULIA_DEPOT_PATH'] = str(self.directory / 'custom depot')
        arguments = ('chat', '中文 with "quotes" $literal', '--root', str(self.project))
        recording = json.loads(self.command(*arguments).stdout)
        self.assertEqual(recording['argv'][-len(arguments):], list(arguments))
        self.assertIn('--project=' + str(REPOSITORY), recording['argv'])
        self.assertEqual(recording['cwd'], str(self.project))
        self.assertEqual(recording['depot'], self.environment['JULIA_DEPOT_PATH'])
        self.environment['CLI_FIXTURE_EXIT'] = '37'
        self.assertEqual(self.command('--version', check=False).returncode, 37)
        self.environment.pop('CLI_FIXTURE_EXIT')
        self.environment['SHENSCOPE_JULIA'] = str(self.directory / 'missing Julia')
        missing = self.command('--version', check=False)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('SHENSCOPE_JULIA', missing.stderr)
        # A normal Julia on PATH must keep its ordinary depot, even in the cloud.
        (self.bin / 'julia').symlink_to(recorder)
        self.environment.pop('SHENSCOPE_JULIA')
        self.environment.pop('JULIA_DEPOT_PATH')
        self.assertIsNone(json.loads(self.command('--version').stdout)['depot'])
        self.environment['SHENSCOPE_JULIA'] = 'julia'
        self.assertIsNone(json.loads(self.command('--version').stdout)['depot'])
        # Follow a relative link to the installed link without changing cwd.
        linked = self.bin / 'linked-shenscope'
        linked.symlink_to('shenscope')
        chained = subprocess.run([str(linked), '--version'], cwd=self.project,
                                 env=self.environment, capture_output=True,
                                 text=True, check=True, timeout=10)
        self.assertIn('--project=' + str(REPOSITORY), json.loads(chained.stdout)['argv'])

    def test_installed_command_runs_real_core_in_another_project(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertTrue(self.command('--version').stdout.startswith('ShenScope '))
        self.assertIn('Usage: shenscope', self.command('--help').stdout)
        config = self.project / 'configuration with spaces.toml'
        config.write_text('[provider]\nprotocol="openai_chat"\nname="installation-test"\n'
                          'endpoint="http://127.0.0.1:1"\nmodel="offline-fixture"\n'
                          'key_env="SHENSCOPE_INSTALL_TEST_KEY"\n')
        state = self.directory / 'test state'
        options = ('--root', str(self.project), '--config', str(config), '--state-dir', str(state))
        doctor = json.loads(self.command('doctor', *options).stdout)
        self.assertEqual(doctor['config_path'], str(config))
        self.assertEqual(doctor['state_dir'], str(state))
        self.assertEqual(doctor['model'], 'offline-fixture')
        script = self.project / 'offline script.json'
        script.write_text(json.dumps([
            {'calls': [{'name': 'write', 'arguments': {'path': 'approved.txt', 'content': '正确的项目'}}]},
            {'text': 'Offline installation verified'},
        ]))
        self.command('chat', '写入当前项目', *options, '--script', str(script), '--allow-edit')
        self.assertEqual((self.project / 'approved.txt').read_text(), '正确的项目')


if __name__ == '__main__':
    unittest.main(verbosity=2)
