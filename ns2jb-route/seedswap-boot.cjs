#!/usr/bin/env node
// SPDX-License-Identifier: GPL-2.0-only
'use strict';
// SeedSwap without Seedsow: one command per boot, with ns2jb and SmileBASIC 4.
//   node seedswap-boot.cjs --ns2jb NS2JB_FOLDER --kaihen KAIHEN_FOLDER [--seedswap SEEDSWAP_FOLDER] [COMPUTER_IP]
// 1. starts ns2jb (run.cjs --rpc) and passes its SmileBASIC lines through; after a failed try it
//    says to restart and waits for the next one
// 2. installs SeedSwap's loader from SD:/kaihen/ml/install (skipped when SeedSwap isn't on the card yet)
// 3. starts kaiHEN and copies kaiHEN's SD files and SeedSwap's missing ones to the card
// 4. stops ns2jb; then you close SmileBASIC 4
// Runs where ns2jb runs: macOS, Linux, or WSL on Windows (Node 22 or newer).

const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');
const path = require('node:path');
const readline = require('node:readline');
const {spawn} = require('node:child_process');

const USAGE = `Usage: node seedswap-boot.cjs --ns2jb NS2JB_FOLDER --kaihen KAIHEN_FOLDER [--seedswap SEEDSWAP_FOLDER] [COMPUTER_IP]

  --ns2jb      the ns2jb folder (kurumuz/ns2jb at commit ae33da1)
  --kaihen     the unpacked kaiHEN zip (bootstrap.bin, ro, ...)
  --seedswap   the SeedSwap release folder (its sd folder is copied to the card when missing);
               default: the folder above this tool's (or its out folder, after build.py)
  COMPUTER_IP  the computer's address on the console's network (ns2jb asks when it isn't given)

  --copy-all   copy every kaiHEN file again, even large ones already on the card
  --any-ns2jb  allow another ns2jb version (not tested with SeedSwap)`;

const LOADER = ['image.lua', 'runtime.bin', 'gateway.bin', 'context.bin'].map(n => '/kaihen/ml/install/' + n);

function options(argv) {
  const o = {copyAll: false, anyNs2jb: false, modloader: path.join(__dirname, 'vendor', 'ns2jb-modloader')};
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { o.help = true; continue; }
    if (a === '--copy-all') { o.copyAll = true; continue; }
    if (a === '--any-ns2jb') { o.anyNs2jb = true; continue; }
    if (['--ns2jb', '--kaihen', '--seedswap', '--modloader'].includes(a)) {
      const v = argv[++i];
      if (!v || v.startsWith('--')) throw Error('Missing folder after ' + a);
      o[a.slice(2)] = path.resolve(v);
      continue;
    }
    if (a.startsWith('-')) throw Error('Unknown option ' + a);
    rest.push(a);
  }
  if (rest.length > 1) throw Error('Give at most one computer address');
  o.host = rest[0];
  if (!o.seedswap) o.seedswap = defaultSeedswap();
  return o;
}

// The release folder this tool is in; in a clone of the GitHub repo, build.py's out folder (the repo's
// own sd folder has no NRO).
function defaultSeedswap() {
  const up = path.resolve(__dirname, '..'), nro = d => fs.existsSync(path.join(d, 'sd', 'switch', 'seedswap.nro'));
  return !nro(up) && nro(path.join(up, 'out')) ? path.join(up, 'out') : up;
}

// SeedSwap's SD files: every file under <seedswap>/sd, at the same path on the card.
function seedswapFiles(folder) {
  const sd = path.join(folder, 'sd');
  if (!fs.statSync(sd, {throwIfNoEntry: false})?.isDirectory()) return null;
  const files = [];
  const walk = (dir, prefix) => {
    for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
      if (e.name.startsWith('.')) continue;
      const p = path.join(dir, e.name), t = `${prefix}/${e.name}`;
      if (e.isDirectory()) walk(p, t); else if (e.isFile()) files.push({source: p, target: t});
    }
  };
  walk(sd, '');
  return files;
}

// The computer's address, as ns2jb run.cjs chooses it (asked here: ns2jb runs without a terminal).
async function chooseHost(given) {
  if (given) { if (!net.isIPv4(given)) throw Error('Not an IPv4 address: ' + given); return given; }
  const choices = [...new Set(Object.values(os.networkInterfaces()).flat().filter(a =>
    a.family === 'IPv4' && !a.internal && a.netmask !== '255.255.255.255' && !a.address.startsWith('169.254.')).map(a => a.address))];
  if (choices.length === 1) return choices[0];
  if (!choices.length) throw Error('Connect this computer to the console\'s network.');
  if (!process.stdin.isTTY) throw Error('Give the computer\'s address on the console\'s network: ' + choices.join(', '));
  choices.forEach((a, i) => console.log(`  ${i + 1}. ${a}`));
  const input = require('node:readline/promises').createInterface({input: process.stdin, output: process.stdout});
  try {
    const n = await input.question('Which address can the console reach? ');
    if (!/^[1-9][0-9]*$/.test(n) || !choices[Number(n) - 1]) throw Error('Choose one of the listed addresses.');
    return choices[Number(n) - 1];
  } finally { input.close(); }
}

