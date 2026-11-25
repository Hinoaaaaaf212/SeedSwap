


local P = require("s2_prim")

local M = {}

local math_floor = math.floor
local math_ceil  = math.ceil
local math_min   = math.min
local math_max   = math.max
local str_byte   = string.byte
local str_char   = string.char
local str_sub    = string.sub
local str_rep    = string.rep
local str_format = string.format
local tbl_concat = table.concat


M.RO_TITLE_NUM  = 0x0400000000000037 -- Note: bit 58 is 0x0400000000000000; use 8-byte LE string!
M.RO_TITLE_STR  = str_char(0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04)
M.HEN_TITLE_STR = str_char(0x3a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04)

-- [safe] kaiHEN releases this save runs, newest first. bootstrap.bin, ro, hen and game must all
-- come from one of them; anything else is refused before it can become the RO donor / bootstrap.
-- 20261123: layout and file sizes as in rushinz/seedsow-semi-untethered d2e6fac.
M.SD_RELEASES = {
    {name = "20261123",   bootstrap = 27948, ro = 29198, hen = 78763, game = 71761},
    {name = "20261117.1", bootstrap = 27948, ro = 23854, hen = 78765, game = 63424},
}
M.SD_REQUIRED = {"bootstrap", "ro", "hen", "game"}
M.SD_ORDER = {"bootstrap", "ro", "hen", "game", "hbmenu", "programs", "lib"}

M.SD_MANIFEST = {
    bootstrap = {path = "/kaihen/bin/bootstrap.bin", size = 27948, optional = false},
    ro        = {path = "/kaihen/bin/ro/main",       size = 29198, optional = false},
    hen       = {path = "/kaihen/bin/hen/main",      size = 78763, optional = false},
    game      = {path = "/kaihen/bin/game/main",     size = 71761, optional = false},
    hbmenu    = {path = "/hbmenu.nro",               size = 11852414, optional = true},
    programs  = {path = "/switch/ounceshell.nro",    size = 22352203, optional = true},
    lib       = {path = "/kaihen/lib/libounce.so.1", size = 2351104, optional = true},
}

-- Where each part is in an unpacked kaiHEN zip: 20261123 first (its sdcard/ mirrors the card),
-- then the older zips (hen/, game/, programs/ at the top). dir = the part is the folder of its
-- SD_MANIFEST file.
M.SD_SOURCES = {
    bootstrap = {dir = false, "bootstrap.bin"},
    ro        = {dir = true,  "ro"},
    hen       = {dir = true,  "sdcard/kaihen/bin/hen", "hen"},
    game      = {dir = true,  "sdcard/kaihen/bin/game", "game"},
    hbmenu    = {dir = false, "sdcard/hbmenu.nro", "hbmenu.nro"},
    programs  = {dir = false, "sdcard/switch/ounceshell.nro", "programs/ounceshell.nro"},
    lib       = {dir = true,  "sdcard/kaihen/lib"},
}

function M.sd_release(sizes)
    for i, r in ipairs(M.SD_RELEASES) do
        if sizes.bootstrap == r.bootstrap and sizes.ro == r.ro and sizes.hen == r.hen and sizes.game == r.game then
            return r, i
        end
    end
    return nil, nil
end

