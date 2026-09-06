"""Explicit local Apple signing with existing profiles; no account or trust edits.
Identity/profile metadata is read in memory and never printed. Callers must have
user authorization before using the signing key. Errors contain fixed messages.
"""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import plistlib
import re
import shutil
import subprocess


def profile_entitlements(config):
    certificate = config.get('certificate', '')
    identifier = config.get('identifier', '')
    if not re.fullmatch(r'[a-fA-F0-9]{40}', certificate) or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', identifier):
        raise ValueError('Invalid certificate selector or app identifier')
    profile = Path(config['profile']).expanduser()
    result = subprocess.run(['security', 'cms', '-D', '-i', str(profile)], capture_output=True, timeout=15)
    if result.returncode: raise ValueError('Cannot decode provisioning profile')
    data = plistlib.loads(result.stdout)
    if data['ExpirationDate'].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError('Provisioning profile expired')
    allowed = data['Entitlements']
    if certificate.upper() not in [hashlib.sha1(c).hexdigest().upper() for c in data['DeveloperCertificates']]:
        raise ValueError('Signing certificate is not in the provisioning profile')
    pattern = allowed['com.apple.application-identifier']
    group = pattern.split('.')[0] + '.' + identifier
    def permits(pattern, value):
        return pattern == value or (pattern.endswith('.*') and value.startswith(pattern[:-1]))
    if not permits(pattern, group): raise ValueError('Profile does not authorize this app identifier')
    if not any(permits(g, group) for g in allowed.get('keychain-access-groups', [])):
        raise ValueError('Profile does not authorize the app-specific Keychain group')
    return {'com.apple.application-identifier': group,
            'com.apple.developer.team-identifier': allowed['com.apple.developer.team-identifier'],
            'keychain-access-groups': [group]}


def sign(app, config, sandboxed=False, networking=False, timeout=120):
    app = Path(app)
    entitlements = profile_entitlements(config)
    if sandboxed:
        entitlements['com.apple.security.app-sandbox'] = True
        if networking:
            entitlements['com.apple.security.network.client'] = True
            entitlements['com.apple.security.network.server'] = True
    # No get-task-allow, library-validation exception, shared group or trust override.
    shutil.copy2(Path(config['profile']).expanduser(), app / 'Contents/embedded.provisionprofile')
    path = app.with_suffix('.entitlements.private.plist')
    path.write_bytes(plistlib.dumps(entitlements))
    path.chmod(0o600)
    result = subprocess.run(['codesign', '--force', '--sign', config['certificate'], '--options', 'runtime',
        '--timestamp=none', '--entitlements', str(path), str(app)], capture_output=True, timeout=timeout)
    if result.returncode: raise RuntimeError('Apple signing failed')
    # Include the actual configured certificate and identifier in verification.
    requirement = 'certificate leaf = H"' + config['certificate'] + '" and identifier "' + config['identifier'] + '" and anchor apple generic'
    result = subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(app)], capture_output=True, timeout=30)
    if result.returncode: raise RuntimeError('Apple signature verification failed')
    result = subprocess.run(['codesign', '--display', '--verbose=4', str(app)], capture_output=True, timeout=15)
    match = re.search(rb'^TeamIdentifier=([^\r\n]+)$', result.stderr, re.MULTILINE)
    if result.returncode or not match or match.group(1).decode('ascii') != entitlements['com.apple.developer.team-identifier']:
        raise RuntimeError('Signed code team does not match the authorized profile')
    return entitlements['com.apple.application-identifier']
