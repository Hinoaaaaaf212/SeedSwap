// SPDX-License-Identifier: GPL-2.0-only
'use strict';
// After SeedSwap's loader on a held normal-mode ns2jb run: replace the running ns2jb helper RO by
// kaiHEN's RO, then start HEN. A port of switch2-themes/hen-after-loader.cjs (which ran on the
// author's console every boot since 2026-11-20, after ns2jb-modloader --keep-rpc) for ns2jb
// ae33da1, whose start-hen.cjs takes (bootstrap.bin, [{source, target}]) and copies a kaiHEN
// release's sdcard/ folder to the card.
// One attempt per boot: never rerun after a failure.

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const check = (ok, message) => { if (!ok) throw Error(message); };
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

// ns2jb (kurumuz/ns2jb) at the commit this tool was written for. sourceSha256 is what run.cjs
// sourceDigest() writes to result.json for that commit; the files are the ones loaded here.
const NS2JB = {
  commit: 'ae33da13542c616874ec23c56b7b6a660745c5e3',
  zip: 'https://gitlab.com/kurumuz/ns2jb/-/archive/ae33da13542c616874ec23c56b7b6a660745c5e3/ns2jb-ae33da13542c616874ec23c56b7b6a660745c5e3.zip',
  sourceSha256: '5cdf1a57a511e135eeacb8cadfaa7ae3dbf3a978ea4f77fb06efc80f56b40828',
  files: {
    'switch2/ro/start-hen.cjs': 'f7db32f8a92a3239988628690f529bc922e176f8db3f19853032dafbc3ee16d8',
    'switch2/ro/package-build.cjs': '38bd63aa1730995c0634d422c11c8d04d42b3ceb79115230f6f45e9dcaf8ce65',
    'switch2/ro/runtime.cjs': '7553e3314e0c5657a8687eb2c7fdca87114ebbd6772149847a4a237ae40454ff',
    'switch2/ro/ready.cjs': '50bd464e40a353b35110ad91b8bed5eaac03fcaa94a808ccf66a304b30159981',
    'shared/stages.cjs': 'a34801ebb44f64eca745a1cb6b18d2f74dbd52f53b0c97ffe74a853567afbe95',
    'switch2/tools/fs-memory.cjs': '78cdd40e60254c4eb236db626d59ed78e096316c5c6cc6cb90af7a95a687e220',
  },
};

// A copy made on Windows can have CRLF line endings; the pins are of git's LF files.
const lf = bytes => Buffer.from(bytes.toString('latin1').replace(/\r\n/g, '\n'), 'latin1');

// run.cjs sourceDigest(), on an ns2jb folder (checked before the user starts SmileBASIC).
// stripCr: of the files with CRLF turned into LF, to compare with the pin.
function sourceDigest(ns2jb, {stripCr = false} = {}) {
  const names = ['run.cjs', 'rpc.cjs', 'dump-firmware.cjs', 'bootstrap.bas'];
  const walk = folder => {
    for (const entry of fs.readdirSync(path.join(ns2jb, folder), {withFileTypes: true})) {
      const name = folder + '/' + entry.name;
      if (entry.isDirectory()) walk(name);
      else if (entry.isFile()) names.push(name);
      else throw Error('Unexpected file in ns2jb: ' + name);
    }
  };
  walk('engine');
  const entries = names.sort().map(name => {
    const bytes = fs.readFileSync(path.join(ns2jb, name));
    return [name, sha(stripCr ? lf(bytes) : bytes)];
  });
  return sha(JSON.stringify(entries));
}

// The ns2jb folder against the pin: {ok, digest} where digest is what run.cjs will record.
function checkNs2jb(ns2jb) {
  let digest;
  try { digest = sourceDigest(ns2jb); } catch { return {digest: null, ok: false}; }   // older ns2jb: files missing
  return {digest, ok: digest === NS2JB.sourceSha256 || sourceDigest(ns2jb, {stripCr: true}) === NS2JB.sourceSha256};
}

// kaiHEN releases this tool knows (sizes as in the Seedsow save's b_s2_kaihen.lua), newest first.
const RELEASES = [
  {name: '20261123', bootstrap: 27948, ro: 29198, hen: 78763, game: 71761},
  {name: '20261117.1', bootstrap: 27948, ro: 23854, hen: 78765, game: 63424},
];

