"""Keep the registry and its template identical.

An absent registry is created from the template. An existing registry is written
back into the template, without check stamps and with the home directory as `~`.
"""
import json
import os
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parents[1] / 'examples/keys.ancplua.json'


def portable(value, home):
    if isinstance(value, str):
        return value.replace(str(home), '~')
    if isinstance(value, list):
        return [portable(item, home) for item in value]
    if isinstance(value, dict):
        return {name: portable(item, home) for name, item in value.items() if name != 'verifiedAt'}
    return value


def sync(home, template=TEMPLATE):
    directory = home / '.config/vitals'
    registry = directory / 'keys.json'
    if not registry.exists():
        if (directory / 'keys.last-good.json').exists():
            return 'registry absent, recovery copy exists: run `vitals keys restore`'
        data = json.loads(template.read_text())
        data.pop('$schema', None)  # The template's relative editor link is checkout-specific.
        directory.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(registry, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as output:
            json.dump(data, output, indent=2)
            output.write('\n')
        return f'registry created from the template: {registry}'
    try:
        keys = json.loads(registry.read_text())['keys']
        names = [entry['name'] for entry in keys]
    except (ValueError, KeyError, TypeError):
        return 'registry unreadable, left untouched: run `vitals keys restore`'
    text = json.dumps({'$schema': '../schema/keys.schema.json', 'keys': portable(keys, home)},
                      indent=2, sort_keys=True, ensure_ascii=False) + '\n'
    if template.read_text() == text:
        return f'template matches the registry: {len(names)} entries'
    before = len(json.loads(template.read_text())['keys'])
    template.write_text(text)
    return f'template updated from the registry ({before} to {len(names)} entries): review and commit {template.name}'


if __name__ == '__main__':
    print(sync(Path.home()))
