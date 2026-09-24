#!/usr/bin/env python3
"""Credential probes. Standard library only; never print credentials or response bodies."""
import argparse
import base64
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

STATES = {'valid', 'invalid', 'missing', 'unavailable', 'pending', 'stale', 'unchecked', 'scopeMismatch'}
MAX_AGE = 24 * 3600

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')

def timestamp(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return 0

def result(state, detail='', **extra):
    assert state in STATES
    return dict(dict(state=state, detail=detail, checkedAt=now()), **extra)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

class ProbeError(Exception):
    def __init__(self, state, detail=""):
        self.state = state
        self.detail = detail

def request(url, headers=None, body=None, form=False):
    headers = dict(headers or {})
    headers['User-Agent'] = 'Vitals-Credential-Health'
    payload = None
    if body is not None:
        payload = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
    try:
        req = urllib.request.Request(url, data=payload, headers=headers)
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=12) as response:
            raw = response.read(1024 * 1024)
            if raw.startswith(b'event:') or raw.startswith(b'data:'):
                raw = next((line[5:].strip() for line in raw.splitlines() if line.startswith(b'data:')), b'{}')
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise ProbeError('invalid', 'Provider rejected authentication (HTTP ' + str(error.code) + ')') from None
        if error.code == 400:
            try:
                code = json.loads(error.read(8192)).get('error')
                if code in ('invalid_grant', 'invalid_client'):
                    raise ProbeError('invalid')
            except (ValueError, TypeError):
                pass
        raise ProbeError('unavailable', 'Provider check returned HTTP ' + str(error.code)) from None
    except (OSError, ValueError):
        raise ProbeError('unavailable') from None

def require(env, *names):
    if any(not env.get(name) for name in names):
        raise ProbeError('missing')
    return [env[name] for name in names]

def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')

