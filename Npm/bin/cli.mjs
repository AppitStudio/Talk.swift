#!/usr/bin/env node
import { cp, lstat, mkdir, mkdtemp, readFile, rename, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = fileURLToPath(new URL('../', import.meta.url));
const skillName = 'talk-integrations';
const help = `Install the Talk.swift integration skill (Node.js 20+).

Usage: npx talk-integrations@latest install [options]

  --agent all|codex|claude   Target agent (default: all)
  --global                 Install for all projects in your home directory
  --dir <skills-directory>  Install for another agent at a custom location
  --help                   Show this help
  --version                Show the installer version

Default: install in the current project's .agents/skills and .claude/skills.
Existing skills are never overwritten. Move an old installation aside to update.
The installer copies the complete skill; it does not install the Swift SDK.
`;

async function exists(path) {
  try { await lstat(path); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

async function main() {
  const args = process.argv.slice(2);
  if (!args.length || (args.length === 1 && ['--help', '-h'].includes(args[0]))) {
    console.log(help); return;
  }
  if (args.length === 1 && args[0] === '--version') {
    console.log(JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8')).version); return;
  }
  if (args.shift() !== 'install') throw new Error('Expected install. Run with --help for usage.');
  let agent = 'all', global = false, directory;
  const seen = new Set();
  while (args.length) {
    const flag = args.shift();
    if (flag === '--help' || flag === '-h') { console.log(help); return; }
    if (seen.has(flag)) throw new Error(`Duplicate option: ${flag}`);
    seen.add(flag);
    if (flag === '--global') { global = true; continue; }
    if (!['--agent', '--dir'].includes(flag)) throw new Error(`Unknown option: ${flag}`);
    const value = args.shift();
    if (!value || value.startsWith('-')) throw new Error(`Missing value for ${flag}`);
    if (flag === '--agent') agent = value;
    else directory = value;
  }
  if (!['all', 'codex', 'claude'].includes(agent)) throw new Error('Agent must be all, codex, or claude.');
  if (directory && (global || seen.has('--agent'))) throw new Error('--dir cannot be combined with --agent or --global.');
  const base = global ? homedir() : process.cwd();
  const parents = directory ? [resolve(directory)] : [
    ...(agent !== 'claude' ? [join(base, '.agents', 'skills')] : []),
    ...(agent !== 'codex' ? [join(base, '.claude', 'skills')] : []),
  ];
  const targets = parents.map(parent => join(parent, skillName));
  // Check every target before writing either installation, including broken links.
  for (const target of targets) {
    if (await exists(target)) throw new Error(`Already exists: ${target}. Move it aside before updating; local customizations are preserved.`);
  }
  await readFile(join(packageRoot, 'skill', 'SKILL.md'));
  const installed = [];
  try {
    for (const target of targets) {
      const parent = dirname(target);
      await mkdir(parent, { recursive: true });
      const staging = await mkdtemp(join(parent, '.talk-install-'));
      let reserved = false;
      try {
        await cp(join(packageRoot, 'skill'), join(staging, skillName), { recursive: true, errorOnExist: true, force: false });
        // Reserve exclusively so another installer or existing symlink cannot be replaced.
        await mkdir(target);
        reserved = true;
        await rename(join(staging, skillName), target);
        installed.push(target);
        reserved = false;
      } finally {
        if (reserved) await rm(target, { recursive: true, force: true });
        await rm(staging, { recursive: true, force: true });
      }
    }
  } catch (error) {
    for (const target of installed) await rm(target, { recursive: true, force: true });
    throw error;
  }
  for (const target of installed) console.log(`Installed ${target}`);
  console.log('\nStart a new agent session in your app project.');
  console.log('Codex: $talk-integrations Add a Talk integration to my macOS app.');
  console.log('Claude Code: /talk-integrations Add a Talk integration to my macOS app.');
  console.log('Provide your app projects and Talk.swift checkout or resolved package source.');
}

main().catch(error => { console.error(`talk-integrations: ${error.message}`); process.exitCode = 1; });
