"""Build both example variants with the production Keychain backend.
Requires explicitly authorized existing Apple signing material. All four bundles
are staged and verified before promotion. No Git/account/upload operation.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import importlib.util
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('apple_signing', Path(__file__).with_name('apple-signing.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--signing-config', required=True, type=Path, help='Private config containing certificate/profile (or a probe config with owner)')
parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
parser.add_argument('--signing-timeout', type=int, default=120, choices=range(1, 301), metavar='SECONDS')
args = parser.parse_args()
parent = root / 'LocalBuild/ExampleBuilds'
parent.mkdir(parents=True, exist_ok=True)
work = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), suffix='.noindex', dir=parent))
work.chmod(0o700)
print('Evidence:', work.relative_to(root), flush=True)

def no_running_apps():
    for name in ['TalkStudio', 'TalkAutomator']:
        if subprocess.run(['pgrep', '-x', name], capture_output=True).returncode == 0:
            raise RuntimeError('Quit all Talk example apps before packaging')

try:
    no_running_apps()
    config = json.loads(args.signing_config.read_text())
    template = config.get('owner', config)
    # Validate every exact identity before building/signing any bundle.
    entries = []
    for variant in ['standard', 'sandboxed']:
        suffix = '.sandbox' if variant == 'sandboxed' else ''
        for product, name, identity, scheme in [
            ('TalkStudio', 'Talk Studio', 'studio', 'talk-spike-provider'),
            ('TalkAutomator', 'Talk Automator', 'automator', 'talk-spike-consumer')]:
            identity_config = {**template, 'identifier': 'dev.talk.examples.paired.' + identity + suffix}
            signing.profile_entitlements(identity_config)
            entries.append((variant, product, name, scheme, identity_config))
    result = subprocess.run(['swift', 'build', '-c', args.configuration], cwd=root, capture_output=True)
    (work / 'build.log').write_bytes(result.stdout + result.stderr)
    if result.returncode: raise RuntimeError('Example compilation failed')
    binaries = Path(subprocess.check_output(['swift', 'build', '-c', args.configuration, '--show-bin-path'], cwd=root, text=True).strip())
    stage = work / 'Apps'
    for variant, product, name, scheme, identity_config in entries:
        display = name + (' Sandbox' if variant == 'sandboxed' else '')
        app = stage / variant / (display + '.app')
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        shutil.copy2(binaries / product, contents / 'MacOS' / product)
        info = {'CFBundleIdentifier': identity_config['identifier'], 'CFBundleName': display,
                'CFBundleDisplayName': display, 'CFBundleExecutable': product, 'CFBundlePackageType': 'APPL',
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '3', 'LSMinimumSystemVersion': '12.4',
                'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication', 'TalkExampleVariant': variant,
                'CFBundleURLTypes': [{'CFBundleURLName': identity_config['identifier'], 'CFBundleURLSchemes': [scheme]}]}
        if product == 'TalkStudio':
            info['TalkContract'] = 'Contract.talk.json'
            subprocess.run([str(binaries / 'TalkSchemaExporter'), str(root / 'Examples/Shared/StudioContract/Contract.talk.json'),
                str(contents / 'Resources/Contract.talk.json')], check=True, capture_output=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        signing.sign(app, identity_config, sandboxed=variant == 'sandboxed', networking=True, timeout=args.signing_timeout)
        print(variant, product, 'signature verified', flush=True)
    no_running_apps()
    destination = root / 'LocalBuild/Apps'
    backup = work / 'PreviousApps.noindex'
    existed = destination.exists()
    if existed: destination.rename(backup)
    try: stage.rename(destination)
    except BaseException:
        if existed: backup.rename(destination)
        raise
    (work / 'summary.json').write_text(json.dumps({'result': 'passed', 'bundles': 4, 'backend': 'data-protection',
        'configuration': args.configuration, 'previousBundlesRetained': existed}, indent=2) + '\n')
    print('PASS: four provisioned example bundles promoted; previous bundles retained outside source.', flush=True)
except Exception as error:
    (work / 'summary.json').write_text(json.dumps({'result': 'failed', 'failureType': type(error).__name__, 'failureReason': str(error) if type(error) is RuntimeError else 'configuration-or-tool-failure'}, indent=2) + '\n')
    print('FAIL:', type(error).__name__, '(sanitized evidence retained; check running apps, profile scope or macOS signing approval)', flush=True)
    raise SystemExit(1)
