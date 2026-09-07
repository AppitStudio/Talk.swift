import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, readdir, rm, symlink, writeFile, lstat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const packageRoot = process.env.TALK_PACKAGE_ROOT;
if (!packageRoot) throw new Error('Run npm run pack:release to test the isolated package.');
const cli = join(packageRoot, 'bin/cli.mjs');
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'talk-installer-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, 'project with spaces'), home = join(root, 'home');
  await mkdir(cwd); await mkdir(home);
  return { cwd, home, run: (...args) => spawnSync(process.execPath, [cli, ...args], {
    cwd, env: { ...process.env, HOME: home, USERPROFILE: home }, encoding: 'utf8',
  }) };
}
async function equalTree(actual, expected) {
  const a = (await readdir(actual)).sort(), b = (await readdir(expected)).sort();
  assert.deepEqual(a, b);
  for (const name of b) {
    const from = join(actual, name), to = join(expected, name);
    if ((await lstat(to)).isDirectory()) await equalTree(from, to);
    else assert.deepEqual(await readFile(from), await readFile(to));
  }
}
test('default project install copies every skill resource for both agents', async t => {
  const f = await fixture(t), result = f.run('install');
  assert.equal(result.status, 0, result.stderr);
  for (const dir of ['.agents', '.claude']) await equalTree(join(f.cwd, dir, 'skills/talk-integrations'), join(packageRoot, 'skill'));
  assert.deepEqual(await readdir(f.home), []);
});
for (const agent of ['codex', 'claude']) test(`${agent} selection installs only that agent`, async t => {
  const f = await fixture(t), result = f.run('install', '--agent', agent);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(await readdir(f.cwd), [agent === 'codex' ? '.agents' : '.claude']);
});
test('global install targets the isolated home and leaves the project untouched', async t => {
  const f = await fixture(t), result = f.run('install', '--global');
  assert.equal(result.status, 0, result.stderr);
  for (const dir of ['.agents', '.claude']) await equalTree(join(f.home, dir, 'skills/talk-integrations'), join(packageRoot, 'skill'));
  assert.deepEqual(await readdir(f.cwd), []);
});
test('custom skill directory handles spaces', async t => {
  const f = await fixture(t), result = f.run('install', '--dir', 'custom skills');
  assert.equal(result.status, 0, result.stderr);
  await equalTree(join(f.cwd, 'custom skills/talk-integrations'), join(packageRoot, 'skill'));
});
test('an existing second destination prevents writes to both targets', async t => {
  const f = await fixture(t), existing = join(f.cwd, '.claude/skills/talk-integrations');
  await mkdir(existing, { recursive: true }); await writeFile(join(existing, 'custom.md'), 'keep me');
  const result = f.run('install');
  assert.equal(result.status, 1); assert.match(result.stderr, /Already exists/);
  assert.deepEqual(await readdir(f.cwd), ['.claude']);
  assert.equal(await readFile(join(existing, 'custom.md'), 'utf8'), 'keep me');
});
test('existing and dangling skill symlinks are preserved', async t => {
  const f = await fixture(t), parent = join(f.cwd, '.agents/skills');
  await mkdir(parent, { recursive: true });
  const target = join(parent, 'talk-integrations');
  for (const destination of [f.home, join(f.home, 'missing')]) {
    await symlink(destination, target);
    assert.equal(f.run('install', '--agent', 'codex').status, 1);
    assert.equal((await lstat(target)).isSymbolicLink(), true);
    await rm(target);
  }
  assert.deepEqual(await readdir(f.home), []);
});
test('invalid second parent prevents either installation and preserves the file', async t => {
  const f = await fixture(t);
  await writeFile(join(f.cwd, '.claude'), 'preserve');
  assert.equal(f.run('install').status, 1);
  await assert.rejects(lstat(join(f.cwd, '.agents/skills/talk-integrations')), { code: 'ENOENT' });
  assert.equal(await readFile(join(f.cwd, '.claude'), 'utf8'), 'preserve');
});
test('invalid arguments fail without writing files', async t => {
  const f = await fixture(t);
  for (const args of [['unknown'], ['install', '--agent', 'unknown'], ['install', '--agent'], ['install', '--global', '--dir', 'custom'], ['install', '--dir', 'custom', '--agent', 'codex'], ['install', '--force'], ['install', '--global', '--global']]) assert.equal(f.run(...args).status, 1, args.join(' '));
  assert.deepEqual(await readdir(f.cwd), []); assert.deepEqual(await readdir(f.home), []);
});
test('help and version have no installation side effects', async t => {
  const f = await fixture(t);
  for (const args of [[], ['--help'], ['install', '--help'], ['--version']]) assert.equal(f.run(...args).status, 0);
  assert.deepEqual(await readdir(f.cwd), []);
});
