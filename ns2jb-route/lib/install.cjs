// SPDX-License-Identifier: GPL-2.0-only
'use strict';
// Install SeedSwap's loader on a held ns2jb run, from the image on the SD card
// (SD:/kaihen/ml/install, the same one the Seedsow route installs and SeedSwap edits).
//
// A port of SD:/kaihen/s2_ml.lua milestone 3 (itself ns2jb-modloader's lib/resident.cjs install,
// from a precomputed image) onto ns2jb-modloader's own PC pieces:
//   native-capture.cjs + Bridge   FS capture, helper RO client, FS calls, patches, data writes
//   game-files attachGame         an IPC session in the held run, for the SD card
// Same checks, same order, same rollback as s2_ml.lua. The ns2jb helper RO keeps running
// afterwards (like install.cjs --keep-rpc); kaiHEN's RO replaces it next.
//
// One attempt per boot: the journal (seedswap-loader.json) refuses a second try in the same run.

const fsp = require('node:fs/promises');
const path = require('node:path');
const I = require('./image.cjs');

const INSTALL_DIR = '/kaihen/ml/install';
const CONFIG = '/seedswap/config.ini';
const RUN_LOG = '/kaihen/seedsow_run.log';   // the Seedsow route's run log; SeedSwap reads the loader's lines there
const ZERO16 = Buffer.alloc(16);
const check = (ok, message) => { if (!ok) throw Error(message); };
const hx = v => '0x' + BigInt(v).toString(16);
const json = v => JSON.stringify(v, (k, x) => typeof x === 'bigint' ? hx(x) : x, 2) + '\n';

// Users the guard must never allow: SD:/seedswap/config.ini exploit_user and protected_users
// (s2_ml.lua protected_users).
function protectedUsers(cfg) {
  const out = new Map();
  const text = '\n' + (cfg || '');
  for (const key of ['exploit_user', 'protected_users']) {
    const m = new RegExp('\\n[ \\t]*' + key + '[ \\t]*=([^\\r\\n]*)').exec(text);
    for (const uid of (m ? m[1] : '').match(/[0-9a-fA-F]+/g) || [])
      if (uid.length === 32 && !out.has(uid.toLowerCase())) out.set(uid.toLowerCase(), key);
  }
  return out;
}

