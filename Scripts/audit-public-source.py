"""Audit the public source allowlist, links, and optionally the exact Git index.

--stage creates a source-only local review copy. Nothing is published by this tool.
Pattern checks supplement human review and dedicated secret scanning.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--stage', action='store_true', help='Create a source-only local review copy')
parser.add_argument('--check-index', action='store_true', help='Require the Git index to match audited working files exactly')
args = parser.parse_args()
folders = ['Sources', 'Tests', 'Examples', 'Plugins', 'Scripts', 'Skills']
root_files = ['Package.swift', 'README.md', 'SECURITY.md', 'CONTRIBUTING.md', '.gitignore', '.gitattributes']
doc_files = [
    'DISCOVERABLE-PAIRING.md', 'INSTALLATION.md', 'INTEGRATION-GUIDE.md', 'EXAMPLES.md', 'LLM-INTEGRATION.md',
    'CONTRACTS.md', 'CREDENTIAL-LIFECYCLE.md', 'SECURITY-NOTES.md',
    'BETA-READINESS.md', 'QUALIFICATION.md', 'LOCAL-HARDENING.md',
    'READINESS-VALIDATION.md', 'PROCESS-VALIDATION.md',
]
if (root / 'LICENSE').exists():
    root_files.append('LICENSE')
suffixes = {'.swift', '.c', '.h', '.py', '.sh', '.md', '.json', '.txt', '.yaml'}
patterns = {
    'host-path': re.compile(r'/(?:Users|home|Volumes)/[A-Za-z0-9_.-]+/'),
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'github-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'service-secret': re.compile(r'\b(?:sk_live_|rk_live_)[A-Za-z0-9]{16,}\b'),
    'aws-access-key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'slack-token': re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
    'credential-url': re.compile(r'https?://[^\s/:]+:[^\s/@]+@'),
    'encoded-pairing': re.compile(r'talk-pair-v1:[A-Za-z0-9+/]{30,}={0,2}'),
    'private-evidence-reference': re.compile(r'LocalBuild/[^\s`]*20\d{6}T\d{6}'),
}
files = [root / p for p in root_files] + [root / 'Docs' / p for p in doc_files]
issues = []


def issue(path, kind):
    # Locations only: never print matching credential or private data values.
    issues.append({'file': str(path.relative_to(root)), 'kind': kind})


for folder in folders:
    directory = root / folder
    if directory.is_symlink() or not directory.is_dir():
        issue(directory, 'missing-or-symlink-directory')
        continue
    for p in directory.rglob('*'):
        if '__pycache__' in p.parts:
            continue
        if p.is_symlink():
            issue(p, 'symlink')
        elif p.is_file():
            if p.suffix not in suffixes or '.private.' in p.name:
                issue(p, 'unapproved-file-type')
            elif p.suffix == '.yaml' and p.relative_to(root).as_posix() != 'Skills/talk-integrations/agents/openai.yaml':
                issue(p, 'unapproved-yaml')
            else:
                files.append(p)
        elif not p.is_dir():
            issue(p, 'special-file')

files = sorted(set(files))
manifest = {}
texts = {}
for p in files:
    if not p.is_file() or p.is_symlink() or any(parent.is_symlink() for parent in p.parents if parent != root):
        issue(p, 'missing-or-symlink')
        continue
    if p.stat().st_size > 1_048_576:
        issue(p, 'oversized-source')
        continue
    data = p.read_bytes()
    try:
        content = data.decode('utf-8')
    except UnicodeDecodeError:
        issue(p, 'binary')
        continue
    if '\0' in content:
        issue(p, 'binary')
        continue
    manifest[p.relative_to(root).as_posix()] = hashlib.sha256(data).hexdigest()
    texts[p] = content
    for name, pattern in patterns.items():
        if pattern.search(content):
            issue(p, name)

# Check against publishable paths, not the private workspace's existing files.
published = set(manifest)
published_dirs = {parent.as_posix() for name in published for parent in Path(name).parents}
for p, content in texts.items():
    if p.suffix != '.md':
        continue
    without_code = re.sub(r'```.*?```', '', content, flags=re.S)
    for target in re.findall(r'\[[^\]\n]+\]\(([^\s)]+)\)', without_code):
        link = urlsplit(target.strip('<>'))
        if link.scheme or link.netloc or not link.path:
            continue
        resolved = (p.parent / unquote(link.path)).resolve()
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError:
            issue(p, 'link-outside-repository')
            continue
        if relative not in published and relative not in published_dirs:
            issue(p, 'link-to-unpublished-file:' + relative)

if args.check_index:
    top = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=root, text=True).strip()
    if Path(top).resolve() != root:
        raise SystemExit('Refusing to inspect an ancestor repository index')
    entries = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root)
    indexed = set()
    for entry in entries.split(b'\0'):
        if not entry:
            continue
        metadata, raw_path = entry.split(b'\t', 1)
        mode, object_id, stage = metadata.decode().split()
        name = raw_path.decode('utf-8')
        indexed.add(name)
        path = root / name
        if name not in published:
            issue(path, 'indexed-outside-allowlist')
            continue
        if mode not in {'100644', '100755'} or stage != '0':
            issue(path, 'index-mode-or-conflict')
            continue
        data = subprocess.check_output(['git', 'cat-file', 'blob', object_id.decode() if isinstance(object_id, bytes) else object_id], cwd=root)
        if hashlib.sha256(data).hexdigest() != manifest[name]:
            issue(path, 'index-differs-from-audited-source')
    for name in published - indexed:
        issue(root / name, 'missing-from-index')

parent = root / 'LocalBuild/PublicSourceReview'
parent.mkdir(parents=True, exist_ok=True)
output = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
report = {
    'audit': 'failed' if issues else 'passed', 'fileCount': len(manifest), 'issues': issues,
    'licensePresent': (root / 'LICENSE').is_file(), 'gitIndexChecked': args.check_index,
    'excluded': ['LocalBuild/', '.build/', '.swiftpm/', 'AGENTS.md', 'TASKS.md',
                 'Docs/HANDOFF.md', 'Docs/DECISIONS.md', 'talk-sdk-spec.md', 'talk-sdk-review.md'],
    'limitations': 'Pattern and allowlist audit; not a complete secret scan or independent security review.',
}
(output / 'audit.json').write_text(json.dumps(report, indent=2) + '\n')
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Evidence:', output.relative_to(root))
print(json.dumps(report, indent=2))
if issues:
    raise SystemExit(1)
if args.stage:
    stage = output / 'Talk.swift'
    for name in manifest:
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
    print('Source-only review copy:', stage.relative_to(root))
