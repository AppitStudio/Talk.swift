"""Observe bounded memory-only pressure/idle probes in standard or sandbox bundles."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['pressure', 'idle'])
    parser.add_argument('--sandboxed', action='store_true')
    parser.add_argument('--seconds', type=int)
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--scratch-path', type=Path)
    parser.add_argument('--memory-policy', choices=['rss', 'footprint'], default='rss',
                        help='footprint requires in-probe Mach metrics; keeps a separate 2 GiB RSS ceiling')
    args = parser.parse_args()
    seconds = args.seconds if args.seconds is not None else (60 if args.mode == 'pressure' else 600)
    minimum, maximum = (5, 300) if args.mode == 'pressure' else (310, 1800)
    if not minimum <= seconds <= maximum:
        parser.error('duration outside mode bounds')
    if args.mode == 'idle' and args.memory_policy == 'footprint':
        parser.error('idle mode uses RSS; in-probe footprint samples are pressure-only')
    root = Path(__file__).resolve().parent.parent
    parent = root / 'LocalBuild/ReadinessMeasurements'; parent.mkdir(parents=True, exist_ok=True)
    variant = 'sandboxed' if args.sandboxed else 'standard'
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + args.mode + '-' + variant + '-', dir=parent))
    print('Evidence:', folder.relative_to(root), flush=True)
    scratch = ['--scratch-path', str(args.scratch_path.resolve())] if args.scratch_path else []
    with (folder / 'build.log').open('w') as build_log:
        subprocess.run(['swift', 'build', '-c', 'release', '--arch', args.arch, *scratch,
                        '--product', 'TalkReadinessProbe'], cwd=root, stdout=build_log,
                       stderr=subprocess.STDOUT, check=True, timeout=300)
    binary_folder = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--arch', args.arch, *scratch, '--show-bin-path'], text=True, cwd=root).strip())
    app = folder / 'Readiness.app'; contents = app / 'Contents'; (contents / 'MacOS').mkdir(parents=True)
    target = contents / 'MacOS/TalkReadinessProbe'; shutil.copy2(binary_folder / 'TalkReadinessProbe', target)
    shutil.copy2(__file__, folder / Path(__file__).name)
    shutil.copy2(root / 'Sources/TalkReadinessProbe/Probe.swift', folder / 'Probe.swift')
    (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.talk.synthetic.readiness.' + variant,
        'CFBundleExecutable': 'TalkReadinessProbe', 'CFBundlePackageType': 'APPL'}))
    entitlements = folder / 'entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True, 'com.apple.security.network.server': True} if args.sandboxed else {}))
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)
    summary = {'status': 'RUNNING', 'mode': args.mode, 'variant': variant, 'requestedSeconds': seconds,
               'architecture': args.arch, 'pressureReliefControl': os.environ.get('TALK_READINESS_PRESSURE_RELIEF') == '1',
               'memoryPolicy': args.memory_policy, 'rssCeilingKiB': (768 if args.memory_policy == 'rss' else 2048) * 1024,
               'footprintCeilingKiB': 768 * 1024, 'watchdogSeconds': seconds + 90,
               'binarySHA256': hashlib.sha256(target.read_bytes()).hexdigest()}
    summary['sourceHashes'] = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                             for path in sorted((root / 'Sources/Talk').glob('*.swift'))}
    summary['sourceHashes']['Sources/TalkReadinessProbe/Probe.swift'] = hashlib.sha256((folder / 'Probe.swift').read_bytes()).hexdigest()
    def save():
        (folder / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    save()
    def read_memory():
        memory = [dict((key, int(value)) for key, value in re.findall(r'(\w+KiB)=(\d+)', line))
                  for line in (folder / 'probe.log').read_text().splitlines() if line.startswith('memory ')]
        if memory:
            summary['machMemoryPeaks'] = {key: max(item.get(key, 0) for item in memory) for key in memory[-1]}
            summary['machMemoryLast'] = memory[-1]
            if summary['machMemoryPeaks'].get('peakFootprintKiB', 0) > 768 * 1024:
                raise RuntimeError('physical footprint ceiling exceeded')
    samples = []
    process = None
    try:
        with (folder / 'probe.log').open('w') as log, (folder / 'resources.jsonl').open('w') as resource_log:
            process = subprocess.Popen([str(target), args.mode], stdout=log, stderr=subprocess.STDOUT,
                                       env={**os.environ, 'TALK_READINESS_SECONDS': str(seconds)})
            started = time.monotonic()
            while process.poll() is None:
                if time.monotonic() - started > seconds + 90:
                    raise RuntimeError('watchdog exceeded')
                row = subprocess.run(['ps', '-p', str(process.pid), '-o', 'rss=,%cpu='], capture_output=True, text=True, timeout=5).stdout.split()
                if len(row) == 2:
                    sockets = subprocess.run(['lsof', '-nP', '-a', '-p', str(process.pid), '-iTCP'], capture_output=True, text=True, timeout=5).stdout
                    descriptors = subprocess.run(['lsof', '-a', '-p', str(process.pid), '-Ff'], capture_output=True, text=True, timeout=5).stdout
                    sample = {'seconds': round(time.monotonic() - started, 3), 'rssKiB': int(row[0]), 'cpuPercent': float(row[1]),
                              'listeners': sockets.count('(LISTEN)'), 'established': sockets.count('(ESTABLISHED)'),
                              'numericFDs': sum(line[1:].isdigit() for line in descriptors.splitlines() if line.startswith('f'))}
                    samples.append(sample)
                    resource_log.write(json.dumps(sample) + '\n'); resource_log.flush()
                    # RSS can include clean reusable allocator pages. The explicit
                    # footprint mode preserves both metrics and the old failed runs.
                    read_memory()
                    if sample['rssKiB'] > summary['rssCeilingKiB']:
                        raise RuntimeError('RSS ceiling exceeded')
                time.sleep(2)
            code = process.wait(timeout=3)
        log_text = (folder / 'probe.log').read_text()
        read_memory()  # Include the final cooldown sample written immediately before exit.
        if code != 0 or 'result=PASS' not in log_text or not samples:
            raise RuntimeError('probe failed or evidence missing')
        if args.memory_policy == 'footprint' and not summary.get('machMemoryPeaks', {}).get('peakFootprintKiB'):
            raise RuntimeError('required Mach physical footprint evidence missing')
        summary.update(status='PASS', exitCode=code, elapsedSeconds=round(time.monotonic() - started, 3))
    except BaseException as error:
        summary.update(status='FAIL', errorType=type(error).__name__)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=3)
        summary['ownedProcessExited'] = process is not None and process.poll() is not None
        summary['samples'] = len(samples)
        if samples:
            summary['peaks'] = {key: max(sample[key] for sample in samples) for key in ['rssKiB', 'cpuPercent', 'listeners', 'established', 'numericFDs']}
            summary['lastSample'] = samples[-1]
        save()
    print(args.mode + ' ' + variant + ': PASS; owned process exited', flush=True)


if __name__ == '__main__':
    main()
