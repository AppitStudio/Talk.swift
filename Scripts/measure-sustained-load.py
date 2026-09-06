"""Opt-in bounded local SDK load; aggregate resources only, no credential persistence."""
from pathlib import Path
import os, subprocess, time, json, argparse, shutil, plistlib, signal, hashlib, uuid, atexit
from datetime import datetime, timezone
root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--standalone', action='store_true')
parser.add_argument('--sandboxed', action='store_true')
parser.add_argument('--scratch-path', type=Path, help='Use an already built SwiftPM scratch directory')
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
args = parser.parse_args()
if args.sandboxed and not args.standalone: parser.error('--sandboxed requires --standalone')
seconds = int(os.environ.get('TALK_SUSTAINED_SECONDS', '180'))
if not 5 <= seconds <= 1800: parser.error('TALK_SUSTAINED_SECONDS must be between 5 and 1800')
if not args.standalone and seconds > 300: parser.error('Runs over 300 seconds require --standalone')
variant = 'sandboxed' if args.sandboxed else 'standard'
prefix = 'standalone-' + variant if args.standalone else 'sustained'
started = datetime.now(timezone.utc)
run_id = started.strftime('%Y%m%dT%H%M%S.%fZ') + '-' + prefix + '-' + uuid.uuid4().hex[:8]
folder = root / 'LocalBuild/LoadValidation' / run_id
folder.mkdir(parents=True, exist_ok=False)
print('Evidence:', folder.relative_to(root), flush=True)
scratch = ['--scratch-path', str(args.scratch_path.resolve())] if args.scratch_path else []
command = ['swift', 'test', '-c', args.configuration, *scratch, '--skip-build', '--filter', 'sustainedIntegrationsReconnectOverflowAndRevocation']
metadata = {'startedUTC': started.isoformat(), 'variant': variant, 'standalone': args.standalone, 'configuration': args.configuration, 'requestedSeconds': seconds, 'rssCeilingKiB': 768*1024, 'watchdogSeconds': seconds+90, 'status': 'preparing'}
metadata_path = folder / 'run.json'
metadata_path.write_text(json.dumps(metadata, indent=2)+'\n')
def record_unfinished_run():
    if metadata['status'] in ('preparing', 'running'):
        metadata.update({'status': 'incomplete', 'completedUTC': datetime.now(timezone.utc).isoformat()})
        metadata_path.write_text(json.dumps(metadata, indent=2)+'\n')
atexit.register(record_unfinished_run)
process_name = 'swiftpm-testing-helper'
if args.standalone:
    binary_folder = Path(subprocess.check_output(['swift','build','-c',args.configuration,*scratch,'--show-bin-path'],cwd=root,text=True).strip())
    app = folder / ('Load-' + variant + '.app')
    contents = app / 'Contents'
    (contents/'MacOS').mkdir(parents=True,exist_ok=True)
    target = contents/'MacOS/TalkLoadProbe'
    shutil.copy2(binary_folder/'TalkLoadProbe', target)
    metadata['inputExecutableSHA256'] = hashlib.sha256(target.read_bytes()).hexdigest()
    (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.talk.synthetic.load.'+variant,'CFBundleExecutable':'TalkLoadProbe','CFBundlePackageType':'APPL'}))
    ent = folder / ('Load-' + variant + '.entitlements')
    ent.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,'com.apple.security.network.server':True} if args.sandboxed else {}))
    subprocess.run(['codesign','--force','--sign','-','--entitlements',str(ent),str(app)],check=True,capture_output=True)
    subprocess.run(['codesign','--verify','--strict',str(app)],check=True,capture_output=True)
    metadata['signedExecutableSHA256'] = hashlib.sha256(target.read_bytes()).hexdigest()
    command = [str(target)]
    process_name = 'TalkLoadProbe'
metadata['status'] = 'running'
metadata_path.write_text(json.dumps(metadata, indent=2)+'\n')
env = dict(os.environ, TALK_SUSTAINED_SECONDS=str(seconds))
samples = []
with (folder / (prefix + '.log')).open('x') as log:
    process = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    start = time.monotonic()
    failure = None
    try:
        while process.poll() is None:
            rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,%cpu=,comm='], text=True, timeout=10)
            entries = [line.split(None, 4) for line in rows.splitlines()]
            descendants = {process.pid}
            for _ in range(5):
                descendants.update(int(row[0]) for row in entries if len(row)==5 and int(row[1]) in descendants)
            for row in entries:
                if len(row)!=5 or int(row[0]) not in descendants or Path(row[4]).name != process_name: continue
                sockets = subprocess.run(['lsof','-nP','-a','-p',row[0],'-iTCP'],capture_output=True,text=True,timeout=10).stdout
                descriptors = subprocess.run(['lsof','-a','-p',row[0],'-Ff'],capture_output=True,text=True,timeout=10).stdout
                sample = {'seconds':round(time.monotonic()-start,2), 'rssKiB':int(row[2]), 'cpuPercent':float(row[3]),
                    'listeners':sockets.count('(LISTEN)'), 'established':sockets.count('(ESTABLISHED)'),
                    'numericFDs':sum(line[1:].isdigit() for line in descriptors.splitlines() if line.startswith('f'))}
                samples.append(sample)
                if sample['rssKiB'] > 768*1024: raise RuntimeError('768 MiB load safety ceiling exceeded')
            if time.monotonic()-start > seconds+90: raise RuntimeError('Load watchdog exceeded')
            time.sleep(2)
    except BaseException as error:
        failure = error
    finally:
        if process.poll() is None:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=5)
code = process.wait()
(folder/(prefix + '-resources.json')).write_text(json.dumps(samples,indent=2)+'\n')
summary = ['exit ' + str(code) + ' samples ' + str(len(samples))]
for field in ['rssKiB','cpuPercent','listeners','established','numericFDs']:
    values=[s[field] for s in samples]
    if values: summary.append(f'{field} min {min(values)} max {max(values)} first {values[0]} last {values[-1]}')
if not samples and failure is None: failure = RuntimeError('No test-process resource samples captured')
metadata.update({'completedUTC': datetime.now(timezone.utc).isoformat(), 'elapsedSeconds': round(time.monotonic()-start, 3),
                 'exitCode': code, 'sampleCount': len(samples), 'status': 'passed' if code == 0 and failure is None else 'failed'})
if failure is not None: metadata['harnessFailure'] = type(failure).__name__
metadata_path.write_text(json.dumps(metadata, indent=2)+'\n')
(folder/'summary.log').write_text('\n'.join(summary)+'\n')
print('\n'.join(summary), flush=True)
if failure is not None: raise failure
raise SystemExit(code)
