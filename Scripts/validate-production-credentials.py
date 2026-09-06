"""Build first; sign/run only with an explicitly authorized local config.
No account API, upload, profile installation, trust/ACL edit, or secret output.
Config is local-only: certificate SHA-1, profile path, identifier, optional second
profile/certificate/identifier for an independently entitled app. Optional update
uses a different authorized certificate/profile for the same application group.
Keep it outside
public source. A different real team is required to qualify cross-team isolation.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import importlib.util
import sys
sys.dont_write_bytecode = True
import hashlib
import json
import plistlib
import shutil
import subprocess
import os
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('apple_signing', Path(__file__).with_name('apple-signing.py'))
apple_signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apple_signing)
SOURCES = ['CredentialStore', 'KeychainOperations', 'IntegrationStore', 'PairingCredential',
           'PairingRecord', 'TalkError', 'Deadline', 'DeadlineTimer']

def checked(command, timeout=90):
    report['activeTool'] = command[0]
    persist()
    result = subprocess.run(command, capture_output=True, timeout=timeout)
    if result.returncode:
        # Compiler output contains only source paths/diagnostics. Signing output
        # can contain personal identity metadata and is deliberately not retained.
        if command[0] == 'xcrun':
            (folder / 'build-failure.log').write_bytes(result.stdout + result.stderr)
        raise RuntimeError('tool failed: ' + command[0] + ' exit ' + str(result.returncode))
    return result.stdout


def build():
    frozen = folder / 'Sources'
    frozen.mkdir()
    files = [ROOT / 'Sources/Talk' / (x + '.swift') for x in SOURCES]
    files.append(ROOT / 'Scripts/Probes/ProductionCredentials.swift')
    for p in files:
        shutil.copy2(p, frozen / p.name)
    (folder / 'source-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, indent=2) + '\n')
    for version in [1, 2]:
        checked(['xcrun', 'swiftc', '-target', f'{os.uname().machine}-apple-macosx12.4', '-parse-as-library', '-swift-version', '6', '-O',
                 *(['-D', 'TALK_PROBE_UPDATE'] if version == 2 else []),
                 *[str(frozen / p.name) for p in files], '-o', str(folder / ('Probe' + str(version)))])
    assert (folder / 'Probe1').read_bytes() != (folder / 'Probe2').read_bytes()


def package(name, variant, version, config=None, copied_identifier=None):
    app = folder / variant / (name + '.app')
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    shutil.copy2(folder / ('Probe' + str(version)), contents / 'MacOS/Probe')
    identifier = config['identifier'] if config else copied_identifier or 'dev.talk.synthetic.production.unprovisioned.' + variant
    (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier,
        'LSMinimumSystemVersion': '12.4', 'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(version)}))
    # Use an unrestricted copied-ID attacker against both owner variants. A
    # sandboxed ad-hoc copy can stall in OS sandbox initialization before main;
    # that is not evidence of Keychain denial. Keep that separate platform result.
    sandboxed = variant == 'sandboxed' and copied_identifier is None
    entitlements = {'com.apple.security.app-sandbox': True} if sandboxed else {}
    certificate = 'adhoc'
    group = 'UNPROVISIONED.' + identifier
    team = None
    if config:
        team = apple_signing.profile_entitlements(config)['com.apple.developer.team-identifier']
        report['activeTool'] = 'codesign'
        persist()
        group = apple_signing.sign(app, config, sandboxed=sandboxed, timeout=args.signing_timeout)
        certificate = config['certificate']
    else:
        path = folder / variant / (name + '.entitlements.private.plist')
        path.write_bytes(plistlib.dumps(entitlements))
        path.chmod(0o600)
        checked(['codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none',
                 '--entitlements', str(path), str(app)], timeout=args.signing_timeout)
        checked(['codesign', '--verify', '--strict', str(app)])
    return {'app': app, 'certificate': certificate, 'identifier': identifier, 'group': group, 'team': team, 'version': version, 'sandboxed': sandboxed}


def run(app, operation, service, target_group=None):
    report['activeProbe'] = {'app': app['app'].stem, 'variant': app['app'].parent.name, 'operation': operation}
    persist()
    try:
        result = subprocess.run([str(app['app'] / 'Contents/MacOS/Probe'), operation, service,
            app['certificate'], app['identifier'], target_group or app['group']], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        raise RuntimeError('probe watchdog expired; outcome inconclusive') from None
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        raise RuntimeError('probe did not return a valid status; exit ' + str(result.returncode)) from None
    proof = value.pop('continuityProof', None)
    if value.get('result') in ['saved', 'loaded']:
        assert isinstance(proof, str) and len(proof) == 64
        proof_key = (app['group'], service)
        if value['result'] == 'saved': continuity[proof_key] = proof
        else: assert continuity.get(proof_key) == proof, 'credential changed across restart/update'
    assert set(value).issubset({'result', 'osStatus', 'dataReturned', 'signerVerified', 'build', 'itemProtectionVerified'})
    assert value.get('signerVerified') is True and value.get('build') == app['version'], value
    report['checks'].append({'app': app['app'].stem, 'variant': app['app'].parent.name,
                            'processSandboxed': app['sandboxed'], 'operation': operation, **value})
    persist()
    return value


def expect(app, operation, service, expected):
    value = run(app, operation, service)
    assert value['result'] == expected, value


def persist():
    (folder / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--config', type=Path, help='Authorized local signing configuration; omission runs only unprovisioned denial controls')
parser.add_argument('--fresh-identifiers', action='store_true', help='Append a disposable per-run/variant suffix; requires profiles authorizing those identifiers')
parser.add_argument('--signing-timeout', type=int, default=120, choices=range(1, 301), metavar='SECONDS', help='Bound the wait for a local macOS signing-key prompt (1–300 seconds)')
args = parser.parse_args()
parent = ROOT / 'LocalBuild/ProductionCredentialValidation'
parent.mkdir(parents=True, exist_ok=True)
folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
folder.chmod(0o700)
print('Evidence:', folder.relative_to(ROOT), flush=True)
continuity = {}  # Possession proofs never enter evidence or exception output.
report = {'result': 'incomplete', 'checks': [], 'appleSignedRun': args.config is not None,
          'crossTeamQualified': False, 'changedCertificateContinuityQualified': False,
          'distributionDeliveryQualified': False, 'freshIdentifiers': args.fresh_identifiers, 'cleanup': []}
try:
    build()
    original_config = json.loads(args.config.read_text()) if args.config else None
    for variant in ['standard', 'sandboxed']:
        config = original_config
        if config and args.fresh_identifiers:
            suffix = '.run' + folder.name.split('-')[-1].replace('_', '') + '.' + variant
            config = {key: {**value, 'identifier': value['identifier'] + suffix}
                      for key, value in config.items() if key in ['owner', 'other', 'update']}
        service = 'dev.talk.synthetic.production.' + str(uuid.uuid4())
        unprovisioned = package('Unprovisioned', variant, 1)
        for operation in ['load', 'save', 'delete']:
            expect(unprovisioned, operation, service, 'credentialConfiguration')
        if config:
            owner = package('Owner', variant, 1, config['owner'])
            update = package('Update', variant, 2, config.get('update', config['owner']))
            assert update['group'] == owner['group'] and update['identifier'] == owner['identifier'], 'update must retain the owner application group'
            other = package('Other', variant, 1, config['other']) if config.get('other') else unprovisioned
            assert other['group'] != owner['group']
            same_team = owner['team'] == other['team'] if other['team'] else None
            report['otherProvisioned'] = config.get('other') is not None
            report['otherSameTeam'] = same_team
            report['otherSamePrefix'] = owner['group'].split('.')[0] == other['group'].split('.')[0]
            copied = package('CopiedIdentifierAdHoc', variant, 1, copied_identifier=owner['identifier'])
            attackers = [unprovisioned, copied]
            if config.get('other'):
                attackers.append(other)
                if same_team is False:
                    copied_config = {**config['other'], 'identifier': owner['identifier']}
                    copied_other = package('CopiedIdentifierOtherTeam', variant, 1, copied_config)
                    assert copied_other['group'] != owner['group']
                    attackers.append(copied_other)
            try:
                expect(owner, 'load', service, 'empty')
                expect(owner, 'save', service, 'saved')
                expect(owner, 'load', service, 'loaded')
                positive = run(owner, 'raw-read', service)
                assert positive['osStatus'] == 0 and positive['dataReturned'] is True
                attributes = run(owner, 'raw-attributes', service)
                assert attributes['osStatus'] == 0 and attributes['itemProtectionVerified'] is True
                for operation in ['load', 'save', 'delete']:
                    expect(copied, operation, service, 'credentialConfiguration')
                expect(update, 'load', service, 'loaded')
                # Repeat at one fixed installation path with fresh processes.
                current = dict(owner)
                current['app'] = folder / variant / 'Current.app'
                shutil.copytree(owner['app'], current['app'])
                expect(current, 'load', service, 'loaded')
                shutil.rmtree(current['app'])
                shutil.copytree(update['app'], current['app'])
                current['version'] = 2
                checked(['codesign', '--verify', '--strict', str(current['app'])])
                expect(current, 'load', service, 'loaded')
                expect(current, 'update', service, 'saved')
                expect(owner, 'load-updated', service, 'loaded')
                # Both ad-hoc and independently provisioned apps bypass the SDK
                # guard and directly attack the exact owner service/access group.
                for attacker in attackers:
                    for operation in ['raw-read', 'raw-read-default', 'raw-update', 'raw-delete']:
                        value = run(attacker, operation, service, owner['group'])
                        assert value['result'] == 'raw' and value['dataReturned'] is False
                        assert value['osStatus'] in [-34018, -25300], value
                        expect(owner, 'load-updated', service, 'loaded')
                # A distinct entitled app can store its own archive under the
                # same public service without affecting the owner's archive.
                if config.get('other'):
                    expect(other, 'load', service, 'empty')
                    expect(other, 'save', service, 'saved')
                    expect(other, 'load', service, 'loaded')
                    expect(owner, 'load-updated', service, 'loaded')
            except Exception as error:
                report['primaryFailure'] = {'failureType': type(error).__name__, 'probe': report.get('activeProbe')}
                persist()
                raise
            finally:
                cleanup_failed = False
                for app in [owner, other] if config.get('other') else [owner]:
                    try:
                        expect(app, 'delete', service, 'deleted')
                        expect(app, 'load', service, 'empty')
                        report['cleanup'].append({'variant': variant, 'app': app['app'].stem, 'verified': True})
                    except Exception:
                        cleanup_failed = True
                        report['cleanup'].append({'variant': variant, 'app': app['app'].stem, 'verified': False})
                try: expect(update, 'load', service, 'empty')
                except Exception: cleanup_failed = True
                persist()
                if cleanup_failed: raise RuntimeError('owning cleanup could not be fully verified')
    report['result'] = 'passed'
    if config:
        report['crossTeamQualified'] = report['otherProvisioned'] and report['otherSameTeam'] is False
        report['changedCertificateContinuityQualified'] = owner['certificate'].upper() != update['certificate'].upper()
    print('PASS:', len(report['checks']), 'checks;', 'authorized Apple-signed storage matrix' if config else 'unprovisioned fail-closed only', flush=True)
except Exception as error:
    report['result'] = 'failed'
    report['failureType'] = type(error).__name__
    if type(error) is RuntimeError: report['failureReason'] = str(error)
    print('FAIL:', type(error).__name__, '(sanitized evidence retained)', flush=True)
    raise SystemExit(1)
finally:
    persist()
