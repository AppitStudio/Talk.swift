"""Typecheck the guide's exact Swift blocks and verify its local tool commands."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
subprocess.run(['swift', 'build'], cwd=root, check=True)
binaries = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
output = root / 'LocalBuild/GuideValidation'
output.mkdir(parents=True, exist_ok=True)
guide = (root / 'Docs/INTEGRATION-GUIDE.md').read_text()
for index, block in enumerate(re.findall(r'```swift\n(.*?)```', guide, re.S)):
    source = output / f'Guide{index}.swift'
    source.write_text(block)
    subprocess.run(['swiftc', '-swift-version', '6', '-typecheck', '-I', str(binaries / 'Modules'), str(source)], check=True)
contract = root / 'Examples/Shared/StudioContract/Contract.talk.json'
exported = output / 'Contract.talk.json'
subprocess.run([str(binaries / 'TalkSchemaExporter'), str(contract), str(exported)], check=True)
subprocess.run([str(binaries / 'TalkClientGenerator'), str(exported), str(output / 'Studio.generated.swift')], check=True)
subprocess.run(['swiftc', '-swift-version', '6', '-typecheck', '-I', str(binaries / 'Modules'), str(output / 'Studio.generated.swift')], check=True)
old = root / 'Tests/Fixtures/CompatibilityOld/Contract.talk.json'
new = root / 'Tests/Fixtures/CompatibilityNew/Contract.talk.json'
subprocess.run([str(binaries / 'TalkContractChecker'), str(old), str(new)], check=True)
reverse = subprocess.run([str(binaries / 'TalkContractChecker'), str(new), str(old)], capture_output=True, text=True)
if reverse.returncode != 1 or 'test.extra' not in reverse.stderr:
    raise RuntimeError('Missing reverse compatibility diagnostic')
print('Exact guide Swift blocks, export, generated client and directional checker commands: PASS')
