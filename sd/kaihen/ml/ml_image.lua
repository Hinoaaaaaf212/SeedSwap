-- ml_image.lua: load and relocate the on-console ns2jb-modloader install image built on the PC
-- by tools/build_install_image.cjs (SD:/kaihen/ml/install/: image.lua, runtime.bin,
-- gateway.bin, context.bin). Pure Lua 5.1, no console calls: the caller passes a file reader
-- and, later, the live values found on the console:
--   base (FS .text), ctx (context allocation), rt (runtime VA), sdfs (SD IFileSystem object),
--   registry (u64(FS+0x11e12d0)+16).
-- Offline test: lua5.1 test/image_apply.lua <image dir> <vectors dir>

local I = {}

local str_byte, str_char, str_sub = string.byte, string.char, string.sub
local tbl_concat, floor, min = table.concat, math.floor, math.min
local ZERO8 = string.rep("\0", 8)
local TWO53 = 9007199254740992

local function u64s(v)
    assert(type(v) == "number" and v >= 0 and v < TWO53 and v == floor(v), "u64 value out of range")
    local t = {}
    for i = 1, 8 do
        local q = floor(v / 256)
        t[i] = str_char(v - q * 256)
        v = q
    end
    return tbl_concat(t)
end
I.u64s = u64s

-- Adler-32, reduced once per 1 KiB chunk (sums stay far below 2^53).
function I.adler32(s)
    local a, b, n = 1, 0, #s
    for i = 1, n, 1024 do
        local bytes = {str_byte(s, i, min(i + 1023, n))}
        for k = 1, #bytes do
            a = a + bytes[k]
            b = b + a
        end
        a = a % 65521
        b = b % 65521
    end
    return b * 65536 + a
end

-- Fill the fixup slots: flat triples {offset, kind, addend}, offsets ascending, each slot zero
-- in the blob; slot := vals[kind] + addend (u64 little-endian).
function I.relocate(blob, fix, vals)
    assert(#fix % 3 == 0, "fixup list is not triples")
    local parts, at = {}, 0
    for i = 1, #fix, 3 do
        local off, kind, add = fix[i], fix[i + 1], fix[i + 2]
        assert(off >= at and off + 8 <= #blob, "fixup offset out of order or range: " .. tostring(off))
        assert(str_sub(blob, off + 1, off + 8) == ZERO8, "fixup slot not zero at " .. off)
        local v = assert(vals[kind], "no live value for fixup kind " .. tostring(kind))
        parts[#parts + 1] = str_sub(blob, at + 1, off)
        parts[#parts + 1] = u64s(v + add)
        at = off + 8
    end
    parts[#parts + 1] = str_sub(blob, at + 1)
    local out = tbl_concat(parts)
    assert(#out == #blob, "relocation changed the size")
    return out
end

-- read(path, max_len) -> string. Checks sizes and checksums of all three blobs.
function I.load(read, dir)
    dir = dir or "/kaihen/ml/install"
    local src = read(dir .. "/image.lua", 0x80000)
    local img = assert(loadstring(src, "@" .. dir .. "/image.lua"))()
    assert(type(img) == "table" and img.format == 1, "unsupported install image format")
    for _, part in ipairs({"runtime", "gateway", "context"}) do
        local m = assert(img[part], "image has no " .. part)
        local b = read(dir .. "/" .. m.file, 0x100000)
        assert(#b == m.bytes, part .. ": size " .. #b .. ", expected " .. m.bytes)
        assert(I.adler32(b) == m.adler32, part .. ": checksum differs")
        m.blob = b
    end
    assert(img.runtime.bytes % 0x1000 == 0 and img.runtime.bytes / 0x1000 == img.runtime.pages, "runtime is not whole pages")
    assert(img.gateway.bytes <= img.fs.cave_bytes and img.gateway.bytes % 16 == 0, "gateway does not fit the cave")
    return img
end

-- SD report/trace paths for boot counter `index` (images built with logs).
function I.log_paths(img, index)
    local L = assert(img.logs, "image has no logs")
    assert(index >= 0 and index < 10 ^ L.digits and index == floor(index), "log index out of range")
    local name = L.stem .. string.format("%0" .. L.digits .. "d", index)
    return {name = name, log = L.dir .. "/" .. name .. ".log", trace = L.trace and (L.dir .. "/" .. name .. ".trace") or nil}
end

-- live = {base, ctx, rt, sdfs, registry [, log, trace, log_index]}; returns the relocated blobs
-- (and, with logs, the report text exactly as it sits in the context).
function I.build(img, live)
    local vals = {}
    for i, k in ipairs(img.kinds) do
        local v = live[k]
        assert(type(v) == "number" and v > 0, "missing live value " .. k)
        vals[i] = v
    end
    assert(live.rt % 0x1000 == 0 and live.ctx % 16 == 0 and live.base % 0x1000 == 0, "live value misaligned")
    local cblob = img.context.blob
    if img.logs then
        local L = img.logs
        local digits = string.sub(I.log_paths(img, assert(live.log_index, "missing log index")).name, -L.digits)
        local parts, at = {}, 0
        for _, off in ipairs(L.name_offsets) do          -- ascending offsets of the counter digits
            assert(off >= at and str_sub(cblob, off + 1, off + L.digits) == string.rep("0", L.digits), "name slot not blank at " .. off)
            parts[#parts + 1] = str_sub(cblob, at + 1, off)
            parts[#parts + 1] = digits
            at = off + L.digits
        end
        parts[#parts + 1] = str_sub(cblob, at + 1)
        cblob = tbl_concat(parts)
    end
    local out = {
        runtime = I.relocate(img.runtime.blob, img.runtime.fixups, vals),
        gateway = I.relocate(img.gateway.blob, img.gateway.fixups, vals),
        context = I.relocate(cblob, img.context.fixups, vals),
    }
    if img.logs then out.report = str_sub(out.context, img.logs.text_offset + 1, img.logs.text_offset + img.logs.text_bytes) end
    return out
end

local function unhex(h)
    return (h:gsub("%x%x", function(p) return str_char(tonumber(p, 16)) end))
end

-- read_code(addr, n) -> n bytes of FS .text (helper 0x11). Returns the list of mismatches.
function I.check_fingerprint(img, base, read_code)
    local bad = {}
    for _, row in ipairs(img.fingerprint) do
        local off, want = row[1], unhex(row[2])
        local got = read_code(base + off, #want)
        if got ~= want then bad[#bad + 1] = off end
    end
    return bad
end

-- Hooks as {name, addr, before (16 B), after (16 B)}, in install order.
function I.hooks(img, base)
    local out = {}
    for i, h in ipairs(img.hooks) do
        out[i] = {name = h.name, addr = base + h.off, before = unhex(h.orig), after = unhex(h.repl)}
        assert(#out[i].before == 16 and #out[i].after == 16, "hook " .. h.name .. " is not 16 bytes")
    end
    return out
end

-- Gateway as 16-byte rows for compare-and-patch over the zero cave: {addr, bytes}.
function I.gateway_rows(img, gateway, base)
    local rows = {}
    for at = 0, #gateway - 16, 16 do
        rows[#rows + 1] = {addr = base + img.fs.cave + at, bytes = str_sub(gateway, at + 1, at + 16)}
    end
    return rows
end

return I
