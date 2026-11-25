#!/usr/bin/env node
// Offline builder for the on-console ns2jb-modloader install image (route B, milestone 3 input).
//
// It runs the modloader's own builders (lib/native.cjs buildAll, lib/lazy-context.cjs
// buildContext) several times with different live values, classifies every byte that changes
// as a fixup of exactly one live value, and writes the result as blobs plus a fixup table
// that s2_ml applies on the console once it knows the values:
//   base      FS .text base (ASLR)
//   ctx       context allocation in FS
//   rt        runtime VA in FS (helper 0x10 freeAddress; 0x8000000 in every boot so far)
//   sdfs      FS's SD IFileSystem object (found live)
//   registry  u64(FS+0x11e12d0)+16
//   log       the SD report file's IFile object (with logs on)
//   trace     the SD trace file's IFile object (with logs and trace on)
// The result is then checked differentially: for unrelated value sets, image+fixups must equal
// a fresh buildAll/buildContext byte for byte. With --check-session it is also replayed against
// a recorded PC install (state/<session>: build/runtime.bin, build/combined.bin, hooks).
//
// SD report + trace (default on; --no-logs, --no-trace): the report text is the modloader's own
// lib/diagnostics.cjs report for session "onconsole-NNNN", written by s2_ml to
// /ns2jb-modloader/logs/onconsole-NNNN.log (+ .trace, 40,960 B). NNNN is a per-boot counter the
// console picks; the image records every context offset of those four digits, and the
// differential check covers several counters.
//
// Plan sources (one of):
//   --plan <overlay.json>    a recorded load.cjs plan (state/<s>/prepared/overlay.json)
//   --tree <listing>         SD listing: inventory.json rows, or "D <path>/" / "F <size> <path>" lines
//   --sd-root <dir>          a local copy of SD:/ns2jb-modloader (e.g. D:\ns2jb-modloader)
// Options: --title <id> (repeatable, like load.cjs), --views-from <overlay.json> (static views +
// payload.bin from a recorded plan), --capture <fs-4.bin>, --ml <modloader source>, --out <dir>,
// --check-session <state dir> (repeatable).
//
// Save-open guard (default on; --no-guard): FS commands 51/53 (OpenSaveDataFileSystem and its
// read-only form) are hooked; while the loader is active, account-save opens by a process of the
// guarded program (--guard-program, default Seedsow 0100ee5021c9e000) started after the install
// are refused with 2002-1002 ("no save", which games handle) for every user except --guard-user (default the second user
// <user ID>). The pid floor is a live value (kind `pidfloor`): s2_ml hands
// in the helper RO's pid. The hooked functions are not in fs-4.bin; their bytes come from the full
// FS dump named in tools/fs-guard-profile.json (checked against the capture and by sha256), and the
// image fingerprints them whole so s2_ml verifies every byte on the console before hooking.
// Live SD sizes (default on; --no-live-sizes): the runtime mounts romfs.bin/exefs.nsp at their
// size on SD at each launch and leaves the game native when they are missing; image.lua carries
// `live_sizes = true` and s2_ml's stale-file check only reports sizes.
// Signature patch (--sig-patch, default off): two more 16-byte hooks (`Sig.Header1`, `Sig.Header2`)
// make FS's NCA header fixed-key signature failure branch a nop, so games installed for HOME with
// plain keys open (tools/fs-sig-profile.json; RAM only, until restart). Their bytes come from the
// full FS dump like the guard's and are fingerprinted whole.
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const HERE = __dirname;
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const check = (ok, why) => { if (!ok) throw Error(why); };
let KINDS = ['base', 'ctx', 'rt', 'sdfs', 'registry'];            // Lua kind index = position + 1; main adds log/trace
const LOG_DIR = '/ns2jb-modloader/logs', LOG_STEM = 'onconsole-', LOG_DIGITS = 4, LOG_KEEP = 4, TRACE_BYTES = 40960;
const GUARD_PROGRAM = '0100ee5021c9e000', GUARD_USER = 'ffffffffffffffffffffffffffffffff';
// Users whose Seedsow saves are never written by tools: main (research) and third (exploit save).
const PROTECTED_USERS = [];
const logName = i => LOG_STEM + String(i).padStart(LOG_DIGITS, '0');

