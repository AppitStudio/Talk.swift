"""Local reproducible export/generation checks; no provider app is launched."""
from pathlib import Path
import json
import subprocess

root = Path(__file__).resolve().parent.parent
subprocess.run(['swift', 'build'], cwd=root, check=True)
binaries = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
output = root / 'LocalBuild' / 'ContractValidation'
output.mkdir(parents=True, exist_ok=True)
source = root / 'Examples/Shared/StudioContract/Contract.talk.json'
exported = output / 'Contract.talk.json'
regenerated = output / 'Studio.generated.swift'
subprocess.run([str(binaries / 'TalkSchemaExporter'), str(source), str(exported)], check=True)
subprocess.run([str(binaries / 'TalkClientGenerator'), str(exported), str(regenerated)], check=True)
subprocess.run(['swiftc', '-swift-version', '6', '-typecheck', '-I', str(binaries / 'Modules'), str(regenerated)], check=True)
# Exercise the full supported subset independently of the example's convenience extensions.
subset = json.loads(source.read_text())
subset['types'].append({'name': 'OptionalValues', 'kind': 'struct', 'fields': [
    {'name': 'case', 'type': 'String?'}, {'name': 'enabled', 'type': 'Bool'},
    {'name': 'values', 'type': '[Int64?]'}, {'name': 'nested', 'type': '[[Scene]]'}]})
subset_path = output / 'Subset.talk.json'
subset_path.write_text(json.dumps(subset))
subprocess.run([str(binaries / 'TalkClientGenerator'), str(subset_path), str(output / 'Subset.swift')], check=True)
subprocess.run(['swiftc', '-swift-version', '6', '-typecheck', '-I', str(binaries / 'Modules'), str(output / 'Subset.swift')], check=True)
for field, value in [('kind', 'class'), ('customCodable', True)]:
    invalid = json.loads(source.read_text())
    invalid['types'][0][field] = value
    path = output / 'Invalid.talk.json'
    path.write_text(json.dumps(invalid))
    result = subprocess.run([str(binaries / 'TalkClientGenerator'), str(path), str(output / 'Invalid.swift')], capture_output=True, text=True)
    if result.returncode == 0 or 'error:' not in result.stderr:
        raise RuntimeError('Unsupported declaration was not diagnosed')
print('Canonical export, independent generated client, complete DTO subset, invalid declarations: PASS')
