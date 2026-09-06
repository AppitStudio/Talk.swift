"""Actual simultaneous duplicate app processes, with owned disposable identities.

Tests EndpointResolver.reply via AppKit delivery, without pairing or Keychain data.
Only owned app registrations/processes are created and removed.
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
    def __init__(self, bundle, callback_id):
        self.process = subprocess.Popen([str(bundle / 'Contents/MacOS/CallbackRouting'), callback_id],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        env={**os.environ, 'TALK_TRANSPORT_DIAGNOSTICS': '1'})
        self.buffer = b''
        try:
            assert self.receive() == {'ready': True}, 'app did not finish launching'
        except Exception:
            self.close()
            raise

    def receive(self):
        deadline = time.monotonic() + 10
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError('app control watchdog')
            data = os.read(self.process.stdout.fileno(), 4096)
            if not data:
                raise RuntimeError('app exited without reply')
            self.buffer += data
            assert len(self.buffer) < 8192, 'control bound exceeded'
        line, self.buffer = self.buffer.split(b'\n', 1)
        reply = json.loads(line)
        assert 'failed' not in reply, 'app command failed'
        return reply

    def command(self, command):
        self.process.stdin.write(command.encode() + b'\n')
        self.process.stdin.flush()
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            try:
                assert self.command('stop') == {'stopped': True}
                self.process.wait(timeout=3)
            except (OSError, RuntimeError, AssertionError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(timeout=3)
        self.process.stdin.close(); self.process.stdout.close()


def eventually(read, predicate):
    deadline = time.monotonic() + 5
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError('bounded observation failed: ' + json.dumps(value))
        time.sleep(0.05)


def main():
    parent = ROOT / 'LocalBuild/CallbackValidation'
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
    print('Evidence:', folder.relative_to(ROOT), flush=True)
    frozen = folder / 'Sources'
    frozen.mkdir()
    paths = [ROOT / 'Sources/Talk' / (name + '.swift') for name in
             ['EndpointResolver', 'PairingCredential', 'PairingRecord', 'TalkError', 'Deadline', 'DeadlineTimer', 'TransportDiagnostics']]
    paths.append(ROOT / 'Scripts/Probes/CallbackRouting.swift')
    for path in paths:
        shutil.copy2(path, frozen / path.name)
    shutil.copy2(__file__, folder / Path(__file__).name)
    metadata = {'status': 'INCOMPLETE', 'system': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
                'architecture': os.uname().machine, 'scenarios': [],
                'source_hashes': {path.name: hashlib.sha256((frozen / path.name).read_bytes()).hexdigest() for path in paths}}
    def save():
        (folder / 'summary.json').write_text(json.dumps(metadata, indent=2) + '\n')
    save()
    result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                             *[str(frozen / path.name) for path in paths], '-o', str(folder / 'CallbackRouting')],
                            capture_output=True, text=True)
    (folder / 'build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    assert 'warning:' not in result.stderr, 'unexpected build warning'
    apps = []
    identities = []
    def bundle(name, bundle_id, sandboxed):
        app = folder / (name + '.app')
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        shutil.copy2(folder / 'CallbackRouting', contents / 'MacOS/CallbackRouting')
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'CallbackRouting',
            'CFBundlePackageType': 'APPL', 'LSUIElement': True, 'LSMinimumSystemVersion': '13.0',
            # Match the SDK's actual callback protocol in the receiver's plist.
            'CFBundleURLTypes': [{'CFBundleURLSchemes': ['talk-spike-consumer'] if name.startswith('Consumer-') else ['talk-validation-' + token]}]}))
        entitlement = folder / (name + '.entitlements')
        entitlement.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True,
                                               'com.apple.security.network.client': True,
                                               'com.apple.security.network.server': True} if sandboxed else {}))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlement), str(app)], check=True, capture_output=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)
        apps.append(app)
        subprocess.run([LSREGISTER, '-f', str(app)], check=True, capture_output=True)
        return app
    try:
        for provider_sandbox in [False, True]:
            for consumer_sandbox in [False, True]:
                token = uuid.uuid4().hex
                callback_id = 'dev.talk.synthetic.routing.consumer.' + token
                identities.append(callback_id)
                identities.append('dev.talk.synthetic.routing.provider.' + token)
                router_bundle = bundle('Router-' + token, 'dev.talk.synthetic.routing.provider.' + token, provider_sandbox)
                consumer_bundle = bundle('Consumer-' + token, callback_id, consumer_sandbox)
                duplicate_bundle = folder / ('Copy-' + token + '.app')
                shutil.copytree(consumer_bundle, duplicate_bundle)
                apps.append(duplicate_bundle)
                subprocess.run([LSREGISTER, '-f', str(duplicate_bundle)], check=True, capture_output=True)
                for same_path in [False, True]:
                    row = dict(provider_sandbox=provider_sandbox, consumer_sandbox=consumer_sandbox,
                               same_path=same_path, status='INCOMPLETE')
                    metadata['scenarios'].append(row); save()
                    processes = []
                    try:
                        router = App(router_bundle, callback_id); processes.append(router)
                        first = App(consumer_bundle, callback_id); processes.append(first)
                        eventually(lambda: router.command('running'), lambda value: value['running'] == 1 and value['knownURLs'])
                        router.command('reply')
                        eventually(lambda: first.command('state'), lambda value: value == {'received': 1, 'invalid': 0})
                        second = App(consumer_bundle if same_path else duplicate_bundle, callback_id); processes.append(second)
                        assert first.process.pid != second.process.pid
                        row['duplicates'] = eventually(lambda: router.command('running'),
                            lambda value: value['running'] == 2 and value['knownURLs'] and value['samePath'] == same_path)
                        router.command('reply')
                        # Silence alone is not denial proof. Require stable duplicate
                        # enumeration plus positive delivery before and after removal.
                        time.sleep(2)
                        assert first.command('state') == {'received': 1, 'invalid': 0}
                        assert second.command('state') == {'received': 0, 'invalid': 0}
                        assert router.command('running') == row['duplicates']
                        second.close()
                        eventually(lambda: router.command('running'), lambda value: value['running'] == 1)
                        router.command('reply')
                        eventually(lambda: first.command('state'), lambda value: value == {'received': 2, 'invalid': 0})
                        row.update(status='PASS', positive_deliveries=2, duplicate_deliveries=0, observation_seconds=2)
                        print('PASS providerSandbox=' + str(provider_sandbox) + ' consumerSandbox=' + str(consumer_sandbox) + ' samePath=' + str(same_path), flush=True)
                    finally:
                        if processes and processes[0].process.poll() is None:
                            try:
                                row['router_diagnostics'] = processes[0].command('diagnostics')
                            except Exception as error:
                                row['diagnostic_collection_error'] = type(error).__name__
                        for process in reversed(processes):
                            process.close()
                        row['owned_processes_exited'] = all(process.process.poll() is not None for process in processes)
                        save()
        metadata['status'] = 'PASS'
    except Exception as error:
        metadata.update(status='FAIL', error=str(error))
        raise
    finally:
        cleanup = []
        for app in apps:
            result = subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)
            cleanup.append(result.returncode == 0)
            # Retain signed bytes while excluding probe bundles from indexing.
            app.rename(app.with_suffix('.app.noindex'))
        metadata['owned_registration_removal_succeeded'] = all(cleanup)
        metadata['inventory_after_cleanup'] = [json.loads(subprocess.check_output(
            [str(folder / 'CallbackRouting'), 'inventory', identity], text=True)) for identity in identities]
        if any(value != {'registered': 0, 'running': 0} for value in metadata['inventory_after_cleanup']):
            metadata['status'] = 'FAIL'
        if not all(cleanup):
            metadata['status'] = 'FAIL'
        save()
    assert metadata['status'] == 'PASS', 'cleanup failed'


if __name__ == '__main__':
    main()
