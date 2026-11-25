// SPDX-License-Identifier: GPL-2.0-only
'use strict';
// SeedSwap's loader install image (SD:/kaihen/ml/install/: image.lua, runtime.bin, gateway.bin,
// context.bin, made by tools/build_install_image.cjs and edited on the console by SeedSwap).
// A port of SD:/kaihen/ml/ml_image.lua (what the Seedsow route runs) for the PC route: the same
// checks and the same relocation, so both routes install the same bytes. Addresses are BigInt.
// Offline test: test/image_test.cjs (compares with ml_image.lua byte for byte).

const ZERO8 = Buffer.alloc(8);

// ---------- image.lua: a Lua table literal ----------
// `return { key = value, value, ... }` with strings, numbers, booleans and nested tables, as
// build_install_image.cjs and SeedSwap (hosts.c) write it. Anything else is refused.
function parseLua(text) {
  let i = 0;
  const fail = what => { throw Error(`image.lua: ${what} at offset ${i}`); };
  const skip = () => {
    for (;;) {
      while (i < text.length && /\s/.test(text[i])) i++;
      if (text.startsWith('--[[', i) || text.startsWith('--[==[', i)) fail('block comments are not supported');
      if (text.startsWith('--', i)) { while (i < text.length && text[i] !== '\n') i++; continue; }
      return;
    }
  };
  const string = () => {
    const q = text[i++];
    let out = '';
    while (i < text.length && text[i] !== q) {
      let c = text[i++];
      if (c === '\n') fail('newline in a string');
      if (c === '\\') {
        c = text[i++];
        const esc = {n: '\n', t: '\t', r: '\r', '\\': '\\', '"': '"', "'": "'", '0': '\0', a: '\x07', b: '\b', f: '\f', v: '\v'};
        if (/[0-9]/.test(c)) {
          let d = c;
          while (d.length < 3 && /[0-9]/.test(text[i])) d += text[i++];
          c = String.fromCharCode(Number(d));
        } else if (c in esc) c = esc[c];
        else fail('unknown escape \\' + c);
      }
      out += c;
    }
    if (text[i++] !== q) fail('unterminated string');
    return out;
  };
  const value = () => {
    skip();
    const c = text[i];
    if (c === '{') return table();
    if (c === '"' || c === "'") return string();
    const m = /^(-?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)|true|false|nil)/.exec(text.slice(i, i + 64));
    if (!m) fail('unexpected ' + JSON.stringify(text.slice(i, i + 12)));
    i += m[0].length;
    if (m[0] === 'true') return true;
    if (m[0] === 'false') return false;
    if (m[0] === 'nil') return null;
    const n = Number(m[0]);
    if (!Number.isFinite(n) || (Number.isInteger(n) && !Number.isSafeInteger(n))) fail('number out of range');
    return n;
  };
  const table = () => {
    i++;                                              // {
    const list = [], map = {};
    let keyed = false;
    for (;;) {
      skip();
      if (text[i] === '}') { i++; break; }
      const m = /^([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)/.exec(text.slice(i, i + 80));
      if (m) {
        i += m[0].length;
        if (Object.prototype.hasOwnProperty.call(map, m[1])) fail('duplicate key ' + m[1]);
        map[m[1]] = value();
        keyed = true;
      } else if (text[i] === '[') fail('[key] = forms are not supported');
      else list.push(value());
      skip();
      if (text[i] === ',' || text[i] === ';') { i++; continue; }
      skip();
      if (text[i] !== '}') fail('expected , or }');
    }
    if (keyed && list.length) fail('a table mixes keys and list items');
    return keyed ? map : list;
  };
  skip();
  if (!text.startsWith('return', i)) fail('expected return');
  i += 6;
  const out = value();
  skip();
  if (i !== text.length) fail('text after the table');
  return out;
}

// ---------- ml_image.lua ----------
function adler32(buf) {
  let a = 1, b = 0;
  for (let i = 0; i < buf.length; i += 1024) {
    const end = Math.min(i + 1024, buf.length);
    for (let k = i; k < end; k++) { a += buf[k]; b += a; }
    a %= 65521; b %= 65521;
  }
  return b * 65536 + a;
}

function u64le(v) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt.asUintN(64, BigInt(v)));
  return b;
}

// Fixups: flat triples {offset, kind, addend}; slot (zero in the blob) := vals[kind] + addend.
function relocate(blob, fix, vals) {
  if (fix.length % 3) throw Error('fixup list is not triples');
  const out = Buffer.from(blob);
  let at = 0;
  for (let i = 0; i < fix.length; i += 3) {
    const [off, kind, add] = [fix[i], fix[i + 1], fix[i + 2]];
    if (!(off >= at && off + 8 <= blob.length)) throw Error('fixup offset out of order or range: ' + off);
    if (!blob.subarray(off, off + 8).equals(ZERO8)) throw Error('fixup slot not zero at ' + off);
    const v = vals[kind];
    if (v === undefined) throw Error('no live value for fixup kind ' + kind);
    u64le(v + BigInt(add)).copy(out, off);
    at = off + 8;
  }
  return out;
}

