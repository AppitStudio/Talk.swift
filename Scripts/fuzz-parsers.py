"""Bounded deterministic parser mutations with AddressSanitizer; no live inputs.

This is not coverage-guided fuzzing. Apple Swift lacks arm64 libFuzzer support.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=300)
    args = parser.parse_args()
    if not 5 <= args.seconds <= 1800:
        parser.error('--seconds must be between 5 and 1800')
    root = Path(__file__).resolve().parent.parent
    parent = root / 'LocalBuild/FuzzValidation'
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
    print('Evidence:', folder.relative_to(root), flush=True)
    frozen = folder / 'Sources'; frozen.mkdir()
    files = [root / 'Sources/Talk' / (name + '.swift') for name in
             ['FrameCodec', 'TalkMessage', 'JSONValue', 'TalkError', 'PairingCredential', 'PairingInvitation']]
    files.append(root / 'Scripts/Probes/ParserFuzz.swift')
    files.append(root / 'Sources/TalkContractSchema/ContractSchema.swift')
    for path in files:
        shutil.copy2(path, frozen / path.name)
    shutil.copy2(__file__, folder / Path(__file__).name)
    summary = {'status': 'INCOMPLETE', 'requestedSeconds': args.seconds,
               'sourceHashes': {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
               'architecture': os.uname().machine, 'sanitizers': ['address'], 'coverageGuided': False, 'seed': 20260906}
    def save():
        (folder / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    save()
    binary = folder / 'ParserFuzz'
    result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-g', '-O',
                             '-sanitize=address', *[str(frozen / path.name) for path in files], '-o', str(binary)],
                            capture_output=True, text=True)
    (folder / 'build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    replay_outputs = []
    for _ in range(2):
        replay = subprocess.run([str(binary), '5'], capture_output=True, text=True, timeout=30,
                                env={**os.environ, 'TALK_FUZZ_REPLAY_CASE': '25000'})
        replay.check_returncode()
        replay_outputs.append(next(line for line in replay.stdout.splitlines() if line.startswith('mutation replay ')))
    if replay_outputs[0] != replay_outputs[1]:
        raise RuntimeError('cross-process mutation sequence is not deterministic')
    summary['deterministicReplay'] = replay_outputs[0]
    summary.update(status='RUNNING', binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
    save()
    command = [str(binary), str(args.seconds)]
    process = None
    try:
        with (folder / 'fuzzer.log').open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            import time
            started = time.monotonic()
            peak = 0
            while process.poll() is None:
                row = subprocess.run(['ps', '-p', str(process.pid), '-o', 'rss='], capture_output=True, text=True, timeout=5).stdout.strip()
                if row:
                    peak = max(peak, int(row))
                if peak > 768 * 1024 or time.monotonic() - started > args.seconds + 60:
                    raise RuntimeError('mutation RSS/watchdog ceiling exceeded')
                time.sleep(1)
            code = process.wait(timeout=3)
        summary.update(status='PASS' if code == 0 else 'FAIL', exitCode=code,
                       peakRSSKiB=peak)
        if code != 0:
            raise RuntimeError('mutation runner reported failure; replay retained seed/source sequence')
    except BaseException:
        summary['status'] = 'FAIL'
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=3)
        summary['ownedProcessExited'] = process is not None and process.poll() is not None
        save()
    print('PASS: bounded AddressSanitizer mutation run; deterministic seed/source retained', flush=True)


if __name__ == '__main__':
    main()
