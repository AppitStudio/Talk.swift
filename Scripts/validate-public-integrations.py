#!/usr/bin/env python3
"""Compile a consumer and exercise guide drift controls without private app source."""
from datetime import datetime, timezone
import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parent = ROOT / 'LocalBuild/PublicIntegrationValidation'
parent.mkdir(parents=True, exist_ok=True)
output = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
summary = {'checks': [], 'signedAppRuntime': 'NOT RUN', 'dependency': 'isolated public SDK source override'}


def passed(name):
    summary['checks'].append(name)
    print(name + ': PASS', flush=True)


def run(command, name, cwd=ROOT, expected=0):
    result = subprocess.run(list(map(str, command)), cwd=cwd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=300)
    (output / (name + '.log')).write_text(result.stdout)
    if result.returncode != expected:
        raise RuntimeError(name + ': unexpected exit status ' + str(result.returncode))
    passed(name)
    return result.stdout


try:
    # Recreate the public tree without .git, LocalBuild, app repositories or signing assets.
    sdk = output / 'SDK'
    sdk.mkdir()
    shutil.copy2(ROOT / 'Package.swift', sdk / 'Package.swift')
    for name in ('Sources', 'Plugins', 'Examples', 'Tests'):
        shutil.copytree(ROOT / name, sdk / name)
    run(['swift', 'build', '--package-path', sdk, '--product', 'TalkSchemaExporter'], 'public-sdk-exporter-build')
    run(['swift', 'build', '--package-path', sdk, '--product', 'TalkContractChecker'], 'public-sdk-checker-build')
    tools = Path(subprocess.check_output(['swift', 'build', '--package-path', str(sdk), '--show-bin-path'], text=True).strip())
    run([sys.executable, ROOT / 'Scripts/integration-guides.py', 'check', '--tools-dir', tools],
        'public-guides-schema-and-reference-check')

    source = ROOT / 'Integrations/dockflow/Contract'
    contract = output / 'DockFlowTalkContract'
    shutil.copytree(source, contract)
    manifest = contract / 'Package.swift'
    manifest.write_text(manifest.read_text().replace(
        '.package(url: "https://github.com/AppitStudio/Talk.swift.git", exact: "0.1.0-beta.2")',
        '.package(name: "talk.swift", path: "../SDK")'))
    consumer = output / 'Consumer'
    (consumer / 'Sources/Consumer').mkdir(parents=True)
    (consumer / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "OutsiderConsumer",
    platforms: [.macOS("12.4")],
    products: [.library(name: "Consumer", targets: ["Consumer"])],
    dependencies: [.package(name: "talk.swift", path: "../SDK"),
                   .package(path: "../DockFlowTalkContract")],
    targets: [.target(name: "Consumer", dependencies: [
        .product(name: "Talk", package: "talk.swift"),
        .product(name: "DockFlowTalkContract", package: "DockFlowTalkContract")])],
    swiftLanguageModes: [.v6]
)
''')
    recipe = ROOT / 'Integrations/dockflow/Examples/DockFlowRecipe.swift'
    shutil.copy2(recipe, consumer / 'Sources/Consumer/DockFlowRecipe.swift')
    run(['swift', 'build', '--package-path', consumer], 'outsider-plugin-and-exact-recipe-build')

    # The CLI runs against an isolated guide checkout for mutation/negative controls.
    fixture = output / 'GuideCheckout'
    (fixture / 'Scripts').mkdir(parents=True)
    shutil.copy2(ROOT / 'Scripts/integration-guides.py', fixture / 'Scripts/integration-guides.py')
    for name in ('Integrations', 'Docs', 'Skills'):
        shutil.copytree(ROOT / name, fixture / name)
    for name in ('CONTRIBUTING.md', 'SECURITY.md'):
        shutil.copy2(ROOT / name, fixture / name)
    cli = fixture / 'Scripts/integration-guides.py'
    canonical = fixture / 'Integrations/dockflow/Contract/Sources/DockFlowTalkContract/Contract.talk.json'
    run([sys.executable, cli, 'init', 'sample-provider', '--name', 'Sample Provider',
         '--bundle-id', 'com.example.provider', '--contract', canonical, '--tools-dir', tools], 'scaffold-provider')
    draft = fixture / 'Integrations/sample-provider/GUIDE.md'
    run([sys.executable, cli, 'check', draft, '--allow-draft', '--tools-dir', tools], 'scaffold-draft-structural-check')
    run([sys.executable, cli, 'check', draft, '--tools-dir', tools], 'unfinished-draft-rejected', expected=1)
    run([sys.executable, cli, 'init', 'sample-provider', '--name', 'Collision', '--roles', 'provider',
         '--bundle-id', 'com.example.provider', '--contract', canonical, '--tools-dir', tools],
        'existing-guide-not-overwritten', expected=1)
    run([sys.executable, cli, 'init', 'sample-dual', '--name', 'Sample Dual', '--roles', 'provider,consumer',
         '--bundle-id', 'com.example.dual', '--contract', canonical, '--tools-dir', tools,
         '--consumes', fixture / 'Integrations/dockflow/GUIDE.md'], 'scaffold-dual-role-provider')
    dual_guide = fixture / 'Integrations/sample-dual/GUIDE.md'
    run([sys.executable, cli, 'check', dual_guide, '--allow-draft', '--tools-dir', tools],
        'dual-role-provider-schema-and-reference-check')
    run([sys.executable, cli, 'init', 'sample-consumer', '--name', 'Sample Consumer', '--roles', 'consumer',
         '--bundle-id', 'com.example.consumer', '--contract', canonical, '--tools-dir', tools,
         '--consumes', fixture / 'Integrations/dockflow/GUIDE.md'], 'consumer-only-scaffold-rejected', expected=1)
    run([sys.executable, cli, 'init', 'missing-contract', '--name', 'Missing Contract',
         '--bundle-id', 'com.example.missing', '--tools-dir', tools], 'missing-contract-scaffold-rejected', expected=2)
    invalid_contract = output / 'InvalidContract.json'
    invalid_contract.write_text('{"not": "a provider contract"}')
    run([sys.executable, cli, 'init', 'invalid-contract', '--name', 'Invalid Contract',
         '--bundle-id', 'com.example.invalid', '--contract', invalid_contract, '--tools-dir', tools],
        'invalid-contract-scaffold-rejected', expected=1)
    for name in ('sample-consumer', 'missing-contract', 'invalid-contract'):
        if (fixture / 'Integrations' / name).exists():
            raise RuntimeError('Rejected scaffold created an entry: ' + name)
    passed('rejected-scaffolds-create-no-entries')

    spec = importlib.util.spec_from_file_location('guide_cli', cli)
    guide_cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guide_cli)
    guide = fixture / 'Integrations/dockflow/GUIDE.md'
    original = guide.read_text()
    schema_original = canonical.read_bytes()

    def rejected(name, mutate, target=guide, allow_draft=False):
        before = target.read_text()
        try:
            mutate()
            try:
                guide_cli.check(target, allow_draft=allow_draft)
            except (ValueError, KeyError, TypeError):
                passed(name)
            else:
                raise RuntimeError(name + ': bad guide accepted')
        finally:
            target.write_text(before)
            canonical.write_bytes(schema_original)

    rejected('changed-contract-hash-rejected', lambda: canonical.write_bytes(schema_original + b'\n'))
    rejected('missing-permission-documentation-rejected', lambda: guide.write_text(
        original.replace('| `dockflow.presets.apply` | `applyPreset(ApplyPresetRequest)` | `dockflow.presets.apply` |',
                         '| absent | absent | absent |')))
    rejected('missing-public-artifact-rejected', lambda: guide.write_text(original + '\n[Missing](missing.swift)\n'))
    rejected('escaping-public-reference-rejected', lambda: guide.write_text(original + '\n[Outside](../../../private.txt)\n'))
    rejected('sdk-contract-package-pin-drift-rejected', lambda: guide.write_text(original.replace(
        '"version": "0.1.0-beta.2"', '"version": "0.1.0-beta.3"', 1)))
    rejected('contract-version-drift-rejected', lambda: guide.write_text(original.replace(
        '"contractVersion": "1.0.0"', '"contractVersion": "2.0.0"', 1)))
    def mutate_metadata(target, mutation):
        meta, text = guide_cli.metadata(target)
        mutation(meta)
        target.write_text(re.sub(r'```json\n.*?\n```',
                                  lambda _: '```json\n' + json.dumps(meta, indent=2) + '\n```',
                                  text, count=1, flags=re.S))

    rejected('consumer-only-guide-rejected', lambda: mutate_metadata(guide,
             lambda meta: meta.update(roles=['consumer'], provider=None)))
    rejected('null-provider-contract-rejected', lambda: mutate_metadata(guide,
             lambda meta: meta.update(provider=None)))
    rejected('dual-role-consumed-contract-pin-drift-rejected', lambda: mutate_metadata(dual_guide,
             lambda meta: meta['consumes'][0].update(contractVersion='2.0.0')),
             dual_guide, allow_draft=True)
    run([sys.executable, cli, 'check', guide, '--tools-dir', tools, '--provider-export', canonical],
        'matching-provider-export-check')
    changed_export = output / 'ChangedProvider.json'
    changed = json.loads(schema_original)
    changed['contractVersion'] = '1.0.1'
    changed_export.write_text(json.dumps(changed))
    run([sys.executable, cli, 'check', guide, '--tools-dir', tools, '--provider-export', changed_export],
        'provider-export-drift-rejected', expected=1)
    summary['result'] = 'PASS'
except Exception:
    summary['result'] = 'FAIL'
    raise
finally:
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Evidence:', output.relative_to(ROOT), flush=True)
