-- s2_ml.lua: on-console ns2jb-modloader stage for seedsow-semi-untethered.
-- Loaded from SD by the hook in the patched s2_kh_ro.lua, after kaiHEN's donor is staged and
-- before kaiHEN's RO launch; the hook pcalls it and always continues with kaiHEN afterwards.
--   M1  stage the ns2jb helper RO (/kaihen/ml/helper_ro_main) as RO donor and launch it; reach
--       ro:dmnt through FS's sm: session; export FS's process handle; FS .text base from the
--       notifier vtable, checked with helper 0x10; caves must be empty.
--   M2  FS call bridge (port of ns2jb lib/native/bridge.cjs): templates from /kaihen/ml/tpl.lua
--       staged in the cave, notifier slot 4 hooked per call.
--   M3  if /kaihen/ml/install/image.lua exists (tools/build_install_image.cjs): install the
--       modloader resident the way ns2jb lib/resident.cjs does, from the precomputed image:
--       fingerprint, SD object, registry, context, runtime pages, lfs_initialize, gateway, hooks,
--       lfs_activate. Without the image, M2 runs its allocate/free self-test instead.
--   B   first, only when the launcher's B entry set _G.__s2_install_nro: copy save:/seedswap.nro to
--       SD:/switch/seedswap.nro (see install_nro below); failures never stop M1-M3 or kaiHEN.
--   Images may carry two semi-untethered options (tools/build_install_image.cjs, default on):
--     guard       FS save-open guard. Its two hooked FS functions are fingerprinted whole; the pid
--                 floor (live value `pidfloor`) is the helper RO's pid, so the running exploit
--                 process and FS itself are below it and Seedsow launched later on any user except
--                 the image's allowed user cannot open its save until reboot (it gets 2002-1002, "no save").
--     live_sizes  the runtime mounts the overlay files at their SD size at each launch and leaves
--                 the title native when they are missing; the stale-file check then only reports.

local ML = {}

local HELPER_PATH   = "/kaihen/ml/helper_ro_main"
local INSTALL_DIR   = "/kaihen/ml/install"
local NOTIFIER_SLOT4_OFFSET = 0x1201b0   -- GetEventHandle in FS .text (ns2jb fs-abi reference build)
local GATEWAY_CAVE  = 0x24d100
local CONTROL_CAVE  = 0x24d800
local FS_PROGRAM    = 0x0400000000000000
local TWO32         = 4294967296

local CMD = {challenge = 0x524f0001, info = 0x524f0010, read = 0x524f0011, map = 0x524f0012,
    unmap = 0x524f0013, patch = 0x524f0014, perm = 0x524f0015}
-- Seedsow saves that tools never write: main (research files) and third (exploit save) users of the
-- first console. Other consoles' come from SeedSwap's SD:/seedswap/config.ini (exploit_user, which
-- SeedSwap fills by finding the chain's files in a user's Seedsow save, and protected_users); the save
-- guard check below refuses an image that would let any of them in.
local PROTECTED_USERS = {}   -- release: each console's come from SD:/seedswap/config.ini

-- PROTECTED_USERS plus the users SD:/seedswap/config.ini names (read: function(path, max) -> string)
local function protected_users(read, log)
    local out, added = {}, 0
    for uid, why in pairs(PROTECTED_USERS) do out[uid] = why end
    local ok, cfg = pcall(read, "/seedswap/config.ini", 0x4000)
    if not ok or type(cfg) ~= "string" then return out end
    for _, key in ipairs({"exploit_user", "protected_users"}) do
        local v = ("\n" .. cfg):match("\n%s*" .. key .. "%s*=([^\r\n]*)")
        for uid in (v or ""):gmatch("%x+") do
            uid = uid:lower()
            if #uid == 32 and not out[uid] then out[uid] = key; added = added + 1 end
        end
    end
    if added > 0 then log("protected users: " .. added .. " more from /seedswap/config.ini") end
    return out
end