// Start ns2jb once; resolves {run} when the held run is verified, or {failed} when it exits first.
// ns2jb gets its own process group, so a Ctrl-C in this terminal reaches only this tool: ns2jb
// stops on its first SIGINT and is killed by a second one, before its cleanup.
function acquire(o, {onChild, out = process.stdout} = {}) {
  const env = {...process.env, NS2_BASIC_ARITY: process.env.NS2_BASIC_ARITY || '9'};
  delete env.NS2_RO_IMAGE;                            // normal mode: ns2jb's helper RO, which the loader needs
  const child = spawn(process.execPath, [path.join(o.ns2jb, 'run.cjs'), '--rpc', o.host],
    {cwd: o.ns2jb, stdio: ['ignore', 'pipe', 'inherit'], env, detached: true, windowsHide: true});
  onChild?.(child);
  child.stdout.pipe(out, {end: false});                // its address prompt has no newline
  const lines = readline.createInterface({input: child.stdout});
  let folder = null;
  return new Promise(resolve => {
    let done = false;
    const finish = v => { if (!done) { done = true; resolve(v); } };
    lines.on('line', line => {
      if (line.startsWith('Run folder: ')) folder = path.resolve(o.ns2jb, line.slice(12).trim());
      if (/^4\/4 verified\b/.test(line) && folder) finish({child, run: folder});
      if (/^RO frontend verified\b/.test(line)) finish({child, failed: 'ns2jb started in RO mode; unset NS2_RO_IMAGE'});
    });
    child.once('exit', code => finish({child, failed: `ns2jb stopped (exit code ${code})`}));
    child.once('error', error => finish({child, failed: error.message}));
  });
}

function stopHost(child, timeoutMs = 120000) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(child.exitCode);
  return new Promise(resolve => {
    const timer = setTimeout(() => resolve('timeout'), timeoutMs);
    child.once('exit', code => { clearTimeout(timer); resolve(code); });
    child.kill('SIGINT');
  });
}

