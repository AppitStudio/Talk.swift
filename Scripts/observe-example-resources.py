"""Observe only Talk example processes; never read credentials or other app data."""
from pathlib import Path
import json
import subprocess
import time

root = Path(__file__).resolve().parent.parent
samples = []
for index in range(7):
    rows = []
    output = subprocess.check_output(['ps', '-axo', 'pid=,rss=,%cpu=,comm='], text=True)
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4 or not fields[3].startswith(str(root / 'LocalBuild/Apps')):
            continue
        product = Path(fields[3]).name
        if product not in {'TalkStudio', 'TalkAutomator'}:
            continue
        sockets = subprocess.run(['lsof', '-nP', '-a', '-p', fields[0], '-iTCP'], capture_output=True, text=True).stdout
        rows.append({'app': product, 'variant': 'sandboxed' if '/sandboxed/' in fields[3] else 'standard',
                     'rssKiB': int(fields[1]), 'cpuPercent': float(fields[2]),
                     'listeners': sockets.count('(LISTEN)'), 'established': sockets.count('(ESTABLISHED)'),
                     'onlyIPv4Loopback': all('127.0.0.1:' in row for row in sockets.splitlines()[1:])})
    samples.append({'elapsedSeconds': index * 5, 'processes': rows})
    if index < 6: time.sleep(5)
path = root / 'LocalBuild/example-resources.json'
path.write_text(json.dumps(samples, indent=2) + '\n')
for product in ['TalkStudio', 'TalkAutomator']:
    for variant in ['standard', 'sandboxed']:
        values = [row for sample in samples for row in sample['processes'] if row['app'] == product and row['variant'] == variant]
        if values:
            print(product, variant, 'samples', len(values), 'RSS KiB', min(v['rssKiB'] for v in values), max(v['rssKiB'] for v in values),
                  'CPU %', min(v['cpuPercent'] for v in values), max(v['cpuPercent'] for v in values),
                  'listeners', sorted(set(v['listeners'] for v in values)), 'established sockets', sorted(set(v['established'] for v in values)),
                  'IPv4 loopback only', all(v['onlyIPv4Loopback'] for v in values))
