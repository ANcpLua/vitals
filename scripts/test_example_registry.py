"""The example registry fits the schema's entry shapes and names nothing real.

The registry of a Mac holds account, project and repository names. The file in
`examples/` is public, so it shows one made-up entry per kind and nothing else.
"""
import json
from pathlib import Path
import re
import unittest
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / 'examples/keys.example.json'
SCHEMA = json.loads((ROOT / 'schema/keys.schema.json').read_text())
ENTRY = SCHEMA['$defs']['entry']


class ExampleRegistryTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads(EXAMPLE.read_text())
        self.entries = self.document['keys']

    def test_points_at_the_schema(self):
        self.assertTrue((EXAMPLE.parent / self.document['$schema']).is_file())
        self.assertEqual(set(self.document), {'$schema', 'keys'})

    def test_entries_use_only_schema_fields_and_what_their_kind_requires(self):
        required_by_kind = {}
        for rule in ENTRY['allOf']:
            kinds = rule['if']['properties']['kind']
            for kind in kinds.get('enum', [kinds.get('const')]):
                required_by_kind[kind] = rule['then']['required']
        for entry in self.entries:
            with self.subTest(entry=entry.get('name')):
                self.assertLessEqual(set(entry), set(ENTRY['properties']))
                self.assertIn(entry['kind'], ENTRY['properties']['kind']['enum'])
                for field in ENTRY['required'] + required_by_kind[entry['kind']]:
                    self.assertTrue(entry.get(field), f'{field} is missing')
                self.assertNotIn('verifiedAt', entry, 'a check stamp belongs to one Mac')
                for check in entry.get('remoteChecks', []):
                    self.assertEqual(set(check), set(SCHEMA['$defs']['remoteCheck']['required']))

    def test_shows_each_kind_once(self):
        self.assertEqual(sorted(entry['kind'] for entry in self.entries),
                         ['environment', 'file', 'keychain', 'reference'])

    def test_names_nothing_real(self):
        for entry in self.entries:
            with self.subTest(entry=entry['name']):
                self.assertTrue(entry['name'].startswith('Example '))
                if 'url' in entry:
                    self.assertEqual(urlparse(entry['url']).hostname, 'example.com')
                for check in entry.get('remoteChecks', []):
                    self.assertEqual(check['repository'], 'owner/repo')
                text = json.dumps(entry)
                self.assertIsNone(re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', text),
                                  'looks like a resource id')
                self.assertNotIn('@', text, 'looks like an account')


if __name__ == '__main__':
    unittest.main()