// The SD card through an IPC session in the held run (diagnostics.cjs writeReport does the same).
// ns2jb's own pathMethod only sends read-only path commands, so every path command here uses the
// modloader's pathRequest packet.
function sdCard(a, sd, pathRequest) {
  const {s, domain, filesystem} = a;
  const u32 = v => { const b = Buffer.alloc(4); b.writeUInt32LE(v); return b; };
  async function op(id, name, data = Buffer.alloc(0)) {
    const text = Buffer.from(name, 'utf8');
    check(name.startsWith('/') && !name.includes('\0') && text.length < 0x301, 'invalid SD path ' + name);
    const b = Buffer.alloc(0x304); text.copy(b);
    await s.write(s.base + 0x2000, b);
    return domain.send(s, `SD path ${id} ${name}`, sd, pathRequest(id, data, s.base + 0x2000));
  }
  const card = {
    op,
    async type(p) {                                  // 0 directory, 1 file, null missing
      const r = await op(7, p);
      if (r.canonicalResult === 0x202) return null;
      check(!r.result, `SD GetEntryType ${p}: 0x${r.result.toString(16)}`);
      return r.data.readUInt32LE();
    },
    async open(p, mode) {
      const r = await op(8, p, u32(mode));
      return r.result ? {result: r.result} : {handle: domain.oneHandle(r)};
    },
    async size(h) { return Number(await filesystem.fileSize(s, h)); },
    async read(p, max) {
      const o = await card.open(p, 1);
      check(o.handle, `cannot open SD:${p} (0x${(o.result || 0).toString(16)})`);
      try {
        const size = await card.size(o.handle);
        check(size > 0 && size <= max, `SD:${p} size ${size} is not in 1..${max}`);
        const parts = [];
        for (let at = 0; at < size; at += 0x40000) {
          const n = Math.min(0x40000, size - at), b = await filesystem.readFile(s, o.handle, at, n);
          check(b.length === n, 'short SD read of ' + p);
          parts.push(b);
        }
        return Buffer.concat(parts, size);
      } finally { await s.close(o.handle); }
    },
    async mkdir(p) { const r = await op(2, p); check(!r.result, `cannot create SD:${p} (0x${r.result.toString(16)})`); },
    async remove(p) { return !(await op(1, p)).result; },
    async list(p) { return filesystem.listDirectory(s, sd, p, 4096); },
    // add data at the end (create the file if missing)
    async append(p, data) {
      let size = 0;
      const t = await card.type(p);
      if (t === null) {
        const c = await op(0, p, Buffer.alloc(16));
        check(!c.result, `cannot create SD:${p} (0x${c.result.toString(16)})`);
      } else check(t === 1, p + ' is a folder');
      const o = await card.open(p, 3);
      check(o.handle, `cannot open SD:${p} for writing`);
      try {
        size = await card.size(o.handle);
        const n = Buffer.alloc(8); n.writeBigUInt64LE(BigInt(size + data.length));
        check(!(await s.ipc('Size ' + p, o.handle, 3, n)).result, 'cannot size SD:' + p);
        for (let at = 0; at < data.length; at += 0x40000) {
          const b = data.subarray(at, at + 0x40000);
          await s.write(s.base + 0x6000, b);
          const input = Buffer.alloc(24); input.writeBigUInt64LE(BigInt(size + at), 8); input.writeBigUInt64LE(BigInt(b.length), 16);
          const w = await s.ipc('Append ' + p, o.handle, 1, input, {send: [{address: s.base + 0x6000, size: b.length, mode: 1}]});
          check(!w.result, `cannot write SD:${p} (0x${w.result.toString(16)})`);
        }
        check(!(await s.ipc('Flush ' + p, o.handle, 2)).result, 'cannot flush SD:' + p);
      } finally { await s.close(o.handle); }
    },
    // delete if present, create, size, write, flush, close (s2_ml.lua make_file)
    async writeWhole(p, data) {
      if (await card.type(p) !== null) check(await card.remove(p), 'cannot replace SD:' + p);
      const create = Buffer.alloc(16); create.writeBigUInt64LE(BigInt(data.length), 8);
      const c = await op(0, p, create);
      check(!c.result, `cannot create SD:${p} (0x${c.result.toString(16)})`);
      const o = await card.open(p, 3);
      check(o.handle, `cannot open SD:${p} for writing`);
      try {
        const size = Buffer.alloc(8); size.writeBigUInt64LE(BigInt(data.length));
        check(!(await s.ipc('Size ' + p, o.handle, 3, size)).result, 'cannot size SD:' + p);
        for (let at = 0; at < data.length; at += 0x40000) {
          const b = data.subarray(at, at + 0x40000);
          await s.write(s.base + 0x6000, b);
          const input = Buffer.alloc(24); input.writeBigUInt64LE(BigInt(at), 8); input.writeBigUInt64LE(BigInt(b.length), 16);
          const w = await s.ipc('Write ' + p, o.handle, 1, input, {send: [{address: s.base + 0x6000, size: b.length, mode: 1}]});
          check(!w.result, `cannot write SD:${p} (0x${w.result.toString(16)})`);
        }
        check(!(await s.ipc('Flush ' + p, o.handle, 2)).result, 'cannot flush SD:' + p);
      } finally { await s.close(o.handle); }
    },
  };
  return card;
}