// ns2jb ae33da1 hen.cjs sdcardFiles(): every file under sdcard/ to the same path; an older flat
// release's files at their known paths.
function sdcardFiles(ship) {
  const sdcard = path.join(ship, 'sdcard');
  if (fs.statSync(sdcard, {throwIfNoEntry: false})?.isDirectory()) {
    const files = [];
    const walk = (dir, prefix) => {
      for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
        if (entry.name.startsWith('.')) continue;
        const child = path.join(dir, entry.name), target = `${prefix}/${entry.name}`;
        if (entry.isDirectory()) walk(child, target);
        else if (entry.isFile()) files.push({source: child, target});
      }
    };
    walk(sdcard, '');
    return files;
  }
  const files = [
    {source: path.join(ship, 'hbmenu.nro'), target: '/hbmenu.nro'},
    {source: path.join(ship, 'hen/main'), target: '/kaihen/bin/hen/main'},
    {source: path.join(ship, 'game/main'), target: '/kaihen/bin/game/main'},
  ];
  for (const entry of fs.readdirSync(path.join(ship, 'programs'), {withFileTypes: true}))
    if (entry.isFile() && !entry.name.startsWith('.'))
      files.push({source: path.join(ship, 'programs', entry.name), target: `/switch/${entry.name}`});
  for (const file of files)
    check(fs.statSync(file.source, {throwIfNoEntry: false})?.isFile(), `Missing kaiHEN file: ${file.source}`);
  return files;
}

// The unpacked kaiHEN zip: which release it is, and the files it puts on the SD card.
function readRelease(ship) {
  const size = p => fs.statSync(path.join(ship, p), {throwIfNoEntry: false})?.size;
  check(size('ro/main') && size('bootstrap.bin'), `${ship} is not an unpacked kaiHEN zip (no ro/main or bootstrap.bin)`);
  const files = sdcardFiles(ship);
  const of = target => { const f = files.find(x => x.target === target); return f && fs.statSync(f.source).size; };
  const sizes = {bootstrap: size('bootstrap.bin'), ro: size('ro/main'), hen: of('/kaihen/bin/hen/main'), game: of('/kaihen/bin/game/main')};
  const release = RELEASES.find(r => ['bootstrap', 'ro', 'hen', 'game'].every(k => r[k] === sizes[k]));
  check(release, `This kaiHEN build isn't one SeedSwap knows (bootstrap.bin ${sizes.bootstrap} B, ro/main ${sizes.ro} B). ` +
    `Use kaiHEN ${RELEASES[0].name} (https://github.com/ouncebrew/kaihen/releases/download/${RELEASES[0].name}/kaiHEN-${RELEASES[0].name}.zip), ` +
    `or a SeedSwap release made for your kaiHEN.`);
  return {release, files, bootstrap: path.join(ship, 'bootstrap.bin'), ro: path.join(ship, 'ro/main')};
}

// Large files already on the card with the same size are not copied again (kaiHEN's small files
// always are). sdSizes: target -> size on the card, or null.
const BIG = 4 * 1024 * 1024;
function filesToCopy(files, sdSizes = {}, copyAll = false) {
  return files.filter(f => copyAll || fs.statSync(f.source).size <= BIG || sdSizes[f.target] !== fs.statSync(f.source).size);
}

// The checks before anything runs on the console (run = the held run folder).
// sourceSha256: the digest checkNs2jb() gave for the ns2jb folder this run came from.
function preflight(run, {loaderJournal, anyNs2jb = false, sourceSha256 = NS2JB.sourceSha256} = {}) {
  const session = path.basename(run), roDir = path.join(run, 'switch2', 'ro');
  const result = readJson(path.join(run, 'result.json'));
  check(result.verified && result.fs && !result.ro && !result.roImage, 'Not a verified normal-mode ns2jb run (ns2jb helper RO)');
  check(result.rpc?.state === 'listening' && !result.completed, 'The held RPC of this run is not listening');
  if (!anyNs2jb) {
    check(result.sourceSha256 === sourceSha256, `This run didn't come from the checked ns2jb folder (source digest ${String(result.sourceSha256).slice(0, 12)}…)`);
    for (const [name, want] of Object.entries(NS2JB.files))
      check(sha(lf(fs.readFileSync(path.join(run, name)))) === want, `${name} in the run differs from ns2jb ${NS2JB.commit.slice(0, 7)}`);
  }
  for (const done of [path.join(roDir, 'hen-startup.json'), path.join(run, 'switch2', 'kaihen-ro-current.json')])
    check(!fs.existsSync(done), 'kaiHEN was already tried on this run; restart the console to try again');
  const execution = readJson(path.join(roDir, 'current-execution.json'));
  check(execution.session === session, 'RO record belongs to another run');
  check(execution.verified && /^\d+$/.test(String(execution.pid)), 'The ns2jb helper RO record is not current');
  if (loaderJournal && fs.existsSync(loaderJournal)) {
    const j = readJson(loaderJournal);
    check(!j.pending, 'SeedSwap\'s loader left a console request running; restart the console before trying again');
    if (j.helperPid) check(BigInt(j.helperPid) === BigInt(execution.pid), `The RO changed after SeedSwap's loader (pid ${BigInt(j.helperPid)}, now ${execution.pid})`);
  }
  return {session, roDir, execution, previousPid: String(execution.pid)};
}

