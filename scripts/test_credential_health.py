import sys
sys.dont_write_bytecode = True
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('health', Path(__file__).parents[1] / 'Sources/VitalsKernel/credential_health.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)

class HealthTests(unittest.TestCase):
    def run_state(self, run=None, jobs=None, updated=0):
        base = dict(status='completed', created_at='2026-09-24T00:00:00Z')
        base.update(run or {})
        jobs = jobs if jobs is not None else [dict(name='railway', conclusion='success', steps=[dict(name='Credential accepted', conclusion='success')])]
        return h.workflow_result(base, jobs, 'railway', updated, h.timestamp('2026-09-24T01:00:00Z'))['state']

    def test_metadata_is_not_authentication(self):
        self.assertEqual(self.run_state(jobs=[]), 'unchecked')
        self.assertEqual(self.run_state(jobs=[dict(name='railway', conclusion='success', steps=[])]), 'unavailable')

    def test_rotation_and_age_invalidate_success(self):
        self.assertEqual(self.run_state(), 'valid')
        self.assertEqual(self.run_state(updated=h.timestamp('2026-09-24T00:30:00Z')), 'stale')
        self.assertEqual(self.run_state(run=dict(created_at='2026-09-22T00:00:00Z')), 'stale')
        self.assertEqual(self.run_state(run=dict(created_at='2026-09-25T00:00:00Z')), 'unavailable')

    def test_latest_failure_and_pending_replace_old_success(self):
        jobs = [dict(name='railway', conclusion='failure', steps=[dict(name='Credential rejected', conclusion='failure')])]
        self.assertEqual(self.run_state(jobs=jobs), 'invalid')
        self.assertEqual(self.run_state(run=dict(status='in_progress')), 'pending')

    def test_railway_scope_is_checked(self):
        env = dict(RAILWAY_TOKEN='secret-canary', RAILWAY_PROJECT_ID='project', RAILWAY_ENVIRONMENT_ID='production')
        with patch.object(h, 'request', return_value={'data': {'projectToken': {'projectId': 'other', 'environmentId': 'production'}}}):
            self.assertEqual(h.probe('railway', env)['state'], 'scopeMismatch')
        with patch.object(h, 'request', return_value={'errors': [{'message': 'Not Authorized'}]}):
            self.assertEqual(h.probe('railway', env)['state'], 'invalid')

    def test_no_secret_or_provider_exception_escapes(self):
        env = dict(AMO_JWT_ISSUER='issuer', AMO_JWT_SECRET='secret-canary')
        with patch.object(h, 'request', side_effect=RuntimeError('Bearer secret-canary')):
            value = h.probe('amo', env)
        self.assertEqual(value['state'], 'unavailable')
        self.assertNotIn('secret-canary', json.dumps(value))

    def test_github_requires_write_permission(self):
        with patch.object(h, 'request', return_value={'permissions': {'push': False}}):
            self.assertEqual(h.probe('github', {'RELEASE_TOKEN': 'token', 'CHECK_REPOSITORY': 'owner/repo'})['state'], 'scopeMismatch')

    def test_edge_never_calls_missing_operation_success(self):
        env = dict(EDGE_API_KEY='token', EDGE_CLIENT_ID='client', EDGE_PRODUCT_ID='product')
        self.assertEqual(h.probe('edge', env)['state'], 'unchecked')
        with patch.object(h, 'request', side_effect=h.ProbeError('unavailable')):
            self.assertEqual(h.probe('edge', dict(env, EDGE_OPERATION_ID='operation'))['state'], 'unavailable')

    def test_oauth_rotation_saved_before_mcp_request(self):
        events = []
        def request(url, *args, **kwargs):
            events.append('refresh' if url.endswith('/oauth/token') else 'mcp')
            if not url.endswith('/oauth/token'):
                headers, body = args
                self.assertEqual(headers['Mcp-Method'], 'server/discover')
                self.assertEqual(body['method'], 'server/discover')
                self.assertEqual(body['params']['_meta']['io.modelcontextprotocol/protocolVersion'], headers['MCP-Protocol-Version'])
            return {'access_token': 'access', 'refresh_token': 'rotated'} if url.endswith('/oauth/token') else {'result': { 'serverInfo': {} }}
        saved = []
        def save(*arguments):
            events.append('save')
            saved.append(arguments)
        env = {'MCP_REFRESH_TOKEN': 'old', 'MCP_CLIENT_ID': 'client', 'AUTH0_DOMAIN': 'tenant.example.com',
               'MCP_URL': 'https://mcp.example.com/mcp', 'MCP_REFRESH_SERVICE': 'example-refresh', 'MCP_KEYCHAIN_ACCOUNT': 'example'}
        with patch.object(h, 'request', side_effect=request) as requested, patch.object(h, 'write_keychain', side_effect=save):
            self.assertEqual(h.probe('auth0', env)['state'], 'valid')
        self.assertEqual(events, ['refresh', 'save', 'mcp'])
        self.assertEqual([call.args[0] for call in requested.call_args_list],
                         ['https://tenant.example.com/oauth/token', 'https://mcp.example.com/mcp'])
        self.assertEqual(saved, [('example-refresh', 'example', 'rotated')])

    def test_hosted_mcp_check_asks_nothing_until_its_options_are_complete(self):
        complete = {'MCP_REFRESH_TOKEN': 'old', 'MCP_CLIENT_ID': 'client', 'AUTH0_DOMAIN': 'tenant.example.com',
                    'MCP_URL': 'https://mcp.example.com/mcp', 'MCP_REFRESH_SERVICE': 'example-refresh', 'MCP_KEYCHAIN_ACCOUNT': 'example'}
        changes = [{name: ''} for name in ('AUTH0_DOMAIN', 'MCP_URL', 'MCP_REFRESH_SERVICE', 'MCP_KEYCHAIN_ACCOUNT')]
        changes += [{'AUTH0_DOMAIN': 'tenant.example.com/path'}, {'AUTH0_DOMAIN': 'localhost'}, {'MCP_URL': 'http://mcp.example.com/mcp'}]
        for change in changes:
            with self.subTest(change=change), patch.object(h, 'request') as requested, patch.object(h, 'write_keychain') as saved:
                self.assertEqual(h.probe('auth0', dict(complete, **change))['state'], 'unchecked')
                requested.assert_not_called()
                saved.assert_not_called()
        with patch.object(h, 'request') as requested:
            self.assertEqual(h.probe('auth0', dict(complete, MCP_REFRESH_TOKEN=''))['state'], 'missing')
            requested.assert_not_called()

    def test_hosted_mcp_credentials_come_from_the_keychain_items_the_entry_names(self):
        spec = {'provider': 'auth0', 'options': {'MCP_REFRESH_SERVICE': 'example-refresh', 'MCP_CLIENT_ID_SERVICE': 'example-client',
                                                'MCP_KEYCHAIN_ACCOUNT': 'example'}}
        with patch.object(h, 'keychain', side_effect=lambda service, account=None, password=True: f'{service}:{account}') as read:
            env = h.local_environment(spec)
        self.assertEqual((env['MCP_REFRESH_TOKEN'], env['MCP_CLIENT_ID']), ('example-refresh:example', 'example-client:example'))
        with patch.object(h, 'keychain') as read:
            self.assertNotIn('MCP_REFRESH_TOKEN', h.local_environment({'provider': 'auth0', 'options': {}}))
            read.assert_not_called()

if __name__ == '__main__':
    unittest.main()