// run: the held ns2jb run folder. modloader: the ns2jb-modloader folder whose lib/ and native/
// are used. directory: where this boot's journal and capture go.
async function installLoader(run, {modloader, directory, log: print = console.log}) {
  run = path.resolve(run);
  const session = path.basename(run);
  const t0 = Date.now(), runLog = [];
  const log = line => { runLog.push(line); print(line); };   // also appended to SD:/kaihen/seedsow_run.log
  const ML = p => require(path.join(modloader, 'lib', p));
  ML('native/artifacts.cjs').artifacts();             // the prebuilt call templates, checked by SHA-256
  const {isUncertain} = ML('game-files/uncertain.cjs');
  const {pathRequest} = ML('game-files/protocol.cjs');
  const {Bridge, CAVE, NOTIFIER} = ML('native/bridge.cjs');

  await fsp.mkdir(directory, {recursive: true, mode: 0o700});
  const journalFile = path.join(directory, 'seedswap-loader.json');
  const st = {session, stage: 'start', started: new Date().toISOString(), pages: [], gatewayRows: [], hooks: 0};
  await fsp.writeFile(journalFile, json(st), {flag: 'wx', mode: 0o600}).catch(e => {
    if (e.code === 'EEXIST') throw Error('SeedSwap\'s loader was already tried on this run; restart the console to try again');
    throw e;
  });
  const save = () => fsp.writeFile(journalFile, json(st), {mode: 0o600});
  const stage = async name => { st.stage = name; await save(); };

  let b = null, a = null, sdh = null, sd = null, img, F, rtva = 0n, initialized = false, active = false;
  const reportHandles = [];
  const readCode = (addr, n) => b.read(BigInt(addr), n);
  const readFs = (addr, n) => b.m.read(Number(addr), n);
  const u64 = async addr => (await readFs(addr, 8)).readBigUInt64LE();
  const u32 = async addr => (await readFs(addr, 4)).readUInt32LE();
  async function info(addr) {
    const r = await b.c.info(b.h, BigInt(addr), b.pid), m = r.memory || {};
    return {result: r.result, base: BigInt(m.address ?? 0), size: BigInt(m.size ?? 0), type: m.type, perm: m.permissions,
      attr: m.attributes, free: BigInt(r.freeAddress || 0)};
  }
  const fsCall = (off, args, label, opts) => b.call(off, args.map(BigInt), label, opts);
  async function runtimeCall(entry, args, label) {
    const row = {label, address: hx(rtva + BigInt(entry)), args: args.map(String), pending: true};
    b.record.operations.push(row); await b.save();
    return b.invoke(args.map(BigInt), row, rtva + BigInt(entry));
  }

  async function install() {
    await stage('capture FS');
    const cap = await ML('native-capture.cjs').captureNative(run, directory, {retainClient: true});
    b = new Bridge();
    b.c = cap.client;                                  // closed below if open() fails
    b.progress = (label, status) => { st.nativeOperation = {label, status}; };
    await stage('open bridge');
    await b.open(run, {captureFile: cap.file, client: cap.client, processHandle: cap.processHandle, directory});
    const base = b.base, fsPid = BigInt(b.pid), helperPid = BigInt(b.c.pid);
    st.base = base; st.fsPid = fsPid; st.helperPid = helperPid;
    log(`FS pid ${fsPid}, .text ${hx(base)}; ns2jb helper RO pid ${helperPid}`);

    a = await ML('game-files/mount-api.cjs').attachGame(run);
    const layout = JSON.parse(await fsp.readFile(path.join(run, 'switch2/ro', session + '-layout.json'), 'utf8'));
    sdh = a.domain.oneHandle(await a.s.ipc('Open SD (SeedSwap loader)', a.root, 18));
    sd = sdCard(a, sdh, pathRequest);

    await stage('load image');
    img = await I.load((p, max) => sd.read(p, max), INSTALL_DIR);
    F = img.fs;
    // s2_ml.lua's wording: SeedSwap reads the titles from this line (model.c load_loader_state)
    log(`image ${img.generated}: titles ${img.plan.titles.join(',')}, views ${(img.plan.views || []).join(',') || 'none'}; ` +
      `runtime ${img.runtime.bytes} B/${img.runtime.fixups.length / 3} fixups, gateway ${img.gateway.bytes} B, ` +
      `context ${img.context.bytes} B/${img.context.fixups.length / 3} fixups, ${img.hooks.length} hooks`);

    await stage('check FS build');
    check(F.cave === CAVE && F.control_cave === 0x24d800 && F.notifier_slot4 === NOTIFIER, 'image FS layout differs from the bridge');
    check(F.allocate === 0x694c0, 'image allocate differs from the bridge\'s clearing allocation');
    for (const off of [F.cave, F.control_cave, F.notifier_slot4, F.allocate, F.free, F.allocate_block, F.free_block])
      check(b.offset(off) === off, 'this FS build is laid out differently from the image\'s');
    check(b.capture.length === F.text_bytes, `FS capture is ${b.capture.length} B, the image's .text ${F.text_bytes} B`);
    const first = await info(base), last = await info(base + BigInt(F.text_bytes - 1));
    check(!first.result && first.base === base && [4, 5].includes(first.perm), 'FS .text start is not code');
    check(!last.result && [4, 5].includes(last.perm) && last.base + last.size === base + BigInt(F.text_bytes),
      `FS .text does not end at ${hx(F.text_bytes)}`);
    const bad = await I.checkFingerprint(img, base, readCode);
    check(!bad.length, `FS fingerprint differs at ${bad.length} offset(s), first ${hx(bad[0] || 0)}`);
    log(`FS fingerprint matches (${img.fingerprint.length} functions)`);

    if (img.guard) {                                   // before anything is written to FS
      await stage('check save guard');
      const G = img.guard;
      const cfg = await sd.type(CONFIG) === 1 ? (await sd.read(CONFIG, 0x10000)).toString('utf8') : '';
      const prot = protectedUsers(cfg);
      check(typeof G.user === 'string' && G.user.length === 32 && !prot.has(G.user.toLowerCase()),
        `save guard: the allowed user must not be a protected user (${G.user})`);
      check(helperPid > 0n && fsPid < helperPid, `save guard: FS pid ${fsPid} is not below the floor ${helperPid}`);
      const named = new Map(img.hooks.map(h => [h.name, h.off]));
      for (const site of G.sites) {
        const whole = img.fingerprint.some(([off, hex]) => off === site.off && hex.length === 2 * site.bytes);
        check(named.get(site.name) === site.off && whole, `save guard: ${site.name} is not hooked and fingerprinted whole`);
      }
      // s2_ml.lua's wording: SeedSwap reads the program and user from this line
      log(`save guard: account saves of program ${G.program} refused (${hx(G.result)}) after pid ${helperPid} for every user except ${G.user}`);
      if (prot.size) log(`${prot.size} protected user(s) in ${CONFIG}`);
    }

    await stage('check SD files');
    let present = 0;
    for (const f of img.files) {
      const o = await sd.open(f.path, 1);
      if (!o.handle) {
        check(img.live_sizes, `planned SD file missing: ${f.path} (0x${o.result.toString(16)})`);
        log(`overlay file missing: ${f.path} (the title stays native for it until it is back)`);
        continue;
      }
      const size = await sd.size(o.handle);
      await a.s.close(o.handle);
      check(img.live_sizes || size === f.size, `SD file changed since the image was built: ${f.path} is ${size} B, plan ${f.size} B`);
      present++;
    }
    // s2_ml.lua's wording: SeedSwap takes "live SD sizes:" as the loader serving files at their SD size
    log(img.live_sizes ? `live SD sizes: ${present} of ${img.files.length} overlay file(s) present`
      : `${img.files.length} planned SD file(s) present with the planned sizes`);

    // The FS object behind one of our sessions: clone it, ConvertToDomain the clone, read the
    // domain table entry (source.cjs locate, s2_ml.lua locate).
    async function locate(handle, refOff, what) {
      const {s, domain} = a;
      const clone = domain.oneHandle(await domain.send(s, 'Locate ' + what, handle, domain.wire.control(2)));
      let loc, uncertain = false;
      try {
        const conv = await domain.send(s, 'Convert ' + what, clone, domain.wire.control(0));
        check(!conv.result, `ConvertToDomain on the ${what} clone failed`);
        const id = conv.data.readUInt32LE();
        check(id > 0 && id <= layout.count, 'invalid domain id');
        const entry = await readFs(layout.table + (id - 1) * 0x30, 0x30);
        const object = entry.readBigUInt64LE(0x20);
        const hdr = await readFs(object, refOff + 8);
        const vptr = hdr.readBigUInt64LE(0), vt = await readFs(vptr, 64);
        loc = {id, object, vptr, refs: hdr.readUInt32LE(refOff), slot: Array.from({length: 8}, (_, i) => vt.readBigUInt64LE(i * 8))};
      } catch (e) { uncertain = b.c.pending || isUncertain(e); throw e; }
      finally { if (!uncertain) await s.close(clone); }
      check(loc.refs >= 2 && loc.refs <= 16, `unexpected ${what} clone references ${loc.refs}`);
      loc.baseline = await u32(loc.object + BigInt(refOff));
      check(loc.refs === loc.baseline + 1 && loc.baseline >= 1, `${what} clone reference did not release exactly once`);
      return loc;
    }

    const L = img.logs;
    let report = null, logobj = null, traceobj = null;
    if (L) {
      await stage('create SD report');
      for (const dir of ['/ns2jb-modloader', L.dir]) {
        const t = await sd.type(dir);
        if (t === null) await sd.mkdir(dir); else check(t === 0, dir + ' is not a folder');
      }
      // next counter after the newest onconsole-NNNN.log; keep the newest `keep` reports
      const pat = new RegExp('^' + L.stem.replace(/[.*+?^${}()|[\]\\-]/g, '\\$&') + `(\\d{${L.digits}})\\.log$`);
      const seen = (await sd.list(L.dir)).map(e => pat.exec(e.name)).filter(Boolean).map(m => Number(m[1])).sort((x, y) => x - y);
      const index = ((seen.at(-1) || 0) + 1) % 10 ** L.digits;
      while (seen.length >= L.keep) {
        const old = I.logPaths(img, seen.shift());
        await sd.remove(old.log);
        await sd.remove(old.log.replace(/\.log$/, '.trace'));
      }
      const paths = I.logPaths(img, index);
      st.logIndex = index; st.report = paths.log;
      // the report text as it will sit in the context (it holds no fixup slots)
      report = I.build(img, {base, ctx: 0x100000000n, rt: 0x1000n, sdfs: 1n, registry: 1n, log: 1n, trace: 1n, pidfloor: 1n, log_index: index}).report;
      await sd.writeWhole(paths.log, report);
      if (paths.trace) await sd.writeWhole(paths.trace, Buffer.alloc(L.trace_bytes));
      log(`SD report ${paths.log} (${report.length} B)${paths.trace ? ', trace ' + paths.trace : ''}`);

      await stage('open SD report for the resident');
      const V = F.file_vtable.map(v => base + BigInt(v));
      async function retain(p, size, what) {
        const o = await sd.open(p, 7);
        check(o.handle, `cannot reopen SD:${p}`);
        reportHandles.push(o.handle);
        check(await sd.size(o.handle) === size, what + ' size changed');
        const loc = await locate(o.handle, F.file_ref_offset, what);
        check(loc.slot[0] === V[0] && loc.slot[1] === V[1] && loc.slot[4] === V[4], what + ' method table differs');
        check(loc.baseline === 1, `${what} is not exclusively owned (refs ${loc.baseline})`);
        return loc;
      }
      logobj = await retain(paths.log, report.length, 'report');
      check(logobj.slot[5] === V[5] && logobj.slot[6] === V[6] && logobj.slot[7] === V[7], 'report write/flush/setSize differ from the image');
      if (paths.trace) {
        traceobj = await retain(paths.trace, L.trace_bytes, 'trace');
        check(traceobj.slot[5] === logobj.slot[5] && traceobj.slot[6] === logobj.slot[6], 'trace and report file operations differ');
      }
    }

    await stage('locate SD filesystem object');          // after the file opens, which retain it too
    const loc = await locate(sdh, F.sdfs_ref_offset, 'SD');
    check(loc.slot[0] === base + BigInt(F.sdfs_vtable0) && loc.slot[1] === base + BigInt(F.sdfs_vtable1), 'SD object method table differs');
    const sdBaseline = loc.baseline;
    log(`SD filesystem object ${hx(loc.object)} (domain id ${loc.id}), refs ${sdBaseline}`);

    await stage('read program registry');
    const registry = (await u64(base + BigInt(F.registry_global))) + BigInt(F.registry_add);
    check(registry >= 0x100000000n && registry < 0x8000000000n, 'FS program registry is unavailable');

    await stage('allocate context');
    const ctxa = await fsCall(F.allocate, [img.context.bytes], 'allocate-loader-context', {clearAllocation: true});
    check(ctxa >= 0x100000000n && ctxa < 0x8000000000n && ctxa % 16n === 0n, 'context allocation failed: ' + hx(ctxa));
    st.ctx = ctxa; await save();
    let q = await info(ctxa);
    check(!q.result && q.perm === 3 && !q.attr && ctxa + BigInt(img.context.bytes) <= q.base + q.size, 'context is not backed by RW memory');
    check((await readFs(ctxa, 64)).equals(Buffer.alloc(64)), 'context allocation is not cleared');

    await stage('allocate runtime pages');               // Bridge.mapRuntime
    const outp = await fsCall(F.allocate, [8], 'allocate-runtime-output');
    check(outp >= 0x100000000n && outp < 0x8000000000n, 'allocation output failed');
    let rb, src;
    try {
      rb = await fsCall(F.allocate_block, [base + BigInt(F.block_manager), outp, img.runtime.bytes], 'allocate-loader-runtime');
      src = await u64(outp);
    } finally { if (!b.c.pending) await fsCall(F.free, [outp, 8], 'free-runtime-output'); }
    check(rb === 0n, 'cannot reserve runtime pages: ' + hx(rb));
    st.block = src; await save();
    q = await info(src);
    check(src >= 0x100000000n && src < 0x8000000000n && src % 0x1000n === 0n && !q.result && q.type === 5 && q.perm === 3 && !q.attr &&
      src + BigInt(img.runtime.bytes) <= q.base + q.size, 'runtime block is not Normal/RW memory');
    rtva = q.free;
    const tq = await info(rtva);
    check(rtva > 0n && rtva % 0x1000n === 0n && !tq.result && tq.type === 0 && rtva + BigInt(img.runtime.bytes) <= tq.base + tq.size,
      'no free range for the runtime at ' + hx(rtva));
    if (rtva !== BigInt(img.runtime.expected_va)) log(`note: runtime VA ${hx(rtva)} (image built expecting ${hx(img.runtime.expected_va)})`);
    log(`registry ${hx(registry)}, context ${hx(ctxa)} (${img.context.bytes} B), runtime block ${hx(src)} -> VA ${hx(rtva)}`);

    await stage('relocate image');
    const live = {base, ctx: ctxa, rt: rtva, sdfs: loc.object, registry, log: logobj?.object, trace: traceobj?.object,
      log_index: st.logIndex, pidfloor: img.guard ? helperPid : undefined};
    const blob = I.build(img, live);
    if (L) check(blob.report.equals(report), 'report text in the context differs from the SD file');

    await stage('write context');
    for (let at = 0; at < blob.context.length; at += 0x10000) {
      const part = blob.context.subarray(at, at + 0x10000);
      await b.writeData(ctxa + BigInt(at), Buffer.alloc(part.length), part);
    }
    await stage('write runtime source');
    for (let at = 0; at < blob.runtime.length; at += 0x10000) {
      const part = blob.runtime.subarray(at, at + 0x10000);
      await b.writeData(src + BigInt(at), await readFs(src + BigInt(at), part.length), part);
    }

    await stage('map runtime pages');
    for (let i = 0; i < img.runtime.pages; i++) {
      const from = src + BigInt(i * 0x1000), to = rtva + BigInt(i * 0x1000);
      const r = await b.c.map(b.h, b.pid, from, to);
      check(!r.result && !r.mapResult && !r.permissionResult, `map page ${i} failed`);
      st.pages.push({src: from, dst: to}); await save();
    }
    await stage('publish runtime');
    const pub = {label: 'publish-loader-runtime', args: [hx(rtva), String(img.runtime.bytes)], pending: true};
    b.record.operations.push(pub); await b.save();
    await b.invoke([rtva, BigInt(img.runtime.bytes)], pub, 0n, true);
    q = await info(rtva + BigInt(img.runtime.entry.lfs_initialize));
    check(!q.result && q.perm === 5, 'runtime entry is not R-X');
    check((await readCode(rtva, 128)).equals(blob.runtime.subarray(0, 128)), 'runtime code readback differs');
    const fx = img.runtime.fixups;
    for (let i = 0; i < fx.length; i += 3)
      check((await readCode(rtva + BigInt(fx[i]), 8)).equals(blob.runtime.subarray(fx[i], fx[i] + 8)), 'runtime literal differs at ' + fx[i]);
    log(`runtime mapped R-X at ${hx(rtva)} (${img.runtime.pages} pages), literals verified`);

    if (L && L.trace) {
      await stage('trace clock probe');
      const at = ctxa + BigInt(L.clock_probe);
      const rc = await runtimeCall(img.runtime.entry.lfs_trace_clock_probe, [at], 'loader-trace-clock');
      const clock = await readFs(at, 16);
      check(rc === 0n && clock.readBigUInt64LE(8) > 0n, 'trace clock probe failed: ' + hx(rc));
      log(`trace clock tick ${clock.readBigUInt64LE(0)}, frequency ${clock.readBigUInt64LE(8)} Hz`);
    }

    await stage('lfs_initialize');
    const refs = (o, off) => u32(o.object + BigInt(off));
    check(await refs(loc, F.sdfs_ref_offset) === sdBaseline, 'SD reference baseline changed');
    if (logobj) check(await refs(logobj, F.file_ref_offset) === 1, 'report reference baseline changed');
    if (traceobj) check(await refs(traceobj, F.file_ref_offset) === 1, 'trace reference baseline changed');
    const ri = await runtimeCall(img.runtime.entry.lfs_initialize, [], 'loader-initialize');
    check(ri === 0n, 'lfs_initialize returned ' + hx(ri));
    initialized = true; st.initialized = true; await save();
    const after = await refs(loc, F.sdfs_ref_offset);
    check(after === sdBaseline + 1, `SD reference did not retain once: ${sdBaseline} -> ${after}`);
    if (logobj) check(await refs(logobj, F.file_ref_offset) === 2, 'report reference did not retain once');
    if (traceobj) check(await refs(traceobj, F.file_ref_offset) === 2, 'trace reference did not retain once');
    log(`lfs_initialize: SD object retained (${sdBaseline} -> ${after})${logobj ? '; report' + (traceobj ? ' and trace' : '') + ' retained (1 -> 2)' : ''}`);
    while (reportHandles.length) await a.s.close(reportHandles.pop());   // the resident keeps its references

    await stage('switch to control cave');
    await b.stage(Buffer.alloc(0));
    await b.controlCave();

    await stage('write gateway');
    for (const row of I.gatewayRows(img, blob.gateway, base)) {
      if (row.bytes.equals(ZERO16)) continue;          // resident.cjs writes the non-zero rows
      await b.patch(row.addr, ZERO16, row.bytes);
      st.gatewayRows.push(row.addr); await save();
    }
    check((await readCode(base + BigInt(F.cave), blob.gateway.length)).equals(blob.gateway), 'gateway readback differs');

    await stage('attach hooks');
    for (const hk of I.hooks(img, base)) {
      st.hookMayBeAttached = true; await save();
      await b.patch(hk.addr, hk.before, hk.after);
      st.hooks++; await save();
    }
    log(`gateway (${blob.gateway.length} B) and ${st.hooks} hooks attached${img.guard ? ' (with the save guard)' : ''}`);

    await stage('lfs_activate');
    const ra = await runtimeCall(img.runtime.entry.lfs_activate, [], 'loader-activate');
    check(ra === 0n, 'lfs_activate returned ' + hx(ra));
    const head = await readFs(ctxa, 16);
    check(head.subarray(0, 8).toString('latin1') === img.context.magic && head.readUInt32LE(img.context.enabled_offset) === 1,
      'context is not active after lfs_activate');
    active = true; st.active = true;
    await stage('done');
  }

  let error = null;
  try { await install(); } catch (e) { error = e; }
  if (error && isUncertain(error) && b?.c) b.c.pending = true;
  const pending = !!b?.c?.pending;
  if (!error) {
    // s2_ml.lua's wording: SeedSwap takes the last such line, and the report it names held open, as
    // this loader being in memory
    log(`milestone 3: modloader resident and active (${img.plan.titles.join(',')}) in ${Date.now() - t0} ms`);
    if (img.logs) log('loader report: ' + st.report);
  } else log(`milestone 3 failed at '${st.stage}': ${error.message}`);
  if (!pending) {                                      // our IPC session in the run
    while (reportHandles.length) await a.s.close(reportHandles.pop()).catch(() => {});
    if (sd) {
      const text = [`=== SeedSwap PC boot (ns2jb) ${new Date().toISOString()} ===`, ...runLog.map(l => 'KH: ML: ' + l), ''].join('\r\n');
      await sd.append(RUN_LOG, Buffer.from(text, 'utf8')).catch(e => print(`note: ${RUN_LOG} not updated (${e.message})`));
    }
    if (sdh !== null) await a.s.close(sdh).catch(() => {});
    if (a) await a.close().catch(() => {});
  }
  if (!error) {
    // The resident owns its pieces: the cave page stays R-X for the gateway (resident.cjs does the same).
    await b.releaseControl(); await b.stage(Buffer.alloc(0)); b.readable = false; await b.c.close();
    st.finished = new Date().toISOString(); await save();
    print(`SeedSwap's loader is resident and active (${img.plan.titles.length} title slot(s))`);
    return {journal: journalFile, helperPid: st.helperPid, report: st.report || null};
  }

  st.error = error.stack;
  if (!b?.c) { await save().catch(() => {}); throw error; }
  if (pending) {
    st.pending = true; st.resourcesRetained = true; await save().catch(() => {});
    log('a console request may still be running: leave everything as it is and restart the console before trying again');
    throw error;
  }
  if (!b.previous) {                                   // the bridge never opened: nothing in FS was changed
    await b.c.close().catch(() => {}); await save().catch(() => {}); throw error;
  }
  if (st.hookMayBeAttached) {
    await b.detach().catch(() => {}); await b.stage(Buffer.alloc(0)).catch(() => {}); b.readable = false; await b.c.close().catch(() => {});
    st.resourcesRetained = true; await save().catch(() => {});
    log(`hooks may be attached: gateway, runtime and context stay until restart (active: ${active})`);
    throw error;
  }
  try {                                                // gateway rows written so far go back to zero
    while (st.gatewayRows.length) {
      const addr = BigInt(st.gatewayRows.at(-1));
      await b.patch(addr, await readCode(addr, 16), ZERO16);
      st.gatewayRows.pop();
    }
  } catch (e2) {
    b.readable = false; await b.c.close().catch(() => {});
    st.resourcesRetained = true; await save().catch(() => {});
    throw Error(`${error.message}; gateway rows could not be removed, cave page left R-X (${e2.message})`);
  }
  let undone = true;
  for (let i = st.pages.length - 1; i >= 0; i--) {
    const pg = st.pages[i];
    const r = await b.c.unmap(b.h, b.pid, pg.src, pg.dst).catch(() => ({result: 1}));
    if (r.result) { undone = false; break; }
    st.pages.pop();
  }
  if (undone && st.block && !initialized)
    await fsCall(F.free_block, [b.base + BigInt(F.block_manager), st.block, img.runtime.bytes], 'free-loader-runtime').catch(() => {});
  if (st.ctx && !initialized) await fsCall(F.free, [st.ctx, img.context.bytes], 'free-loader-context').catch(() => {});
  await b.close().catch(() => {});                    // empties the cave, restores the page permission
  st.rolledBack = true; st.resourcesRetained = !!(st.pages.length || initialized);
  log(`rolled back (runtime pages still mapped: ${st.pages.length}, SD retained: ${initialized})`);
  await save().catch(() => {});
  throw error;
}

// Read-only: the size of each SD path (null when missing), through an IPC session in the held run.
async function surveySd(run, {modloader, paths}) {
  const ML = p => require(path.join(modloader, 'lib', p));
  const a = await ML('game-files/mount-api.cjs').attachGame(path.resolve(run));
  const out = {};
  let sdh = null;
  try {
    sdh = a.domain.oneHandle(await a.s.ipc('Open SD (SeedSwap check)', a.root, 18));
    const sd = sdCard(a, sdh, ML('game-files/protocol.cjs').pathRequest);
    for (const p of paths) {
      const t = await sd.type(p);
      if (t !== 1) { out[p] = t === null ? null : 'folder'; continue; }
      const o = await sd.open(p, 1);
      out[p] = o.handle ? await sd.size(o.handle) : null;
      if (o.handle) await a.s.close(o.handle);
    }
    return out;
  } finally {
    if (sdh !== null) await a.s.close(sdh).catch(() => {});
    await a.close().catch(() => {});
  }
}

module.exports = {installLoader, surveySd, protectedUsers, sdCard, INSTALL_DIR};
