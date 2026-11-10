"""The example registry fits the schema's entry shapes and names nothing real.

The registry of a Mac holds account, project and repository names. The file in
`examples/` is public, so it shows one made-up entry per kind and nothing else:
every field has to carry an example marker, and no text may look like an id, an
account, a token or a link to anything but example.com.
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
REMOTE = SCHEMA['$defs']['remoteCheck']

# What each field of a made-up entry has to look like.
MARKERS = {
    'name': r'Example [A-Za-z ]+',
    'service': r'example-[a-z-]+',
    'account': r'example',
    'variable': r'EXAMPLE_[A-Z_]+',
    'path': r'~/\.config/vitals/example-[a-z-]+',
    'reference': r'GitHub Actions secret EXAMPLE_[A-Z_]+ in owner/repo',
    'note': r'Use as EXAMPLE_[A-Z_]+\. .+',
}
UNREAL = {
    'an id': r'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    'an account': r'@',
    'a token': r'[A-Za-z0-9_+/=-]{28,}|\b(sk|pk|rk|ghp|gho|ghs|github_pat|xox[a-z]|AKIA|ASIA|AIza|re)[-_][A-Za-z0-9_-]{6,}|\bAKIA[0-9A-Z]{12,}',
    'a repository': r'\b(?!owner/repo\b)[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9][A-Za-z0-9._-]*\b',
    'a domain': r'(?i)\b(?!example\.com\b)[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}\b',
}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


def problems(entry):
    """Why an entry does not look made-up; empty when it does."""
    found = []
    for field, pattern in MARKERS.items():
        if field in entry and not re.fullmatch(pattern, entry[field]):
            found.append(f'{field} lacks its example marker')
    if 'url' in entry:
        url = urlparse(entry['url'])
        if url.scheme != 'https' or url.hostname != 'example.com':
            found.append('url is not on example.com')
    for check in entry.get('remoteChecks', []):
        if check.get('repository') != 'owner/repo':
            found.append('remote check names a repository')
        if not all(re.fullmatch(r'EXAMPLE_[A-Z_]+', secret) for secret in check.get('secrets', [])):
            found.append('remote check names a secret')
        if check.get('workflow') != 'credential-health.yml':
            found.append('remote check names a workflow')
    if 'localCheck' in entry:
        found.append('local checks point at real credential files')
    # The url and the workflow file name are checked exactly above.
    rest = {name: value for name, value in entry.items() if name not in ('url', 'remoteChecks')}
    rest['remoteChecks'] = [{name: value for name, value in check.items() if name != 'workflow'}
                            for check in entry.get('remoteChecks', [])]
    for text in strings(rest):
        text = text.replace('~/.config/vitals/', '')
        for what, pattern in UNREAL.items():
            if re.search(pattern, text):
                found.append(f'{what} in {text[:40]!r}')
    return found


class ExampleRegistryTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads(EXAMPLE.read_text())
        self.entries = self.document['keys']

    def test_points_at_the_schema(self):
        self.assertTrue((EXAMPLE.parent / self.document['$schema']).is_file())
        self.assertEqual(set(self.document), {'$schema', 'keys'})
        self.assertIsInstance(self.entries, list)

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
                    self.assertIsInstance(entry.get(field), str, f'{field} is missing')
                    self.assertTrue(entry[field], f'{field} is empty')
                self.assertNotIn('verifiedAt', entry, 'a check stamp belongs to one Mac')
                for check in entry.get('remoteChecks', []):
                    self.assertEqual(set(check), set(REMOTE['required']))
                    self.assertRegex(check['repository'], REMOTE['properties']['repository']['pattern'])
                    self.assertTrue(check['secrets'])
                    for field in ('workflow', 'job'):
                        self.assertIsInstance(check[field], str)

    def test_shows_each_kind_once(self):
        self.assertEqual(sorted(entry['kind'] for entry in self.entries),
                         ['environment', 'file', 'keychain', 'reference'])

    def test_names_nothing_real(self):
        for entry in self.entries:
            with self.subTest(entry=entry.get('name')):
                self.assertEqual(problems(entry), [])

    def test_the_check_itself_catches_real_looking_entries(self):
        base = {'name': 'Example API key', 'kind': 'environment', 'variable': 'EXAMPLE_API_KEY',
                'note': 'Use as EXAMPLE_API_KEY. Exported in the zsh rc files.'}
        self.assertEqual(problems(base), [])
        real = [
            {'name': 'Production API key'},
            {'variable': 'STRIPE_API_KEY'},
            {'note': 'Use as EXAMPLE_API_KEY. Value sk-live-4f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c.'},
            {'note': 'Use as EXAMPLE_API_KEY. Created at https://dashboard.stripe.com/apikeys.'},
            {'note': 'Use as EXAMPLE_API_KEY. Key id AKIAIOSFODNN7EXAMPLE.'},
            {'note': 'Use as EXAMPLE_API_KEY. Project 7C1E5A90-3B4D-4F62-8A17-D09E6B2C4F58.'},
            {'note': 'Use as EXAMPLE_API_KEY. Read by acme/billing-service.'},
            {'note': 'Use as EXAMPLE_API_KEY. Account owner@example.com.'},
            {'kind': 'keychain', 'service': 'Claude Code-credentials'},
            {'kind': 'keychain', 'service': 'example-token', 'account': 'jane'},
            {'kind': 'file', 'path': '~/.config/vitals/resend-key'},
            {'kind': 'reference', 'reference': 'GitHub Actions secret RAILWAY_TOKEN in acme/api'},
            {'url': 'https://railway.com/project/1'},
            {'remoteChecks': [{'repository': 'acme/api', 'secrets': ['EXAMPLE_TOKEN'],
                               'workflow': 'credential-health.yml', 'job': 'railway'}]},
            {'remoteChecks': [{'repository': 'owner/repo', 'secrets': ['RAILWAY_TOKEN'],
                               'workflow': 'credential-health.yml', 'job': 'railway'}]},
            {'localCheck': {'provider': 'chrome', 'clientFile': '~/client.json'}},
        ]
        for change in real:
            with self.subTest(change=change):
                self.assertNotEqual(problems({**base, **change}), [])


if __name__ == '__main__':
    unittest.main()
