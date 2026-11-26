-- b_s2_guard.lua (require "s2_guard") - guards for the cache-alias stage and a progress log that
-- survives a crash. Loaded by b_s2_main.lua; the wave modules use it through _G.__s2_guard and run
-- as before when it is missing.
--
-- Why (2026-11-25): with a Switch 1 game installed to the SD card as a normal title, every run
-- crashed the whole console right after "CAMPAIGN: qualified canary flip! Installing cache
-- alias...", 4-5 times in a row; with the game deleted the first run worked. The alias stage
-- opens Seedsow's RomFS storage (the candidate) so its cache array lands in the slot the race
-- overflows into, then overwrites one cache entry there. Nothing checked that the candidate
-- really landed in that slot, or that no other FS client was allocating at that moment.
--
--   quiet(...)          before the candidate is opened and before every cache-alias wave: FS's
--                       heap must not change for a short window (cmd 1009, the expanded heap's
--                       peak free size, the counter every wave already checks); it waits up to
--                       about 1.2 s for that, else the stage is not run (the attempt is retried).
--   candidate_ok(...)   the candidate must cost what it cost in this console's good runs
--                       (save:/s2_candidate.txt, written after a HIT; _G.S2_CANDIDATE_ALLOC
--                       overrides). It differs between consoles (7536 B, 7440 B), so with no
--                       record any cost goes, and after MISMATCH_LIMIT refusals in a run it goes.
--   progress(...)       one line appended to save:/s2_progress.log and committed, at points where
--                       the run holds nothing in FS (setup done, canary qualified, alias result,
--                       cleanup). A clean end deletes the file; a run that finds one shows it first
--                       ("PREVIOUS RUN STOPPED AT: ..."), so a crash leaves a trace.
--   step(...)           finer lines (candidate placed, bucket, alias step, guard stops, promote).
--                       Each is a save commit in the middle of the stage, so they are off unless
--                       _G.S2_PROGRESS_DETAIL = true.
local P = require("s2_prim")

local G = {}
local PATH = "/s2_progress.log"
local LEARNED = "/s2_candidate.txt"
local str_format = string.format

G.override = _G.S2_CANDIDATE_ALLOC
G.learned = G.override
G.MISMATCH_LIMIT = 3
G.mismatches = 0
G.QUIET_WINDOW_MS = 5
G.QUIET_PAUSE_MS = 40
G.QUIET_TRIES = 25
G.detail = (_G.S2_PROGRESS_DETAIL == true)
G.stats = {quietChecks = 0, quietWaits = 0, busy = 0}

-- ---- progress log in save: (through an FS session handle the caller owns)

