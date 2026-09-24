"""Install the reviewed, pinned, read-only workflows for the registered repositories."""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import tempfile

REPOS = {
    'qyl.mcp': [('railway', ['RAILWAY_TOKEN'], {'RAILWAY_PROJECT_ID': '5eaa4020-71d9-4828-89d3-316cb188529e', 'RAILWAY_ENVIRONMENT_ID': '616ff7bf-ef19-4e34-bb22-d3eb002b74e9'})],
    'Qyl.OpenTelemetry.AutoInstrumentation': [('github', ['RELEASE_TOKEN'], {})],
    'Qyl.OpenTelemetry.SemanticConventions': [('github', ['RELEASE_TOKEN'], {})],
    'save-media': [('chrome', ['CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN', 'CWS_PUBLISHER_ID'], {}), ('amo', ['AMO_JWT_ISSUER', 'AMO_JWT_SECRET'], {}), ('edge', ['EDGE_API_KEY', 'EDGE_CLIENT_ID'], {'EDGE_OPERATION_ID': '899b2074-4ad5-496f-861a-b08b7b3e54f4'})],
    'yt-transcript': [('chrome', ['CWS_CLIENT_ID', 'CWS_CLIENT_SECRET', 'CWS_REFRESH_TOKEN', 'CWS_PUBLISHER_ID'], {}), ('amo', ['AMO_JWT_ISSUER', 'AMO_JWT_SECRET'], {}), ('edge', ['EDGE_API_KEY', 'EDGE_CLIENT_ID'], {'EDGE_OPERATION_ID': 'dafc8df6-2e73-4e94-90e6-64d7a872e242'})],
}
CHECKOUT = '3d3c42e5aac5ba805825da76410c181273ba90b1'

def workflow(repo, sha):
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
    for provider, secrets, options in REPOS[repo]:
        text += f'''  {provider}:
    name: {provider}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@{CHECKOUT}
        with:
          repository: ANcpLua/vitals
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
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if len(args.ref) != 40 or any(c not in '0123456789abcdef' for c in args.ref):
        raise ValueError('Use an immutable 40-character commit SHA')
    for repo in REPOS:
        content = workflow(repo, args.ref)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yml') as f:
            f.write(content); f.flush()
            subprocess.run(['actionlint', f.name], check=True)
        if not args.apply:
            print(repo + ': workflow validated')
            continue
        endpoint = f'repos/ANcpLua/{repo}/contents/.github/workflows/credential-health.yml'
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