function args(argv) {
  const o = {ml: path.resolve(HERE, '../../tools/ns2jb-modloader-source'), titles: [], checks: [],
    out: path.resolve(HERE, '../sd/kaihen/ml/install'), logs: true, trace: true,
    guard: true, guardProgram: GUARD_PROGRAM, guardUser: GUARD_USER, liveSizes: true,
    guardProfile: path.join(HERE, 'fs-guard-profile.json'),
    sigPatch: false, sigProfile: path.join(HERE, 'fs-sig-profile.json')};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = () => { const x = argv[++i]; check(x !== undefined, 'missing value after ' + a); return x; };
    if (a === '--ml') o.ml = path.resolve(v());
    else if (a === '--capture') o.capture = path.resolve(v());
    else if (a === '--plan') o.plan = path.resolve(v());
    else if (a === '--tree') o.tree = path.resolve(v());
    else if (a === '--sd-root') o.sdRoot = path.resolve(v());
    else if (a === '--title') o.titles.push(v().toLowerCase());
    else if (a === '--views-from') o.viewsFrom = path.resolve(v());
    else if (a === '--out') o.out = path.resolve(v());
    else if (a === '--check-session') o.checks.push(path.resolve(v()));
    else if (a === '--vectors') o.vectors = path.resolve(v());
    else if (a === '--no-logs') { o.logs = false; o.trace = false; }
    else if (a === '--no-trace') o.trace = false;
    else if (a === '--no-guard') o.guard = false;
    else if (a === '--guard-user') o.guardUser = v().toLowerCase();
    else if (a === '--guard-program') o.guardProgram = v().toLowerCase();
    else if (a === '--guard-profile') o.guardProfile = path.resolve(v());
    else if (a === '--full-capture') o.fullCapture = path.resolve(v());
    else if (a === '--no-live-sizes') o.liveSizes = false;
    else if (a === '--sig-patch') o.sigPatch = true;
    else if (a === '--sig-profile') o.sigProfile = path.resolve(v());
    else throw Error('unknown option ' + a);
  }
  check([o.plan, o.tree, o.sdRoot].filter(Boolean).length === 1, 'give exactly one of --plan, --tree, --sd-root');
  o.capture ??= path.join(o.ml, 'state/switch2-1gvoAG/native-fs/fs-4.bin');
  if (o.guard) {
    check(/^[0-9a-f]{16}$/.test(o.guardProgram) && !/^0+$/.test(o.guardProgram), 'bad --guard-program ' + o.guardProgram);
    check(/^[0-9a-f]{32}$/.test(o.guardUser) && !/^0+$/.test(o.guardUser), 'bad --guard-user (32 hex digits, byte order as mxdump prints it)');
    check(!PROTECTED_USERS.includes(o.guardUser), 'the guard must not allow a protected user (main or third): ' + o.guardUser);
  }
  return o;
}

// ---------- save-open guard sites ----------
// The capture plus the guard functions' bytes from the full dump of the same FS build.
function guardCapture(o, capture) {
  const profile = JSON.parse(fs.readFileSync(o.guardProfile, 'utf8'));
  check(profile.schema === 1 && profile.ranges.length === 2, 'unexpected guard profile ' + o.guardProfile);
  check(sha(capture) === profile.capture_sha256, 'the guard profile was made for capture ' + profile.capture_sha256.slice(0, 8) +
    ', not ' + sha(capture).slice(0, 8));
  const full = fs.readFileSync(o.fullCapture || path.resolve(path.dirname(o.guardProfile), profile.full_dump));
  check(sha(full) === profile.full_dump_sha256 && full.length === capture.length, 'full FS dump differs from the guard profile');
  let nonzero = 0;
  for (let i = 0; i < capture.length; i++) if (capture[i]) { nonzero++; check(full[i] === capture[i], 'full FS dump differs from the capture at +0x' + i.toString(16)); }
  const out = Buffer.from(capture), ranges = [];
  for (const r of profile.ranges) {
    const bytes = full.subarray(r.offset, r.offset + r.size);
    check(sha(bytes) === r.sha256, r.name + ' bytes differ from the guard profile');
    check(capture.subarray(r.offset, r.offset + r.size).every(x => x === 0), r.name + ' overlaps captured bytes');
    bytes.copy(out, r.offset);
    ranges.push({name: r.name, off: r.offset, bytes: r.size, sha256: r.sha256});
  }
  return {capture: out, ranges, nonzero, refuse: profile.refuse_result};
}

// ---------- signature patch sites ----------
// Two 16-byte hooks from the full dump: the first word (tbz to the 2002-4518 path) becomes a nop.
const NOP = '1f2003d5';
function sigSites(o, capture) {
  const profile = JSON.parse(fs.readFileSync(o.sigProfile, 'utf8'));
  check(profile.schema === 1 && profile.sites.length === 2, 'unexpected signature profile ' + o.sigProfile);
  check(sha(capture) === profile.capture_sha256, 'the signature profile was made for capture ' + profile.capture_sha256.slice(0, 8) +
    ', not ' + sha(capture).slice(0, 8));
  const full = fs.readFileSync(o.fullCapture || path.resolve(path.dirname(o.sigProfile), profile.full_dump));
  check(sha(full) === profile.full_dump_sha256 && full.length === capture.length, 'full FS dump differs from the signature profile');
  return profile.sites.map(s => {
    const bytes = full.subarray(s.offset, s.offset + 16);
    check(bytes.toString('hex') === s.orig && sha(bytes) === s.sha256, s.name + ' bytes differ from the signature profile');
    check(s.orig.startsWith(s.first_word) && (bytes.readUInt32LE(0) & 0x7f000000) === 0x36000000, s.name + ' does not start with tbz');
    check(capture.subarray(s.offset, s.offset + 16).every((x, i) => x === 0 || x === bytes[i]), s.name + ' differs from captured bytes');
    return {name: s.name, offset: s.offset, originalHex: s.orig, replacementHex: NOP + s.orig.slice(8)};
  });
}

// ---------- plan ----------
const SD_ROOT = '/ns2jb-modloader';
const IGNORED = ['.DS_Store', 'Thumbs.db', '.gitkeep'];

function treeFromRows(rows) {
  const tree = new Map();
  const add = (p, type, size) => {
    p = p.replace(/\/+$/, '');
    check(p === SD_ROOT || p.startsWith(SD_ROOT + '/'), 'listing path outside ' + SD_ROOT + ': ' + p);
    if (!tree.has(p)) tree.set(p, type === 'directory' ? {type, children: []} : {type, size});
    else check(tree.get(p).type === type, 'listing has ' + p + ' as both file and directory');
    if (p === SD_ROOT) return;
    const parent = path.posix.dirname(p);
    add(parent, 'directory');
    const kids = tree.get(parent).children, name = path.posix.basename(p);
    if (!kids.includes(name) && !IGNORED.includes(name)) kids.push(name);
  };
  add(SD_ROOT, 'directory');
  for (const r of rows) add(r.path, r.type, r.size);
  return tree;
}

