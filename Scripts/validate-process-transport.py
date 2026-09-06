"""Separate-process source-port role reversal using actual SDK sources.

Synthetic credentials and numeric endpoints travel only in anonymous pipes.
Evidence contains sanitized results; no Keychain, registrations or native app edits.
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
import argparse

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ['TalkConnection', 'TLSConfiguration', 'PairedTLSIdentity', 'PairingCredential',
           'TalkMessage', 'FrameCodec', 'JSONValue', 'TalkError', 'Deadline', 'DeadlineTimer',
           'TransportDiagnostics', 'TransportDiagnosticBuffer']


class Peer:
    def __init__(self, executable, role):
        self.process = subprocess.Popen([str(executable), role], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        env={**os.environ, 'TALK_TRANSPORT_DIAGNOSTICS': '1'})
        self.buffer = b''

    def send(self, operation, **fields):
        self.process.stdin.write(json.dumps(dict(operation=operation, **fields)).encode() + b'\n')
        self.process.stdin.flush()

    def receive(self, expected='ok'):
        deadline = time.monotonic() + 10
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError('watchdog: no control reply')
            data = os.read(self.process.stdout.fileno(), 4096)
            if not data:
                raise RuntimeError('probe exited without reply')
            self.buffer += data
            if len(self.buffer) > 65536:
                raise RuntimeError('control reply exceeded bound')
        line, self.buffer = self.buffer.split(b'\n', 1)
        reply = json.loads(line)
        if reply.get('result') != expected:
            # Never include the complete control reply: it can hold secrets.
            raise RuntimeError('probe failure: ' + str(reply.get('result')) +
                               '; diagnostics=' + json.dumps(reply.get('diagnostics', [])))
        return reply

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.process.stdin.close()
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--without-source-binding', action='store_true', help='Control: remove only the outgoing assignment in the frozen source copy')
    args = parser.parse_args()
    parent = ROOT / 'LocalBuild/ProcessValidation'
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
    print('Evidence:', folder.relative_to(ROOT), flush=True)
    frozen = folder / 'Sources'
    frozen.mkdir()
    inputs = [ROOT / 'Sources/Talk' / (name + '.swift') for name in SOURCES]
    inputs += [ROOT / 'Scripts/Probes/ProcessTransport.swift']
    for path in inputs:
        shutil.copy2(path, frozen / path.name)
    if args.without_source_binding:
        path = frozen / 'TalkConnection.swift'
        assignment = '        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)\n'
        source = path.read_text()
        assert source.count(assignment) == 1
        path.write_text(source.replace(assignment, ''))
    shutil.copy2(__file__, folder / Path(__file__).name)
    metadata = {'status': 'INCOMPLETE', 'trials_per_combination': 16,
                'outgoing_source_binding': not args.without_source_binding,
                'system': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
                'architecture': os.uname().machine,
                'source_hashes': {path.name: hashlib.sha256((frozen / path.name).read_bytes()).hexdigest() for path in inputs},
                'combinations': []}
    summary = folder / 'summary.json'
    def save():
        summary.write_text(json.dumps(metadata, indent=2) + '\n')
    save()
    command = ['xcrun', 'swiftc', '-target', f'{os.uname().machine}-apple-macosx12.4', '-parse-as-library', '-swift-version', '6',
               *[str(frozen / path.name) for path in inputs], '-o', str(folder / 'ProcessTransport')]
    result = subprocess.run(command, capture_output=True, text=True)
    (folder / 'build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    assert 'warning:' not in result.stderr, 'unexpected build warning'
    executables = {}
    for variant in ['standard', 'sandboxed']:
        app = folder / (variant + '.app')
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        target = contents / 'MacOS/ProcessTransport'
        shutil.copy2(folder / 'ProcessTransport', target)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.talk.synthetic.process-transport.' + variant,
            'CFBundleExecutable': 'ProcessTransport', 'CFBundlePackageType': 'APPL',
            'LSMinimumSystemVersion': '12.4'}))
        entitlements = folder / (variant + '.entitlements')
        entitlements.write_bytes(plistlib.dumps({
            'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True,
            'com.apple.security.network.server': True} if variant == 'sandboxed' else {}))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True, capture_output=True)
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)
        executables[variant] = target
    metadata['binary_hashes'] = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in executables.items()}
    try:
        for provider_variant in executables:
            for consumer_variant in executables:
                row = dict(provider=provider_variant, consumer=consumer_variant, completed=0,
                           exchanges=0, reconnects=0, status='INCOMPLETE')
                metadata['combinations'].append(row)
                save()
                peers = []
                try:
                    provider = Peer(executables[provider_variant], 'provider'); peers.append(provider)
                    consumer = Peer(executables[consumer_variant], 'consumer'); peers.append(consumer)
                    assert provider.process.pid != consumer.process.pid
                    row['distinct_processes'] = True
                    for trial in range(16):
                        provider.send('listen')
                        offer = provider.receive()
                        credential = offer['credential']
                        provider.send('seed')
                        consumer.send('seed', credential=credential, port=offer['port'])
                        source = consumer.receive()['port']
                        provider.receive()
                        consumer.send('closeSeed'); consumer.receive()
                        provider.send('replace', credential=credential, port=source); provider.receive()
                        # Two new connections with the same credential and endpoint;
                        # every exchange is required, never a recovery of a failure.
                        for _ in range(2):
                            provider.send('exchange')
                            consumer.send('exchange', credential=credential, port=source)
                            consumer.receive(); provider.receive()
                            row['exchanges'] += 8
                        row['reconnects'] += 1
                        # Wrong-key control on this final unchanged listener. Both
                        # peers must reject and client must record TLS pin failure.
                        if trial == 15:
                            provider.send('reject')
                            consumer.send('reject', credential=credential, port=source)
                            negative = consumer.receive('rejected')
                            server_negative = provider.receive('rejected')
                            events = negative.get('diagnostics', [])
                            row['negative_control'] = {'client': events, 'provider': server_negative.get('diagnostics', [])}
                            save()
                            assert any('trust rejected stage=chain-or-pin' in event for event in events), 'missing actual pin rejection'
                            assert any('tls:' in event for event in events), 'missing numeric TLS failure'
                        row['completed'] += 1
                        save()
                    for peer in peers:
                        peer.send('stop'); peer.receive()
                        assert peer.process.wait(timeout=3) == 0
                    row['status'] = 'PASS'
                    print(provider_variant + ' -> ' + consumer_variant + ': PASS 16 role reversals, 256 round trips, 16 reconnects, wrong-key denial', flush=True)
                finally:
                    for peer in peers:
                        peer.close()
                    row['owned_processes_exited'] = all(peer.process.poll() is not None for peer in peers)
                    save()
        metadata['status'] = 'PASS'
    except Exception as error:
        metadata['status'] = 'FAIL'
        metadata['error'] = str(error)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
