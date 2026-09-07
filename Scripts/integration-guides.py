#!/usr/bin/env python3
"""Scaffold/check public Talk provider guides; Python standard library only."""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / 'Integrations/TEMPLATE.md'
SDK_URL = 'https://github.com/AppitStudio/Talk.swift.git'
SDK_VERSION = '0.1.0-beta.2'
MARKER = '<!-- talk-integration-guide:1 -->'
HEADINGS = re.findall(r'^## .+$', TEMPLATE.read_text(), re.M)
META_KEYS = {'formatVersion', 'app', 'displayName', 'guideVersion', 'updated', 'status',
             'roles', 'sdk', 'provider', 'consumes'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inside(base, relative):
    require(isinstance(relative, str) and relative and not Path(relative).is_absolute(),
            'references must be nonempty relative paths')
    result = (base / relative).resolve()
    require(result.is_relative_to(ROOT.resolve()), 'reference escapes SDK checkout')
    require(result.is_file(), f'missing public artifact: {relative}')
    return result


def metadata(path):
    text = path.read_text()
    require(text.startswith(MARKER + '\n'), 'missing guide format marker')
    match = re.search(r'```json\n(.*?)\n```', text, re.S)
    require(match is not None, 'missing JSON metadata block')
    return json.loads(match.group(1)), text


def tool_run(tools, name, *arguments):
    executable = tools / name
    require(executable.is_file(), f'missing {name}; build the SDK tools first')
    result = subprocess.run([str(executable), *map(str, arguments)], capture_output=True,
                            text=True, timeout=60)
    require(result.returncode == 0, name + ' rejected the artifact: ' + result.stdout + result.stderr)


def check(path, tools=None, allow_draft=False, provider_export=None):
    meta, text = metadata(path)
    require(set(meta) == META_KEYS, 'metadata keys differ from format version 1')
    require(meta['formatVersion'] == 1, 'unsupported guide format')
    require(re.fullmatch(r'[a-z][a-z0-9-]*', meta['app']) is not None, 'invalid app slug')
    require(path.parent.name == meta['app'], 'app slug must match folder')
    require(isinstance(meta['displayName'], str) and meta['displayName'].strip(), 'missing display name')
    require(re.fullmatch(r'\d+\.\d+\.\d+', meta['guideVersion']) is not None, 'invalid guide version')
    date.fromisoformat(meta['updated'])
    require(meta['status'] in ('draft', 'beta', 'stable'), 'invalid guide status')
    require(allow_draft or meta['status'] != 'draft', 'draft is not publication-ready')
    require(allow_draft or '{{' not in text, 'unfilled template instructions')
    roles = meta['roles']
    require(isinstance(roles, list) and roles and len(set(roles)) == len(roles)
            and set(roles) <= {'provider', 'consumer'} and 'provider' in roles,
            'Integrations entries require the provider role and a public contract')
    require(re.findall(r'^## .+$', text, re.M) == HEADINGS, 'use the canonical template section order')
    for section in HEADINGS:
        body = text.split(section + '\n', 1)[1].split('\n## ', 1)[0].strip()
        require(body, 'empty section: ' + section)
    sdk = meta['sdk']
    require(isinstance(sdk, dict) and set(sdk) == {'repository', 'version'}
            and sdk['repository'] == SDK_URL and isinstance(sdk['version'], str)
            and re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', sdk['version']) is not None,
            'SDK reference must pin a version of the canonical repository')
    require(isinstance(meta['consumes'], list), 'consumes must be a list')
    require(('consumer' in roles) == bool(meta['consumes']), 'consumer role needs a known outgoing library')
    require(isinstance(meta['provider'], dict), 'a public provider contract is required; provider cannot be null')
    for item in meta['consumes']:
        require(set(item) == {'app', 'guide', 'contractID', 'contractVersion'}, 'invalid consumed contract')
        other_path = inside(path.parent, item['guide'])
        other, _ = metadata(other_path)
        require(other['app'] == item['app'] and 'provider' in other['roles']
                and isinstance(other['provider'], dict), 'outgoing guide is not that provider')
        require(other['provider']['contractID'] == item['contractID'] and
                other['provider']['contractVersion'] == item['contractVersion'], 'outgoing contract pin mismatch')
    provider = meta['provider']
    require(set(provider) == {'bundleID', 'contract', 'contractID', 'contractVersion', 'sha256', 'module'},
            'invalid provider metadata')
    require(re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', provider['bundleID']) is not None,
            'invalid provider routing bundle ID')
    require(re.fullmatch(r'[A-Za-z][A-Za-z0-9]*', provider['module']) is not None, 'invalid Swift module')
    schema_path = inside(path.parent, provider['contract'])
    require(digest(schema_path) == provider['sha256'], 'contract SHA-256 mismatch; review/update guide with contract')
    schema = json.loads(schema_path.read_text())
    require(schema['contractID'] == provider['contractID'] and
            schema['contractVersion'] == provider['contractVersion'], 'contract identity/version mismatch')
    require(schema_path.relative_to(path.parent).as_posix() ==
            f"Contract/Sources/{provider['module']}/Contract.talk.json", 'unexpected contract module layout')
    manifest = inside(path.parent, 'Contract/Package.swift').read_text()
    require(f'name: "{provider["module"]}"' in manifest and 'TalkClientPlugin' in manifest and
            SDK_URL in manifest and f'exact: "{sdk["version"]}"' in manifest, 'contract package pin/plugin mismatch')
    permissions = text.split('## Actions, permissions, and side effects\n', 1)[1].split('\n## ', 1)[0]
    for action in schema['actions']:
        require(f"`{action['id']}`" in permissions and f"`{action['scope']}`" in permissions
                and f"`{action['method']}" in permissions, 'undocumented action/scope/method: ' + action['id'])
    for event in schema['events']:
        require(f"`{event['id']}`" in permissions, 'undocumented event: ' + event['id'])
    if tools:
        with tempfile.TemporaryDirectory(prefix='talk-guide-check-') as temp:
            canonical = Path(temp) / 'canonical.json'
            tool_run(tools, 'TalkSchemaExporter', schema_path, canonical)
            require(canonical.read_bytes() == schema_path.read_bytes(), 'publish canonical exporter output')
            tool_run(tools, 'TalkContractChecker', schema_path, schema_path)
            if provider_export:
                actual = Path(temp) / 'actual.json'
                tool_run(tools, 'TalkSchemaExporter', provider_export, actual)
                require(actual.read_bytes() == canonical.read_bytes(), 'public schema differs from provider export')
    elif provider_export:
        raise ValueError('--provider-export requires --tools-dir')
    # Markdown links must resolve inside this checkout. The separate public-source
    # audit determines publication eligibility. Remote links are not fetched.
    for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
        target = target.split('#', 1)[0]
        if target and not re.match(r'https?://', target):
            inside(path.parent, target)
    return meta


def scaffold(args):
    require(re.fullmatch(r'[a-z][a-z0-9-]*', args.app) is not None, 'invalid app slug')
    roles = args.roles.split(',')
    require(roles and len(roles) == len(set(roles)) and set(roles) <= {'provider', 'consumer'}
            and 'provider' in roles, 'Integrations entries require the provider role and a public contract')
    dest = ROOT / 'Integrations' / args.app
    require(not dest.exists(), 'destination already exists; existing guides are never overwritten')
    require(args.contract and args.bundle_id and args.tools_dir,
            'provider scaffolding requires --contract, --bundle-id and --tools-dir')
    require(('consumer' in roles) == bool(args.consumes),
            'a dual-role provider needs --consumes PATH/TO/PROVIDER/GUIDE.md')
    with tempfile.TemporaryDirectory(prefix='talk-guide-init-') as temp:
        canonical = Path(temp) / 'Contract.talk.json'
        tool_run(args.tools_dir, 'TalkSchemaExporter', args.contract, canonical)
        schema_bytes = canonical.read_bytes()
        schema = json.loads(schema_bytes)
    module = args.module or schema['name'] + 'Contract'
    require(re.fullmatch(r'[A-Za-z][A-Za-z0-9]*', module) is not None, 'invalid Swift module')
    provider = {'bundleID': args.bundle_id, 'contract': f'Contract/Sources/{module}/Contract.talk.json',
                'contractID': schema['contractID'], 'contractVersion': schema['contractVersion'],
                'sha256': hashlib.sha256(schema_bytes).hexdigest(), 'module': module}
    consumes = []
    for supplied in args.consumes or []:
        guide = supplied.resolve()
        require(guide.is_relative_to((ROOT / 'Integrations').resolve()), 'consumed guide must be in Integrations')
        pinned, _ = metadata(guide)
        require('provider' in pinned['roles'] and isinstance(pinned['provider'], dict),
                'consumed guide exposes no provider API')
        consumes.append({'app': pinned['app'], 'guide': f"../{pinned['app']}/GUIDE.md",
                         'contractID': pinned['provider']['contractID'],
                         'contractVersion': pinned['provider']['contractVersion']})
    meta = {'formatVersion': 1, 'app': args.app, 'displayName': args.name,
            'guideVersion': '1.0.0', 'updated': date.today().isoformat(), 'status': 'draft',
            'roles': roles, 'sdk': {'repository': SDK_URL, 'version': SDK_VERSION},
            'provider': provider, 'consumes': consumes}
    output = TEMPLATE.read_text().replace('{{display_name}}', args.name)
    output = re.sub(r'```json\n.*?\n```', lambda _: '```json\n' + json.dumps(meta, indent=2) + '\n```',
                    output, count=1, flags=re.S)
    table = '| Action | Generated method | Scope | Mutation | Meaning |\n| --- | --- | --- | --- | --- |\n'
    for action in schema['actions']:
        table += f"| `{action['id']}` | `{action['method']}()` | `{action['scope']}` | {str(action['mutation']).lower()} | {{{{describe semantics}}}} |\n"
    for event in schema['events']:
        table += f"\nEvent `{event['id']}`: `" + event['payload'] + '`; {{subscription permission and semantics}}.\n'
    output = output.replace('{{permissions}}', table)
    output = output.replace('{{contract}}', f"Source of truth: [public contract]({provider['contract']}). {{{{document DTO semantics and limits}}}}")
    dest.mkdir()
    contract = dest / provider['contract']
    contract.parent.mkdir(parents=True)
    contract.write_bytes(schema_bytes)
    (contract.parent / 'Module.swift').write_text('// The TalkClientPlugin generates this module from Contract.talk.json.\n')
    (dest / 'Contract/Package.swift').write_text(package_manifest(provider['module']))
    (dest / 'GUIDE.md').write_text(output)
    print('Created ' + str((dest / 'GUIDE.md').relative_to(ROOT)) + '; draft instructions remain for author review.')


def package_manifest(module):
    return f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "{module}",
    platforms: [.macOS("12.4")],
    products: [.library(name: "{module}", targets: ["{module}"])],
    dependencies: [.package(url: "{SDK_URL}", exact: "{SDK_VERSION}")],
    targets: [.target(name: "{module}",
        dependencies: [.product(name: "Talk", package: "talk.swift")],
        exclude: ["Contract.talk.json"],
        plugins: [.plugin(name: "TalkClientPlugin", package: "talk.swift")])],
    swiftLanguageModes: [.v6]
)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init', help='create a draft from the canonical template')
    init.add_argument('app')
    init.add_argument('--name', required=True)
    init.add_argument('--roles', default='provider', help='provider (default), or provider,consumer; a public contract is required')
    init.add_argument('--contract', type=Path, required=True)
    init.add_argument('--bundle-id', required=True)
    init.add_argument('--module')
    init.add_argument('--consumes', type=Path, action='append')
    init.add_argument('--tools-dir', type=Path, required=True)
    verify = commands.add_parser('check', help='validate guide metadata, references and contract pins')
    verify.add_argument('guides', type=Path, nargs='*')
    verify.add_argument('--tools-dir', type=Path)
    verify.add_argument('--allow-draft', action='store_true')
    verify.add_argument('--provider-export', type=Path, help='compare one guide with actual provider export')
    args = parser.parse_args()
    try:
        if args.command == 'init':
            scaffold(args)
        else:
            paths = args.guides or sorted((ROOT / 'Integrations').glob('*/GUIDE.md'))
            require(paths, 'no app guides found')
            require(not args.provider_export or len(paths) == 1, '--provider-export requires exactly one guide')
            for path in paths:
                check(path.resolve(), args.tools_dir, args.allow_draft, args.provider_export)
                print(str(path.relative_to(ROOT) if path.is_absolute() else path) + ': PASS')
            if args.tools_dir:
                print('Authoritative schema export/compatibility: PASS; signed-app runtime: NOT RUN.')
            else:
                print('Metadata/references/hashes checked. Swift schema validation and signed-app runtime: NOT RUN.')
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