def probe(provider, env):
    try:
        if provider == 'railway':
            token, project, environment = require(env, 'RAILWAY_TOKEN', 'RAILWAY_PROJECT_ID', 'RAILWAY_ENVIRONMENT_ID')
            data = request('https://backboard.railway.com/graphql/v2', {'Project-Access-Token': token},
                           {'query': 'query { projectToken { projectId environmentId } }'})
            if data.get('errors'):
                codes = [str(e.get('message', '')).lower() for e in data['errors']]
                raise ProbeError('invalid' if any('authoriz' in e or 'invalid' in e for e in codes) else 'unavailable')
            scope = data.get('data', {}).get('projectToken', {})
            if scope.get('projectId') != project or scope.get('environmentId') != environment:
                return result('scopeMismatch', 'Project or environment does not match')
        elif provider == 'github':
            token, repo = require(env, 'RELEASE_TOKEN', 'CHECK_REPOSITORY')
            if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
                raise ProbeError('unchecked')
            data = request('https://api.github.com/repos/' + repo,
                           {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json'})
            # A public repository alone does not prove release permission.
            if not data.get('permissions', {}).get('push'):
                return result('scopeMismatch', 'Repository write permission not confirmed')
        elif provider == 'chrome':
            client, secret, refresh = require(env, 'CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN')
            data = request('https://oauth2.googleapis.com/token', body={
                'client_id': client, 'client_secret': secret, 'refresh_token': refresh, 'grant_type': 'refresh_token'}, form=True)
            access = data.get('access_token')
            if not access:
                raise ProbeError('invalid')
            if not env.get('CWS_PUBLISHER_ID'):
                scopes = data.get('scope', '').split()
                if not any(s in scopes for s in ('https://www.googleapis.com/auth/chromewebstore', 'https://www.googleapis.com/auth/chromewebstore.readonly')):
                    return result('scopeMismatch', 'Chrome Web Store OAuth scope not confirmed')
                return result('valid', 'OAuth accepted with Chrome Web Store scope; item access not tested')
            publisher, item = require(env, 'CWS_PUBLISHER_ID', 'CWS_ITEM_ID')
            if not re.fullmatch(r'[A-Za-z0-9_-]+', publisher) or not re.fullmatch(r'[a-p]{32}', item):
                raise ProbeError('unchecked')
            request('https://chromewebstore.googleapis.com/v2/publishers/' + publisher + '/items/' + item + ':fetchStatus',
                    {'Authorization': 'Bearer ' + access})
        elif provider == 'amo':
            issuer, secret = require(env, 'AMO_JWT_ISSUER', 'AMO_JWT_SECRET')
            issued = int(time.time())
            unsigned = b64(b'{"alg":"HS256","typ":"JWT"}') + '.' + b64(json.dumps({
                'iss': issuer, 'jti': str(uuid.uuid4()), 'iat': issued, 'exp': issued + 60}).encode())
            token = unsigned + '.' + b64(hmac.new(secret.encode(), unsigned.encode(), hashlib.sha256).digest())
            request('https://addons.mozilla.org/api/v5/accounts/profile/', {'Authorization': 'JWT ' + token})
        elif provider == 'edge':
            key, client, product = require(env, 'EDGE_API_KEY', 'EDGE_CLIENT_ID', 'EDGE_PRODUCT_ID')
            # Only a real operation's successful GET proves access. A 404 must never be called valid.
            operation = env.get('EDGE_OPERATION_ID')
            if not operation:
                return result('unchecked', 'Read-only Edge check needs a previous operation ID')
            for value in (product, operation):
                if not re.fullmatch(r'[A-Za-z0-9_-]+', value):
                    raise ProbeError('unchecked')
            request('https://api.addons.microsoftedge.microsoft.com/v1/products/' + product + '/submissions/operations/' + operation,
                    {'Authorization': 'ApiKey ' + key, 'X-ClientID': client})
        elif provider == 'auth0':
            refresh, client = require(env, 'MCP_REFRESH_TOKEN', 'MCP_CLIENT_ID')
            data = request('https://qyl-eu.eu.auth0.com/oauth/token', body={
                'grant_type': 'refresh_token', 'refresh_token': refresh, 'client_id': client})
            # Store rotated credentials before any further request so a failed probe cannot lose them.
            if data.get('refresh_token') and data['refresh_token'] != refresh:
                write_keychain('qyl-mcp-hosted-refresh', 'qyl', data['refresh_token'])
            access = data.get('access_token')
            if not access:
                raise ProbeError('invalid')
            response = request('https://mcp.qyl.at/mcp', {
                'Authorization': 'Bearer ' + access, 'Accept': 'application/json, text/event-stream',
                'MCP-Protocol-Version': env.get('MCP_PROTOCOL_VERSION', '2026-07-28'), 'Mcp-Method': 'server/discover'},
                {'jsonrpc': '2.0', 'id': 1, 'method': 'server/discover', 'params': {'_meta': {
                    'io.modelcontextprotocol/protocolVersion': env.get('MCP_PROTOCOL_VERSION', '2026-07-28'),
                    'io.modelcontextprotocol/clientInfo': {'name': 'vitals-health', 'version': '1'},
                    'io.modelcontextprotocol/clientCapabilities': {}}}})
            if not response.get('result'):
                raise ProbeError('unavailable')
        else:
            return result('unchecked', 'No authentication probe configured')
        return result('valid', 'Read-only authentication check passed')
    except ProbeError as error:
        return result(error.state, error.detail or {'invalid': 'Credential rejected', 'missing': 'Required credential is absent',
                                   'unavailable': 'Provider or network check unavailable', 'unchecked': 'Check configuration incomplete'}[error.state])
    except Exception:
        # Never expose exception text: libraries may embed a request, header or provider response.
        return result('unavailable', 'Check could not be completed')

def command(arguments, input_text=None):
    try:
        p = subprocess.run(arguments, input=input_text, capture_output=True, text=True, timeout=20)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return -1, ''

def gh_api(path):
    executable = next((p for p in ('/opt/homebrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh') if Path(p).exists()), 'gh')
    code, output = command([executable, 'api', '--hostname', 'github.com', path])
    if code:
        return None
    try:
        return json.loads(output)
    except ValueError:
        return None

def workflow_result(run, jobs, job_name, updated_at, now_seconds=None):
    current = time.time() if now_seconds is None else now_seconds
    started = timestamp(run.get('run_started_at') or run.get('created_at'))
    if not started or started > current + 300:
        return result('unavailable', 'Invalid check timestamp')
    if started < updated_at or current - started > MAX_AGE:
        return result('stale', 'Run a fresh check after credential changes')
    if run.get('status') != 'completed':
        return result('pending', 'Authentication check is running')
    job = next((j for j in jobs if j.get('name') == job_name), None)
    if not job:
        return result('unchecked', 'Authentication job not found')
    steps = job.get('steps', [])
    state = 'unavailable'
    for name, value in [('Credential rejected', 'invalid'), ('Credential scope mismatch', 'scopeMismatch'),
                        ('Credential absent', 'missing'), ('Check not configured', 'unchecked')]:
        if any(s.get('name') == name and s.get('conclusion') == 'failure' for s in steps):
            state = value
    if job.get('conclusion') == 'success' and any(s.get('name') == 'Credential accepted' and s.get('conclusion') == 'success' for s in steps):
        state = 'valid'
    return result(state, 'GitHub Actions read-only check', checkedAt=run.get('run_started_at') or run['created_at'])

def remote_check(spec, memo):
    repo = spec.get('repository', '')
    label = repo + ' / ' + spec.get('job', 'credential')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        return dict(result('unchecked', 'Invalid repository'), label=label), 'unchecked'
    def get(path):
        if path not in memo:
            memo[path] = gh_api(path)
        return memo[path]
    meta = get('repos/' + repo)
    secrets = get('repos/' + repo + '/actions/secrets?per_page=100')
    if not isinstance(secrets, dict) or not isinstance(meta, dict):
        return dict(result('unavailable', 'GitHub metadata access unavailable'), label=label), 'unchecked'
    found = {s['name']: s for s in secrets.get('secrets', [])}
    names = spec.get('secrets', [])
    if not names:
        return dict(result('unchecked', 'No secret names configured'), label=label), 'unchecked'
    if any(name not in found for name in names):
        # Do not infer missing from a truncated first page.
        state = 'unchecked' if secrets.get('total_count', 0) > 100 else 'missing'
        return dict(result(state, 'Required GitHub secret not listed'), label=label), state
    updated = max(timestamp(found[name].get('updated_at')) for name in names)
    workflow = spec.get('workflow', 'credential-health.yml')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', workflow):
        return dict(result('unchecked', 'Invalid workflow'), label=label), 'present'
    branch = urllib.parse.quote(meta.get('default_branch', 'main'), safe='')
    runs = get('repos/' + repo + '/actions/workflows/' + workflow + '/runs?branch=' + branch + '&per_page=10')
    if not isinstance(runs, dict):
        return dict(result('unavailable', 'Authentication workflow unavailable'), label=label), 'present'
    run = next((r for r in runs.get('workflow_runs', []) if r.get('event') in ('schedule', 'workflow_dispatch', 'push')), None)
    if not run:
        return dict(result('unchecked', 'No authentication run yet'), label=label), 'present'
    jobs = get('repos/' + repo + '/actions/runs/' + str(run['id']) + '/attempts/' + str(run.get('run_attempt', 1)) + '/jobs?per_page=100')
    value = workflow_result(run, (jobs or {}).get('jobs', []), spec.get('job', ''), updated)
    return dict(value, label=label, url=run.get('html_url', '')), 'present'

def keychain(service, account=None, password=True):
    args = ['/usr/bin/security', 'find-generic-password', '-s', service]
    if account:
        args += ['-a', account]
    if password:
        args.append('-w')
    code, text = command(args)
    if code:
        raise ProbeError('missing' if code == 44 else 'unavailable')
    return text.strip()

def write_keychain(service, account, value):
    # Use stdin, never the process argument list. Capture and discard all output.
    line = 'add-generic-password -U -s ' + shlex.quote(service) + ' -a ' + shlex.quote(account) + ' -w ' + shlex.quote(value) + '\n'
    code, _ = command(['/usr/bin/security', '-i'], line)
    if code or keychain(service, account) != value:
        raise ProbeError('unavailable')

def local_environment(spec):
    env = dict(spec.get('options', {}))
    if spec.get('envFile'):
        for line in Path(spec['envFile']).expanduser().read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            match = re.fullmatch(r'(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)', line)
            if match:
                parts = shlex.split(match[2], comments=True)
                if len(parts) == 1:
                    env[match[1]] = parts[0]
    if spec.get('clientFile'):
        obj = json.loads(Path(spec['clientFile']).expanduser().read_text())
        obj = obj.get('installed', obj.get('web', obj))
        env.update(CWS_CLIENT_ID=obj['client_id'], CWS_CLIENT_SECRET=obj['client_secret'])
    if spec.get('refreshFile'):
        env['CWS_REFRESH_TOKEN'] = Path(spec['refreshFile']).expanduser().read_text().strip()
    if spec.get('provider') == 'auth0':
        env['MCP_REFRESH_TOKEN'] = keychain('qyl-mcp-hosted-refresh', 'qyl')
        env['MCP_CLIENT_ID'] = keychain('qyl-mcp-hosted-client-id', 'qyl')
    if spec.get('keychainService'):
        service = spec['keychainService']
        env['AMO_JWT_SECRET'] = keychain(service)
        match = re.search(r'"acct"<blob>="([^"]+)"', keychain(service, password=False))
        if match:
            env['AMO_JWT_ISSUER'] = match[1]
    return env

def local_fingerprint(spec):
    metadata = [spec]
    for name in ('envFile', 'clientFile', 'refreshFile'):
        if spec.get(name):
            try:
                stat = Path(spec[name]).expanduser().stat()
                metadata.append([name, stat.st_mtime_ns, stat.st_size])
            except OSError:
                metadata.append([name, 'absent'])
    return hashlib.sha256(json.dumps(metadata, sort_keys=True).encode()).hexdigest()

def check_registry(path, do_local=False):
    lock_fd = None
    if do_local:
        import fcntl
        lock_fd = os.open(str(Path(path).with_name('key-health.lock')), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(lock_fd)
            lock_fd = None
            do_local = False
    entries = json.loads(Path(path).read_text())['keys']
    cache_path = Path(path).with_name('key-health.json')
    try:
        cache = json.loads(cache_path.read_text())
    except (OSError, ValueError):
        cache = {}
    memo, local_memo, output = {}, {}, {}
    for entry in entries:
        checks, remote_presence = [], []
        for spec in entry.get('remoteChecks', []):
            value, presence = remote_check(spec, memo)
            checks.append(value)
            remote_presence.append(presence)
        spec = entry.get('localCheck')
        if spec and spec.get('provider') != 'claude':
            fingerprint = local_fingerprint(spec)
            value = cache.get(entry['name'])
            if do_local:
                memo_key = json.dumps(spec, sort_keys=True)
                if memo_key not in local_memo:
                    try:
                        local_memo[memo_key] = probe(spec['provider'], local_environment(spec))
                    except ProbeError as error:
                        local_memo[memo_key] = result(error.state, 'Local credential access unavailable')
                    except Exception:
                        local_memo[memo_key] = result('unavailable', 'Local credential check unavailable')
                value = dict(local_memo[memo_key], fingerprint=local_fingerprint(spec))
                cache[entry['name']] = value
            if not value:
                value = result('unchecked', 'Choose Test local credentials')
            elif value.get('fingerprint') != fingerprint or time.time() - timestamp(value.get('checkedAt')) > MAX_AGE:
                value = dict(value, state='stale', detail='Local credentials need a fresh check')
            checks.insert(0, dict(value, label='local ' + spec['provider']))
        presence = None
        if entry.get('kind') == 'reference' and remote_presence:
            presence = 'missing' if 'missing' in remote_presence else 'present' if all(p == 'present' for p in remote_presence) else 'unchecked'
        output[entry['name']] = dict(checks=checks, presence=presence)
    if do_local:
        import tempfile
        fd, tmp = tempfile.mkstemp(prefix='.key-health-', dir=cache_path.parent)
        try:
            with os.fdopen(fd, 'w') as f:
                json.dump(cache, f)
            os.replace(tmp, cache_path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    if lock_fd is not None:
        os.close(lock_fd)
    return output

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--registry')
    parser.add_argument('--config')
    parser.add_argument('--local', action='store_true')
    parser.add_argument('--probe', choices=['railway', 'github', 'chrome', 'amo', 'edge'])
    args = parser.parse_args()
    if args.probe:
        env = dict(os.environ)
        if args.config:
            stores = json.loads(Path(args.config).read_text()).get('stores', {})
            env['CWS_ITEM_ID'] = stores.get('chrome', {}).get('id', '')
            env['EDGE_PRODUCT_ID'] = stores.get('edge', {}).get('id', '')
        value = probe(args.probe, env)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
                f.write('state=' + value['state'] + '\n')
        print(json.dumps(value))
    elif args.registry:
        print(json.dumps(check_registry(args.registry, args.local)))
    else:
        parser.error('--registry or --probe is required')

if __name__ == '__main__':
    main()
