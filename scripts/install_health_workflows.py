"""Install the reviewed, pinned, read-only workflows for the repositories in the owner's map."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import tempfile

# Which repository gets which provider job is the owner's own map. It names
# repositories, projects and operation ids, so it lives on the Mac, outside this
# public repository. `examples/health-workflows.example.json` shows the shape.
MAP = Path.home() / '.config/vitals/health-workflows.json'
VITALS = 'ANcpLua/vitals'
PROVIDERS = ('railway', 'github', 'chrome', 'amo', 'edge')
OWNER = r'[A-Za-z0-9][A-Za-z0-9-]*'
REPOSITORY = r'(?!\.{1,2}$)[A-Za-z0-9._-]+'
VARIABLE = r'[A-Z][A-Z0-9_]*'


def load_map(path):
    """The owner and, per repository, its provider jobs; raises ValueError with the reason."""
    try:
        data = json.loads(Path(path).read_text())
    except FileNotFoundError:
        raise ValueError(f'no monitoring map at {path}: copy examples/health-workflows.example.json there and fill it in')
    except OSError as error:
        raise ValueError(f'{path} cannot be read: {error.strerror}')
    except json.JSONDecodeError as error:
        raise ValueError(f'{path} is not JSON: {error}')
    if not isinstance(data, dict):
        raise ValueError(f'{path} must hold an object with "owner" and "repositories"')
    owner, repositories = data.get('owner'), data.get('repositories')
    if not isinstance(owner, str) or not re.fullmatch(OWNER, owner):
        raise ValueError('"owner" must be the GitHub owner of the monitored repositories')
    if not isinstance(repositories, dict) or not repositories:
        raise ValueError('"repositories" must map at least one repository name to its jobs')
    for repo, jobs in repositories.items():
        if not re.fullmatch(REPOSITORY, repo) or not isinstance(jobs, list) or not jobs:
            raise ValueError(f'{repo!r} needs a repository name and a list of jobs')
        for job in jobs:
            if not isinstance(job, dict) or job.get('job') not in PROVIDERS:
                raise ValueError(f'{repo}: "job" must be one of {", ".join(PROVIDERS)}')
            secrets, variables = job.get('secrets'), job.get('variables', {})
            if not isinstance(secrets, list) or not secrets or not all(isinstance(name, str) and re.fullmatch(VARIABLE, name) for name in secrets):
                raise ValueError(f'{repo} {job["job"]}: "secrets" must list secret names')
            if not isinstance(variables, dict) or not all(re.fullmatch(VARIABLE, name) and isinstance(value, str) for name, value in variables.items()):
                raise ValueError(f'{repo} {job["job"]}: "variables" must map names to text')
            if set(variables) & (set(secrets) | {'CHECK_REPOSITORY'}):
                raise ValueError(f'{repo} {job["job"]}: a variable may not reuse the name of a secret or CHECK_REPOSITORY')
            if any('${{' in value for value in variables.values()):
                raise ValueError(f'{repo} {job["job"]}: a variable is plain text, not a workflow expression')
            if set(job) - {'job', 'secrets', 'variables'}:
                raise ValueError(f'{repo} {job["job"]}: only "job", "secrets" and "variables" are read')
        if len({job['job'] for job in jobs}) != len(jobs):
            raise ValueError(f'{repo}: each job may appear once')
    return owner, repositories


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

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ref', required=True)
    parser.add_argument('--map', default=MAP, help='the monitoring map (default: %(default)s)')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if len(args.ref) != 40 or any(c not in '0123456789abcdef' for c in args.ref):
        raise ValueError('Use an immutable 40-character commit SHA')
    try:
        owner, repositories = load_map(args.map)
    except ValueError as error:
        parser.exit(2, f'{error}\n')
    for repo, jobs in repositories.items():
        content = workflow(jobs, args.ref)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yml') as f:
            f.write(content); f.flush()
            subprocess.run(['actionlint', f.name], check=True)
        if not args.apply:
            print(repo + ': workflow validated')
            continue
        endpoint = f'repos/{owner}/{repo}/contents/.github/workflows/credential-health.yml'
        p = subprocess.run(['gh', 'api', endpoint], capture_output=True, text=True)
        payload = {'message': 'ci: monitor credentials with read-only scheduled checks', 'content': base64.b64encode(content.encode()).decode()}
        if p.returncode == 0:
            previous = json.loads(p.stdout)
            if base64.b64decode(previous['content']).decode() == content:
                print(repo + ': already current'); continue
            payload['sha'] = previous['sha']
        elif '404' not in p.stderr:
            raise RuntimeError(p.stderr)
        data = api(endpoint, payload)
        print(repo + ': ' + data['commit']['html_url'])

if __name__ == '__main__':
    main()