function readListing(file) {
  const text = fs.readFileSync(file, 'utf8');
  if (text.trimStart().startsWith('[')) {
    return JSON.parse(text).map(r => ({path: r.path, type: r.type === 'file' ? 'file' : 'directory', size: r.size}));
  }
  const rows = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let m;
    if ((m = /^D (\/.*)$/.exec(line))) rows.push({path: m[1], type: 'directory'});
    else if ((m = /^F (\d+) (\/.*)$/.exec(line))) rows.push({path: m[2], type: 'file', size: Number(m[1])});
    else throw Error('unreadable listing line: ' + line);
  }
  return rows;
}

function rowsFromLocal(dir) {
  const rows = [];
  const walk = (local, sd) => {
    for (const e of fs.readdirSync(local, {withFileTypes: true})) {
      const l = path.join(local, e.name), s = sd + '/' + e.name;
      check(!e.isSymbolicLink(), 'symlink in SD copy: ' + l);
      if (e.isDirectory()) { rows.push({path: s, type: 'directory'}); walk(l, s); }
      else if (e.isFile()) rows.push({path: s, type: 'file', size: fs.statSync(l).size});
    }
  };
  walk(dir, SD_ROOT);
  return rows;
}

function planFromTree(o, ML) {
  const rows = o.tree ? readListing(o.tree) : rowsFromLocal(o.sdRoot);
  const tree = treeFromRows(rows);
  const stat = name => {
    const r = tree.get(name); check(r, 'not in the SD listing: ' + name);
    return {size: r.size, isSymbolicLink: () => false, isFile: () => r.type === 'file', isDirectory: () => r.type === 'directory'};
  };
  const io = {remote: true, existsSync: n => tree.has(n), statSync: stat, lstatSync: stat,
    readdirSync: (n, opt) => tree.get(n).children.map(c => opt?.withFileTypes ? {name: c, ...stat(n + '/' + c)} : c)};
  const {collectMods} = require(path.join(ML, 'lib/mods.cjs'));
  const collection = collectMods(SD_ROOT, io);
  if (o.titles.length) {                                   // same selection as install.cjs describe()
    collection.games = collection.games.filter(g => o.titles.includes(g.titleId));
    for (const id of o.titles) if (!collection.games.some(g => g.titleId === id))
      collection.games.push({titleId: id, romfs: [], exefs: [], patches: [], stubs: []});
  }
  const lists = [collection.patches, ...collection.games.map(g => g.patches)];
  for (const list of lists) for (let i = 0; i < list.length; i++) if (list[i].format === 'pchtxt') {
    check(o.sdRoot, '.pchtxt patches need --sd-root (their text is compiled on the PC): ' + list[i].sdPath);
    const {compileTextPatch} = require(path.join(ML, 'lib/patch-input.cjs'));
    const local = path.join(o.sdRoot, ...list[i].sdPath.slice(SD_ROOT.length + 1).split('/'));
    list[i] = compileTextPatch(list[i], fs.readFileSync(local));
  }
  return {plan: require(path.join(ML, 'lib/lazy-context.cjs')).plan(collection, 'onconsole'), collection};
}

function loadPlan(o, ML) {
  let plan, payload = Buffer.alloc(0), origin, collection;
  if (o.plan) {
    plan = JSON.parse(fs.readFileSync(o.plan, 'utf8'));
    check(plan.schema === 5 && plan.lazy, 'expected a lazy schema-5 load.cjs plan');
    if (o.titles.length) {
      plan.lazyGames = plan.lazyGames.filter(g => o.titles.includes(g.titleId));
      check(plan.lazyGames.length === o.titles.length, 'a --title is not in the recorded plan');
      plan.titleIds = plan.lazyGames.map(g => g.titleId);
    }
    if (plan.views.length) payload = fs.readFileSync(path.join(path.dirname(o.plan), plan.payload.filename));
    origin = {kind: 'recorded plan', file: o.plan, session: plan.session};
  } else {
    ({plan, collection} = planFromTree(o, ML));
    origin = {kind: o.tree ? 'SD listing' : 'local SD copy', file: o.tree || o.sdRoot};
  }
  if (o.viewsFrom) {
    const v = JSON.parse(fs.readFileSync(o.viewsFrom, 'utf8'));
    check(v.views?.length, 'no static views in ' + o.viewsFrom);
    for (const view of v.views) check(!plan.titleIds.includes(view.titleId), 'static view title is also a lazy title: ' + view.titleId);
    plan.views = v.views; plan.payload = v.payload;
    payload = fs.readFileSync(path.join(path.dirname(o.viewsFrom), v.payload.filename));
    origin.views = {file: o.viewsFrom, session: v.session};
  }
  check(sha(payload) === plan.payload.sha256 && payload.length === plan.payload.size, 'static view payload differs from its plan');
  // A recorded plan's own report belongs to its PC session; withLogs() adds the console's.
  delete plan.diagnostics; plan.runtimeDiagnostics = false; plan.runtimeTrace = false;
  return {plan, payload, origin, collection};
}

