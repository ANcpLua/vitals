"""The workflow generator reads the owner's map from a file and the example map is made-up."""
import sys
sys.dont_write_bytecode = True
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / 'examples/health-workflows.example.json'
spec = importlib.util.spec_from_file_location('generator', ROOT / 'scripts/install_health_workflows.py')
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
SHA = 'a' * 40


class HealthWorkflowTests(unittest.TestCase):
    def load(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'map.json'
            path.write_text(data if isinstance(data, str) else json.dumps(data))
            return g.load_map(path)

    def test_example_map_loads_and_is_made_up(self):
        owner, repositories = g.load_map(EXAMPLE)
        self.assertEqual(owner, 'owner')
        self.assertEqual({job['job'] for jobs in repositories.values() for job in jobs}, set(g.PROVIDERS))
        text = EXAMPLE.read_text()
        for value in re.findall(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', text, re.I):
            self.assertTrue(value.startswith('00000000-0000-4000-8000-'), f'{value} looks like a real id')
        self.assertNotIn('@', text)

    def test_the_script_names_no_repository_or_id_of_its_own(self):
        source = (ROOT / 'scripts/install_health_workflows.py').read_text()
        self.assertIsNone(re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', source, re.I))
        self.assertEqual(set(re.findall(r"'([A-Za-z0-9-]+/[A-Za-z0-9._-]+)'", source)), {g.VITALS})

    def test_workflow_has_one_job_per_entry_with_its_secrets_and_variables(self):
        _, repositories = g.load_map(EXAMPLE)
        text = g.workflow(repositories['extension'], SHA)
        self.assertEqual(re.findall(r'^  (\w+):$', text.split('\njobs:\n')[1], re.M), ['chrome', 'amo', 'edge'])
        self.assertIn('          EDGE_API_KEY: ${{ secrets.EDGE_API_KEY }}\n', text)
        self.assertIn('          EDGE_OPERATION_ID: "00000000-0000-4000-8000-000000000003"\n', text)
        self.assertEqual(text.count(f'          ref: {SHA}\n'), 3)
        self.assertEqual(text.count(f'          repository: {g.VITALS}\n'), 3)
        self.assertIn('--probe edge --config source/store.config.json', text)
        service = g.workflow(repositories['service'], SHA)
        self.assertIn('--probe railway\n', service)
        self.assertNotIn('store.config.json', service)
        self.assertIn('          CHECK_REPOSITORY: ${{ github.repository }}\n', g.workflow(repositories['library'], SHA))
        self.assertIn('permissions:\n  contents: read\n', text)

    def test_a_missing_or_malformed_map_says_why(self):
        with self.assertRaisesRegex(ValueError, 'no monitoring map'):
            g.load_map(ROOT / 'examples/does-not-exist.json')
        with self.assertRaisesRegex(ValueError, 'not JSON'):
            self.load('{')
        with self.assertRaisesRegex(ValueError, 'cannot be read'):
            g.load_map(ROOT / 'examples')
        self.assertEqual(self.load({'owner': 'owner', 'repositories': {'.github': [{'job': 'github', 'secrets': ['RELEASE_TOKEN']}]}})[0], 'owner')
        job = {'job': 'railway', 'secrets': ['RAILWAY_TOKEN']}
        for data, reason in [
            ({'repositories': {'service': [job]}}, 'owner'),
            ({'owner': 'owner/extra', 'repositories': {'service': [job]}}, 'owner'),
            ({'owner': 'owner', 'repositories': {}}, 'repositories'),
            ({'owner': 'owner', 'repositories': {'bad name': [job]}}, 'repository name'),
            ({'owner': 'owner', 'repositories': {'service': [{'job': 'jenkins', 'secrets': ['TOKEN']}]}}, 'must be one of'),
            ({'owner': 'owner', 'repositories': {'service': [{'job': 'railway', 'secrets': []}]}}, 'secret names'),
            ({'owner': 'owner', 'repositories': {'service': [{'job': 'railway', 'secrets': ['lower-case']}]}}, 'secret names'),
            ({'owner': 'owner', 'repositories': {'service': [dict(job, variables={'ID': 7})]}}, 'variables'),
            ({'owner': 'owner', 'repositories': {'service': [dict(job, run='echo')]}}, 'only'),
            ({'owner': 'owner', 'repositories': {'..': [job]}}, 'repository name'),
            ({'owner': 'owner', 'repositories': {'service': [dict(job, variables={'RAILWAY_TOKEN': 'x'})]}}, 'reuse'),
            ({'owner': 'owner', 'repositories': {'service': [dict(job, variables={'CHECK_REPOSITORY': 'x'})]}}, 'reuse'),
            ({'owner': 'owner', 'repositories': {'service': [dict(job, variables={'ID': '${{ secrets.OTHER }}'})]}}, 'expression'),
            (['owner'], 'object'),
            ({'owner': 'owner', 'repositories': {'service': [job, job]}}, 'once'),
        ]:
            with self.subTest(reason=reason, data=data):
                with self.assertRaisesRegex(ValueError, reason):
                    self.load(data)

    def test_a_variable_value_cannot_break_out_of_the_yaml(self):
        jobs = [{'job': 'railway', 'secrets': ['RAILWAY_TOKEN'], 'variables': {'RAILWAY_PROJECT_ID': 'x"\n    run: echo owned'}}]
        text = g.workflow(jobs, SHA)
        self.assertIn('          RAILWAY_PROJECT_ID: "x\\"\\n    run: echo owned"\n', text)
        self.assertNotIn('\n    run: echo owned', text)
        self.assertEqual(text.count('echo owned'), 1)


if __name__ == '__main__':
    unittest.main()