-- Checks kaiHEN's files on the SD card. When an unpacked kaiHEN zip of a release above is on the
-- card (a kaihen* folder, /kaihen, /kaihen/bin or the root) and is newer than what /kaihen/bin
-- holds, or /kaihen/bin holds no release above, its files are moved into place first (as
-- d2e6fac does, but only from a complete known release, so a stale old zip never replaces a
-- working install). e = {fs, rt, P, slots, sdh, log}. Returns the release in place; errors if none.
function M.verify_sd(e)
    local fs, rt, sdh, log = e.fs, e.rt, e.sdh, e.log
    local function exists(p)
        local r = fs.ipc_get_entry_type(sdh, p, 0x301)
        return r.transport == 0 and r.result == 0, r.type
    end
    local function size_of(p)
        local fh = fs.ipc_open_file(sdh, p, 1, 0x301)
        if not fh or fh == 0 then return nil end
        local sz = fs.ipc_file_get_size(fh)
        rt.close_handle(fh)
        return sz
    end
    local function dir_of(p) return p:match("^(.*)/[^/]+$") end
    local function base_of(p) return p:match("([^/]+)$") end
    local function where(c) return c == "" and "the SD card's root" or c end
    local function installed()
        local s = {}
        for _, n in ipairs(M.SD_REQUIRED) do s[n] = size_of(M.SD_MANIFEST[n].path) end
        return s
    end
    -- part n in candidate c: the path to move and the file whose size counts, or nil
    local function source(c, n)
        local src = M.SD_SOURCES[n]
        for _, rel in ipairs(src) do
            local p = c .. "/" .. rel
            local ok, t = exists(p)
            if ok and (t == 0) == src.dir then
                if src.dir then return p, p .. "/" .. base_of(M.SD_MANIFEST[n].path) end
                return p, p
            end
        end
        return nil, nil
    end

    local have = installed()
    local _, have_i = M.sd_release(have)
    local cands = {""}
    local list = fs.ipc_list_directory(sdh, "/", 3)
    for _, ent in ipairs(list.entries or {}) do
        local low = ent.name:lower()
        if ent.type == 0 and low:sub(1, 6) == "kaihen" and low ~= "kaihen" then
            cands[#cands + 1] = "/" .. ent.name
        end
    end
    cands[#cands + 1] = "/kaihen"
    cands[#cands + 1] = "/kaihen/bin"
    local best, best_i, best_c
    for _, c in ipairs(cands) do
        if exists(c .. "/bootstrap.bin") then
            local s = {}
            for _, n in ipairs(M.SD_REQUIRED) do
                local _, f = source(c, n)
                s[n] = (f and size_of(f)) or have[n]
            end
            local r, i = M.sd_release(s)
            if r and (not best_i or i < best_i) then
                best, best_i, best_c = r, i, c
            elseif not r and c ~= "/kaihen/bin" then
                log("not using the kaiHEN files in " .. where(c) .. ": not a release this save supports")
            end
        end
    end

    if best and (not have_i or best_i < have_i) then
        log(str_format("moving kaiHEN %s from %s into /kaihen/bin", best.name, where(best_c)))
        fs.ipc_create_directory(sdh, "/kaihen")
        fs.ipc_create_directory(sdh, "/kaihen/bin")
        fs.ipc_create_directory(sdh, "/switch")
        for _, n in ipairs(M.SD_ORDER) do
            local from = source(best_c, n)
            local dst = M.SD_MANIFEST[n].path
            if from and M.SD_SOURCES[n].dir then
                local dd = dir_of(dst)
                if from ~= dd and from:sub(1, #dd + 1) ~= dd .. "/" and dd:sub(1, #from + 1) ~= from .. "/" then
                    fs.ipc_delete_directory_recursively(sdh, dd)
                    rt.wr_str(e.slots.path, from)
                    rt.wr_str(e.slots.info, dd)
                    fs.send_packet(sdh, e.P.packet(6, "", {
                        x = {{addr = e.slots.path, size = 0x301, index = 0},
                             {addr = e.slots.info, size = 0x301, index = 1}}
                    }), e.slots.pkt)
                end
            elseif from and from ~= dst then
                fs.ipc_delete_file(sdh, dst)
                fs.ipc_rename_file(sdh, from, dst, 0x301, 0x301)
            end
        end
        fs.ipc_commit(sdh)
    end

    local newest = M.SD_RELEASES[1]
    local missing = {}
    for _, n in ipairs(M.SD_REQUIRED) do
        if not exists(M.SD_MANIFEST[n].path) then missing[#missing + 1] = M.SD_MANIFEST[n].path end
    end
    if #missing > 0 then
        error("KH: required SD files missing: " .. tbl_concat(missing, ", ") .. ". Copy all of the kaiHEN "
            .. newest.name .. " zip (bootstrap.bin, ro and sdcard) to the SD card's root and try again")
    end
    local now = installed()
    local r = M.sd_release(now)
    if not r then
        local bad = {}
        for _, n in ipairs(M.SD_REQUIRED) do
            if now[n] ~= newest[n] then
                bad[#bad + 1] = str_format("%s is %s bytes, not %d", M.SD_MANIFEST[n].path, tostring(now[n]), newest[n])
            end
        end
        error("KH: the kaiHEN files on the SD card are from a kaiHEN build this save doesn't support ("
            .. tbl_concat(bad, "; ") .. "). Copy all of the kaiHEN " .. newest.name
            .. " zip (bootstrap.bin, ro and sdcard) to the SD card's root and try again."
            .. " Stopped before the RO swap")
    end
    log("SD files: kaiHEN " .. r.name .. " (sizes checked)")
    return r
end










function M.try_wait_adapter_bytes(try_wait_addr)
    return P.u32s(0x927df000)
        .. P.u32s(0x58000070)
        .. P.u32s(0xd61f0200)
        .. P.u32s(0xd503201f)
        .. P.u64s(try_wait_addr)
end


function M.build_nro_image(text_bytes, opts)
    opts = opts or {}
    local text_str = P.bytes_to_str(text_bytes)
    if #text_str > 0xFF80 then
        error("Native bootstrap exceeds text segment")
    end
    local img = str_rep("\0", 0x12000)
    if not opts.zero_prefix then
        img = P.put_u32(img, 0x00, 0x14000020)
        img = P.put_u32(img, 0x04, 0xF0)
        img = P.put_bytes(img, 0x08, "HOMEBREW")
    end
    img = P.put_bytes(img, 0x10, "NRO0")
    img = P.put_u32(img, 0x18, 0x12000)
    img = P.put_u32(img, 0x24, 0x10000)
    img = P.put_u32(img, 0x28, 0x10000)
    img = P.put_u32(img, 0x2C, 0x1000)
    img = P.put_u32(img, 0x30, 0x11000)
    img = P.put_u32(img, 0x34, 0x1000)
    img = P.put_u32(img, 0x38, 0x1000)
    img = P.put_bytes(img, 0x80, text_str)
    return img
end


function M.build_bootstrap_args(spec)
    local buf = str_rep("\0", 432)

    buf = P.put_u32(buf, 0, spec.candidateHandle or 0)

    buf = P.put_u64(buf, 8, spec.dataOffset or 0x4000)

    buf = P.put_u64(buf, 16, spec.pointerFieldOffset or ((spec.dataEntryOffset or 0x90) + 0x20))


    local row = spec.row or {}
    local row_vptr = spec.rowVptr or row.vptr or (row.raw and str_sub(P.unhex(row.raw), 1, 8)) or 0
    buf = P.put_u64(buf, 24, row.address or 0)
    buf = P.put_u64(buf, 32, row_vptr)
    buf = P.put_u64(buf, 40, row.domain or 0)
    buf = P.put_u64(buf, 48, row.metadata or 0)
    buf = P.put_u64(buf, 56, row.request or 0)
    local waiters = spec.waiters or {}
    for i = 1, 7 do
        buf = P.put_u64(buf, 64 + (i - 1) * 8, waiters[i] or 0)
    end


    local api_workers = spec.apiWorkers or {}
    for i = 1, 7 do
        local wh = type(api_workers[i]) == "table" and api_workers[i].handle or api_workers[i] or 0
        buf = P.put_u32(buf, 120 + (i - 1) * 4, wh)
    end


    local ev = spec.event or {}
    local handles6 = {
        row.receive or 0,
        row.wait or 0,
        ev.sourceHandle or 0,
        spec.exportedHandle or 0,
        ev.read or 0,
        ev.write or 0
    }
    for i = 1, 6 do
        buf = P.put_u32(buf, 148 + (i - 1) * 4, handles6[i])
    end


    local donor = spec.donor or {}
    local hen_title = spec.henTitle or M.HEN_TITLE_STR
    buf = P.put_u64(buf, 176, spec.table or 0)
    buf = P.put_u64(buf, 184, spec.loaderDomain or 0)
    buf = P.put_u64(buf, 192, spec.loaderEntryIndex or 0)
    buf = P.put_u64(buf, 200, donor.entry or 0)
    buf = P.put_u64(buf, 208, donor.object or 0)
    buf = P.put_u64(buf, 216, donor.metadata or 0)
    buf = P.put_u64(buf, 224, donor.vptr or 0)
    buf = P.put_u64(buf, 232, hen_title)


    local pm = spec.pm or {}
    buf = P.put_u32(buf, 240, pm.shell or 0)
    buf = P.put_u32(buf, 244, pm.monitor or 0)
    buf = P.put_u64(buf, 248, hen_title)
    buf = P.put_u32(buf, 256, spec.flags or 0x14)
    buf = P.put_u8(buf,  260, spec.storageId or 3)
    buf = P.put_u64(buf, 264, spec.pthreadCreate or 0)
    buf = P.put_u64(buf, 272, spec.pthreadTryWait or 0)
    buf = P.put_u64(buf, 280, spec.pthreadJoin or 0)
    buf = P.put_u32(buf, 288, pm.sm or 0)
    buf = P.put_u32(buf, 292, spec.roHandle or 0)
    buf = P.put_u32(buf, 296, spec.fsRoot or 0)


    local pkg_path = spec.packagePath or "@Sdcard:/kaihen/bin/hen/exefs.nsp"
    buf = P.put_bytes(buf, 300, str_sub(pkg_path, 1, 95))


    buf = P.put_u32(buf, 396, spec.fsProcessHandle or 0)
    buf = P.put_u32(buf, 400, spec.notifierHandle or 0)
    buf = P.put_u32(buf, 404, spec.loaderCopyHandle or 0)

    return buf
end




function M.run_kaihen(rt, fs, log_fn)
    local function kh_log(msg)
        if log_fn then log_fn("KH: " .. msg) end
    end

    local state = _G.fsKaihen
    assert(state and state.domainSession and state.candidateHandle and state.endpoint and state.domainLayout,
        "KH: _G.fsKaihen is missing; run Stage B promotion first")

    _G.__KH = _G.__KH or {stages = {}}
    if _G.__KH.stages.launch or _G.__KH.stages.complete then
        error("KH: this boot already ran a kaiHEN launch attempt — power-cycle first")
    end


    if type(_G.__KH_TRACKED) == "table" and #_G.__KH_TRACKED > 0 then
        for i = #_G.__KH_TRACKED, 1, -1 do
            pcall(rt.close_handle, _G.__KH_TRACKED[i].handle)
        end
        _G.__KH_TRACKED = nil
        _G.__KH.sd = nil
    end

    local arena_base = _G.__KH_ARENA or rt.alloc_page(0x180000, false)
    assert(arena_base ~= 0, "KH: arena alloc failed")
    _G.__KH_ARENA = arena_base
    local arena_next = 0x1000
    local function arena_alloc(bytes)
        local pages = math_ceil(bytes / 0x1000)
        local addr  = arena_base + arena_next
        arena_next  = arena_next + pages * 0x1000
        assert(arena_next <= 0x180000, "KH: arena exhausted")
        rt.memset(addr, 0, pages * 0x1000)
        return addr
    end

    local slots = {
        pkt  = arena_alloc(0x2000),
        pkt2 = arena_alloc(0x2000),
        path = arena_alloc(0x1000),
        data = arena_alloc(0x10000),
        info = arena_alloc(0x2000),
    }

    local ctx = {
        state           = state,
        fspSrv          = {handle = state.domainSession.handle, rootObj = state.domainSession.rootObj},
        candidateHandle = state.candidateHandle,
        handles         = {},
        slots           = slots,
        arenaAlloc      = arena_alloc,
    }

    local function track(h, label)
        h = P.u32_norm(h)
        assert(h > 0 and h < 0xFFFF8000, "KH: invalid handle from " .. tostring(label))
        ctx.handles[#ctx.handles + 1] = {handle = h, label = label}
        _G.__KH_TRACKED = _G.__KH_TRACKED or {}
        _G.__KH_TRACKED[#_G.__KH_TRACKED + 1] = {handle = h, label = label}
        return h
    end


    local function open_sd_card()
        if _G.__KH.sd and _G.__KH.sd ~= 0 then return _G.__KH.sd end
        if not ctx.fsRootPlain then
            local plain = fs.clone_object(ctx.fspSrv.handle, ctx.fspSrv.rootObj)
            assert(plain ~= 0, "KH: plain root clone failed")
            ctx.fsRootPlain = track(plain, "fs-root-plain")
        end
        local rep = fs.send_packet(ctx.fsRootPlain, P.packet(18, ""), slots.pkt)
        assert(rep.transport == 0 and rep.result == 0 and #rep.moves == 1, "KH: OpenSdCardFileSystem failed")
        local sdh = track(rep.moves[1], "sdcard")
        _G.__KH.sd = sdh
        return sdh
    end

    local function sd_read_file(sdh, path_str, max_len)
        local fh, oerr = fs.ipc_open_file(sdh, path_str, 1, 0x301)
        assert(fh ~= 0, "KH: open SD file " .. path_str .. " failed: " .. P.hex32(oerr))
        local fsize = fs.ipc_file_get_size(fh)
        if not fsize or fsize <= 0 or fsize > (max_len or 0x100000) then
            rt.close_handle(fh)
            error("KH: SD file size invalid for " .. path_str)
        end
        local parts = {}
        local at = 0
        while at < fsize do
            local take = math_min(0x10000, fsize - at)
            local rpkt = P.packet(0, P.u64s(0) .. P.u64s(at) .. P.u64s(take), {
                b = {{addr = slots.data, size = take, mode = 1}}
            })
            local rrep = fs.send_packet(fh, rpkt, slots.pkt)
            if rrep.transport ~= 0 or rrep.result ~= 0 then
                rt.close_handle(fh)
                error("KH: SD file read failed for " .. path_str)
            end
            parts[#parts + 1] = rt.rd(slots.data, take)
            at = at + take
        end
        rt.close_handle(fh)
        local full = tbl_concat(parts)
        return {str = full, size = fsize}
    end


    local function verify_and_relocate_sd()
        local sdh = open_sd_card()
        local skip_probe = fs.ipc_get_entry_type(sdh, "/kaihen/civswitchfs-skipcheck", 0x301)
        ctx.sdSkipCheck = (skip_probe.transport == 0 and skip_probe.result == 0)
        ctx.sdRelease = M.verify_sd({fs = fs, rt = rt, P = P, slots = slots, sdh = sdh, log = kh_log})
    end


    local ep_read_buf  = arena_alloc(0x4000)
    local ep_write_buf = arena_alloc(0x4000)
    local ep = {
        array           = state.endpoint.array,
        owner           = state.endpoint.owner,
        arrayLength     = state.endpoint.arrayLength or 0x5A0,
        dataOffset      = state.endpoint.dataOffset or 0x4000,
        dataEntryOffset = state.endpoint.dataEntryOffset or 0x90,
        pointer         = 0,
        armed           = false
    }

    local function ep_storage_read(off, len)
        local r = fs.ipc_storage_read(ctx.candidateHandle, off, len, ep_read_buf)
        assert(r.transport == 0 and r.error == 0, "KH: ep storage read failed")
        return rt.rd(ep_read_buf, len)
    end

    local function ep_storage_write(off, data_str)
        rt.wr(ep_write_buf, data_str)
        local r = fs.ipc_storage_write(ctx.candidateHandle, off, ep_write_buf, #data_str)
        assert(r.transport == 0 and r.error == 0, "KH: ep storage write failed")
    end

    local function set_pointer(addr)
        local entry_s = ep_storage_read(ep.dataEntryOffset, 0x30)
        assert(P.u64(entry_s, 0) == ep.dataOffset and P.u64(entry_s, 8) == 0x4000 and str_byte(entry_s, 0x11) == 1,
            "KH: retained data descriptor changed")
        if addr == ep.pointer then return end
        local t8 = P.u64s(addr)
        ep_storage_write(ep.dataEntryOffset + 0x20, t8)
        assert(ep_storage_read(ep.dataEntryOffset + 0x20, 8) == t8, "KH: retained pointer readback differs")
        ep.pointer = addr
    end

    local function read_fs(addr, len)
        local parts = {}
        local at = 0
        while at < len do
            local take = math_min(0x4000, len - at)
            set_pointer(addr + at)
            parts[#parts + 1] = ep_storage_read(ep.dataOffset, take)
            at = at + take
        end
        return tbl_concat(parts)
    end

    local function write_fs(addr, data_str)
        local at = 0
        while at < #data_str do
            local part = str_sub(data_str, at + 1, math_min(at + 0x4000, #data_str))
            set_pointer(addr + at)
            ep_storage_write(ep.dataOffset, part)
            assert(ep_storage_read(ep.dataOffset, #part) == part, "KH: write_fs readback differs")
            at = at + #part
        end
    end

    local function write_fs_unverified(addr, data_str)
        set_pointer(addr)
        ep_storage_write(ep.dataOffset, data_str)
    end

    local function compare_write_fs(addr, expected_str, replacement_str)
        local before = read_fs(addr, #expected_str)
        assert(before == expected_str, "KH: compare_write_fs precondition differs")
        write_fs(addr, replacement_str)
        local after = read_fs(addr, #replacement_str)
        assert(after == replacement_str, "KH: compare_write_fs readback differs")
    end

    local function arm_endpoint()
        local head  = ep_storage_read(0, 0x30)
        local entry = ep_storage_read(ep.dataEntryOffset, 0x30)
        assert(P.u64(head, 0) == 0 and P.u64(head, 8) == 0x4000, "KH: control bucket head invalid")
        assert(P.u64(entry, 0) == ep.dataOffset and P.u64(entry, 8) == 0x4000, "KH: data descriptor invalid")
        ep.pointer = P.u64(entry, 0x20)
        set_pointer(ep.owner)
        local ow = ep_storage_read(ep.dataOffset, 0x78)
        assert(P.u64(ow, 0x48) == ep.array and P.u32(ow, 0x58) == 0, "KH: retained owner layout changed")
        set_pointer(ep.array)
        ep.armed = true
        ctx.ep = ep
        kh_log(str_format("endpoint armed array=0x%x owner=0x%x", ep.array, ep.owner))
    end


    local function derive_layout_and_loader()
        local base = state.domainLayout
        local waiters = {}
        for i = 0, 6 do waiters[i + 1] = base.manager + 0x410 + i * 0x110 end
        local layout = {
            manager      = base.manager,
            table        = base.table,
            count        = 0x4000,
            rootVptr     = base.rootVptr,
            captureStart = base.captureStart,
            captureEnd   = base.captureEnd,
            sdk          = base.captureStart + 0x500000,
            holderVptr   = base.rootVptr - 0x7d78,
            slots        = base.manager + 0xd48,
            waiters      = waiters,
        }
        local mgr = read_fs(layout.manager, 0x20)
        assert(P.u32(mgr, 0x10) == 0x4000 and P.u64(mgr, 0x18) == layout.table, "KH: live domain manager changed")
        local ring_hdr = read_fs(layout.sdk + 0x830, 0x20)
        assert(P.u64(ring_hdr, 8) == (layout.sdk + 0x668), "KH: FS SDK thread-ring header mismatch")
        ctx.layout = layout


        local dv1         = layout.rootVptr + 0x28E0
        local dv2         = layout.rootVptr + 0x2938
        local rv          = layout.rootVptr + 0x1EA0
        local mgr_v       = layout.manager
        local meta_wanted = layout.rootVptr + 0x5880
        local cap_s       = layout.captureStart
        local cap_e       = layout.captureEnd
        local tbytes      = read_fs(layout.table, 0x4000)
        local accepted    = {}
        for off = 0, 0x4000 - 0x30, 0x30 do
            local owner = P.u64(tbytes, off + 0x18)
            local obj   = P.u64(tbytes, off + 0x20)
            local meta  = P.u64(tbytes, off + 0x28)
            if owner ~= 0 and obj ~= 0 and meta == meta_wanted and
               owner >= cap_s and (owner + 0x20) <= cap_e and ((owner - cap_s) % 8) == 0 then
                local db = read_fs(owner, 0x20)
                if P.u64(db, 0) == dv1 and P.u64(db, 8) == dv2 and P.u64(db, 24) == mgr_v then
                    local obj_ok = (obj < cap_s or obj >= cap_e)
                    if not obj_ok and (obj + 0x20) <= cap_e and ((obj - cap_s) % 8) == 0 then
                        obj_ok = (P.u64(read_fs(obj, 8), 0) == rv)
                    end
                    if obj_ok then
                        accepted[#accepted + 1] = {
                            index  = (off / 0x30) + 1,
                            entry  = layout.table + off,
                            owner  = owner,
                            domain = owner,
                            object = obj
                        }
                    end
                end
            end
        end
        assert(#accepted == 1, "KH: Loader root is not unique (" .. #accepted .. ")")
        ctx.loaderRoot = accepted[1]


        local sentinel = layout.sdk + 0x830
        local nodes, seen = {}, {}
        local cur = P.u64(read_fs(sentinel, 8), 0)
        while cur ~= sentinel do
            assert(cur ~= 0 and not seen[cur] and #nodes < 128, "KH: thread ring did not terminate")
            seen[cur] = true
            local tb = read_fs(cur, 0x1C0)
            nodes[#nodes + 1] = {
                address  = cur,
                next     = P.u64(tb, 0),
                state    = str_byte(tb, 0x41),
                size     = P.u64(tb, 0x58),
                argument = P.u64(tb, 0x60),
                entry    = P.u64(tb, 0x68),
                handle   = P.u32(tb, 0x1B0),
                id       = P.u64(tb, 0x1B8),
            }
            cur = P.u64(tb, 0)
        end
        ctx.threadRing = nodes
        kh_log(str_format("layout verified loaderEntry=0x%x threads=%d", ctx.loaderRoot.entry, #nodes))
    end


    local function locate_by_clone(source_handle, inspect_fn)
        local crep = fs.send_packet(source_handle, P.domain_control(2, ""), slots.pkt2)
        assert(crep.transport == 0 and crep.result == 0 and #crep.moves == 1, "KH: locator clone failed")
        local clone_h = crep.moves[1]
        local loc_res = nil
        local ok, err = pcall(function()
            local conv = fs.send_packet(clone_h, P.domain_control(0, ""), slots.pkt)
            assert(conv.transport == 0 and conv.result == 0, "KH: locator ConvertToDomain failed")
            local root_id = P.u32(conv.data, 0)
            local entry_addr = ctx.layout.table + (root_id - 1) * 0x30
            local eb = read_fs(entry_addr, 0x30)
            loc_res = {
                root   = root_id,
                entry  = entry_addr,
                owner  = P.u64(eb, 0x18),
                object = P.u64(eb, 0x20),
                clone  = clone_h
            }
            if inspect_fn then inspect_fn(loc_res) end
        end)
        rt.close_handle(clone_h)
        if not ok then error(err) end
        return loc_res
    end

    local function open_notifier()
        local rep = fs.send_packet(ctx.fsRootPlain, P.packet(510, ""), slots.pkt)
        assert(rep.transport == 0 and rep.result == 0 and #rep.moves == 1, "KH: cmd 510 notifier failed")
        local nh = track(rep.moves[1], "notifier")
        local proof = nil
        locate_by_clone(nh, function(loc)
            local b = read_fs(loc.object, 0x18)
            local B = P.u64(b, 8)
            local backend = read_fs(B, 0x48)
            local ev_h = P.u32(backend, 0x24)
            proof = {object = loc.object, B = B, handleField = B + 0x24, eventHandle = ev_h}
        end)
        local erep = fs.send_packet(nh, P.packet(0, ""), slots.pkt2)
        assert(erep.transport == 0 and erep.result == 0 and #erep.copies == 1, "KH: GetEventHandle failed")
        local read_ev = track(erep.copies[1], "notifier-event")
        ctx.notifier = {
            handle      = nh,
            object      = proof.object,
            B           = proof.B,
            handleField = proof.handleField,
            eventHandle = proof.eventHandle,
            readEvent   = read_ev
        }

        local ded = fs.open_fsp_session()
        assert(ded ~= 0, "KH: dedicated fsp-srv failed")
        ctx.fsRootDedicated = track(ded, "fsp-dedicated")
        kh_log(str_format("notifier ready event=0x%x", proof.eventHandle))
    end

    local function export_handle(fs_handle, label)
        local notif = ctx.notifier
        local before4 = read_fs(notif.handleField, 4)
        assert(P.u32(before4, 0) == notif.eventHandle, "KH: notifier handleField changed before export")
        local repl4 = P.u32s(fs_handle)
        local copied_h = 0
        compare_write_fs(notif.handleField, before4, repl4)
        local ok, err = pcall(function()
            local rep = fs.send_packet(notif.handle, P.packet(0, ""), slots.pkt2)
            assert(rep.transport == 0 and rep.result == 0 and #rep.copies == 1, "KH: export GetEventHandle failed")
            copied_h = track(rep.copies[1], "export-" .. label)
        end)
        compare_write_fs(notif.handleField, repl4, before4)
        if not ok then error(err) end
        return {handle = copied_h, sourceHandle = fs_handle, label = label}
    end


    local function open_pm_sessions()
        local sm_addr = ctx.layout.sdk + 4768
        local sm_b    = read_fs(sm_addr - 4, 16)
        local sm_h    = P.u32(sm_b, 4)
        local exported_sm = export_handle(sm_h, "fs-sm")

        local function tipc_lookup(svc_name)
            rt.memset(slots.pkt, 0, 0x80)
            rt.wr(slots.pkt, P.tipc_get_service_packet(svc_name))
            local trc = rt.send_ipc(exported_sm.handle, slots.pkt)
            assert(trc == 0, "KH: TIPC sm lookup transport failed for " .. svc_name)
            local raw20 = rt.rd(slots.pkt, 20)
            assert(P.u32(raw20, 16) == 0, "KH: TIPC sm lookup failed for " .. svc_name)
            return track(P.u32(raw20, 12), svc_name)
        end

        local shell_h   = tipc_lookup("pm:shell")
        local monitor_h = tipc_lookup("pm:dmnt")
        local qrep      = fs.send_packet(shell_h, P.packet(12, M.RO_TITLE_STR), slots.pkt2)
        assert(qrep.transport == 0 and qrep.result == 0, "KH: pm:shell query RO pid failed")
        local orig_pid  = P.u64(qrep.data, 0)
        ctx.pm = {sm = exported_sm.handle, shell = shell_h, monitor = monitor_h, originalPid = orig_pid}
        kh_log(str_format("pm ready shell=0x%x dmnt=0x%x roPid=%d", shell_h, monitor_h, orig_pid))
    end


    local function copy_loader_and_open_codefs()
        local idom = fs.open_domain_session()
        assert(idom, "KH: inspection domain open failed")
        track(idom.handle, "inspection-domain")
        ctx.inspectionDomain = {handle = idom.handle, root = idom.rootObj}

        local own_entry = ctx.layout.table + (idom.rootObj - 1) * 0x30
        local orig_entry = read_fs(own_entry, 0x30)
        local old_pair   = str_sub(orig_entry, 0x21, 0x30)
        local borrow_pair = read_fs(ctx.loaderRoot.entry + 0x20, 0x10)


        write_fs(own_entry + 0x20, borrow_pair)
        local copy_h = 0
        local ok_c, err_c = pcall(function()
            local rep = fs.send_packet(idom.handle, P.domain_control(1, P.u32s(idom.rootObj)), slots.pkt)
            assert(rep.transport == 0 and rep.result == 0 and #rep.moves == 1, "KH: Loader root copy failed")
            copy_h = track(rep.moves[1], "loader-root-copy")
        end)
        write_fs(own_entry + 0x20, old_pair)
        if not ok_c then error(err_c) end
        ctx.loaderCopy = {
            handle    = copy_h,
            ownDomain = P.u64(orig_entry, 0x18),
            ownObject = P.u64(orig_entry, 0x20),
            ownEntry  = own_entry,
            target    = ctx.loaderRoot
        }


        local is_info = arena_alloc(0x2000)
        write_fs(own_entry + 0x20, borrow_pair)
        local ok_is, err_is = pcall(function()
            local cpkt = P.build_context_packet({
                cmd    = 0,
                object = idom.rootObj,
                token  = 0x00200001,
                input  = P.u32s(0x0301) .. P.u32s(0) .. M.RO_TITLE_STR,
                b      = {{addr = is_info, size = 0x1A4, attr = 0}}
            })
            rt.memset(slots.pkt, 0, 0x200)
            rt.wr(slots.pkt, cpkt)
            local trc = rt.send_ipc(idom.handle, slots.pkt)
            if trc == 0 then
                local r64b = rt.rd(slots.pkt, 64)
                for w = 0, 14 do
                    if P.u32(r64b, w * 4) == P.SFCO_MAGIC then
                        local rc = P.u32(r64b, (w + 1) * 4)
                        local a  = P.u32(r64b, (w + 4) * 4)
                        if rc == 0 and a > 0 and a <= 0x4000 then
                            ctx.instantCodeFsAdded = a
                        end
                        break
                    end
                end
            end
        end)
        write_fs(own_entry + 0x20, old_pair)
        if not ok_is then error(err_is) end
        assert(ctx.instantCodeFsAdded, "KH: WithContext OpenCodeFileSystem did not add a CodeFS object")
        kh_log(str_format("loader copied=0x%x codefsAdded=0x%x", copy_h, ctx.instantCodeFsAdded))
    end

    return require("s2_kh_ro").run_ro_and_bootstrap(M, {
        rt                          = rt,
        fs                          = fs,
        ctx                         = ctx,
        slots                       = slots,
        ep                          = ep,
        kh_log                      = kh_log,
        arena_alloc                 = arena_alloc,
        track                       = track,
        open_sd_card                = open_sd_card,
        sd_read_file                = sd_read_file,
        read_fs                     = read_fs,
        write_fs_unverified         = write_fs_unverified,
        compare_write_fs            = compare_write_fs,
        export_handle               = export_handle,
        verify_and_relocate_sd      = verify_and_relocate_sd,
        arm_endpoint                = arm_endpoint,
        derive_layout_and_loader    = derive_layout_and_loader,
        open_notifier               = open_notifier,
        open_pm_sessions            = open_pm_sessions,
        copy_loader_and_open_codefs = copy_loader_and_open_codefs,
    })
end

return M
