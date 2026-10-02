"""Run the registry and template sync in isolated home directories."""
import json
from pathlib import Path
import tempfile
import unittest

from registry_template import sync

ENTRY = {'kind': 'file', 'name': 'Example', 'path': '~/.config/vitals/example-key'}


class RegistryTemplateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name) / 'home'
        self.registry = self.home / '.config/vitals/keys.json'
        self.template = Path(self.directory.name) / 'keys.template.json'
        self.template.write_text(json.dumps({'$schema': '../schema/keys.schema.json', 'keys': [ENTRY]}))

    def tearDown(self):
        self.directory.cleanup()

    def test_absent_registry_is_created_from_the_template(self):
        self.assertIn('created', sync(self.home, self.template))
        self.assertEqual(json.loads(self.registry.read_text()), {'keys': [ENTRY]})
        self.assertEqual(self.registry.stat().st_mode & 0o777, 0o600)

    def test_registry_is_written_back_portable(self):
        self.registry.parent.mkdir(parents=True)
        local = {'kind': 'file', 'name': 'Local', 'path': f'{self.home}/.config/vitals/local-key',
                 'note': f'Read {self.home}/notes.', 'verifiedAt': '2026-10-02T06:00:10Z'}
        self.registry.write_text(json.dumps({'keys': [ENTRY, local]}))
        self.assertIn('1 to 2 entries', sync(self.home, self.template))
        written = json.loads(self.template.read_text())
        self.assertEqual(written['keys'][1], {'kind': 'file', 'name': 'Local',
                                              'path': '~/.config/vitals/local-key', 'note': 'Read ~/notes.'})
        self.assertIn('matches', sync(self.home, self.template))

    def test_damaged_or_recoverable_registry_changes_nothing(self):
        before = self.template.read_text()
        self.registry.parent.mkdir(parents=True)
        (self.registry.parent / 'keys.last-good.json').write_text('{"keys": []}')
        self.assertIn('restore', sync(self.home, self.template))
        self.assertFalse(self.registry.exists())
        self.registry.write_text('{not json')
        self.assertIn('restore', sync(self.home, self.template))
        self.assertEqual(self.registry.read_text(), '{not json')
        self.assertEqual(self.template.read_text(), before)


if __name__ == '__main__':
    unittest.main()