-- ===== Launcher B: install SeedSwap from the exploit save to the SD card (runs before M1) =====
-- The B entry (save:/exploitb2.lua) sets _G.__s2_install_nro. The save copy is streamed in 64 KiB
-- parts three times (size + NRO magic; write; read-back compare), so it is never held whole in
-- memory. An identical SD copy is left alone, and so is a newer one (the NACP display versions,
-- "0.12.0", compared as numbers; when either can't be read the save copy is installed as before).
-- New bytes go to a .tmp file, are compared byte for byte with the save copy, then the old copy is
-- deleted and the .tmp renamed into place. Any failure is logged and M1-M3 and kaiHEN continue as on A.
local NRO = {save = "seedswap.nro", dir = "/switch", path = "/switch/seedswap.nro",
    tmp = "/switch/seedswap.nro.tmp", max = 0x4000000, part = 0x10000}

local function install_nro(h, log)
    local P, env = h.P, h.env
    local rt, fs, slots = env.rt, env.fs, env.slots
    local open_save = h.open_save or function(name) return io.open("save:/" .. name, "rb") end
    local function hx(v) return string.format("0x%x", v) end
    local function ok_rep(rp, what)
        assert(rp.transport == 0 and rp.result == 0,
            string.format("%s failed: transport=0x%x result=0x%x", what, rp.transport, rp.result or 0))
    end

    -- fn(offset, part) for every part of the save copy; returns the size, or nil without the file
    local function each_save_part(fn)
        local f = open_save(NRO.save)
        if not f then return nil end
        local at = 0
        local ok, err = pcall(function()
            while true do
                local s = f:read(NRO.part)
                if not s or #s == 0 then break end
                fn(at, s)
                at = at + #s
                assert(at <= NRO.max, "save copy is larger than " .. NRO.max .. " B")
            end
        end)
        f:close()
        if not ok then error(err, 0) end
        return at
    end

    local size = each_save_part(function(at, s)
        if at == 0 then
            assert(#s >= 0x80 and string.sub(s, 0x11, 0x14) == "NRO0", "save:/" .. NRO.save .. " is not an NRO")
        end
    end)
    if not size then
        log("no save:/" .. NRO.save .. " in this save; nothing to install")
        return "missing"
    end

    local sdh = env.open_sd_card()
    local function exists(path)
        local r = fs.ipc_get_entry_type(sdh, path, 0x301)
        return r.transport == 0 and r.result == 0
    end
    local function read_part(fh, at, n)
        ok_rep(fs.send_packet(fh, P.packet(0, P.u64s(0) .. P.u64s(at) .. P.u64s(n),
            {b = {{addr = slots.data, size = n, mode = 1}}}), slots.pkt), "SD read")
        return rt.rd(slots.data, n)
    end
    local function same_as_save(path)          -- the SD file holds exactly the save copy's bytes
        local fh = fs.ipc_open_file(sdh, path, 1, 0x301)
        if fh == 0 then return false end
        local okc, res = pcall(function()
            if fs.ipc_file_get_size(fh) ~= size then return false end
            local same = true
            each_save_part(function(at, s) if same and read_part(fh, at, #s) ~= s then same = false end end)
            return same
        end)
        rt.close_handle(fh)
        if not okc then error(res, 0) end
        return res
    end

    -- an NRO's NACP display version as numbers and text; read(at, n) -> n bytes. nil when it has none.
    local function nro_version(read)
        local ok, nums, text = pcall(function()
            local size = P.u32(read(0x18, 4), 0)
            local aset = read(size, 0x28)
            if aset:sub(1, 4) ~= "ASET" then return nil end
            local s = read(size + P.u64(aset, 0x18) + 0x3060, 0x10):match("^[^%z]*")
            local t = {}
            for d in s:gmatch("%d+") do t[#t + 1] = tonumber(d) end
            if #t == 0 then return nil end
            return t, s
        end)
        if ok then return nums, text end
    end
    local function save_read(at, n)              -- bytes [at, at + n) of the save copy
        local out = {}
        each_save_part(function(p, s)
            local a, b = math.max(at, p), math.min(at + n, p + #s)
            if a < b then out[#out + 1] = s:sub(a - p + 1, b - p) end
        end)
        local r = table.concat(out)
        assert(#r == n, "save copy too short")
        return r
    end
    local function newer(a, b)                   -- version a is above version b
        for i = 1, math.max(#a, #b) do
            local x, y = a[i] or 0, b[i] or 0
            if x ~= y then return x > y end
        end
        return false
    end

    if not exists(NRO.dir) then
        local cr = fs.ipc_create_directory(sdh, NRO.dir)
        assert(cr == 0, "cannot create " .. NRO.dir .. " (" .. hx(cr or 0) .. ")")
    end
    local had = exists(NRO.path)
    if had and same_as_save(NRO.path) then
        log(string.format("%s is already up to date (%d B); nothing written", NRO.path, size))
        return "same"
    end
    if had then                                  -- never put an older SeedSwap over a newer one
        local sv, st = nro_version(save_read)
        local dv, dt
        local fh = fs.ipc_open_file(sdh, NRO.path, 1, 0x301)
        if fh ~= 0 then
            local fsize = fs.ipc_file_get_size(fh)
            dv, dt = nro_version(function(at, n)
                assert(at + n <= fsize, "past the end")
                return read_part(fh, at, n)
            end)
            rt.close_handle(fh)
        end
        if sv and dv and newer(dv, sv) then
            log(string.format("%s is SeedSwap %s, newer than the save's %s; kept", NRO.path, dt, st))
            return "newer"
        end
    end

    if exists(NRO.tmp) then fs.ipc_delete_file(sdh, NRO.tmp) end
    local cr = fs.ipc_create_file(sdh, NRO.tmp, size)
    assert(cr == 0, "cannot create " .. NRO.tmp .. " (" .. hx(cr or 0) .. ")")
    local fh, oerr = fs.ipc_open_file(sdh, NRO.tmp, 3, 0x301)
    if fh == 0 then
        fs.ipc_delete_file(sdh, NRO.tmp)
        error("cannot open " .. NRO.tmp .. " (" .. hx(oerr or 0) .. ")", 0)
    end
    local okw, errw = pcall(function()
        ok_rep(fs.send_packet(fh, P.packet(3, P.u64s(size)), slots.pkt), "SD resize")
        local wrote = each_save_part(function(at, s)
            rt.wr(slots.data, s)
            ok_rep(fs.send_packet(fh, P.packet(1, P.u32s(0) .. P.u32s(0) .. P.u64s(at) .. P.u64s(#s),
                {a = {{addr = slots.data, size = #s, mode = 1}}}), slots.pkt), "SD write")
        end)
        assert(wrote == size, "save copy changed size while it was copied")
        ok_rep(fs.send_packet(fh, P.packet(2, ""), slots.pkt), "SD flush")
    end)
    rt.close_handle(fh)
    if okw and not same_as_save(NRO.tmp) then okw, errw = false, "read-back of " .. NRO.tmp .. " differs from the save copy" end
    if not okw then
        fs.ipc_delete_file(sdh, NRO.tmp)
        error(errw, 0)
    end

    if had then
        local dr = fs.ipc_delete_file(sdh, NRO.path)
        assert(dr == 0, "cannot delete the old " .. NRO.path .. " (" .. hx(dr or 0) .. "); new copy left at " .. NRO.tmp)
    end
    local rr = fs.ipc_rename_file(sdh, NRO.tmp, NRO.path)
    assert(rr == 0, "rename " .. NRO.tmp .. " -> " .. NRO.path .. " failed (" .. hx(rr or 0) .. ")")
    log(string.format("installed %s (%d B, read back identical%s)", NRO.path, size, had and ", replaced the old copy" or ""))
    return "installed"
end

function ML.run(h)
    local M, P, env = h.M, h.P, h.env
    local rt, fs, ctx, slots = env.rt, env.fs, env.ctx, env.slots
    local read_fs = env.read_fs
    local t0 = rt.now_ms()
    local function log(s) env.kh_log("ML: " .. s) end
    local function hx(v) return string.format("0x%x", v) end
    local ZERO16 = string.rep("\0", 16)

    if _G.__s2_install_nro then
        local okn, resn = pcall(install_nro, h, function(s) env.kh_log("NRO: " .. s) end)
        if not okn then env.kh_log("NRO: install failed (the loader and kaiHEN continue): " .. tostring(resn)) end
        _G.__s2_install_nro_result = okn and resn or "failed"
    end

    -- ===== M1: helper RO, ro:dmnt, FS process handle and base =====
    local orig = M.SD_MANIFEST.ro.path
    M.SD_MANIFEST.ro.path = HELPER_PATH
    local okp, errp = pcall(h.prepare)
    M.SD_MANIFEST.ro.path = orig
    if not okp then error("helper donor staging failed: " .. tostring(errp)) end
    log("helper donor staged; launching helper RO in place of pid " .. ctx.pm.originalPid)
    h.launch()
    local helper_pid = ctx.launch.pid          -- save guard pid floor (images with `guard`)
    ctx.pm.originalPid = ctx.launch.pid        -- the next launch (kaiHEN) must terminate the helper
    log("helper RO running, pid=" .. ctx.launch.pid)

    local function tipc_lookup(name)
        rt.memset(slots.pkt, 0, 0x80)
        rt.wr(slots.pkt, P.tipc_get_service_packet(name))
        local trc = rt.send_ipc(ctx.pm.sm, slots.pkt)
        if trc ~= 0 then return nil, "transport " .. hx(trc) end
        local raw = rt.rd(slots.pkt, 20)
        local res = P.u32(raw, 16)
        if res ~= 0 then return nil, "result " .. hx(res) end
        return env.track(P.u32(raw, 12), name)
    end
    local ro, why = nil, nil
    for _ = 1, 60 do
        ro, why = tipc_lookup("ro:dmnt")
        if ro then break end
        rt.wait_ms(100)
    end
    assert(ro, "ro:dmnt lookup failed: " .. tostring(why))
    log("ro:dmnt session " .. hx(ro))

    local function call(cmd, words, fs_handle)
        local input = ""
        for _, w in ipairs(words) do input = input .. P.u64s(w) end
        local opts = {}
        if fs_handle then opts.copies = {fs_handle} end
        local rep = fs.send_packet(ro, P.packet(cmd, input, opts), slots.pkt2)
        assert(rep.transport == 0, string.format("helper %s transport 0x%x", hx(cmd), rep.transport))
        local out = {}
        for i = 0, 12 do out[i] = P.u64(rep.data, i * 8) end
        return rep.result, out, rep
    end

    -- Echo challenge: output[0] = "NS2ROEXE", output[1] = nonce ^ 0x9d7c3a51e6b2048f.
    local nonce_lo, nonce_hi = 0x13572468, 0x0000abcd
    local res, out, rep = call(CMD.challenge, {nonce_hi * TWO32 + nonce_lo})
    local magic = string.sub(rep.data, 1, 8)
    local x_lo, x_hi = P.u32(rep.data, 8), P.u32(rep.data, 12)
    local ok_echo = res == 0 and magic == "NS2ROEXE" and
        x_lo == P.bxor32(nonce_lo, 0xe6b2048f) and x_hi == P.bxor32(nonce_hi, 0x9d7c3a51)
    log(string.format("challenge result=%s magic=%q echo=%s helper pid=%d tid=%d registration=0x%x",
        hx(res), magic, tostring(ok_echo), out[2], out[3], out[5]))
    assert(ok_echo, "helper challenge mismatch")
    local helper_pid_echo = out[2]

    local fsp = env.export_handle(0xFFFF8001, "ml-fs-process").handle
    local vptr = P.u64(read_fs(ctx.notifier.object, 8), 0)
    local slot4 = P.u64(read_fs(vptr + 4 * 8, 8), 0)
    local base = slot4 - NOTIFIER_SLOT4_OFFSET
    log(string.format("notifier object=%s vptr=%s slot4=%s -> FS .text base guess %s",
        hx(ctx.notifier.object), hx(vptr), hx(slot4), hx(base)))

    res, out = call(CMD.info, {0, slot4, 0, 0}, fsp)
    local fs_pid = out[0]
    local text_bytes, free_fs = out[5], out[11]
    log(string.format("0x10 result=%s pid=%d program=%s region=%s+%s type=%d perm=%d aslr=%s+%s free(FS)=%s free(RO)=%s",
        hx(res), fs_pid, hx(out[1]), hx(out[4]), hx(out[5]), out[6] % TWO32, out[7] % TWO32,
        hx(out[9]), hx(out[10]), hx(out[11]), hx(out[12])))
    assert(res == 0 and out[1] == FS_PROGRAM, "helper 0x10 did not identify FS")
    if out[4] ~= base then log("WARNING: code region base " .. hx(out[4]) .. " differs from the vtable guess") end

    -- Query any FS address: region {base, size, type, attr, perm}, plus the first free page.
    local function query(addr)
        local r, o = call(CMD.info, {fs_pid, addr, 0, 0}, fsp)
        return {result = r, base = o[4], size = o[5], type = o[6] % TWO32, attr = math.floor(o[6] / TWO32),
            perm = o[7] % TWO32, free = o[11]}
    end

    local function read128(addr, n)
        local r, o, rp = call(CMD.read, {fs_pid, addr, n, 0}, fsp)
        if r ~= 0 then return nil, r end
        return string.sub(rp.data, 57, 56 + n), r
    end
    -- Any length; split at 128 bytes and page ends (helper 0x11 limits).
    local function read_code(addr, n)
        local parts, at = {}, 0
        while at < n do
            local a = addr + at
            local take = math.min(128, n - at, 0x1000 - a % 0x1000)
            local b, r = read128(a, take)
            assert(b, string.format("code read failed at %s (result %s)", hx(a), hx(r or 0)))
            parts[#parts + 1] = b
            at = at + take
        end
        return table.concat(parts)
    end
    local prologue = read128(base + NOTIFIER_SLOT4_OFFSET, 16)
    log("slot4 prologue " .. (prologue and P.hex(prologue) or "read failed"))
    local zero = read_code(base + GATEWAY_CAVE, 1024) == string.rep("\0", 1024) and
        read_code(base + CONTROL_CAVE, 256) == string.rep("\0", 256)
    log("gateway/control caves zero (not installed this boot): " .. tostring(zero))
    log(string.format("milestone 1 done in %d ms", rt.now_ms() - t0))
    assert(zero, "caves are not empty; refusing to stage the bridge")

    -- ===== M2: FS call bridge (ns2jb lib/native/bridge.cjs, ported) =====
    local EXPECT = {                      -- first 16 bytes, from the reference FS capture a8cf885c
        [0x1201b0] = "7f2303d5ff8300d1fd7b01a9fd430091",   -- notifier GetEventHandle (slot 4)
        [0x0694c0] = "7f2303d5ffc300d1fd7b01a9f44f02a9",   -- allocate(size)
        [0x069580] = "600300b47f2303d5fd7bbda9f50b00f9",   -- free(p, size)
    }
    local function raw_call(cmd, input)
        local rp = fs.send_packet(ro, P.packet(cmd, input, {copies = {fsp}}), slots.pkt2)
        assert(rp.transport == 0, string.format("helper %s transport 0x%x", hx(cmd), rp.transport))
        return rp.result, rp
    end
    local function patch16(addr, before, after)
        local r, rp = raw_call(CMD.patch, P.u64s(fs_pid) .. P.u64s(addr) .. P.u64s(16) .. P.u64s(0) .. before .. after)
        local matched, readback = P.u32(rp.data, 48), P.u32(rp.data, 56)
        assert(r == 0 and matched == 1 and readback == 1,
            string.format("patch at %s failed result=%s matched=%d readback=%d", hx(addr), hx(r), matched, readback))
    end
    local function set_perm(page, perm)
        local r, rp = raw_call(CMD.perm, P.u64s(fs_pid) .. P.u64s(page) .. P.u64s(0x1000) .. P.u64s(perm))
        return r, P.u64(rp.data, 24)
    end
    local SLOT4, PAGE = base + NOTIFIER_SLOT4_OFFSET, base + (GATEWAY_CAVE - GATEWAY_CAVE % 0x1000)
    local original = read_code(SLOT4, 16)
    assert(P.hex(original) == EXPECT[0x1201b0], "slot 4 prologue differs from the reference FS build")

    local E, B_raw = ctx.notifier.object, read_fs(ctx.notifier.object + 8, 8)
    local refs = P.u32(read_fs(E + 16, 4), 0)
    log(string.format("notifier E=%s B=%s refs=%d", hx(E), P.hex(B_raw), refs))
    assert(P.u64(B_raw, 0) == ctx.notifier.B and refs == 1, "notifier is not exclusively owned")

    local sdh = env.open_sd_card()
    local function sd_str(path, max) return env.sd_read_file(sdh, path, max).str end
    local TPL = assert(loadstring(sd_str("/kaihen/ml/tpl.lua", 0x10000), "@/kaihen/ml/tpl.lua"))()

    -- Bridge state: the cave moves from the 1024-byte call cave to the 256-byte control cave once
    -- the gateway takes the call cave's place (ns2jb Bridge.controlCave).
    local br = {cave = base + GATEWAY_CAVE, width = 1024}
    br.now = string.rep("\0", br.width)
    local function hook_bytes()
        return P.u32s(0x14000000 + ((br.cave - SLOT4) / 4) % 0x4000000) .. string.rep(P.u32s(0xd503201f), 3)
    end
    local function nop_pad(s) return s .. string.rep("\0", (16 - #s % 16) % 16) end
    local function instantiate(name, op, args)
        local t = assert(TPL[name], "no template " .. name)
        local code = P.unhex(t.hex)
        code = P.put_bytes(code, t.lit.owner, P.u64s(E))
        code = P.put_bytes(code, t.lit.operation, P.u64s(op))
        code = P.put_bytes(code, t.lit.result, P.u64s(E + 8))
        for i, a in ipairs(args) do code = P.put_bytes(code, assert(t.lit["arg" .. (i - 1)], "too many args"), P.u64s(a)) end
        local delta = (SLOT4 + 16) - (br.cave + t.branch)
        assert(delta % 4 == 0, "misaligned branch")
        code = P.put_u32(code, t.branch, 0x14000000 + (delta / 4) % 0x4000000)
        code = nop_pad(code)
        assert(#code <= br.width, name .. " does not fit the cave")
        return code
    end
    local function stage(code)
        local nxt = code .. string.rep("\0", br.width - #code)
        for i = 0, br.width - 1, 16 do
            local a, b = string.sub(br.now, i + 1, i + 16), string.sub(nxt, i + 1, i + 16)
            if a ~= b then patch16(br.cave + i, a, b) end
        end
        br.now = nxt
    end

    -- Cave page must be readable (R-X) for the templates' literal loads.
    local r15, page_perm_before = set_perm(PAGE, 5)
    assert(r15 == 0, "cave page permission change failed " .. hx(r15))
    log("cave page " .. hx(PAGE) .. " now R-X (was perm " .. page_perm_before .. ")")

    local hooked = false
    local function invoke(name, op, args)
        stage(instantiate(name, op, args))
        local hb = hook_bytes()
        patch16(SLOT4, original, hb); hooked = hb
        local ok, res2 = pcall(function()
            local rp = fs.send_packet(ctx.notifier.handle, P.packet(0, ""), slots.pkt2)
            assert(rp.transport == 0 and rp.canonical_result == 0x6dfe and #rp.copies == 0 and #rp.moves == 0,
                string.format("bridge nonce missing: transport=0x%x result=0x%x", rp.transport, rp.result))
            return read_fs(E + 8, 8)
        end)
        local now = read_fs(E + 8, 8)
        if now ~= B_raw then env.compare_write_fs(E + 8, now, B_raw) end
        patch16(SLOT4, hb, original); hooked = false
        if not ok then error(res2) end
        return P.u64(res2, 0), res2
    end
    -- FS function at base+off; its first 16 bytes must match the reference build.
    local function fs_call(name, off, args, expect_hex)
        expect_hex = expect_hex or EXPECT[off]
        if expect_hex then assert(P.hex(read_code(base + off, 16)) == expect_hex, "call target differs at " .. hx(off)) end
        return invoke(name, base + off, args)
    end
    local function bridge_cleanup(keep_page_rx)
        if hooked then pcall(patch16, SLOT4, hooked, original); hooked = false end
        pcall(stage, "")
        if not keep_page_rx then
            local rr = set_perm(PAGE, page_perm_before)
            log(string.format("cave emptied, page permission restored (result %s)", hx(rr)))
        else
            log("control cave emptied; cave page stays R-X for the resident gateway")
        end
    end

    local img_ex = fs.ipc_get_entry_type(sdh, INSTALL_DIR .. "/image.lua", 0x301)
    if not (img_ex.transport == 0 and img_ex.result == 0) then
        -- M2 self-test only.
        local okb, errb = pcall(function()
            local p = fs_call("call1", 0x0694c0, {0x40})
            log("bridge call allocate(0x40) -> " .. hx(p))
            assert(p > 0x100000000, "allocation result implausible")
            log("allocated block readable via data channel, first 16 B " .. P.hex(string.sub(read_fs(p, 0x40), 1, 16)))
            log("bridge call free(p, 0x40) -> " .. hx(fs_call("call2", 0x069580, {p, 0x40})))
        end)
        bridge_cleanup(false)
        if not okb then error("milestone 2 bridge test failed: " .. tostring(errb)) end
        log(string.format("milestone 2 done in %d ms (no install image at %s)", rt.now_ms() - t0, INSTALL_DIR))
        return
    end

    -- ===== M3: resident install from the precomputed image (ns2jb lib/resident.cjs) =====
    local I = assert(loadstring(sd_str("/kaihen/ml/ml_image.lua", 0x10000), "@/kaihen/ml/ml_image.lua"))()
    local st = {stage = "load image", pages = {}, gateway_rows = 0, hooks = 0}
    local img
    local function install()
        img = I.load(sd_str, INSTALL_DIR)
        local F = img.fs
        log(string.format("image %s: titles %s, views %s; runtime %d B/%d fixups, gateway %d B, context %d B/%d fixups, %d hooks",
            tostring(img.generated), table.concat(img.plan.titles, ","), table.concat(img.plan.views, ",") ~= "" and table.concat(img.plan.views, ",") or "none",
            img.runtime.bytes, #img.runtime.fixups / 3, img.gateway.bytes, img.context.bytes, #img.context.fixups / 3, #img.hooks))

        st.stage = "check FS build"
        assert(text_bytes == F.text_bytes, "FS .text size " .. hx(text_bytes) .. " differs from the image's " .. hx(F.text_bytes))
        assert(F.cave == GATEWAY_CAVE and F.control_cave == CONTROL_CAVE and F.notifier_slot4 == NOTIFIER_SLOT4_OFFSET,
            "image FS layout differs from this stage's bridge")
        local bad = I.check_fingerprint(img, base, read_code)
        assert(#bad == 0, "FS fingerprint differs at " .. #bad .. " offset(s), first " .. hx(bad[1] or 0))
        log("FS fingerprint matches (" .. #img.fingerprint .. " functions)")

        if img.guard then                                    -- before anything is written to FS
            st.stage = "check save guard"
            local G = img.guard
            local protected = protected_users(sd_str, log)
            assert(type(G.user) == "string" and #G.user == 32 and not protected[G.user:lower()],
                "save guard: the allowed user must not be a protected user (" .. tostring(G.user) .. ")")
            assert(type(helper_pid) == "number" and helper_pid > 0 and helper_pid == helper_pid_echo,
                "save guard: helper pid " .. tostring(helper_pid) .. " and its challenge pid " .. tostring(helper_pid_echo) .. " differ")
            assert(fs_pid < helper_pid, "save guard: FS pid " .. tostring(fs_pid) .. " is not below the floor " .. helper_pid)
            local named = {}
            for _, hk in ipairs(img.hooks) do named[hk.name] = hk.off end
            for _, site in ipairs(G.sites) do                -- verified byte for byte by the fingerprint above
                local whole = false
                for _, row in ipairs(img.fingerprint) do if row[1] == site.off and #row[2] == 2 * site.bytes then whole = true end end
                assert(named[site.name] == site.off and whole, "save guard: " .. site.name .. " is not hooked and fingerprinted whole")
            end
            log(string.format("save guard: account saves of program %s refused (%s) after pid %d for every user except %s",
                G.program, hx(G.result), helper_pid, G.user))
        end

        st.stage = "check SD files"                          -- the plan opens these by path later
        if img.live_sizes then                               -- served at their SD size at each launch
            local present = 0
            for _, f in ipairs(img.files) do
                local fh = fs.ipc_open_file(sdh, f.path, 1, 0x301)
                if fh == 0 then
                    log("overlay file missing: " .. f.path .. " (the title stays native for it until it is back)")
                else
                    local size = fs.ipc_file_get_size(fh)
                    rt.close_handle(fh)
                    present = present + 1
                    log(string.format("overlay file %s: %s B%s", f.path, tostring(size),
                        size ~= f.size and string.format(" (image built with %s B; served at the SD size)", tostring(f.size)) or ""))
                end
            end
            log(string.format("live SD sizes: %d of %d overlay file(s) present", present, #img.files))
        else
            for _, f in ipairs(img.files) do
                local fh, oerr = fs.ipc_open_file(sdh, f.path, 1, 0x301)
                assert(fh ~= 0, "planned SD file missing: " .. f.path .. " (" .. hx(oerr or 0) .. ")")
                local size = fs.ipc_file_get_size(fh)
                rt.close_handle(fh)
                assert(size == f.size, string.format("SD file changed since the image was built: %s is %s B, plan %s B",
                    f.path, tostring(size), tostring(f.size)))
            end
            log(#img.files .. " planned SD file(s) present with the planned sizes")
        end

        -- FS object behind one of our sessions: clone it (control 2), ConvertToDomain the clone, read
        -- the domain table entry (ns2jb lib/native/source.cjs locate(); the chain's locate_by_clone).
        local function locate(handle, ref_off, what)
            local crep = fs.send_packet(handle, P.domain_control(2, ""), slots.pkt2)
            assert(crep.transport == 0 and crep.result == 0 and #crep.moves == 1, what .. " session clone failed")
            local clone = crep.moves[1]
            local okl, loc = pcall(function()
                local conv = fs.send_packet(clone, P.domain_control(0, ""), slots.pkt)
                assert(conv.transport == 0 and conv.result == 0, "ConvertToDomain on the " .. what .. " clone failed")
                local id = P.u32(conv.data, 0)
                local entry = read_fs(ctx.layout.table + (id - 1) * 0x30, 0x30)
                local obj = P.u64(entry, 0x20)
                local hdr = read_fs(obj, ref_off + 8)
                local vt = read_fs(P.u64(hdr, 0), 64)
                local slots_ = {}
                for i = 0, 7 do slots_[i] = P.u64(vt, i * 8) end
                return {id = id, object = obj, vptr = P.u64(hdr, 0), refs = P.u32(hdr, ref_off), slot = slots_}
            end)
            rt.close_handle(clone)
            if not okl then error(loc) end
            assert(loc.refs >= 2 and loc.refs <= 16, "unexpected " .. what .. " clone references " .. loc.refs)
            loc.baseline = P.u32(read_fs(loc.object + ref_off, 4), 0)
            assert(loc.refs == loc.baseline + 1 and loc.baseline >= 1, what .. " clone reference did not release exactly once")
            return loc
        end

        -- SD report + trace (ns2jb lib/diagnostics.cjs writeReport, then source.cjs openSource).
        local L, report = img.logs, nil
        local logobj, traceobj
        if L then
            st.stage = "create SD report"
            local function ipc_ok(rp, what)
                assert(rp.transport == 0 and rp.result == 0, string.format("%s failed: transport=0x%x result=0x%x", what, rp.transport, rp.result or 0))
            end
            local function file_write(fh, data)
                local pos = 0
                while pos < #data do
                    local take = math.min(0x10000, #data - pos)
                    rt.wr(slots.data, string.sub(data, pos + 1, pos + take))
                    ipc_ok(fs.send_packet(fh, P.packet(1, P.u32s(0) .. P.u32s(0) .. P.u64s(pos) .. P.u64s(take),
                        {a = {{addr = slots.data, size = take, mode = 1}}}), slots.pkt), "SD report write")
                    pos = pos + take
                end
            end
            local function make_file(path, data)       -- create (or reuse), size, write, flush, close
                local e = fs.ipc_get_entry_type(sdh, path, 0x301)
                if e.transport == 0 and e.result == 0 then fs.ipc_delete_file(sdh, path) end
                local cr = fs.ipc_create_file(sdh, path, #data)
                assert(cr == 0, "cannot create " .. path .. " (" .. hx(cr or 0) .. ")")
                local fh, oerr = fs.ipc_open_file(sdh, path, 3, 0x301)
                assert(fh ~= 0, "cannot open " .. path .. " (" .. hx(oerr or 0) .. ")")
                local okw, errw = pcall(function()
                    ipc_ok(fs.send_packet(fh, P.packet(3, P.u64s(#data)), slots.pkt), "SD report resize")
                    file_write(fh, data)
                    ipc_ok(fs.send_packet(fh, P.packet(2, ""), slots.pkt), "SD report flush")
                end)
                rt.close_handle(fh)
                if not okw then error(errw) end
            end
            for _, dir in ipairs({"/ns2jb-modloader", L.dir}) do
                local e = fs.ipc_get_entry_type(sdh, dir, 0x301)
                if not (e.transport == 0 and e.result == 0) then
                    assert(fs.ipc_create_directory(sdh, dir) == 0, "cannot create " .. dir)
                end
            end
            -- Next boot counter after the newest onconsole-NNNN.log; keep the newest `keep` reports.
            local listing = fs.ipc_list_directory(sdh, L.dir, 3)
            local seen = {}
            local pat = "^" .. L.stem:gsub("%-", "%%-") .. string.rep("%d", L.digits) .. "%.log$"
            for _, e in ipairs(listing.entries or {}) do
                if e.name:match(pat) then seen[#seen + 1] = tonumber(e.name:sub(#L.stem + 1, #L.stem + L.digits)) end
            end
            table.sort(seen)
            local index = ((seen[#seen] or 0) + 1) % (10 ^ L.digits)
            while #seen >= L.keep do
                local old = I.log_paths(img, table.remove(seen, 1))
                fs.ipc_delete_file(sdh, old.log)
                fs.ipc_delete_file(sdh, (old.log:gsub("%.log$", ".trace")))
            end
            local paths = I.log_paths(img, index)
            st.log_index = index
            -- The report text as it will sit in the context (counter digits filled in).
            -- (the text holds no fixup slots, so placeholder values do not change it)
            report = I.build(img, {base = base, ctx = 0x100000000, rt = 0x1000, sdfs = 1, registry = 1, log = 1, trace = 1,
                pidfloor = 1, log_index = index}).report
            make_file(paths.log, report)
            if paths.trace then make_file(paths.trace, string.rep("\0", L.trace_bytes)) end
            log(string.format("SD report %s (%d B)%s", paths.log, #report, paths.trace and (", trace " .. paths.trace) or ""))

            st.stage = "open SD report for the resident"
            st.files = {}
            local function retain(path, size, what)
                local fh, oerr = fs.ipc_open_file(sdh, path, 7, 0x301)
                assert(fh ~= 0, "cannot reopen " .. path .. " (" .. hx(oerr or 0) .. ")")
                st.files[#st.files + 1] = fh
                assert(fs.ipc_file_get_size(fh) == size, what .. " size changed")
                local o = locate(fh, F.file_ref_offset, what)
                local V = F.file_vtable
                assert(o.slot[0] == base + V[1] and o.slot[1] == base + V[2] and o.slot[4] == base + V[5], what .. " method table differs")
                assert(o.baseline == 1, what .. " is not exclusively owned (refs " .. o.baseline .. ")")
                return o
            end
            logobj = retain(paths.log, #report, "report")
            local V = F.file_vtable
            assert(logobj.slot[5] == base + V[6] and logobj.slot[6] == base + V[7] and logobj.slot[7] == base + V[8],
                "report write/flush/setSize differ from the image")
            if paths.trace then
                traceobj = retain(paths.trace, L.trace_bytes, "trace")
                assert(traceobj.slot[5] == logobj.slot[5] and traceobj.slot[6] == logobj.slot[6], "trace and report file operations differ")
            end
            log(string.format("report IFile %s%s (exclusively ours)", hx(logobj.object), traceobj and (", trace IFile " .. hx(traceobj.object)) or ""))
        end

        st.stage = "locate SD filesystem object"             -- after the file opens, which retain it too
        local loc = locate(sdh, F.sdfs_ref_offset, "SD")
        assert(loc.slot[0] == base + F.sdfs_vtable0 and loc.slot[1] == base + F.sdfs_vtable1, "SD object method table differs")
        local sd_baseline = loc.baseline
        local sdfs = loc.object
        log(string.format("SD filesystem object %s (domain id %d, vptr %s), refs %d", hx(sdfs), loc.id, hx(loc.vptr), sd_baseline))

        st.stage = "read program registry"
        local registry = P.u64(read_fs(base + F.registry_global, 8), 0) + F.registry_add
        assert(registry >= 0x100000000 and registry < 0x8000000000, "FS program registry is unavailable")

        st.stage = "allocate context"
        local ctxa = fs_call("allocate", F.allocate, {img.context.bytes})   -- clearing allocation
        assert(ctxa >= 0x100000000 and ctxa < 0x8000000000 and ctxa % 16 == 0, "context allocation failed: " .. hx(ctxa))
        st.ctx = ctxa
        local q = query(ctxa)
        assert(q.result == 0 and q.perm == 3 and q.attr == 0 and ctxa + img.context.bytes <= q.base + q.size,
            "context is not backed by RW memory")
        assert(read_fs(ctxa, 64) == string.rep("\0", 64), "context allocation is not cleared")

        st.stage = "allocate runtime pages"                  -- ns2jb Bridge.mapRuntime
        local outp = fs_call("call1", F.allocate, {8})
        assert(outp >= 0x100000000 and outp < 0x8000000000, "allocation output failed")
        local rb = fs_call("call3", F.allocate_block, {base + F.block_manager, outp, img.runtime.bytes})
        local src = P.u64(read_fs(outp, 8), 0)
        fs_call("call2", F.free, {outp, 8})
        assert(rb == 0, "cannot reserve runtime pages: " .. hx(rb))
        st.block = src
        q = query(src)
        assert(src >= 0x100000000 and src < 0x8000000000 and src % 0x1000 == 0 and q.result == 0 and q.type == 5 and
            q.perm == 3 and q.attr == 0 and src + img.runtime.bytes <= q.base + q.size, "runtime block is not Normal/RW memory")
        local rtva = free_fs
        local tq = query(rtva)
        assert(rtva > 0 and rtva % 0x1000 == 0 and tq.result == 0 and tq.type == 0 and rtva + img.runtime.bytes <= tq.base + tq.size,
            "no free range for the runtime at " .. hx(rtva))
        if rtva ~= img.runtime.expected_va then log("note: runtime VA " .. hx(rtva) .. " (image built expecting " .. hx(img.runtime.expected_va) .. ")") end
        log(string.format("registry %s, context %s (%d B), runtime block %s -> VA %s", hx(registry), hx(ctxa),
            img.context.bytes, hx(src), hx(rtva)))

        st.stage = "relocate image"
        local live = {base = base, ctx = ctxa, rt = rtva, sdfs = sdfs, registry = registry,
            log = logobj and logobj.object, trace = traceobj and traceobj.object, log_index = st.log_index,
            pidfloor = img.guard and helper_pid or nil}
        local blob = I.build(img, live)
        if L then assert(blob.report == report, "report text in the context differs from the SD file") end

        st.stage = "write context"
        for at = 0, #blob.context - 1, 0x4000 do
            local part = string.sub(blob.context, at + 1, at + 0x4000)
            env.compare_write_fs(ctxa + at, string.rep("\0", #part), part)
        end
        st.stage = "write runtime source"
        for at = 0, #blob.runtime - 1, 0x4000 do
            local part = string.sub(blob.runtime, at + 1, at + 0x4000)
            env.compare_write_fs(src + at, read_fs(src + at, #part), part)
        end

        st.stage = "map runtime pages"
        for i = 0, img.runtime.pages - 1 do
            local s, d = src + i * 0x1000, rtva + i * 0x1000
            local r, rp = raw_call(CMD.map, P.u64s(fs_pid) .. P.u64s(s) .. P.u64s(d) .. P.u64s(0x1000))
            local mr, pr = P.u64(rp.data, 24), P.u64(rp.data, 32)
            assert(r == 0 and mr == 0 and pr == 0, string.format("map page %d failed result=%s map=%s perm=%s", i, hx(r), hx(mr), hx(pr)))
            st.pages[#st.pages + 1] = {src = s, dst = d}
        end
        st.stage = "publish runtime"
        invoke("publish", 0, {rtva, img.runtime.bytes})
        local entry_init = rtva + img.runtime.entry.lfs_initialize
        q = query(entry_init)
        assert(q.result == 0 and q.perm == 5, "runtime entry is not R-X")
        assert(read_code(rtva, 128) == string.sub(blob.runtime, 1, 128), "runtime code readback differs")
        local fx = img.runtime.fixups
        for i = 1, #fx, 3 do
            assert(read_code(rtva + fx[i], 8) == string.sub(blob.runtime, fx[i] + 1, fx[i] + 8), "runtime literal differs at " .. fx[i])
        end
        log(string.format("runtime mapped R-X at %s (%d pages), literals verified", hx(rtva), img.runtime.pages))

        if L and L.trace then                               -- resident.cjs: qualify the trace clock
            st.stage = "trace clock probe"
            local at = ctxa + L.clock_probe
            local rc = invoke("call1", rtva + img.runtime.entry.lfs_trace_clock_probe, {at})
            local clock = read_fs(at, 16)
            assert(rc == 0 and P.u64(clock, 8) > 0, "trace clock probe failed: " .. hx(rc))
            log(string.format("trace clock tick %d, frequency %d Hz", P.u64(clock, 0), P.u64(clock, 8)))
        end

        st.stage = "lfs_initialize"
        local function refs(o, off) return P.u32(read_fs(o.object + off, 4), 0) end
        assert(refs(loc, F.sdfs_ref_offset) == sd_baseline, "SD reference baseline changed")
        if logobj then assert(refs(logobj, F.file_ref_offset) == 1, "report reference baseline changed") end
        if traceobj then assert(refs(traceobj, F.file_ref_offset) == 1, "trace reference baseline changed") end
        local ri = invoke("call0", entry_init, {})
        assert(ri == 0, "lfs_initialize returned " .. hx(ri))
        st.initialized = true
        local after = refs(loc, F.sdfs_ref_offset)
        assert(after == sd_baseline + 1, "SD reference did not retain once: " .. sd_baseline .. " -> " .. after)
        if logobj then assert(refs(logobj, F.file_ref_offset) == 2, "report reference did not retain once") end
        if traceobj then assert(refs(traceobj, F.file_ref_offset) == 2, "trace reference did not retain once") end
        log("lfs_initialize: SD object retained (" .. sd_baseline .. " -> " .. after .. ")" ..
            (logobj and ("; report" .. (traceobj and " and trace" or "") .. " retained (1 -> 2)") or ""))
        -- resident.cjs source.close(): our own sessions go; the resident keeps its references.
        for i = #(st.files or {}), 1, -1 do rt.close_handle(st.files[i]); st.files[i] = nil end

        st.stage = "switch to control cave"
        stage("")
        assert(read_code(base + CONTROL_CAVE, 256) == string.rep("\0", 256), "control cave is occupied")
        br.cave, br.width = base + CONTROL_CAVE, 256
        br.now = string.rep("\0", 256)

        st.stage = "write gateway"
        for _, row in ipairs(I.gateway_rows(img, blob.gateway, base)) do
            patch16(row.addr, ZERO16, row.bytes)
            st.gateway_rows = st.gateway_rows + 1
        end
        assert(read_code(base + GATEWAY_CAVE, #blob.gateway) == blob.gateway, "gateway readback differs")

        st.stage = "attach hooks"
        for _, hk in ipairs(I.hooks(img, base)) do
            patch16(hk.addr, hk.before, hk.after)
            st.hooks = st.hooks + 1
        end
        log(string.format("gateway (%d B) and %d hooks attached%s", #blob.gateway, st.hooks,
            img.guard and " (including the save guard's Save.Open and Save.OpenReadOnly)" or ""))

        st.stage = "lfs_activate"
        local ra = invoke("call0", rtva + img.runtime.entry.lfs_activate, {})
        assert(ra == 0, "lfs_activate returned " .. hx(ra))
        local head = read_fs(ctxa, 16)
        assert(string.sub(head, 1, 8) == img.context.magic and P.u32(head, img.context.enabled_offset) == 1,
            "context is not active after lfs_activate")
        st.active = true
        st.stage = "done"
    end

    local oki, erri = pcall(install)
    for i = #(st.files or {}), 1, -1 do pcall(rt.close_handle, st.files[i]); st.files[i] = nil end   -- report/trace sessions
    if oki then
        bridge_cleanup(true)
        log(string.format("milestone 3: modloader resident and active (%s) in %d ms",
            table.concat(img.plan.titles, ","), rt.now_ms() - t0))
        if img.logs then log("loader report: " .. I.log_paths(img, st.log_index).log) end
        log("NOTE: until reboot, those titles load the SD overlay on every user")
        if img.guard then
            log(string.format("NOTE: until reboot, program %s started now on any user except %s cannot open its save",
                img.guard.program, img.guard.user))
        end
        return
    end
    log("milestone 3 failed at '" .. st.stage .. "': " .. tostring(erri))
    -- Undo what can be undone. Once a hook is attached the resident pieces stay (hooks pass through
    -- until lfs_activate), exactly like ns2jb's own install failure path.
    if st.hooks > 0 then
        bridge_cleanup(true)
        log(string.format("%d hook(s) attached: gateway, runtime and context retained until reboot (inactive=%s)",
            st.hooks, tostring(not st.active)))
    else
        local okg = pcall(function()                     -- gateway rows written so far go back to zero
            for i = st.gateway_rows, 1, -1 do
                local a = base + GATEWAY_CAVE + (i - 1) * 16
                patch16(a, read_code(a, 16), ZERO16)
                st.gateway_rows = i - 1
            end
        end)
        if not okg then
            bridge_cleanup(true)
            error("milestone 3 install failed: " .. tostring(erri) .. "; gateway rows could not be removed, page left R-X")
        end
        local undone = true
        for i = #st.pages, 1, -1 do
            local pg = st.pages[i]
            local okp2, r = pcall(raw_call, CMD.unmap, P.u64s(fs_pid) .. P.u64s(pg.src) .. P.u64s(pg.dst) .. P.u64s(0x1000))
            if not okp2 or r ~= 0 then undone = false; break end
            st.pages[i] = nil
        end
        if undone and st.block and not st.initialized then
            pcall(fs_call, "call3", img.fs.free_block, {base + img.fs.block_manager, st.block, img.runtime.bytes})
        end
        if st.ctx and not st.initialized then pcall(fs_call, "call2", img.fs.free, {st.ctx, img.context.bytes}) end
        bridge_cleanup(false)
        log(string.format("rolled back (runtime pages still mapped: %d, SD retained: %s)", #st.pages, tostring(st.initialized == true)))
    end
    error("milestone 3 install failed: " .. tostring(erri))
end

return ML