// deps: the console steps (replaced by fakes in test/boot_test.cjs)
async function boot(o, deps = {}) {
  const log = deps.log || (s => console.log(s));
  const install = deps.install || require('./lib/install.cjs');
  const kaihen = deps.kaihen || require('./lib/kaihen.cjs');
  const waitRetry = deps.waitRetry || (() => Promise.resolve());

  // before anything runs on the console
  if (!deps.skipPlatform) {
    if (process.platform === 'win32') throw Error('ns2jb runs on macOS or Linux. On Windows, run this in WSL (see INSTALL.md).');
    if (Number(process.versions.node.split('.')[0]) < 22) throw Error('ns2jb needs Node 22 or newer (this is Node ' + process.versions.node + ')');
  }
  if (!o.ns2jb || !o.kaihen) throw Error(USAGE);
  if (!fs.existsSync(path.join(o.ns2jb, 'run.cjs'))) throw Error('No run.cjs in ' + o.ns2jb + ': --ns2jb must be the ns2jb folder');
  let sourceSha256;
  if (!o.anyNs2jb) {
    const v = kaihen.checkNs2jb(o.ns2jb);
    if (!v.ok)
      throw Error(`ns2jb in ${o.ns2jb} isn't commit ${kaihen.NS2JB.commit.slice(0, 7)}. ` +
        `Run: git -C "${o.ns2jb}" fetch && git -C "${o.ns2jb}" checkout ${kaihen.NS2JB.commit.slice(0, 7)}` +
        ` (or download ${kaihen.NS2JB.zip} and use its folder)`);
    sourceSha256 = v.digest;                          // what run.cjs records for this folder
  }
  const release = kaihen.readRelease(o.kaihen);
  const ours = seedswapFiles(o.seedswap);
  if (!ours) throw Error(`No sd folder in ${o.seedswap}: --seedswap must be the SeedSwap release folder`);
  if (!ours.some(f => f.target === '/switch/seedswap.nro'))
    throw Error(`No sd/switch/seedswap.nro in ${o.seedswap}. In a copy of the GitHub repo, run build.py first.`);
  if (!deps.skipModloader) require(path.join(o.modloader, 'lib', 'native', 'artifacts.cjs')).artifacts();
  o = {...o, host: await (deps.chooseHost || chooseHost)(o.host)};
  log(`kaiHEN ${release.release.name}, SeedSwap files from ${o.seedswap}, computer address ${o.host}`);

  // 1. acquisition, as many tries as it takes
  let held;
  for (let attempt = 1; ; attempt++) {
    held = await (deps.acquire || acquire)(o, {onChild: deps.onChild});
    if (held.run) break;
    log(`\nThat try didn't work (${held.failed}).`);
    log('Restart the console, open SmileBASIC 4, and enter the lines again. Waiting for the next try. (Ctrl-C stops.)\n');
    await waitRetry(attempt);
  }
  const run = held.run, directory = path.join(run, 'seedswap');
  deps.onHeld?.();
  fs.mkdirSync(directory, {recursive: true, mode: 0o700});
  const record = {run, started: new Date().toISOString(), kaihen: release.release.name};
  const saveRecord = () => fs.writeFileSync(path.join(directory, 'boot.json'), JSON.stringify(record, null, 2) + '\n', {mode: 0o600});
  log('\nns2jb is ready. Setting up SeedSwap and kaiHEN; leave SmileBASIC open.');

  let pending = false, ok = false;
  try {
    // 2. SeedSwap's loader
    const big = release.files.filter(f => fs.statSync(f.source).size > 4 * 1024 * 1024).map(f => f.target);
    const sizes = await install.surveySd(run, {modloader: o.modloader, paths: [...new Set([...ours.map(f => f.target), ...LOADER, ...big])]});
    const loaderJournal = path.join(directory, 'seedswap-loader.json');
    if (LOADER.every(p => typeof sizes[p] === 'number' && sizes[p] > 0)) {
      try {
        const r = await install.installLoader(run, {modloader: o.modloader, directory, log: s => log('  ' + s)});
        record.loader = {ok: true, report: r.report};
        log('SeedSwap\'s loader is running.');
      } catch (error) {
        record.loader = {ok: false, error: error.message};
        const j = fs.existsSync(loaderJournal) ? JSON.parse(fs.readFileSync(loaderJournal, 'utf8')) : {};
        if (j.pending) { pending = true; throw error; }
        log(`SeedSwap's loader didn't start: ${error.message}`);
        log('Starting kaiHEN anyway. SeedSwap games won\'t work until the next boot.');
      }
    } else {
      record.loader = {ok: false, skipped: 'SeedSwap files not on the SD card'};
      log('SeedSwap isn\'t on the SD card yet. Its files are copied now; its loader starts from the next boot.');
    }

    // 3. kaiHEN, with kaiHEN's SD files and SeedSwap's missing ones
    const missing = ours.filter(f => sizes[f.target] === null);
    const files = [...kaihen.filesToCopy(release.files, sizes, o.copyAll), ...missing];
    record.copied = files.map(f => f.target);
    const k = await kaihen.startKaihen(run, {ship: o.kaihen, files, loaderJournal, anyNs2jb: o.anyNs2jb, sourceSha256, log: s => log('  ' + s)});
    record.started_kaihen = {release: k.release, roPid: k.roPid, henPid: k.henPid};
    log(`kaiHEN is running${missing.length ? `; ${missing.length} SeedSwap file(s) copied` : ''}.`);
    ok = true;
  } catch (error) {
    record.error = error.stack;
    log(`\nStopped: ${error.message}`);
  } finally {
    record.finished = new Date().toISOString();
    saveRecord();
  }

  // 4. ns2jb
  if (pending) {
    deps.onSettled?.();
    log('A request to the console may still be running. Restart the console now (hold the power button), then run this again.');
    await new Promise(resolve => held.child.once('exit', resolve));
    return {ok: false, run, record};
  }
  log('Stopping ns2jb...');
  const code = await stopHost(held.child);
  record.hostStopped = code;
  saveRecord();
  if (ok) {
    log('\nDone. Close SmileBASIC 4 now, without restarting the console.');
    log('To open the homebrew menu, hold R while starting a game.');
  } else {
    log('\nRestart the console before trying again.');
  }
  return {ok, run, record};
}

if (require.main === module) {
  let o;
  try { o = options(process.argv.slice(2)); } catch (e) { console.error(e.message + '\n\n' + USAGE); process.exit(1); }
  if (o.help) { console.log(USAGE); process.exit(0); }
  // Ctrl-C: while waiting for ns2jb it stops ns2jb and this tool; once ns2jb is ready it is ignored
  // until the setup ends (stopping in the middle could leave the console half set up).
  let child = null, held = false;
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
    if (held) { console.log('\nPlease wait: SeedSwap is still setting up. It stops ns2jb itself when it is done.'); return; }
    if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGINT');
    process.exit(130);
  });
  boot(o, {onChild: c => { child = c; }, onHeld: () => { held = true; }, onSettled: () => { held = false; }}).then(r => { process.exitCode = r.ok ? 0 : 1; },
    e => { console.error(e.message); process.exitCode = 1; });
}

module.exports = {boot, options, seedswapFiles, acquire, stopHost, LOADER};
