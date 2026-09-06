#!/usr/bin/env python3
"""Read-only Talk app preflight. Static results never qualify runtime integration."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile


def bounded_read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
            raise ValueError('invalid resource')
        data = handle.read(65537)
        if len(data) > 65536:
            raise ValueError('oversized resource')
        return data


def run(arguments):
    return subprocess.run([str(arg) for arg in arguments], capture_output=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--role', required=True, choices=['provider', 'consumer', 'both'])
    parser.add_argument('--tools-dir', type=Path, help='Already-built SDK executable directory')
    parser.add_argument('--source-contract', type=Path, help='Provider build input, to detect stale export')
    parser.add_argument('--client-contract', type=Path, help='Pinned consumer contract for directional check')
    args = parser.parse_args()
    if (args.source_contract or args.client_contract) and not args.tools_dir:
        parser.error('Contract comparison requires --tools-dir')
    if args.role == 'consumer' and (args.source_contract or args.client_contract):
        parser.error('Contract comparisons target a provider bundle')
    results = []

    def check(name, condition):
        results.append({'check': name, 'status': 'PASS' if condition else 'FAIL'})
        return condition

    try:
        app = args.app.resolve(strict=True)
        info = plistlib.loads(bounded_read(app / 'Contents/Info.plist'))
        if not isinstance(info, dict):
            raise ValueError('invalid plist')
        check('bundle_identity', info.get('CFBundleIdentifier') == args.bundle_id
              and info.get('CFBundlePackageType') == 'APPL')
        declared = info.get('CFBundleURLTypes', [])
        schemes = {scheme for item in declared if isinstance(item, dict)
                   for scheme in item.get('CFBundleURLSchemes', []) if isinstance(scheme, str)}
        if args.role in ('provider', 'both'):
            check('provider_scheme', 'talk-spike-provider' in schemes)
        if args.role in ('consumer', 'both'):
            check('consumer_scheme', 'talk-spike-consumer' in schemes)

        signature = run(['/usr/bin/codesign', '--verify', '--strict', '-R',
                         '=anchor apple generic', app])
        check('apple_anchored_signature', signature.returncode == 0)
        details = run(['/usr/bin/codesign', '-d', '--verbose=4', app])
        fields = {}
        for line in (details.stdout + details.stderr).decode('utf-8', errors='replace').splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                fields[key] = value
        check('signed_code_identity', details.returncode == 0
              and fields.get('Identifier') == args.bundle_id
              and fields.get('TeamIdentifier') not in (None, '', 'not set'))
        extracted = run(['/usr/bin/codesign', '-d', '--entitlements', ':-', app])
        entitlements = plistlib.loads(extracted.stdout) if extracted.returncode == 0 and extracted.stdout else {}
        app_id = entitlements.get('com.apple.application-identifier')
        check('application_identifier', isinstance(app_id, str) and '*' not in app_id
              and '\0' not in app_id and len(app_id.encode()) <= 1024
              and app_id.endswith('.' + args.bundle_id) and len(app_id) > len(args.bundle_id) + 1)
        groups = entitlements.get('keychain-access-groups', [])
        check('app_specific_keychain_group', isinstance(app_id, str)
              and isinstance(groups, list) and app_id in groups)
        if entitlements.get('com.apple.security.app-sandbox') is True:
            check('sandbox_network_client', entitlements.get('com.apple.security.network.client') is True)
            check('sandbox_network_server', entitlements.get('com.apple.security.network.server') is True)

        if args.role in ('provider', 'both'):
            check('contract_metadata', info.get('TalkContract') == 'Contract.talk.json')
            resources = (app / 'Contents/Resources').resolve(strict=True)
            contract = resources / 'Contract.talk.json'
            check('contract_resource_location', contract.resolve(strict=True).parent == resources)
            data = bounded_read(contract)
            check('contract_json_object', isinstance(json.loads(data), dict))
            if args.tools_dir:
                exporter = args.tools_dir.resolve() / 'TalkSchemaExporter'
                checker = args.tools_dir.resolve() / 'TalkContractChecker'
                with tempfile.TemporaryDirectory(prefix='talk-preflight-') as temporary:
                    output = Path(temporary)
                    # Validate the bounded bytes already read, not a second unchecked bundle read.
                    (output / 'embedded.json').write_bytes(data)
                    canonical = output / 'canonical.json'
                    exported = run([exporter, output / 'embedded.json', canonical])
                    if check('embedded_schema_validation', exported.returncode == 0):
                        if args.source_contract:
                            source = output / 'source.json'
                            source.write_bytes(bounded_read(args.source_contract))
                            source_export = output / 'source-canonical.json'
                            result = run([exporter, source, source_export])
                            check('embedded_matches_source', result.returncode == 0
                                  and source_export.read_bytes() == canonical.read_bytes())
                        else:
                            results.append({'check': 'embedded_matches_source', 'status': 'NOT RUN'})
                        if args.client_contract:
                            client = output / 'client.json'
                            client.write_bytes(bounded_read(args.client_contract))
                            result = run([checker, client, canonical])
                            check('client_to_provider_compatibility', result.returncode == 0)
                        else:
                            results.append({'check': 'client_to_provider_compatibility', 'status': 'NOT RUN'})
            else:
                for name in ('embedded_schema_validation', 'embedded_matches_source', 'client_to_provider_compatibility'):
                    results.append({'check': name, 'status': 'NOT RUN'})
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException,
            subprocess.SubprocessError):
        # Public metadata can still contain personal identifiers. Do not echo inputs/tool output.
        check('input_or_tool_operation', False)
    results.append({'check': 'signed_runtime_acceptance_matrix', 'status': 'NOT RUN'})
    passed = not any(item['status'] == 'FAIL' for item in results)
    print(json.dumps({'staticPreflight': 'PASS' if passed else 'FAIL', 'checks': results,
                      'limitation': 'Runtime provisioning, registration, consent, calls, events, persistence and revocation require actual-app tests.'}, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