// The plan with the console report for boot counter `index` (same text length for every index).
function withLogs(ML, plan, collection, index, trace) {
  const {report} = require(path.join(ML, 'lib/diagnostics.cjs'));
  const name = logName(index), sdPath = LOG_DIR + '/' + name + '.log';
  const r = report({session: name, sdPath, collection, plan, trace});
  const text = r.buffer.toString('utf8');
  check(Buffer.byteLength(text) === r.buffer.length && r.buffer.length < 1024 * 1024, 'report text is not plain or too large');
  return {...plan, runtimeDiagnostics: true, runtimeTrace: trace,
    diagnostics: {...r, buffer: undefined, text, size: r.buffer.length}};
}

// ---------- reference builds ----------
async function reference(ML, plan, payload, capture, t, scratch, file) {
  const {buildAll} = require(path.join(ML, 'lib/native.cjs'));
  const {buildContext} = require(path.join(ML, 'lib/context.cjs'));
  const native = await buildAll(t.base, t.ctx, plan, {capture, directory: scratch, runtimeAddress: t.rt});
  const source = {filesystem: {object: t.sdfs}, registry: t.registry};
  if (plan.guard) source.pidFloor = t.pidfloor;
  if (plan.diagnostics) {                                  // the IFile methods are FS functions (checked live)
    source.logFile = {object: t.log, write: t.base + BigInt(file.write), flush: t.base + BigInt(file.flush),
      setSize: t.base + BigInt(file.setSize)};
    if (plan.diagnostics.tracePath) source.traceFile = {object: t.trace};
  }
  const context = buildContext(plan, source, t.base, t.ctx, native, 0, payload);
  return {native, runtime: Buffer.from(native.runtimeCode), gateway: Buffer.from(native.code), context};
}

// Write boot counter `index` into the name digits of a context blob.
function nameAt(blob, offsets, index) {
  const out = Buffer.from(blob), digits = String(index).padStart(LOG_DIGITS, '0');
  for (const off of offsets) out.write(digits, off, 'ascii');
  return out;
}

function classify(name, ref0, variants, t0) {
  // variants: [{kind, delta, bytes}] each with one live value moved by delta.
  const fix = new Map();                                   // offset -> {kind, addend}
  for (const v of variants) {
    check(v.bytes.length === ref0.length, name + ': size depends on ' + v.kind);
    for (let i = 0; i < ref0.length; i++) {
      if (ref0[i] === v.bytes[i]) continue;
      const at = i - i % 8;
      const a = ref0.readBigUInt64LE(at), b = v.bytes.readBigUInt64LE(at);
      check(BigInt.asUintN(64, b - a) === v.delta,
        `${name}+${at}: changes with ${v.kind} but not by exactly its delta (${a.toString(16)} -> ${b.toString(16)})`);
      const prev = fix.get(at);
      check(!prev || prev.kind === v.kind, `${name}+${at}: depends on both ${prev?.kind} and ${v.kind}`);
      fix.set(at, {kind: v.kind, addend: BigInt.asUintN(64, a - t0[v.kind])});
      i = at + 7;
    }
  }
  const blob = Buffer.from(ref0);
  const list = [...fix.entries()].sort((x, y) => x[0] - y[0]).map(([off, f]) => ({off, ...f}));
  for (const f of list) {
    check(f.addend < 2n ** 40n, `${name}+${f.off}: addend 0x${f.addend.toString(16)} too large`);
    blob.writeBigUInt64LE(0n, f.off);
  }
  return {blob, fixups: list};
}

function apply(blob, fixups, t) {
  const out = Buffer.from(blob);
  for (const f of fixups) out.writeBigUInt64LE(BigInt.asUintN(64, t[f.kind] + f.addend), f.off);
  return out;
}

function adler32(b) {
  let a = 1, s = 0;
  for (const x of b) { a = (a + x) % 65521; s = (s + a) % 65521; }
  return s * 65536 + a;
}

// ---------- Lua manifest ----------
function lua(v, ind = '') {
  if (typeof v === 'bigint') { check(v < 2n ** 53n, 'number too large for Lua'); return v.toString(); }
  if (typeof v === 'number') { check(Number.isSafeInteger(v), 'not an integer: ' + v); return String(v); }
  if (typeof v === 'string') {                                      // printable ASCII: JSON escapes are then valid Lua
    check(/^[\x20-\x7e]*$/.test(v), 'non-ASCII string in manifest: ' + JSON.stringify(v));
    return JSON.stringify(v);
  }
  if (typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) {
    if (v.every(x => typeof x === 'number' || typeof x === 'bigint')) return '{' + v.map(x => lua(x)).join(', ') + '}';
    return '{\n' + v.map(x => ind + '  ' + lua(x, ind + '  ') + ',').join('\n') + '\n' + ind + '}';
  }
  const keys = Object.keys(v);
  return '{\n' + keys.map(k => ind + '  ' + (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : '[' + JSON.stringify(k) + ']') +
    ' = ' + lua(v[k], ind + '  ') + ',').join('\n') + '\n' + ind + '}';
}

