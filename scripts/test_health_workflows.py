"""The workflow generator reads the jobs from the registry's remote checks."""
import sys
sys.dont_write_bytecode = True
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / 'examples/keys.example.json'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


g = module('generator', 'scripts/install_health_workflows.py')
h = module('health', 'Sources/VitalsKernel/credential_health.py')
SHA = 'a' * 40
# The ids a job carries as variables when a test does not say otherwise.
VARIABLES = {'railway': {'RAILWAY_PROJECT_ID': 'project', 'RAILWAY_ENVIRONMENT_ID': 'environment'},
             'edge': {'EDGE_OPERATION_ID': 'op-1'}}


def check(repository='owner/repo', job='railway', secrets=None, variables=None, **extra):
    """A remote check. Secrets that are not given are whatever the probe needs beyond the variables."""
    variables = VARIABLES.get(job, {}) if variables is None else variables
    if secrets is None:
        secrets = [name for name in g.NEEDS.get(job, ()) if name not in variables]
    made = {'repository': repository, 'job': job, 'secrets': list(secrets), 'workflow': g.WORKFLOW}
    if variables:
        made['variables'] = dict(variables)
    return dict(made, **extra)


class HealthWorkflowTests(unittest.TestCase):
    def load(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'keys.json'
            path.write_text(data if isinstance(data, str) else json.dumps(data))
            return g.load_jobs(path)

    def registry(self, *entries):
        return {'keys': [{'name': f'entry {index}', 'kind': 'reference', 'reference': 'r', 'remoteChecks': list(checks)}
                         for index, checks in enumerate(entries)]}

    def test_the_example_registry_yields_its_one_job(self):
        jobs = g.load_jobs(EXAMPLE)
        self.assertEqual(list(jobs), ['owner/repo'])
        self.assertEqual([job['job'] for job in jobs['owner/repo']], ['railway'])
        self.assertEqual(list(jobs['owner/repo'][0]['variables']), ['RAILWAY_ENVIRONMENT_ID', 'RAILWAY_PROJECT_ID'])

    def test_the_script_names_no_repository_or_id_of_its_own(self):
        source = (ROOT / 'scripts/install_health_workflows.py').read_text()
        self.assertIsNone(re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', source, re.I))
        self.assertEqual(set(re.findall(r"'([A-Za-z0-9-]+/[A-Za-z0-9._-]+)'", source)), {g.VITALS})

    def test_entries_that_share_a_repository_and_job_become_one_job(self):
        jobs = self.load(self.registry(
            [check('owner/extension', 'edge')],
            [check('owner/extension', 'chrome', ['CWS_CLIENT_ID', 'CWS_CLIENT_SECRET'])],
            [check('owner/extension', 'chrome', ['CWS_CLIENT_ID', 'CWS_REFRESH_TOKEN', 'CWS_REFRESH_TOKEN']),
             check('owner/service', secrets=['RAILWAY_TOKEN'], variables={'RAILWAY_PROJECT_ID': 'project'})],
            [check('owner/service', secrets=['RAILWAY_TOKEN'], variables=VARIABLES['railway'])],
            [check('owner/extension', 'amo', ['not a name'], workflow='release.yml')],
        ))
        self.assertEqual(sorted(jobs), ['owner/extension', 'owner/service'])
        extension = jobs['owner/extension']
        self.assertEqual([job['job'] for job in extension], ['chrome', 'edge'], 'provider order, and another workflow is not ours')
        self.assertEqual(extension[0]['secrets'], ['CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN'])
        self.assertEqual(extension[1]['variables'], {'EDGE_OPERATION_ID': 'op-1'})
        self.assertEqual(jobs['owner/service'], [{'job': 'railway', 'secrets': ['RAILWAY_TOKEN'], 'variables': {
            'RAILWAY_ENVIRONMENT_ID': 'environment', 'RAILWAY_PROJECT_ID': 'project'}}])

    def test_two_spellings_of_a_repository_are_one_repository(self):
        jobs = self.load(self.registry([check('Owner/Extension', 'chrome')], [check('owner/extension', 'amo')]))
        self.assertEqual(list(jobs), ['Owner/Extension'])
        self.assertEqual([job['job'] for job in jobs['Owner/Extension']], ['chrome', 'amo'])

    def test_order_in_the_registry_does_not_change_the_workflow(self):
        one = self.load(self.registry([check(variables={'RAILWAY_PROJECT_ID': 'p', 'RAILWAY_ENVIRONMENT_ID': 'e'})]))
        other = self.load(self.registry([check(variables={'RAILWAY_ENVIRONMENT_ID': 'e', 'RAILWAY_PROJECT_ID': 'p'})]))
        self.assertEqual(list(one['owner/repo'][0]['variables']), ['RAILWAY_ENVIRONMENT_ID', 'RAILWAY_PROJECT_ID'])
        self.assertEqual(g.workflow(one['owner/repo'], SHA), g.workflow(other['owner/repo'], SHA))
        # Entries in another order, and secrets in another order inside an entry.
        first = [check('owner/extension', 'chrome', ['CWS_CLIENT_SECRET', 'CWS_CLIENT_ID'])]
        second = [check('owner/extension', 'chrome', ['CWS_REFRESH_TOKEN', 'CWS_PUBLISHER_ID'])]
        forward, backward = self.load(self.registry(first, second)), self.load(self.registry(second, first))
        self.assertEqual(forward['owner/extension'][0]['secrets'], ['CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_PUBLISHER_ID', 'CWS_REFRESH_TOKEN'])
        self.assertEqual(g.workflow(forward['owner/extension'], SHA), g.workflow(backward['owner/extension'], SHA))

    def test_a_job_that_lacks_what_its_probe_needs_is_refused(self):
        for made, reason in [
            (check(job='edge', secrets=['EDGE_API_KEY', 'EDGE_CLIENT_ID'], variables={}), 'owner/repo edge: the probe needs EDGE_OPERATION_ID,'),
            (check(secrets=['RAILWAY_TOKEN'], variables={}), 'the probe needs RAILWAY_PROJECT_ID, RAILWAY_ENVIRONMENT_ID,'),
            (check(job='chrome', secrets=['CWS_CLIENT_ID']), 'the probe needs CWS_CLIENT_SECRET, CWS_REFRESH_TOKEN,'),
        ]:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason):
                    self.load(self.registry([made]))
        # The ids may be repository secrets instead of variables.
        as_secrets = self.load(self.registry([check(variables={})]))['owner/repo'][0]
        self.assertEqual(as_secrets, {'job': 'railway', 'secrets': sorted(g.NEEDS['railway']), 'variables': {}})

    def test_needs_is_what_each_probe_requires_before_it_asks_the_provider(self):
        # What the workflow adds itself: the repository for the GitHub probe, and the
        # store id that --config reads from the monitored repository.
        added = {'github': {'CHECK_REPOSITORY': 'owner/repo'}, 'edge': {'EDGE_PRODUCT_ID': 'product'}}
        self.assertEqual({name for names in added.values() for name in names} | {'CWS_ITEM_ID'}, set(g.FILLED_IN))
        for provider, names in g.NEEDS.items():
            full = dict({name: 'value' for name in names}, **added.get(provider, {}))
            with patch.object(h, 'request', side_effect=h.ProbeError('unavailable')) as request:
                self.assertEqual(h.probe(provider, full)['state'], 'unavailable', provider)
                self.assertEqual(request.call_count, 1, f'{provider}: with everything given, the probe asks the provider')
            for name in names:
                with self.subTest(provider=provider, without=name), patch.object(h, 'request') as request:
                    state = h.probe(provider, {key: value for key, value in full.items() if key != name})['state']
                    self.assertIn(state, ('missing', 'unchecked'))
                    request.assert_not_called()

    def test_workflow_has_one_job_per_provider_with_its_secrets_and_variables(self):
        jobs = self.load(self.registry([
            check('owner/extension', 'chrome'), check('owner/extension', 'amo'),
            check('owner/extension', 'edge', variables={'EDGE_OPERATION_ID': '00000000-0000-4000-8000-000000000003'}),
            check('owner/service'), check('owner/library', 'github')]))
        text = g.workflow(jobs['owner/extension'], SHA)
        self.assertEqual(re.findall(r'^  (\w+):$', text.split('\njobs:\n')[1], re.M), ['chrome', 'amo', 'edge'])
        self.assertIn('          EDGE_API_KEY: ${{ secrets.EDGE_API_KEY }}\n', text)
        self.assertIn('          EDGE_OPERATION_ID: "00000000-0000-4000-8000-000000000003"\n', text)
        self.assertEqual(text.count(f'          ref: {SHA}\n'), 3)
        self.assertEqual(text.count(f'          repository: {g.VITALS}\n'), 3)
        self.assertIn('--probe edge --config source/store.config.json', text)
        service = g.workflow(jobs['owner/service'], SHA)
        self.assertIn('--probe railway\n', service)
        self.assertNotIn('store.config.json', service)
        self.assertIn('          CHECK_REPOSITORY: ${{ github.repository }}\n', g.workflow(jobs['owner/library'], SHA))
        self.assertIn('permissions:\n  contents: read\n', text)

    def test_a_missing_or_malformed_registry_says_why(self):
        missing = ROOT / 'examples/does-not-exist.json'
        with self.assertRaisesRegex(ValueError, 'no registry at') as raised:
            g.load_jobs(missing)
        self.assertNotIn('vitals keys', str(raised.exception), 'the hint is for the registry of this Mac only')
        with patch.object(g, 'REGISTRY', missing), self.assertRaisesRegex(ValueError, 'no registry at .*vitals keys'):
            g.load_jobs(missing)
        with self.assertRaisesRegex(ValueError, 'not JSON'):
            self.load('{')
        with self.assertRaisesRegex(ValueError, 'cannot be read'):
            g.load_jobs(ROOT / 'examples')
        for data, reason in [
            (['keys'], '"keys" list'),
            ({'keys': {}}, '"keys" list'),
            ({'keys': ['text']}, '"keys" list of entries'),
            ({'keys': [{'name': 'plain', 'kind': 'file', 'path': 'p'}]}, 'no entry'),
            ({'keys': [{'name': 'plain', 'remoteChecks': {}}]}, 'plain: "remoteChecks" must be a list'),
            ({'keys': [{'name': 'plain', 'remoteChecks': ['text']}]}, 'plain: a remote check must be an object'),
            (self.registry([check('owner/extra/repo')]), 'owner/name'),
            (self.registry([check('owner/..')]), 'owner/name'),
            (self.registry([check(job='jenkins')]), 'must be one of'),
            (self.registry([check(secrets=[])]), 'secret names'),
            (self.registry([check(secrets=['lower-case'])]), 'secret names'),
            (self.registry([check(variables={'ID': 7})]), 'variables'),
            (self.registry([check(secrets=['RAILWAY_TOKEN'], variables={'RAILWAY_TOKEN': 'x'})]), 'reuse'),
            (self.registry([check(variables={'RAILWAY_PROJECT_ID': ''})]), 'non-empty'),
            (self.registry([check(variables={'CHECK_REPOSITORY': 'x'})]), 'fills in CHECK_REPOSITORY itself'),
            (self.registry([check(job='github', secrets=['RELEASE_TOKEN', 'CHECK_REPOSITORY'])]), 'fills in CHECK_REPOSITORY itself'),
            (self.registry([check(job='edge', variables={'EDGE_OPERATION_ID': 'op', 'EDGE_PRODUCT_ID': 'p'})]), 'fills in EDGE_PRODUCT_ID itself'),
            (self.registry([check(job='chrome', secrets=list(g.NEEDS['chrome']) + ['CWS_ITEM_ID'])]), 'fills in CWS_ITEM_ID itself'),
            (self.registry([check(variables={'ID': '${{ secrets.OTHER }}'})]), 'expression'),
            (self.registry([check(variables={'ID': 'a'})], [check(variables={'ID': 'b'})]), 'different values'),
        ]:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason):
                    self.load(data)
        self.assertEqual(list(self.load(self.registry([check('owner/.github', 'github')]))), ['owner/.github'])

    def apply(self, registry, deployed):
        """Run --apply against repositories whose workflow file is `deployed(repository)`, or absent for None.

        Returns the calls that went to GitHub's API and what was printed.
        """
        account = {'login': 'owner', 'id': 1, 'name': 'A Real Name', 'email': 'someone@example.com'}
        calls = []

        def api(path, payload=None):
            calls.append((path, payload))
            return account if path == 'user' else {'commit': {'html_url': 'https://example.com/commit'}}

        def run(arguments, **options):
            if arguments[0] == 'actionlint':
                return subprocess.CompletedProcess(arguments, 0, '', '')
            content = deployed(arguments[2].split('/contents/')[0].removeprefix('repos/'))
            if content is None:
                return subprocess.CompletedProcess(arguments, 1, '', 'gh: Not Found (HTTP 404)')
            return subprocess.CompletedProcess(arguments, 0, json.dumps({'sha': 'blob', 'content': base64.b64encode(content.encode()).decode()}), '')

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'keys.json'
            path.write_text(json.dumps(registry))
            with patch.object(g, 'api', side_effect=api), patch.object(g.subprocess, 'run', side_effect=run), \
                    patch.object(sys, 'argv', ['install', '--ref', SHA, '--registry', str(path), '--apply']), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                g.main()
        return calls, output.getvalue()

    def test_apply_commits_as_the_handle_with_the_no_reply_address(self):
        registry = self.registry([check('owner/new'), check('owner/changed', 'github')])
        calls, _ = self.apply(registry, lambda repository: None if repository == 'owner/new' else 'name: older\n')
        self.assertEqual([path for path, _ in calls], ['user'] + [
            f'repos/owner/{name}/contents/.github/workflows/credential-health.yml' for name in ('new', 'changed')])
        who = {'name': 'owner', 'email': '1+owner@users.noreply.github.com'}
        for _, payload in calls[1:]:
            self.assertEqual((payload['committer'], payload['author']), (who, who), 'not the profile name or the account email')
        self.assertNotIn('sha', calls[1][1], 'a new file')
        self.assertEqual(calls[2][1]['sha'], 'blob', 'a changed file replaces the one that is there')
        jobs = self.load(registry)
        self.assertEqual(base64.b64decode(calls[1][1]['content']).decode(), g.workflow(jobs['owner/new'], SHA))

    def test_apply_leaves_a_current_workflow_alone(self):
        registry = self.registry([check('owner/current')])
        current = g.workflow(self.load(registry)['owner/current'], SHA)
        calls, printed = self.apply(registry, lambda repository: current)
        self.assertEqual(calls, [], 'no commit, and no question about the account')
        self.assertEqual(printed, 'owner/current: already current\n')

    def test_a_variable_value_cannot_break_out_of_the_yaml(self):
        jobs = self.load(self.registry([check(variables={'RAILWAY_PROJECT_ID': 'x"\n    run: echo owned'})]))
        text = g.workflow(jobs['owner/repo'], SHA)
        self.assertIn('          RAILWAY_PROJECT_ID: "x\\"\\n    run: echo owned"\n', text)
        self.assertNotIn('\n    run: echo owned', text)
        self.assertEqual(text.count('echo owned'), 1)


if __name__ == '__main__':
    unittest.main()
