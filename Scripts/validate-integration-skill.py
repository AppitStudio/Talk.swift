"""Build the portable skill starter as an external package and exercise bundle preflight."""
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
skill = root / 'Skills/talk-integrations'
parent = root / 'LocalBuild/SkillValidation'
parent.mkdir(parents=True, exist_ok=True)
output = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
(output / 'Talk.swift').symlink_to(root, target_is_directory=True)
starter = output / 'Integration'
shutil.copytree(skill / 'assets', starter)
summary = {'checks': [], 'runtimeAppValidation': 'NOT RUN'}


def passed(name):
    summary['checks'].append(name)
    print(name + ': PASS', flush=True)


def checked(command, name, cwd=root):
    with (output / (name + '.log')).open('w') as log:
        subprocess.run([str(part) for part in command], cwd=cwd, stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=300)
    passed(name)


try:
    checked(['swift', 'build', '--package-path', starter], 'external-package-plugin-build')
    checked(['swift', 'build'], 'sdk-tools-build')
    binaries = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
    contract = starter / 'Sources/IntegrationContract/Contract.talk.json'
    canonical = output / 'Contract.talk.json'
    checked([binaries / 'TalkSchemaExporter', contract, canonical], 'starter-export')
    checked([binaries / 'TalkClientGenerator', canonical, output / 'Example.generated.swift'], 'starter-generation')
    checked([binaries / 'TalkContractChecker', contract, canonical], 'starter-self-compatibility')

    def preflight(app, identifier, role, extra=()):
        result = subprocess.run([sys.executable, str(skill / 'scripts/validate-app.py'),
                                 '--app', str(app), '--bundle-id', identifier, '--role', role,
                                 *map(str, extra)], capture_output=True, text=True, timeout=180)
        report = json.loads(result.stdout)
        assert (result.returncode == 0) == (report['staticPreflight'] == 'PASS')
        assert report['checks'][-1]['status'] == 'NOT RUN'
        return report, {item['check']: item['status'] for item in report['checks']}

    # Synthetic unsigned bundles exercise metadata/schema checks without any signing or secrets.
    app = output / 'Fixture.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    info = {'CFBundleIdentifier': 'com.example.provider', 'CFBundlePackageType': 'APPL',
            'TalkContract': 'Contract.talk.json',
            'CFBundleURLTypes': [{'CFBundleURLSchemes': ['talk-spike-provider']}]}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(canonical, resources / 'Contract.talk.json')
    extra = ['--tools-dir', binaries, '--source-contract', contract, '--client-contract', contract]
    report, checks = preflight(app, 'com.example.provider', 'provider', extra)
    assert checks['apple_anchored_signature'] == 'FAIL'
    assert checks['embedded_matches_source'] == checks['client_to_provider_compatibility'] == 'PASS'
    passed('unsigned-host-rejected-valid-schema-accepted')

    changed = json.loads(canonical.read_text())
    changed['contractVersion'] = '2.0.0'
    (resources / 'Contract.talk.json').write_text(json.dumps(changed))
    report, checks = preflight(app, 'com.example.provider', 'provider', extra)
    assert checks['embedded_matches_source'] == checks['client_to_provider_compatibility'] == 'FAIL'
    passed('stale-export-and-incompatible-major-rejected')

    info['CFBundleURLTypes'] = []
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    report, checks = preflight(app, 'com.example.provider', 'provider')
    assert checks['provider_scheme'] == 'FAIL' and checks['embedded_schema_validation'] == 'NOT RUN'
    passed('missing-scheme-rejected-and-omitted-tools-not-run')

    (resources / 'Contract.talk.json').write_text('{invalid')
    report, checks = preflight(app, 'com.example.provider', 'provider')
    assert checks['input_or_tool_operation'] == 'FAIL'
    passed('malformed-resource-rejected')

    # Existing provisioned examples are read only. No credentials/signing material is accessed.
    for variant in ('standard', 'sandboxed'):
        for title, role in (('Studio', 'provider'), ('Automator', 'consumer')):
            suffix = ' Sandbox' if variant == 'sandboxed' else ''
            example = root / 'LocalBuild/Apps' / variant / ('Talk ' + title + suffix + '.app')
            if not example.exists():
                continue
            identifier = 'dev.talk.examples.paired.' + title.lower() + ('.sandbox' if suffix else '')
            options = (['--tools-dir', binaries, '--source-contract', root / 'Examples/Shared/StudioContract/Contract.talk.json',
                        '--client-contract', root / 'Examples/Shared/StudioContract/Contract.talk.json']
                       if role == 'provider' else [])
            report, checks = preflight(example, identifier, role, options)
            name = variant + '-' + title.lower() + '-static-preflight'
            (output / (name + '.json')).write_text(json.dumps(report, indent=2) + '\n')
            assert report['staticPreflight'] == 'PASS', name
            passed(name)
    summary['result'] = 'PASS'
except Exception:
    summary['result'] = 'FAIL'
    raise
finally:
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Evidence:', output.relative_to(root), flush=True)