// ---------- main ----------
async function main() {
  const o = args(process.argv.slice(2));
  const ML = o.ml;
  const capture = fs.readFileSync(o.capture);
  const {validateCapture} = require(path.join(ML, 'lib/native.cjs'));
  const validation = validateCapture(capture);
  const guard = o.guard ? guardCapture(o, capture) : null;
  const sig = o.sigPatch ? sigSites(o, capture) : [];
  const fsLayout = validation.layout || null;
  const resolve = r => require(path.join(ML, 'lib/native/fs-layout.cjs')).offset(fsLayout, r);
  const {artifacts} = require(path.join(ML, 'lib/native/artifacts.cjs'));
  const art = artifacts();                                 // checks prebuilt hashes against sources
  const templatesSha = art.manifest.files['templates.json'];
  const offsets = art.templates.runtime.offsets;

  const {plan, payload, origin, collection} = loadPlan(o, ML);
  // Same report header lines as install.cjs (FS profile, native components).
  const profileFile = path.join(path.dirname(o.capture), 'manifest.json');
  if (fs.existsSync(profileFile)) {
    const p = JSON.parse(fs.readFileSync(profileFile, 'utf8'));
    plan.nativeProfile = {sha256: p.sha256, validatedRanges: p.validatedRanges, pid: p.pid, programId: p.programId,
      runtimeLoggingCompatible: p.runtimeLoggingCompatible, resolution: p.layout ? 'relocated-functions' : 'verified-offsets'};
    check(p.runtimeLoggingCompatible !== false || !o.logs, 'this FS build is not compatible with runtime logging; use --no-logs');
  }
  plan.nativeRuntime = templatesSha;
  if (guard) plan.guard = {program: o.guardProgram, user: o.guardUser};
  if (o.liveSizes) plan.liveSizes = true;
  if (o.logs) KINDS = [...KINDS, 'log', ...(o.trace ? ['trace'] : [])];
  if (guard) KINDS = [...KINDS, 'pidfloor'];
  const planFor = index => o.logs ? withLogs(ML, plan, collection, index, o.trace) : plan;
  const plan0 = planFor(0);
  const layout = require(path.join(ML, 'lib/context.cjs')).layout(plan0);
  check(layout.bytes <= 0x100000, 'context over 1 MiB needs the allocate_block path; not supported by the image yet');
  const file = {write: resolve(0x1050a0), flush: resolve(0x1053d0), setSize: resolve(0x105410)};

  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ml-image-'));
  try {
    // Reference builds read hook prologues from the capture: with the guard, from the capture
    // plus the two guard functions (and nothing else) from the full dump.
    const buildCapture = guard ? path.join(scratch, 'fs-guard.bin') : o.capture;
    if (guard) {
      fs.writeFileSync(buildCapture, guard.capture);
      check(validateCapture(guard.capture).sha256 === sha(guard.capture), 'guard capture does not validate');
    }
    // Base values (REC-like) and one distinct delta per live value.
    const t0 = {base: 0x13e9600000n, ctx: 0x13ea3b2000n, rt: 0x8000000n, sdfs: 0x13ea37aa50n, registry: 0x13ea1c0010n,
      log: 0x13ea37aae0n, trace: 0x13ea37a8d0n, pidfloor: 0x55n};
    const delta = {base: 0x1a00000000n, ctx: 0x2c40d0n, rt: 0x7000000n, sdfs: 0x5310n, registry: 0x61b0n,
      log: 0x7130n, trace: 0x8250n, pidfloor: 0x31n};
    const r0 = await reference(ML, plan0, payload, buildCapture, t0, scratch, file);
    const varied = {};
    for (const k of KINDS) varied[k] = await reference(ML, plan0, payload, buildCapture, {...t0, [k]: t0[k] + delta[k]}, scratch, file);
    const parts = {};
    for (const part of ['runtime', 'gateway', 'context'])
      parts[part] = classify(part, r0[part], KINDS.map(k => ({kind: k, delta: delta[k], bytes: varied[k][part]})), t0);
    for (const k of KINDS) {                               // hooks: offsets and bytes must not move
      check(JSON.stringify(varied[k].native.hooks.map(h => [h.name, h.offset, h.originalHex, h.replacementHex])) ===
        JSON.stringify(r0.native.hooks.map(h => [h.name, h.offset, h.originalHex, h.replacementHex])), 'hooks depend on ' + k);
    }
    for (const part of ['runtime', 'gateway']) check(parts[part].fixups.every(f => ['base', 'ctx', 'rt'].includes(f.kind)),
      part + ' depends on a value other than base/ctx/rt');

    // Report name digits (boot counter) inside the context: the report text copy and the trace path.
    const nameOffsets = [];
    if (o.logs) {
      const token = Buffer.from(logName(0), 'ascii');
      for (let at = r0.context.indexOf(token); at >= 0; at = r0.context.indexOf(token, at + 1)) nameOffsets.push(at + LOG_STEM.length);
      check(nameOffsets.length >= 2, 'report name not found in the context');
      for (const off of nameOffsets) for (const f of parts.context.fixups)
        check(off + LOG_DIGITS <= f.off || off >= f.off + 8, 'report name digits overlap a fixup slot');
      const d = plan0.diagnostics;
      check(parts.context.fixups.every(f => f.off + 8 <= layout.logOffset || f.off >= layout.logOffset + d.size), 'fixup inside the report text');
    }

    // Differential check against fresh reference builds for unrelated value sets (and boot counters).
    const trials = [
      {base: 0x5b0600000n, ctx: 0x5b1394a00n, rt: 0x8000000n, sdfs: 0x5b1370150n, registry: 0x5b1200010n,      // M2-boot-like
        log: 0x5b1370e60n, trace: 0x5b1371b10n, pidfloor: 0x51n, index: 1},
      {base: 0x172e000000n, ctx: 0x172edbf000n, rt: 0x8000000n, sdfs: 0x172ed67780n, registry: 0x172ec11230n,  // akVICv-like
        log: 0x172ed67660n, trace: 0x172ed67450n, pidfloor: 0x6an, index: 42},
      {base: 0x6b29a00000n, ctx: 0x6b2a800040n, rt: 0x9234000n, sdfs: 0x6b2a75f000n, registry: 0x6b2a6a0010n,
        log: 0x6b2a75f300n, trace: 0x6b2a75f900n, pidfloor: 0x1234n, index: 9999},
    ];
    const verified = [];
    for (const [i, t] of trials.entries()) {
      const r = await reference(ML, planFor(t.index), payload, buildCapture, t, scratch, file);
      const named = {...parts, context: {...parts.context, blob: nameAt(parts.context.blob, nameOffsets, t.index)}};
      for (const part of ['runtime', 'gateway', 'context'])
        check(apply(named[part].blob, named[part].fixups, t).equals(r[part]), `differential check failed: ${part} for base 0x${t.base.toString(16)}`);
      verified.push('0x' + t.base.toString(16) + (o.logs ? '/' + logName(t.index) : ''));
      if (o.vectors) {                                     // reference bytes for test/image_apply.lua
        const d = path.join(o.vectors, 't' + (i + 1));
        fs.mkdirSync(d, {recursive: true});
        for (const part of ['runtime', 'gateway', 'context']) fs.writeFileSync(path.join(d, part + '.bin'), r[part]);
        fs.writeFileSync(path.join(d, 'values.lua'), 'return ' + lua({...Object.fromEntries(KINDS.map(k => [k, t[k]])), log_index: t.index}) + '\n');
      }
    }

    // Replays against recorded PC installs.
    const replays = [];
    for (const dir of o.checks) replays.push(replay(dir, plan0, layout, templatesSha, parts, r0.native.hooks));

    // Signature patch hooks go last (after the save guard), in the same {name, offset, bytes} form.
    const hooks = [...r0.native.hooks, ...sig];
    for (const s of sig) check(!r0.native.hooks.some(h => Math.abs(h.offset - s.offset) < 16), s.name + ' overlaps another hook');

    // Fingerprint: 16 bytes at every FS function the image depends on.
    const refs = new Set([...hooks.map(h => h.offset)]);
    for (const r of [0x694c0, 0x69580, 0x215620, 0x215800, 0x2187d0, 0x218870, 0x121400, 0x24a7a0,
      0x1077b0, 0x107bc0, 0x107cd0, 0x1201b0, 0x4b8c0, 0x103390]) refs.add(resolve(r));
    // Guard functions come from the full dump: fingerprint them whole (s2_ml compares every byte).
    const whole = new Map((guard ? guard.ranges : []).map(r => [r.off, r.bytes]));
    const code = Buffer.from(guard ? guard.capture : capture);
    for (const s of sig) Buffer.from(s.originalHex, 'hex').copy(code, s.offset);
    const fingerprint = [...refs].sort((a, b) => a - b).map(off => [off, code.subarray(off, off + (whole.get(off) || 16)).toString('hex')]);
    check(fingerprint.every(([off, hex]) => !/^(00)+$/.test(hex)), 'a fingerprinted FS function is not in the capture');
    if (guard) {
      const names = r0.native.hooks.map(h => h.name);
      check(guard.ranges.every(r => names.includes(r.name) && whole.has(r.off) && refs.has(r.off)), 'guard hooks missing from the build');
    }
    const cave = resolve(0x24d100), control = resolve(0x24d800);
    check(capture.subarray(cave, cave + 1024).every(x => x === 0) && capture.subarray(control, control + 256).every(x => x === 0),
      'capture caves are not zero');

    // Files the lazy plan opens by path, for a stale-plan check on the console.
    const files = [];
    for (const g of plan.lazyGames) for (const f of g.files) if (f.sdPath) files.push({title: g.titleId, kind: f.kind, path: f.sdPath, size: f.size});
    for (const f of plan.lazyPatches) if (f.sdPath) files.push({title: 'global', kind: f.kind, path: f.sdPath, size: f.size});

    // Write the image.
    fs.mkdirSync(o.out, {recursive: true});
    const blobs = {runtime: 'runtime.bin', gateway: 'gateway.bin', context: 'context.bin'};
    for (const [part, file] of Object.entries(blobs)) fs.writeFileSync(path.join(o.out, file), parts[part].blob);
    const flat = list => list.flatMap(f => [f.off, KINDS.indexOf(f.kind) + 1, f.addend]);
    const counts = part => Object.fromEntries(KINDS.map(k => [k, parts[part].fixups.filter(f => f.kind === k).length]));
    const manifest = {
      format: 1,
      generated: new Date().toISOString(),
      builder: 'semi-untethered-port/tools/build_install_image.cjs',
      modloader: {templates_sha256: templatesSha, runtime_bytes: Buffer.from(art.templates.runtime.code, 'base64').length},
      plan: {origin: origin.kind, file: origin.file, session: origin.session || '', views_from: origin.views?.file || '',
        titles: plan.titleIds, views: plan.views.map(v => v.titleId), global_patches: plan.lazyPatches.length,
        layout: Object.fromEntries(Object.entries(layout).map(([k, v]) => [k, v]))},
      fs: {
        sha256: validation.sha256 || sha(capture), text_bytes: capture.length, program: '0400000000000000',
        cave: cave, cave_bytes: 1024, control_cave: control, control_bytes: 256, cave_page: cave - cave % 0x1000,
        notifier_slot4: resolve(0x1201b0),
        registry_global: resolve(0x11e12d0), registry_add: 16, block_manager: resolve(0x11ee960),
        allocate: resolve(0x694c0), free: resolve(0x69580), allocate_block: resolve(0x215620), free_block: resolve(0x215800),
        sdfs_vtable0: resolve(0x4b8c0), sdfs_vtable1: resolve(0x103390), sdfs_ref_offset: 0x28,
        // IFile method table (report/trace files): slots 0 AddRef, 1 Release, 4 Read, 5 Write, 6 Flush, 7 SetSize
        file_vtable: [resolve(0x1036f0), resolve(0x104e10), 0, 0, resolve(0x104ef0), file.write, file.flush, file.setSize],
        file_ref_offset: 0x20,
      },
      fingerprint,
      kinds: KINDS,
      logs: o.logs ? {dir: LOG_DIR, stem: LOG_STEM, digits: LOG_DIGITS, keep: LOG_KEEP, name_offsets: nameOffsets,
        text_offset: layout.logOffset, text_bytes: plan0.diagnostics.size, ready_offset: plan0.diagnostics.readyOffset,
        trace: o.trace, trace_bytes: TRACE_BYTES, clock_probe: o.trace ? layout.traceOffset + 49136 : 0} : false,
      runtime: {file: blobs.runtime, bytes: parts.runtime.blob.length, pages: parts.runtime.blob.length / 0x1000,
        sha256: sha(parts.runtime.blob), adler32: adler32(parts.runtime.blob), expected_va: 0x8000000,
        entry: {lfs_initialize: offsets.lfs_initialize, lfs_activate: offsets.lfs_activate, lfs_zero: offsets.lfs_zero,
          lfs_trace_clock_probe: offsets.lfs_trace_clock_probe},
        fixup_counts: counts('runtime'), fixups: flat(parts.runtime.fixups)},
      gateway: {file: blobs.gateway, bytes: parts.gateway.blob.length, sha256: sha(parts.gateway.blob),
        adler32: adler32(parts.gateway.blob), fixup_counts: counts('gateway'), fixups: flat(parts.gateway.fixups)},
      context: {file: blobs.context, bytes: parts.context.blob.length, sha256: sha(parts.context.blob),
        adler32: adler32(parts.context.blob), alloc: 'heap', magic: 'NS2LFS02', enabled_offset: 8,
        romfs: layout.romfs, lazy: layout.lazyOffset,
        fixup_counts: counts('context'), fixups: flat(parts.context.fixups)},
      hooks: hooks.map(h => ({name: h.name, off: h.offset, orig: h.originalHex, repl: h.replacementHex})),
      sig_patch: sig.length ? {result: 0x234c02, sites: sig.map(s => ({name: s.name, off: s.offset}))} : false,
      files: files.map(f => ({title: f.title, kind: f.kind, path: f.path, size: f.size})),
      live_sizes: o.liveSizes,
      guard: guard ? {program: o.guardProgram, user: o.guardUser, result: guard.refuse, pid_floor: 'helper RO pid (kind pidfloor)',
        sites: guard.ranges.map(r => ({name: r.name, off: r.off, bytes: r.bytes, sha256: r.sha256})),
        full_dump_sha256: sha(fs.readFileSync(o.fullCapture || path.resolve(path.dirname(o.guardProfile),
          JSON.parse(fs.readFileSync(o.guardProfile, 'utf8')).full_dump)))} : false,
      verified: {differential: verified, replays: replays.map(r => r.summary)},
    };
    // sizes over 2^53 cannot be Lua numbers; file sizes are well below that (7.2 GB romfs.bin is fine)
    fs.writeFileSync(path.join(o.out, 'image.lua'),
      '-- generated by semi-untethered-port/tools/build_install_image.cjs; do not edit\n' +
      '-- kinds: 1 base (FS .text), 2 ctx, 3 rt (runtime VA), 4 sdfs (SD IFileSystem object), 5 registry,\n' +
      '--        6 log (report IFile object), 7 trace (trace IFile object), pidfloor (helper RO pid);\n' +
      '--        the Lua kind index is the position in `kinds` below\n' +
      '-- live_sizes: the runtime mounts the files at their size on SD at each launch (sizes in `files` are informational)\n' +
      '-- guard: account-save opens by the guarded program after the pid floor are refused except for `user`\n' +
      '-- logs.name_offsets: context offsets of the 4 boot-counter digits in "onconsole-NNNN"\n' +
      '-- fixups are flat triples {offset, kind, addend}: u64 at offset := value[kind] + addend\n' +
      'return ' + lua(manifest) + '\n');

    console.log(`plan: ${origin.kind} ${origin.file}`);
    console.log(`  titles ${plan.titleIds.join(', ') || '(none)'}; static views ${plan.views.map(v => v.titleId).join(', ') || 'none'}; ` +
      `${files.length} SD file(s) opened by path`);
    for (const part of ['runtime', 'gateway', 'context']) {
      const c = counts(part);
      console.log(`${part.padEnd(8)} ${String(parts[part].blob.length).padStart(6)} B, ${parts[part].fixups.length} fixups (` +
        KINDS.filter(k => c[k]).map(k => k + ' ' + c[k]).join(', ') + ')');
    }
    console.log(`hooks    ${hooks.length}${sig.length ? ' (with ' + sig.map(s => s.name + '@0x' + s.offset.toString(16)).join(', ') + ')' : ''}; fingerprint ${fingerprint.length} rows; context alloc ${layout.bytes} B`);
    if (guard) console.log(`guard    ${guard.ranges.map(r => r.name + '@0x' + r.off.toString(16) + '/' + r.bytes).join(', ')} from the full dump ` +
      `(${guard.nonzero} captured bytes agree); program ${o.guardProgram}, allowed user ${o.guardUser}, floor = helper RO pid`);
    else console.log('guard    off');
    console.log(`sizes    ${o.liveSizes ? 'live (marker live_sizes = true)' : 'planned (stale check on the console)'}`);
    if (o.logs) console.log(`logs     ${LOG_DIR}/${LOG_STEM}NNNN.log (${plan0.diagnostics.size} B report text` +
      `${o.trace ? ', .trace ' + TRACE_BYTES + ' B' : ', no trace'}); name digits at ${nameOffsets.length} context offsets`);
    else console.log('logs     off');
    console.log(`differential check vs fresh buildAll/buildContext: OK for bases ${verified.join(', ')}`);
    for (const r of replays) console.log(r.text);
    if (replays.some(r => !r.ok)) process.exitCode = 1;
    console.log('wrote ' + o.out);
  } finally {
    fs.rmSync(scratch, {recursive: true, force: true});
  }
}

