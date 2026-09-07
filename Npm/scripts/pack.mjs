// Build an isolated publication package from the canonical skill; never publish the SDK tree.
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = join(root, 'LocalBuild', 'NpmPublication');
await mkdir(evidence, { recursive: true });
const run = await mkdtemp(join(evidence, 'candidate-'));
const candidate = join(run, 'package');
await mkdir(join(candidate, 'bin'), { recursive: true });
const metadata = JSON.parse(await readFile(join(root, 'Npm/package.json'), 'utf8'));
delete metadata.scripts;
await writeFile(join(candidate, 'package.json'), JSON.stringify(metadata, null, 2) + '\n');
await copyFile(join(root, 'Npm/README.md'), join(candidate, 'README.md'));
await copyFile(join(root, 'Npm/LICENSE'), join(candidate, 'LICENSE'));
await copyFile(join(root, 'Npm/bin/cli.mjs'), join(candidate, 'bin/cli.mjs'));
await chmod(join(candidate, 'bin/cli.mjs'), 0o755);
const skill = join(root, 'Skills/talk-integrations');
async function copySkill(source, target) {
  await mkdir(target, { recursive: true });
  for (const entry of await readdir(source, { withFileTypes: true })) {
    if (entry.name === '__pycache__' || entry.name === '.DS_Store') continue;
    const from = join(source, entry.name), to = join(target, entry.name);
    if (entry.isDirectory()) await copySkill(from, to);
    else if (entry.isFile() && (/\.(md|swift|json|yaml|py)$/.test(entry.name) || entry.name === 'LICENSE')) await copyFile(from, to);
    else throw new Error(`Unexpected skill entry: ${relative(skill, from)}`);
  }
}
await copySkill(skill, join(candidate, 'skill'));
const test = spawnSync(process.execPath, ['--test', join(root, 'Npm/test/installer.test.mjs')], {
  env: { ...process.env, TALK_PACKAGE_ROOT: candidate }, encoding: 'utf8',
});
await writeFile(join(run, 'tests.log'), test.stdout + test.stderr);
process.stdout.write(test.stdout); process.stderr.write(test.stderr);
if (test.status !== 0) process.exit(test.status ?? 1);
const pack = spawnSync('npm', ['pack', '--json', '--ignore-scripts', '--pack-destination', run], { cwd: candidate, encoding: 'utf8' });
if (pack.status !== 0) throw new Error(pack.stderr || 'npm pack failed');
const [manifest] = JSON.parse(pack.stdout);
await writeFile(join(run, 'pack.json'), JSON.stringify(manifest, null, 2) + '\n');
const expected = new Set(['package.json', 'README.md', 'LICENSE', 'bin/cli.mjs']);
async function addExpected(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) await addExpected(path);
    else expected.add(relative(candidate, path));
  }
}
await addExpected(join(candidate, 'skill'));
if (manifest.files.length !== expected.size || manifest.files.some(file => !expected.has(file.path))) throw new Error('Packed file list does not match the approved package');
const tarball = join(run, manifest.filename);
await writeFile(join(evidence, 'latest.json'), JSON.stringify({ run, candidate, tarball, integrity: manifest.integrity, files: manifest.files.length }, null, 2) + '\n');
console.log(`Verified ${manifest.files.length} package files. Tarball: ${tarball}`);