// read(path, maxLen) -> Promise<Buffer>
async function load(read, dir = '/kaihen/ml/install') {
  const src = (await read(dir + '/image.lua', 0x80000)).toString('utf8');
  const img = parseLua(src);
  if (!img || typeof img !== 'object' || img.format !== 1) throw Error('unsupported install image format');
  for (const part of ['runtime', 'gateway', 'context']) {
    const m = img[part];
    if (!m) throw Error('image has no ' + part);
    const b = await read(dir + '/' + m.file, 0x100000);
    if (b.length !== m.bytes) throw Error(`${part}: size ${b.length}, expected ${m.bytes}`);
    if (adler32(b) !== m.adler32) throw Error(part + ': checksum differs');
    m.blob = b;
  }
  if (!(img.runtime.bytes % 0x1000 === 0 && img.runtime.bytes / 0x1000 === img.runtime.pages)) throw Error('runtime is not whole pages');
  if (!(img.gateway.bytes <= img.fs.cave_bytes && img.gateway.bytes % 16 === 0)) throw Error('gateway does not fit the cave');
  return img;
}

function logPaths(img, index) {
  const L = img.logs;
  if (!L) throw Error('image has no logs');
  if (!(Number.isInteger(index) && index >= 0 && index < 10 ** L.digits)) throw Error('log index out of range');
  const name = L.stem + String(index).padStart(L.digits, '0');
  return {name, log: `${L.dir}/${name}.log`, trace: L.trace ? `${L.dir}/${name}.trace` : null};
}

// live = {base, ctx, rt, sdfs, registry [, log, trace, pidfloor]} as BigInt (or numbers), and
// log_index (number) with logs. Returns {runtime, gateway, context [, report]} as Buffers.
function build(img, live) {
  const vals = {};
  img.kinds.forEach((k, idx) => {
    const v = live[k];
    if (v === undefined || v === null || BigInt(v) <= 0n) throw Error('missing live value ' + k);
    vals[idx + 1] = BigInt(v);
  });
  if (BigInt(live.rt) % 0x1000n || BigInt(live.ctx) % 16n || BigInt(live.base) % 0x1000n) throw Error('live value misaligned');
  let cblob = img.context.blob;
  if (img.logs) {
    const L = img.logs;
    if (live.log_index === undefined) throw Error('missing log index');
    const digits = Buffer.from(logPaths(img, live.log_index).name.slice(-L.digits), 'latin1');
    cblob = Buffer.from(cblob);
    let at = 0;
    for (const off of L.name_offsets) {
      if (!(off >= at && cblob.subarray(off, off + L.digits).equals(Buffer.from('0'.repeat(L.digits))))) throw Error('name slot not blank at ' + off);
      digits.copy(cblob, off);
      at = off + L.digits;
    }
  }
  const out = {
    runtime: relocate(img.runtime.blob, img.runtime.fixups, vals),
    gateway: relocate(img.gateway.blob, img.gateway.fixups, vals),
    context: relocate(cblob, img.context.fixups, vals),
  };
  if (img.logs) out.report = out.context.subarray(img.logs.text_offset, img.logs.text_offset + img.logs.text_bytes);
  return out;
}

// readCode(addr: BigInt, n) -> Promise<Buffer>; returns the offsets whose bytes differ.
async function checkFingerprint(img, base, readCode) {
  const bad = [];
  for (const [off, hex] of img.fingerprint) {
    const want = Buffer.from(hex, 'hex');
    const got = await readCode(BigInt(base) + BigInt(off), want.length);
    if (!got.equals(want)) bad.push(off);
  }
  return bad;
}

function hooks(img, base) {
  return img.hooks.map(h => {
    const before = Buffer.from(h.orig, 'hex'), after = Buffer.from(h.repl, 'hex');
    if (before.length !== 16 || after.length !== 16) throw Error(`hook ${h.name} is not 16 bytes`);
    return {name: h.name, off: h.off, addr: BigInt(base) + BigInt(h.off), before, after};
  });
}

function gatewayRows(img, gateway, base) {
  const rows = [];
  for (let at = 0; at + 16 <= gateway.length; at += 16)
    rows.push({addr: BigInt(base) + BigInt(img.fs.cave + at), bytes: gateway.subarray(at, at + 16)});
  return rows;
}

module.exports = {parseLua, adler32, relocate, load, logPaths, build, checkFingerprint, hooks, gatewayRows};
