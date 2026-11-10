"""Install the reviewed, pinned, read-only workflows for the repositories the registry names."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile

# Which repository gets which provider job is in the registry itself: the remoteChecks
# of its entries. The registry names repositories, projects and operation ids, so it
# lives on the Mac, outside this public repository.
REGISTRY = Path.home() / '.config/vitals/keys.json'
VITALS = 'ANcpLua/vitals'
WORKFLOW = 'credential-health.yml'
# What each provider's probe has to find in its job's environment before it asks the
# provider anything, given as a secret or as a variable. A job that lacks one of
# them could only fail, so it is refused here and never installed.
NEEDS = {
    'railway': ('RAILWAY_TOKEN', 'RAILWAY_PROJECT_ID', 'RAILWAY_ENVIRONMENT_ID'),
    'github': ('RELEASE_TOKEN',),
    'chrome': ('CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN'),
    'amo': ('AMO_JWT_ISSUER', 'AMO_JWT_SECRET'),
    'edge': ('EDGE_API_KEY', 'EDGE_CLIENT_ID', 'EDGE_OPERATION_ID'),
}
PROVIDERS = tuple(NEEDS)
# Names the workflow fills in itself: the repository for the GitHub probe, and the
# store ids that --config reads from the monitored repository. A job cannot set them.
FILLED_IN = ('CHECK_REPOSITORY', 'CWS_ITEM_ID', 'EDGE_PRODUCT_ID')
REPOSITORY = r'[A-Za-z0-9][A-Za-z0-9-]*/(?!\.{1,2}$)[A-Za-z0-9._-]+'
VARIABLE = r'[A-Z][A-Z0-9_]*'


def load_jobs(path):
    """Per repository (owner/name), its provider jobs, collected from every entry's remoteChecks.

    Entries that share a repository and a job are one job. Its secrets and variables
    are merged and put in name order, so neither the order of entries nor the order
    inside an entry changes the workflow. GitHub ignores case in a repository's name,
    so two spellings are one repository and the first spelling is used.
    Raises ValueError with the reason.
    """
    try:
        data = json.loads(Path(path).read_text())
    except FileNotFoundError:
        hint = ': run `vitals keys` to see how to create or restore it' if Path(path) == REGISTRY else ''
        raise ValueError(f'no registry at {path}{hint}')
    except OSError as error:
        raise ValueError(f'{path} cannot be read: {error.strerror}')
    except json.JSONDecodeError as error:
        raise ValueError(f'{path} is not JSON: {error}')
    keys = data.get('keys') if isinstance(data, dict) else None
    if not isinstance(keys, list) or not all(isinstance(entry, dict) for entry in keys):
        raise ValueError(f'{path} must hold an object with a "keys" list of entries')
    repositories = {}
    for entry in keys:
        name = entry.get('name', '?')
        checks = entry.get('remoteChecks', [])
        if not isinstance(checks, list):
            raise ValueError(f'{name}: "remoteChecks" must be a list')
        for check in checks:
            if not isinstance(check, dict):
                raise ValueError(f'{name}: a remote check must be an object')
            if check.get('workflow') != WORKFLOW:
                continue  # someone's own workflow; only credential-health.yml is generated here
            repository, provider = check.get('repository'), check.get('job')
            secrets, variables = check.get('secrets'), check.get('variables', {})
            if not isinstance(repository, str) or not re.fullmatch(REPOSITORY, repository):
                raise ValueError(f'{name}: "repository" must be owner/name')
            if provider not in PROVIDERS:
                raise ValueError(f'{name}: "job" must be one of {", ".join(PROVIDERS)}')
            if not isinstance(secrets, list) or not secrets or not all(isinstance(secret, str) and re.fullmatch(VARIABLE, secret) for secret in secrets):
                raise ValueError(f'{name}: "secrets" must list secret names')
            if not isinstance(variables, dict) or not all(re.fullmatch(VARIABLE, key) and isinstance(value, str) and value for key, value in variables.items()):
                raise ValueError(f'{name}: "variables" must map names to non-empty text')
            if any('${{' in value for value in variables.values()):
                raise ValueError(f'{name}: a variable is plain text, not a workflow expression')
            spelling, jobs = repositories.setdefault(repository.lower(), (repository, {}))
            job = jobs.setdefault(provider, {'job': provider, 'secrets': [], 'variables': {}})
            for secret in secrets:
                if secret not in job['secrets']:
                    job['secrets'].append(secret)
            for key, value in variables.items():
                if job['variables'].setdefault(key, value) != value:
                    raise ValueError(f'{spelling} {provider}: two entries give {key} different values')
    if not repositories:
        raise ValueError(f'no entry in {path} has a remote check for {WORKFLOW}')
    for spelling, jobs in repositories.values():
        for provider, job in jobs.items():
            taken = [name for name in FILLED_IN if name in job['secrets'] or name in job['variables']]
            if taken:
                raise ValueError(f'{spelling} {provider}: the workflow fills in {", ".join(taken)} itself, so it cannot be a secret or a variable')
            if set(job['variables']) & set(job['secrets']):
                raise ValueError(f'{spelling} {provider}: a variable may not reuse the name of a secret')
            missing = [name for name in NEEDS[provider] if name not in job['secrets'] and name not in job['variables']]
            if missing:
                raise ValueError(f'{spelling} {provider}: the probe needs {", ".join(missing)}, as a secret or as a variable')
            job['secrets'].sort()
            job['variables'] = dict(sorted(job['variables'].items()))
    return {spelling: [jobs[provider] for provider in PROVIDERS if provider in jobs] for spelling, jobs in repositories.values()}


CHECKOUT = '3d3c42e5aac5ba805825da76410c181273ba90b1'

def workflow(jobs, sha):
    text = '''name: Credential health
on:
  workflow_dispatch:
  schedule:
    - cron: '17 */6 * * *'
  push:
    paths: ['.github/workflows/credential-health.yml']
permissions:
  contents: read
concurrency:
  group: credential-health
  cancel-in-progress: false
jobs:
'''
    for job in jobs:
        provider, secrets, options = job['job'], job['secrets'], job.get('variables', {})
        text += f'''  {provider}:
    name: {provider}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@{CHECKOUT}
        with:
          repository: {VITALS}
          ref: {sha}
          path: .vitals
          sparse-checkout: Sources/VitalsKernel/credential_health.py
          sparse-checkout-cone-mode: false
          persist-credentials: false
'''
        config = ''
        if provider in ('chrome', 'amo', 'edge'):
            text += f'''      - uses: actions/checkout@{CHECKOUT}
        with:
          path: source
          sparse-checkout: store.config.json
          sparse-checkout-cone-mode: false
          persist-credentials: false
'''
            config = ' --config source/store.config.json'
        text += f'''      - name: Probe credentials
        id: probe
        env:
'''
        for name in secrets:
            text += '          ' + name + ': ${{ secrets.' + name + ' }}\n'
        for name, value in options.items():
            text += '          ' + name + ': ' + json.dumps(value) + '\n'
        if provider == 'github':
            text += '          CHECK_REPOSITORY: ${{ github.repository }}\n'
        text += f'        run: python3 .vitals/Sources/VitalsKernel/credential_health.py --probe {provider}{config}\n'
        for state, name in [('valid', 'Credential accepted'), ('invalid', 'Credential rejected'), ('scopeMismatch', 'Credential scope mismatch'), ('missing', 'Credential absent'), ('unchecked', 'Check not configured'), ('unavailable', 'Provider unavailable')]:
            text += '      - name: ' + name + '\n'
            text += "        if: steps.probe.outputs.state == '" + state + "'\n"
            text += '        run: ' + ('echo "Read-only authentication passed"' if state == 'valid' else 'exit 1') + '\n'
    return text

def api(path, payload=None):
    args = ['gh', 'api', path]
    if payload is not None:
        args += ['--method', 'PUT', '--input', '-']
    p = subprocess.run(args, input=json.dumps(payload) if payload is not None else None, text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError(p.stderr)
    return json.loads(p.stdout)

def committer():
    """The account's handle with its GitHub no-reply address.

    Left to itself GitHub fills in the account's profile name and the email the
    account shows, whatever identity git uses on this Mac.
    """
    user = api('user')
    return {'name': user['login'], 'email': f'{user["id"]}+{user["login"]}@users.noreply.github.com'}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ref', required=True)
    parser.add_argument('--registry', default=REGISTRY, help='the credential registry (default: %(default)s)')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if len(args.ref) != 40 or any(c not in '0123456789abcdef' for c in args.ref):
        raise ValueError('Use an immutable 40-character commit SHA')
    try:
        repositories = load_jobs(args.registry)
    except ValueError as error:
        parser.exit(2, f'{error}\n')
    who = None
    for repo, jobs in repositories.items():
        content = workflow(jobs, args.ref)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yml') as f:
            f.write(content); f.flush()
            subprocess.run(['actionlint', f.name], check=True)
        if not args.apply:
            print(repo + ': workflow validated')
            continue
        endpoint = f'repos/{repo}/contents/.github/workflows/{WORKFLOW}'
        p = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True)
        payload = {'message': 'ci: monitor credentials with read-only scheduled checks', 'content': base64.b64encode(content.encode()).decode()}
        if p.returncode == 0:
            previous = json.loads(p.stdout)
            if base64.b64decode(previous['content']).decode() == content:
                print(repo + ': already current'); continue
            payload['sha'] = previous['sha']
        elif '404' not in p.stderr:
            raise RuntimeError(p.stderr)
        who = who or committer()
        data = api(endpoint, dict(payload, committer=who, author=who))
        print(repo + ': ' + data['commit']['html_url'])

if __name__ == '__main__':
    main()