// ship: unpacked kaiHEN zip; files: [{source, target}] to stage (from readRelease + SeedSwap's).
async function startKaihen(run, {ship, files, loaderJournal, anyNs2jb = false, sourceSha256, log = console.log}) {
  run = path.resolve(run);
  const engine = path.join(run, 'switch2');
  const {session, roDir, execution, previousPid} = preflight(run, {loaderJournal, anyNs2jb, sourceSha256});
  const kaihen = readRelease(ship);
  process.env.NS2_RUN_DIR = run;                      // run-folder modules find the run through it

  // kaiHEN RO + this console's RO policy (run.cjs + pipeline.cjs build it the same way)
  const policy = path.join(roDir, session + '-code-0400000000000037', 'main.npdm');
  check(fs.existsSync(policy), 'No RO policy in this run: ' + policy);
  const packageFile = path.join(roDir, 'payload', 'kaihen-ro-exefs.nsp');
  await require(path.join(roDir, 'package-build.cjs')).build(kaihen.ro, policy, packageFile);
  log(`kaiHEN ${kaihen.release.name}: RO package ${sha(fs.readFileSync(packageFile)).slice(0, 16)}…; replacing RO pid ${previousPid}`);

  const {connect} = require(path.join(engine, 'tools/fs-memory.cjs'));
  const runtime = require(path.join(roDir, 'runtime.cjs'));
  const {run: stage} = require(path.join(run, 'shared/stages.cjs'));
  const memory = await connect();
  check(memory.info.session === session, 'The FS memory endpoint belongs to another run');
  const stamp = Date.now();
  for (const suffix of ['-activation.json', '-handoff.json', '-bound-sessions.json', '-filesystem-types.json']) {
    const file = path.join(roDir, session + suffix);
    if (fs.existsSync(file)) fs.copyFileSync(file, file.replace(/\.json$/, '.before-kaihen-' + stamp + '.json'), fs.constants.COPYFILE_EXCL);
  }

  // stage and select the donor, requalify, gate-launch, start (pipeline.cjs order)
  const root = readJson(memory.reportFile).ownedRoot.clones[0];
  await memory.request({command: 'root-native-package-stage', root, kind: 'ro', source: packageFile});
  const opened = await memory.request({command: 'root-native-package-open', root, kind: 'ro', selectDonor: true});
  check(!opened.result && opened.entries.length === 2, 'kaiHEN RO package did not expose its ExeFS files');
  await stage(roDir, 'bind-sessions');
  const gate = await stage(roDir, 'test-gate');
  check(gate?.verified && gate.restored, 'The native request gate did not qualify');
  const launch = await stage(roDir, 'launch', [], 300000);
  check(launch?.imageAccepted && launch.restored && launch.pid, 'PM did not accept the kaiHEN RO image');
  const activation = await runtime.activate(launch.file, previousPid);   // start new, end previous
  // No tool may send the ns2jb helper protocol to kaiHEN's RO.
  fs.writeFileSync(path.join(roDir, 'current-execution.json'), JSON.stringify({...execution, verified: false, retiredForKaihenRo: true,
    kaihenRoPid: activation.pid, kaihenActivation: activation.file}, null, 2) + '\n', {mode: 0o600});
  const handoff = await runtime.handoff();                    // Loader idle again
  await require(path.join(roDir, 'ready.cjs')).main();        // ldr:ro Initialize answered
  const donor = await memory.request({command: 'root-native-donor-cleanup'});
  check(donor.cleanedUp, 'The kaiHEN RO donor did not close');
  fs.writeFileSync(path.join(engine, 'kaihen-ro-current.json'), JSON.stringify({session, previousPid, release: kaihen.release.name,
    pid: activation.pid, launch: launch.file, handoff: handoff.file, verified: true, at: new Date().toISOString()}, null, 2) + '\n', {mode: 0o600});
  log(`kaiHEN RO pid ${activation.pid} replaced RO pid ${previousPid}`);

  // HEN, as ns2jb ae33da1 hen.cjs starts it (files are copied to the card first)
  log(`copying ${files.length} file(s) to the SD card`);
  const {main: startHen} = require(path.join(roDir, 'start-hen.cjs'));
  const started = await startHen(kaihen.bootstrap, files);
  log(`HEN pid ${started.pid}`);
  return {release: kaihen.release.name, roPid: activation.pid, henPid: started.pid, record: started.file};
}

module.exports = {NS2JB, RELEASES, sourceDigest, checkNs2jb, sdcardFiles, readRelease, filesToCopy, preflight, startKaihen};