// Replay the image with a recorded install's live values and compare with what it wrote.
function replay(dir, plan, layout, templatesSha, parts, hooks) {
  const session = path.basename(dir);
  const ri = JSON.parse(fs.readFileSync(path.join(dir, 'resident-install.json'), 'utf8'));
  const rp = JSON.parse(fs.readFileSync(path.join(dir, 'prepared/overlay.json'), 'utf8'));
  const t = {base: BigInt(ri.base), ctx: BigInt(ri.context), rt: BigInt(ri.runtime.address),
    sdfs: BigInt(ri.filesystem.object), registry: 0n};
  const lines = [], res = {};
  const recLayout = JSON.parse(fs.readFileSync(path.join(dir, 'build/combined-layout.json'), 'utf8'));
  const sameRuntime = rp.nativeRuntime === templatesSha;
  // runtime: depends on base, ctx, ctx+romfs, ctx+lazyOffset only
  if (!sameRuntime) { res.runtime = 'skipped (recorded with templates ' + String(rp.nativeRuntime).slice(0, 8) + ')'; }
  else if (recLayout.context.romfs !== layout.romfs || recLayout.context.lazyOffset !== layout.lazyOffset) {
    res.runtime = 'skipped (context layout differs: romfs ' + recLayout.context.romfs + ')';
  } else {
    const got = apply(parts.runtime.blob, parts.runtime.fixups, t), want = fs.readFileSync(path.join(dir, 'build/runtime.bin'));
    res.runtime = got.equals(want) ? 'identical' : 'DIFFERS';
  }
  // The save guard's gateways and hooks are appended after everything a PC install has; the
  // recorded install is compared with the part before them.
  const guardHooks = hooks.filter(h => h.name.startsWith('Save.')), pcHooks = hooks.filter(h => !h.name.startsWith('Save.'));
  let gw = apply(parts.gateway.blob, parts.gateway.fixups, t);
  const wantGw = fs.readFileSync(path.join(dir, 'build/combined.bin'));
  const appended = guardHooks.length && gw.length > wantGw.length ? gw.length - wantGw.length : 0;
  if (appended) gw = gw.subarray(0, wantGw.length);
  const note = appended ? `; save guard appends ${appended} B` : '';
  if (sameRuntime) res.gateway = gw.equals(wantGw) ? 'identical' + note : 'DIFFERS';
  else {
    // other runtime build: only the trampoline quads (runtime symbol addresses) may differ
    const quads = new Set(parts.gateway.fixups.filter(f => f.kind === 'rt').map(f => f.off));
    let same = gw.length === wantGw.length;
    for (let i = 0; same && i < gw.length; i += 8) if (!quads.has(i) && !gw.subarray(i, i + 8).equals(wantGw.subarray(i, i + 8))) same = false;
    res.gateway = same ? 'identical apart from runtime symbol addresses' + note : 'DIFFERS';
  }
  const recHooks = JSON.stringify(ri.hooks.map(h => [h.name, h.offset, h.originalHex, h.replacementHex]));
  res.hooks = recHooks === JSON.stringify(pcHooks.map(h => [h.name, h.offset, h.originalHex, h.replacementHex])) ?
    'identical (' + ri.hooks.length + ')' + (guardHooks.length ? ' + ' + guardHooks.map(h => h.name).join(', ') : '') : 'DIFFERS';
  const ok = !Object.values(res).includes('DIFFERS');
  // Informational: did this plan come out the same as the one load.cjs built in that session?
  const rows = p => JSON.stringify([p.lazyGames.map(g => [g.titleId, g.files.map(f => [f.name, f.kind, f.size ?? null, f.sdPath ?? null])]),
    p.lazyPatches.map(f => [f.name, f.kind, f.size, f.sdPath]), (p.views || []).map(v => v.titleId)]);
  res.plan = rows(plan) === rows(rp) ? 'same as recorded' : 'differs from recorded (other titles or SD contents)';
  lines.push(`replay ${session} (base 0x${t.base.toString(16)}, ctx 0x${t.ctx.toString(16)}, rt 0x${t.rt.toString(16)}): ` +
    Object.entries(res).map(([k, v]) => k + ' ' + v).join('; '));
  return {ok, text: lines.join('\n'), summary: session + ': ' + Object.entries(res).map(([k, v]) => k + ' ' + v).join('; ')};
}

main().catch(e => { console.error('build_install_image: ' + (e.stack || e)); process.exitCode = 1; });
