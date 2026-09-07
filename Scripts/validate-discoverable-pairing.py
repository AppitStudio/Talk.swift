"""Actual AppKit discovery/key agreement/TLS in four sandbox combinations.

Disposable ad-hoc apps; no protected storage or existing user app changes.
Verification codes exist only in anonymous pipes and are never saved as evidence.
"""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import plistlib
import select
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

class App:
    def __init__(self, bundle, peer_id, peer_bundle):
        self.process = subprocess.Popen([str(bundle / 'Contents/MacOS/PairingProbe'), peer_id, str(peer_bundle)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.buffer = b''
        assert self.receive() == {'ready': True}, 'launch failed'

    def receive(self):
        deadline = time.monotonic() + 15
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError('app control watchdog')
            chunk = os.read(self.process.stdout.fileno(), 4096)
            if not chunk:
                raise RuntimeError('app exited without reply')
            self.buffer += chunk
            assert len(self.buffer) < 8192, 'control bound exceeded'
        line, self.buffer = self.buffer.split(b'\n', 1)
        value = json.loads(line)
        assert 'failed' not in value, 'app command failed'
        return value

    def command(self, value):
        self.process.stdin.write(value.encode() + b'\n')
        self.process.stdin.flush()
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            try:
                self.command('stop')
                self.process.wait(timeout=3)
            except Exception:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(timeout=3)
        self.process.stdin.close(); self.process.stdout.close()

def eventually(app, predicate):
    deadline = time.monotonic() + 8
    while True:
        value = app.command('state')
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError('bounded observation failed')
        time.sleep(0.05)

def main():
    parent = ROOT / 'LocalBuild/DiscoverablePairing'
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), suffix='.noindex', dir=parent))
    print('Evidence:', folder.relative_to(ROOT), flush=True)
    scratch = folder / 'Build'
    with (folder / 'sdk-build.log').open('w') as log:
        subprocess.run(['swift', 'build', '-c', 'release', '--scratch-path', str(scratch)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    products = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--scratch-path', str(scratch), '--show-bin-path'], cwd=ROOT, text=True).strip())
    probe = ROOT / 'Scripts/Probes/DiscoverablePairing.swift'
    shutil.copy2(probe, folder / probe.name)
    shutil.copy2(__file__, folder / Path(__file__).name)
    objects = list((products / 'Talk.build').glob('*.o')) + list((products / 'TalkContractSchema.build').glob('*.o'))
    result = subprocess.run(['xcrun', 'swiftc', '-target', f'{os.uname().machine}-apple-macosx12.4', '-parse-as-library', '-swift-version', '6',
                             '-I', str(products / 'Modules'), str(folder / probe.name), *map(str, objects), '-o', str(folder / 'PairingProbe')],
                            capture_output=True, text=True)
    (folder / 'probe-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    assert 'warning:' not in result.stderr, 'unexpected compiler warning'
    summary = {'status': 'INCOMPLETE', 'system': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
               'source_hashes': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT / 'Sources').rglob('*.swift')},
               'callback_policy': 'generic-unique-running', 'scenarios': []}
    def save(): (folder / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    apps = []
    def bundle(name, identity, sandboxed):
        app = folder / (name + '.app')
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        shutil.copy2(folder / 'PairingProbe', contents / 'MacOS/PairingProbe')
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identity, 'CFBundleExecutable': 'PairingProbe', 'CFBundlePackageType': 'APPL',
            'LSUIElement': True, 'LSMinimumSystemVersion': '12.4',
            'CFBundleURLTypes': [{'CFBundleURLSchemes': ['talk-spike-provider', 'talk-spike-consumer']}]}))
        entitlements = folder / (name + '.entitlements')
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True, 'com.apple.security.network.server': True} if sandboxed else {}))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True, capture_output=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)
        apps.append(app)
        subprocess.run([LSREGISTER, '-f', str(app)], check=True, capture_output=True)
        return app
    save()
    try:
        for provider_sandbox in [False, True]:
            for consumer_sandbox in [False, True]:
                token = uuid.uuid4().hex
                provider_id = 'dev.talk.synthetic.pairing.provider.' + token
                consumer_id = 'dev.talk.synthetic.pairing.consumer.' + token
                provider_bundle = bundle('Provider-' + token, provider_id, provider_sandbox)
                consumer_bundle = bundle('Consumer-' + token, consumer_id, consumer_sandbox)
                row = {'provider_sandbox': provider_sandbox, 'consumer_sandbox': consumer_sandbox, 'status': 'INCOMPLETE'}
                summary['scenarios'].append(row); save()
                peers = []
                try:
                    provider = App(provider_bundle, consumer_id, consumer_bundle); peers.append(provider)
                    consumer = App(consumer_bundle, provider_id, provider_bundle); peers.append(consumer)
                    assert consumer.command('discover')['discovered'] is False, 'discovery outside pairing mode'
                    row['mode_off_denied'] = True
                    for decision in ['deny', 'allow', 'cancel']:
                        assert provider.command('start') == {'started': True}
                        assert consumer.command('discover') == {'discovered': True}
                        assert consumer.command('connect') == {'connecting': True}
                        provider_state = eventually(provider, lambda s: s['pending'])
                        consumer_state = consumer.command('state')
                        assert provider_state['code'] and provider_state['code'] == consumer_state['code'], 'verification mismatch'
                        assert not provider_state['discoverable'], 'consumed session still discoverable'
                        if decision == 'cancel':
                            consumer.command('cancel')
                            eventually(provider, lambda s: not s['pending'])
                        else:
                            provider.command(decision)
                            expected = 'paired' if decision == 'allow' else 'permissionDenied'
                            eventually(consumer, lambda s: s['result'] == expected)
                        row[decision] = 'PASS'
                    provider.command('cancel')
                    assert not provider.command('state')['discoverable']
                    row['status'] = 'PASS'
                    print('PASS providerSandbox=' + str(provider_sandbox) + ' consumerSandbox=' + str(consumer_sandbox), flush=True)
                finally:
                    for peer in reversed(peers): peer.close()
                    row['owned_processes_exited'] = all(p.process.poll() is not None for p in peers)
                    save()
        summary['status'] = 'PASS'
    except Exception as error:
        summary.update(status='FAIL', error=type(error).__name__)
        raise
    finally:
        cleanup = [subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True).returncode == 0 for app in apps]
        summary['registrations_removed'] = all(cleanup)
        save()

if __name__ == '__main__': main()