local function append(handle, text, path)
    local rt, fs = G.rt, G.fs
    path = path or PATH
    local ex = fs.ipc_get_entry_type(handle, path)
    if ex.transport ~= 0 or ex.result ~= 0 then
        fs.ipc_create_file(handle, path, 0)
    end
    local fh = fs.ipc_open_file(handle, path, 7)
    if fh == 0 then return false end
    local offset = fs.ipc_file_get_size(fh) or 0
    local buf, raw = rt.alloc_page(#text + 0x1000, false)
    if buf ~= 0 then
        rt.wr(buf, text)
        -- IFile::Write (cmd 1): option 1 (flush), offset, size
        fs.send_packet(fh, P.packet(1, P.u32s(1) .. P.u32s(0) .. P.u64s(offset) .. P.u64s(#text), {
            a = {{addr = buf, size = #text, mode = 1}}
        }))
        rt.free_raw(raw)
    end
    rt.close_handle(fh)
    return fs.ipc_commit(handle) == 0
end

local function read_all(handle, path)
    local rt, fs = G.rt, G.fs
    local fh = fs.ipc_open_file(handle, path or PATH, 1)
    if fh == 0 then return nil end
    local size = fs.ipc_file_get_size(fh) or 0
    local text = ""
    if size > 0 then
        size = math.min(size, 0x8000)
        local buf, raw = rt.alloc_page(size + 0x1000, false)
        if buf ~= 0 then
            -- IFile::Read (cmd 0): option 0, offset 0, size
            local rep = fs.send_packet(fh, P.packet(0, P.u32s(0) .. P.u32s(0) .. P.u64s(0) .. P.u64s(size), {
                b = {{addr = buf, size = size, mode = 1}}
            }))
            if rep.transport == 0 and rep.result == 0 then text = rt.rd(buf, size) end
            rt.free_raw(raw)
        end
    end
    rt.close_handle(fh)
    return text
end

-- A short-lived clone of the game's save mount (for the start and the end of a run, when no
-- attempt holds one). Closed before the race starts, so it leaves nothing allocated in FS.
local function with_save(fn)
    local rt, fs = G.rt, G.fs
    local mount = rt.get_mount_handle("save")
    if not mount then return nil end
    local h = fs.clone_object(mount.handle, mount.objId)
    if not h or h == 0 then return nil end
    local ok, res = pcall(fn, h)
    rt.close_handle(h)
    return ok and res or nil
end

function G.attach(rt, fs)
    G.rt, G.fs = rt, fs
    G.mismatches, G.last_cost = 0, nil
    G.learned = G.override
    if G.learned then return end
    local ok, text = pcall(with_save, function(h)
        local ex = fs.ipc_get_entry_type(h, LEARNED)
        if ex.transport ~= 0 or ex.result ~= 0 then return false end
        return read_all(h, LEARNED) or false
    end)
    G.learned = ok and type(text) == "string" and tonumber(text:match("%d+")) or nil
end

-- At the start of a run: the previous run's progress lines when it did not end cleanly (nil if
-- it did), and the file removed.
function G.take_previous()
    if not G.fs then return nil end
    return with_save(function(h)
        local ex = G.fs.ipc_get_entry_type(h, PATH)
        if ex.transport ~= 0 or ex.result ~= 0 then return false end
        local text = read_all(h) or ""
        G.fs.ipc_delete_file(h, PATH)
        G.fs.ipc_commit(h)
        local lines = {}
        for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
        return lines
    end) or nil
end

-- At a clean end of a run (also after a failed run that stopped by itself).
function G.clear()
    G.handle = nil
    if not G.fs then return end
    with_save(function(h)
        G.fs.ipc_delete_file(h, PATH)
        G.fs.ipc_commit(h)
        return true
    end)
end

function G.bind(handle) G.handle = (handle and handle ~= 0) and handle or nil end
function G.unbind() G.handle = nil end

function G.progress(text)
    if not (G.handle and G.rt) then return end
    local stamp = math.floor(G.rt.now_ms() + 0.5)
    pcall(append, G.handle, str_format("%d %s\n", stamp, tostring(text)))
end

function G.step(text)
    if G.detail then G.progress(text) end
end

-- ---- quiet FS heap before a write the race aims at a fixed slot

local function peak_free(fs, setup, clear_first)
    local pkt = P.packet(1009, "")
    local rep
    for _ = 1, clear_first and 2 or 1 do
        rep = fs.send_packet(setup.handles.rootSession, pkt, setup.pktBuf)
        if rep.transport ~= 0 or rep.result ~= 0 then return nil end
    end
    local raw = G.rt.rd(setup.pktBuf + rep.data_offset, 48)
    return P.u64(raw, 5 * 8)
end

-- True when FS's expanded heap did not change (within the wave jitter) during a short window,
-- trying for up to QUIET_TRIES windows. The first read clears the peak, so a block allocated
-- and freed inside the window still shows.
function G.quiet(rt, fs, setup, config, log_fn, what)
    local jitter = config.HEAP_JITTER_BYTES or 192
    G.stats.quietChecks = G.stats.quietChecks + 1
    for try = 1, G.QUIET_TRIES do
        local before = peak_free(fs, setup, true)
        rt.wait_ms(G.QUIET_WINDOW_MS)
        local after = peak_free(fs, setup, false)
        if before and after and math.abs(before - after) <= jitter then
            if try > 1 then
                G.stats.quietWaits = G.stats.quietWaits + 1
                if log_fn then log_fn(str_format("GUARD: FS heap quiet before %s after %d tries", what, try)) end
            end
            return true
        end
        if not (before and after) then break end
        rt.wait_ms(G.QUIET_PAUSE_MS)
    end
    G.stats.busy = G.stats.busy + 1
    if log_fn then log_fn(str_format("GUARD: FS heap kept changing before %s; not writing", what)) end
    G.step("guard: FS busy before " .. what)
    return false
end

function G.candidate_ok(alloc_cost, log_fn)
    G.last_cost = alloc_cost
    if not G.learned or alloc_cost == G.learned then return true end
    G.mismatches = G.mismatches + 1
    if G.mismatches > G.MISMATCH_LIMIT then
        if log_fn then
            log_fn(str_format("GUARD: candidate cost %dB again (good runs had %dB); trying it", alloc_cost or -1, G.learned))
        end
        return true
    end
    if log_fn then
        log_fn(str_format("GUARD: candidate cost %dB, good runs had %dB; FS heap is not as the race needs, not writing",
            alloc_cost or -1, G.learned))
    end
    G.step(str_format("guard: candidate cost %dB", alloc_cost or -1))
    return false
end

function G.remember()
    local cost = G.last_cost
    if G.override or not (G.handle and G.fs and cost) or cost == G.learned then return end
    G.fs.ipc_delete_file(G.handle, LEARNED)
    if append(G.handle, tostring(cost) .. "\n", LEARNED) then G.learned = cost end
end

return G
