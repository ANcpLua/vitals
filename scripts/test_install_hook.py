"""Run the actual installer hook registration in isolated, empty home directories."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class InstallHookTests(unittest.TestCase):
    def register(self, home):
        installer = Path(__file__).resolve().parents[1] / 'install.sh'
        code = installer.read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        subprocess.run(
            [sys.executable, '-', str(home / 'Applications/Vitals.app/Contents/Resources/fable-subagent-gate.sh')],
            input=code, text=True, capture_output=True, check=True,
            env=dict(os.environ, HOME=str(home)),
        )
        return json.loads((home / '.claude/settings.json').read_text())

    def test_empty_home(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            settings = self.register(home)
            self.assertEqual(len(settings['hooks']['PreToolUse']), 1)
            self.assertEqual(settings['hooks']['PreToolUse'][0]['matcher'], 'Agent')
            self.assertEqual(self.register(home), settings)

    def test_preserves_other_settings_and_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / '.claude').mkdir()
            other = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'existing-hook'}]}
            original = {'theme': 'dark', 'hooks': {'PreToolUse': [other], 'Stop': []}}
            (home / '.claude/settings.json').write_text(json.dumps(original))
            settings = self.register(home)
            self.assertEqual(settings['theme'], 'dark')
            self.assertEqual(settings['hooks']['Stop'], [])
            self.assertIn(other, settings['hooks']['PreToolUse'])
            self.assertEqual(len(settings['hooks']['PreToolUse']), 2)
            self.assertEqual(self.register(home), settings)


if __name__ == '__main__':
    unittest.main()
