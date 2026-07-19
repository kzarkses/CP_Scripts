-- CP_Sampler — Kit
-- The sampler engine: a folder track ("CP Kit") with one child track per pad,
-- each hosting a hidden ReaSamplOmatic5000. RS5K is the audio engine — its
-- window is never shown; the CP_Sampler grid is the only interface.
--
-- Why track-per-pad (mpl RS5K manager / Ableton Drum Rack semantics):
-- every pad gets its own FX chain, sends, meter and mixer strip for free,
-- and the whole kit is saved inside the project like any other tracks.
--
-- Identification is P_EXT track state (saved in the project, undo-safe):
--   parent: P_EXT:CP_KIT = "1"     pads: P_EXT:CP_KIT_NOTE = "36".."99"
--
-- MIDI flow: parent receives all MIDI inputs (armed + monitoring), its FX
-- chain runs the generated choke JSFX, then per-pad MIDI-only sends fan out
-- to the children whose RS5K note range does the note filtering.
--
-- RS5K param indices (verified against mpl_RS5K_manager_functions.lua):
--   0 vol · 1 pan · 3/4 note range · 8 max voices · 9 attack · 10 release
--   11 obey note-offs · 12 loop · 13/14 sample start/end · 15 tune
--   17/18 min/max vel · 23 loop offset · 24 decay · 25 sustain
--
-- This module owns PROJECT state only (no UI): CP_Sampler renders it, and
-- CP_SampleEditor dofiles it too (slice-to-pads) — keep it dependency-free.

local Kit = {}

local r  -- reaper, injected

Kit.BASE = 36    -- pad 0 ↔ MIDI note 36 (GM kick, FL/Ableton convention)
Kit.MAX  = 64    -- 64 pads = 4 pages of 16
Kit.version = 0  -- bumped on every structural change (UI cache key)

-- Param ids (RS5K indices)
Kit.P = {
    VOL = 0, PAN = 1, NOTE_LO = 3, NOTE_HI = 4, MAXV = 8,
    ATTACK = 9, RELEASE = 10, OBEY = 11, LOOP = 12,
    SOFFS = 13, EOFFS = 14, TUNE = 15, MINVEL = 17, MAXVEL = 18,
    LOOPOFFS = 23, DECAY = 24, SUSTAIN = 25,
    PITCH_LO = 5, PITCH_HI = 6,   -- pitch@start/end (chromatic instrument)
}

-- RS5K pitch param scale: normalized 0.5 = 0 st, ±80 st across 0..1.
local function pitchNorm(st)
    local v = 0.5 + st / 160
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return v
end

local RS5K_ADD  = "ReaSamplOmatic5000 (Cockos)"
local CHOKE_ADD = "JS:CP_Scripts/cp_kit_choke.jsfx"
local CHOKE_VERSION = "CP Kit Choke v1"

Kit.parent = nil       -- folder MediaTrack (validated on access)
Kit.bus    = nil       -- "CP Kit MIDI" child track — the INPUT bus.
                       -- CRITICAL: MIDI fan-out sends must come from a
                       -- separate child track, NOT the folder parent: a
                       -- parent→child send + the child's audio returning
                       -- through the folder is a feedback loop and REAPER
                       -- silently mutes the send (mpl's "MIDI bus" design
                       -- exists for exactly this reason).
Kit.pads   = {}        -- [note] = { track, fx, path, name, note, fmt = {} }
Kit.mode   = "drum"    -- "drum" (4x4 pads) | "instrument" (chromatic)
Kit.instr  = nil       -- instrument track { track, fx, path, name, root, fmt }
local choke_fx = nil   -- index of the choke JSFX…
local choke_tr = nil   -- …and the track carrying it (bus; parent = legacy)
local last_change = -1 -- GetProjectStateChangeCount snapshot
local repaired = false -- one routing migration/repair pass per session

function Kit.init(reaper_api)
    r = reaper_api
end

local function valid(tr)
    return tr ~= nil and r.ValidatePtr2(0, tr, "MediaTrack*")
end

-- Nesting-safe undo blocks: public ops call each other (LoadSample →
-- EnsurePad → Ensure) and raw Undo_BeginBlock pairs would unbalance —
-- only the outermost pair touches REAPER, and its description wins.
local undo_depth = 0
local function ubegin()
    if undo_depth == 0 then r.Undo_BeginBlock() end
    undo_depth = undo_depth + 1
end
local function uend(desc)
    undo_depth = undo_depth - 1
    if undo_depth == 0 then
        r.Undo_EndBlock(desc, -1)
        last_change = r.GetProjectStateChangeCount(0)
    end
end

local function trackIdx(tr)  -- 0-based
    return math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1
end

local function getExt(tr, key)
    local ok, val = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, "", false)
    if ok and val ~= "" then return val end
    return nil
end

local function setExt(tr, key, val)
    r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, val or "", true)
end

-- FX identity check. CRITICAL: RS5K RENAMES its instance to the loaded
-- sample's filename — TrackFX_GetFXName returns that alias, so matching
-- it alone loses every loaded pad on the next scan. fx_ident/fx_name
-- named config parms return the immutable identity (REAPER 6.37+); the
-- alias check stays as a last resort for fresh instances.
local function fxMatches(tr, i, needle)
    local ok, s = r.TrackFX_GetNamedConfigParm(tr, i, "fx_ident")
    if ok and s and s:lower():find(needle, 1, true) then return true end
    ok, s = r.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
    if ok and s and s:lower():find(needle, 1, true) then return true end
    local _, name = r.TrackFX_GetFXName(tr, i, "")
    return name ~= nil and name:lower():find(needle, 1, true) ~= nil
end

local function findRS5K(tr)
    local n = r.TrackFX_GetCount(tr)
    for i = 0, n - 1 do
        if fxMatches(tr, i, "samplomatic") then return i end
    end
    return nil
end

local function findChoke(tr)
    local n = r.TrackFX_GetCount(tr)
    for i = 0, n - 1 do
        if fxMatches(tr, i, "cp_kit_choke") then return i end
    end
    return nil
end

-- Adding FX through the API pops the chain window / floats the FX
-- depending on user preferences — close both, the pad grid is the UI.
local function hideFX(tr, fx)
    r.TrackFX_Show(tr, fx, 2)   -- close floating window
    r.TrackFX_Show(tr, fx, 0)   -- close chain window
end

local function baseName(path)
    local name = path:match("([^/\\]+)$") or path
    return name:match("(.+)%.[^.]+$") or name
end

-- ---------------------------------------------------------------------------
-- Choke JSFX (generated once into the Effects folder)
-- ---------------------------------------------------------------------------
-- One instance on the parent: per-note choke group (0=off, 1..8). Members
-- are one-shots — their incoming note-offs are swallowed (RS5K obey
-- note-offs must be ON so the synthesized choke note-off can cut them,
-- but a released key must NOT gate the sample). A note-on in group g sends
-- note-off to every other group-g note. Param index = note - BASE.
local function chokeFilePath()
    return r.GetResourcePath() .. "/Effects/CP_Scripts/cp_kit_choke.jsfx"
end

local function ensureChokeFile()
    local path = chokeFilePath()
    local f = io.open(path, "r")
    if f then
        local head = f:read(256) or ""
        f:close()
        if head:find(CHOKE_VERSION, 1, true) then return true end
    end
    r.RecursiveCreateDirectory(r.GetResourcePath() .. "/Effects/CP_Scripts", 0)
    f = io.open(path, "w")
    if not f then return false end
    f:write("desc:", CHOKE_VERSION, " (do not edit - generated by CP_Sampler)\n")
    f:write("//tags: MIDI processing\n\n")
    for i = 1, Kit.MAX do
        -- leading '-' hides the slider in the generic FX UI; it stays a
        -- normal automatable param (index = slider order - 1)
        f:write(string.format("slider%d:0<0,8,1>-note %d\n", i, Kit.BASE + i - 1))
    end
    f:write([[
in_pin:none
out_pin:none

@block
while (midirecv(ofs, m1, m2, m3)) (
  st = m1 & 0xF0;
  idx = m2 - ]], Kit.BASE, [[;
  grp = (idx >= 0 && idx < ]], Kit.MAX, [[) ? slider(idx + 1) : 0;
  isoff = (st == 0x80 || (st == 0x90 && m3 == 0));
  isoff && grp > 0 ? (
    0; // swallowed: choke members are one-shots, only the group cuts them
  ) : (
    st == 0x90 && m3 > 0 && grp > 0 ? (
      i = 0;
      loop(]], Kit.MAX, [[,
        i != idx && slider(i + 1) == grp ?
          midisend(ofs, 0x80 | (m1 & 0x0F), ]], Kit.BASE, [[ + i, 0);
        i += 1;
      );
    );
    midisend(ofs, m1, m2, m3);
  );
);
]])
    f:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------
-- Direct + nested children of the kit folder (folder-depth walk).
local function folderWalk(parent, fn)
    local d = r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH")
    if d <= 0 then return end
    local run = d
    local i = trackIdx(parent) + 1
    local count = r.CountTracks(0)
    while run > 0 and i < count do
        local tr = r.GetTrack(0, i)
        if fn(tr) then return tr end
        run = run + r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
        i = i + 1
    end
end

-- One pad candidate. Detection is layered so a kit survives anything:
--   1. the P_EXT:CP_KIT_NOTE tag (our own pads)
--   2. inside the kit folder: any RS5K with a single-note range is
--      ADOPTED (mpl RS5K-manager kits, hand-built kits, lost tags) and
--      the tag is healed for next time.
-- FILE0 is the RS5K sample path; some builds answer to "FILE" instead.
local function scanPad(tr, pads, in_folder)
    local note = tonumber(getExt(tr, "CP_KIT_NOTE") or "")
    local fx = findRS5K(tr)
    if not note and in_folder and fx then
        local lo = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.NOTE_LO)
        local hi = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.NOTE_HI)
        local nlo = math.floor(lo * 127 + 0.5)
        local nhi = math.floor(hi * 127 + 0.5)
        if nlo == nhi then
            note = nlo
            setExt(tr, "CP_KIT_NOTE", tostring(note))  -- heal the tag
        end
    end
    if not note or note < Kit.BASE or note >= Kit.BASE + Kit.MAX
       or pads[note] then
        return
    end
    local path = nil
    if fx then
        local ok, fn = r.TrackFX_GetNamedConfigParm(tr, fx, "FILE0")
        if ok and fn ~= "" then
            path = fn
        else
            ok, fn = r.TrackFX_GetNamedConfigParm(tr, fx, "FILE")
            if ok and fn ~= "" then path = fn end
        end
    end
    local _, tname = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    pads[note] = {
        track = tr, fx = fx, path = path, note = note,
        name = (tname ~= "" and tname) or (path and baseName(path)) or "",
        fmt = {},
    }
end

-- Full rebuild of Kit.pads from the project. Event-driven only (allocations
-- fine here) — never called per frame unless the project actually changed.
local function scanInstrument(tr)
    local fx = findRS5K(tr)
    local path, root = nil, tonumber(getExt(tr, "CP_KIT_ROOT") or "") or 60
    if fx then
        local ok, fn = r.TrackFX_GetNamedConfigParm(tr, fx, "FILE0")
        if ok and fn ~= "" then path = fn end
    end
    local _, tname = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    Kit.instr = {
        track = tr, fx = fx, path = path, root = root,
        name = (tname ~= "" and tname) or (path and baseName(path)) or "Instrument",
        fmt = {},
    }
end

function Kit.Scan()
    Kit.parent, Kit.bus, Kit.instr, choke_fx = nil, nil, nil, nil
    local pads = {}
    local count = r.CountTracks(0)
    for i = 0, count - 1 do
        local tr = r.GetTrack(0, i)
        if getExt(tr, "CP_KIT") then
            Kit.parent = tr
            break
        end
    end
    if Kit.parent then
        Kit.mode = getExt(Kit.parent, "CP_KIT_MODE") or "drum"
        folderWalk(Kit.parent, function(tr)
            if getExt(tr, "CP_KIT_MIDI") then
                Kit.bus = tr
            elseif getExt(tr, "CP_KIT_INSTR") then
                scanInstrument(tr)
            else
                scanPad(tr, pads, true)
            end
        end)
        -- Safety nets: tagged tracks that escaped the folder (moved
        -- around, folder depths mangled by hand) are still adopted.
        if not Kit.bus then
            for i = 0, count - 1 do
                local tr = r.GetTrack(0, i)
                if getExt(tr, "CP_KIT_MIDI") then Kit.bus = tr break end
            end
        end
        if next(pads) == nil then
            for i = 0, count - 1 do
                local tr = r.GetTrack(0, i)
                if tr ~= Kit.parent and tr ~= Kit.bus then
                    scanPad(tr, pads, false)
                end
            end
        end
        if Kit.bus then
            choke_fx = findChoke(Kit.bus)
            choke_tr = choke_fx and Kit.bus or nil
        end
        if not choke_fx then
            choke_fx = findChoke(Kit.parent)   -- legacy pre-bus position
            choke_tr = choke_fx and Kit.parent or nil
        end
    end
    Kit.pads = pads
    Kit.version = Kit.version + 1
end

-- Loaded-pad count (status displays, diagnostics).
function Kit.Count()
    local pads, loaded = 0, 0
    for _, pad in pairs(Kit.pads) do
        pads = pads + 1
        if pad.fx then loaded = loaded + 1 end
    end
    return pads, loaded
end

-- Adopt an existing kit: mark this folder track as THE kit bus and rescan
-- (children with single-note RS5Ks get pad tags healed). Works on mpl
-- RS5K-manager kits and hand-built track-per-pad setups.
function Kit.Adopt(track)
    if not valid(track) then return false end
    ubegin()
    -- drop any previous kit tag (single kit per project)
    local count = r.CountTracks(0)
    for i = 0, count - 1 do
        local tr = r.GetTrack(0, i)
        if getExt(tr, "CP_KIT") then setExt(tr, "CP_KIT", "") end
    end
    setExt(track, "CP_KIT", "1")
    uend("Sampler: adopt kit bus")
    Kit.Scan()
    return true
end

-- Per-frame poll: rescan when the project changed (undo, manual edits,
-- other scripts). One native call on the fast path.
function Kit.Poll()
    local c = r.GetProjectStateChangeCount(0)
    if c == last_change then return false end
    last_change = c
    Kit.Scan()
    -- One-time routing migration/repair per session: kits built before
    -- the MIDI-bus architecture have choke+sends on the folder parent
    -- (feedback-muted) and possibly pads armed as a user workaround.
    if valid(Kit.parent) and not repaired then
        repaired = true
        Kit.Repair()
        Kit.Scan()
    end
    -- keep the inactive set (pads vs instrument) muted per the saved mode —
    -- newly scanned/created tracks are unmuted by default
    Kit.EnforceMode()
    return true
end

function Kit.Exists()
    return valid(Kit.parent)
end

function Kit.Pad(note)
    local pad = Kit.pads[note]
    if pad and valid(pad.track) then return pad end
    return nil
end

-- ---------------------------------------------------------------------------
-- Creation
-- ---------------------------------------------------------------------------
function Kit.Ensure()
    if valid(Kit.parent) then return Kit.parent end
    Kit.Scan()
    if valid(Kit.parent) then return Kit.parent end

    ubegin()
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Kit", true)
    setExt(tr, "CP_KIT", "1")
    Kit.parent = tr
    Kit.version = Kit.version + 1
    uend("Sampler: create kit")
    return tr
end

-- Insert a track as first child of the folder (depth dance shared by the
-- MIDI bus and the pads — never touches non-kit tracks).
local function insertChildTrack(parent)
    local pidx = trackIdx(parent)
    local has_children = r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH") > 0
        and (function()
            local any = false
            folderWalk(parent, function() any = true return true end)
            return any
        end)()
    r.InsertTrackAtIndex(pidx + 1, false)
    local tr = r.GetTrack(0, pidx + 1)
    if has_children then
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
    else
        r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", -1)
    end
    return tr
end

-- The MIDI input bus: armed + monitoring, listens to all MIDI inputs
-- (incl. the virtual keyboard = StuffMIDIMessage pad clicks), hosts the
-- choke JSFX, and fans MIDI out to the pads. Recording lands MIDI
-- performances as items HERE — their playback drives the kit too.
function Kit.EnsureBus()
    if valid(Kit.bus) then return Kit.bus end
    local parent = Kit.Ensure()
    local count = r.CountTracks(0)
    for i = 0, count - 1 do
        local tr = r.GetTrack(0, i)
        if getExt(tr, "CP_KIT_MIDI") then
            Kit.bus = tr
            return tr
        end
    end
    ubegin()
    local tr = insertChildTrack(parent)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Kit MIDI", true)
    setExt(tr, "CP_KIT_MIDI", "1")
    r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 4096 + (63 << 5))
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)   -- record MIDI input
    if ensureChokeFile() then
        local fi = r.TrackFX_AddByName(tr, CHOKE_ADD, false, -1000)
        if fi >= 0 then
            choke_fx = fi
            hideFX(tr, fi)
        end
    end
    Kit.bus = tr
    Kit.version = Kit.version + 1
    uend("Sampler: create MIDI bus")
    return tr
end

function Kit.EnsurePad(note)
    if note < Kit.BASE or note >= Kit.BASE + Kit.MAX then return nil end
    local pad = Kit.Pad(note)
    if pad then return pad end
    local parent = Kit.Ensure()

    ubegin()
    local bus = Kit.EnsureBus()
    local tr = insertChildTrack(parent)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "Pad " .. note, true)
    setExt(tr, "CP_KIT_NOTE", tostring(note))

    -- MIDI-only send bus → pad (the pad's audio flows through the folder;
    -- sourcing from the folder parent itself would be a feedback loop and
    -- REAPER would mute the send)
    local s = r.CreateTrackSend(bus, tr)
    if s >= 0 then
        r.SetTrackSendInfo_Value(bus, 0, s, "I_SRCCHAN", -1)
        r.SetTrackSendInfo_Value(bus, 0, s, "I_MIDIFLAGS", 0)
    end

    local fx = r.TrackFX_AddByName(tr, RS5K_ADD, false, -1000)
    if fx >= 0 then
        hideFX(tr, fx)
        -- Factory defaults captured once (0dB volume knob reset target etc.)
        if not Kit.DEFAULT_VOL then
            Kit.DEFAULT_VOL = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.VOL)
            Kit.DEFAULT_ATT = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.ATTACK)
            Kit.DEFAULT_REL = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.RELEASE)
            Kit.DEFAULT_DEC = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.DECAY)
            Kit.DEFAULT_SUS = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.SUSTAIN)
        end
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.NOTE_LO, note / 127)
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.NOTE_HI, note / 127)
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.OBEY, 0)  -- one-shot
        -- 4 voices: rapid hits overlap naturally instead of hard-stealing
        -- the single default voice (drum-roll feel)
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.MAXV, 4 / 64)
    else
        fx = nil
    end

    pad = { track = tr, fx = fx, path = nil, note = note,
            name = "Pad " .. note, fmt = {} }
    Kit.pads[note] = pad
    Kit.version = Kit.version + 1
    uend("Sampler: create pad " .. note)
    return pad
end

-- ---------------------------------------------------------------------------
-- Samples
-- ---------------------------------------------------------------------------
function Kit.LoadSample(note, path)
    if not path or path == "" then return false end
    ubegin()
    local pad = Kit.EnsurePad(note)
    if not pad then
        uend("Sampler: load sample")
        return false
    end
    if not pad.fx then
        local fx = r.TrackFX_AddByName(pad.track, RS5K_ADD, false, -1000)
        if fx < 0 then
            uend("Sampler: load sample")
            return false
        end
        hideFX(pad.track, fx)
        pad.fx = fx
        r.TrackFX_SetParamNormalized(pad.track, fx, Kit.P.NOTE_LO, note / 127)
        r.TrackFX_SetParamNormalized(pad.track, fx, Kit.P.NOTE_HI, note / 127)
        r.TrackFX_SetParamNormalized(pad.track, fx, Kit.P.OBEY, 0)
        r.TrackFX_SetParamNormalized(pad.track, fx, Kit.P.MAXV, 4 / 64)
    end
    r.TrackFX_SetNamedConfigParm(pad.track, pad.fx, "FILE0", path)
    r.TrackFX_SetNamedConfigParm(pad.track, pad.fx, "DONE", "")
    -- Fresh sample: full range (RS5K keeps the previous sample's offsets)
    r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.SOFFS, 0)
    r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.EOFFS, 1)
    pad.path = path
    pad.name = baseName(path)
    pad.fmt = {}
    r.GetSetMediaTrackInfo_String(pad.track, "P_NAME", pad.name, true)
    Kit.version = Kit.version + 1
    uend("Sampler: load " .. pad.name)
    return true
end

-- Remove the sample (RS5K instance) but keep the pad track and its FX chain.
function Kit.ClearPad(note)
    local pad = Kit.Pad(note)
    if not pad then return end
    ubegin()
    if pad.fx then r.TrackFX_Delete(pad.track, pad.fx) end
    pad.fx, pad.path = nil, nil
    pad.name = "Pad " .. note
    pad.fmt = {}
    r.GetSetMediaTrackInfo_String(pad.track, "P_NAME", pad.name, true)
    Kit.version = Kit.version + 1
    uend("Sampler: clear pad")
end

-- Delete the pad track entirely (folder closer handled).
function Kit.DeletePad(note)
    local pad = Kit.Pad(note)
    if not pad then return end
    ubegin()
    local parent = Kit.parent
    local was_closer = r.GetMediaTrackInfo_Value(pad.track, "I_FOLDERDEPTH") < 0
    if was_closer and valid(parent) then
        -- Hand the folder-closing depth to the previous track if it is
        -- still inside the folder; otherwise the parent stops being one.
        local idx = trackIdx(pad.track)
        local prev = idx > 0 and r.GetTrack(0, idx - 1) or nil
        if prev and prev ~= parent then
            r.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH",
                r.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH") - 1)
        elseif prev == parent then
            r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 0)
        end
    end
    r.DeleteTrack(pad.track)
    Kit.pads[note] = nil
    Kit.version = Kit.version + 1
    uend("Sampler: delete pad")
end

-- Swap two pad SLOTS (Drum Rack drag): tracks keep their FX chains and
-- samples, only the note assignment moves — plus the choke groups, which
-- belong to the slot.
function Kit.SwapPads(a, b)
    if a == b then return end
    local pa, pb = Kit.Pad(a), Kit.Pad(b)
    if not pa and not pb then return end
    ubegin()
    local ga, gb = Kit.Choke(a), Kit.Choke(b)
    local function assign(pad, note)
        if not pad then return end
        setExt(pad.track, "CP_KIT_NOTE", tostring(note))
        if pad.fx then
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.NOTE_LO, note / 127)
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.NOTE_HI, note / 127)
        end
        pad.note = note
        pad.fmt = {}
    end
    assign(pa, b)
    assign(pb, a)
    Kit.pads[a], Kit.pads[b] = pb, pa
    Kit.SetChoke(a, gb or 0)
    Kit.SetChoke(b, ga or 0)
    Kit.version = Kit.version + 1
    uend("Sampler: swap pads")
end

-- ---------------------------------------------------------------------------
-- Instrument (chromatic) mode: one sample spread across the whole keyboard,
-- pitched per semitone from a root note — Ableton Simpler-style.
-- ---------------------------------------------------------------------------
-- Root note → RS5K note range + pitch@start/end for exactly 1 semitone per
-- MIDI note. RS5K interpolates pitch linearly across the NOTE range, and the
-- pitch params clamp to ±80 st — so the note range must be tied to the root
-- (root ± 80) instead of a fixed 0-127, otherwise a clamped endpoint changes
-- the slope and detunes the whole keyboard (root included). Within [root-80,
-- root+80]: pitch_start = lo-root, pitch_end = hi-root ⇒ pitch(N) = N - root
-- exactly, root plays at original pitch. Notes past ±80 st don't sound
-- (±6.6 octaves of range — musically ample).
local function applyRoot(instr)
    if not instr or not instr.fx then return end
    local root = instr.root
    local lo = math.max(0, root - 80)
    local hi = math.min(127, root + 80)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.NOTE_LO, lo / 127)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.NOTE_HI, hi / 127)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.PITCH_LO,
                                 pitchNorm(lo - root))
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.PITCH_HI,
                                 pitchNorm(hi - root))
end

function Kit.EnsureInstrument()
    if Kit.instr and valid(Kit.instr.track) then return Kit.instr end
    local parent = Kit.Ensure()
    local count = r.CountTracks(0)
    for i = 0, count - 1 do
        local tr = r.GetTrack(0, i)
        if getExt(tr, "CP_KIT_INSTR") then
            scanInstrument(tr)
            return Kit.instr
        end
    end
    ubegin()
    local bus = Kit.EnsureBus()
    local tr = insertChildTrack(parent)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Instrument", true)
    setExt(tr, "CP_KIT_INSTR", "1")
    setExt(tr, "CP_KIT_ROOT", "60")
    local s = r.CreateTrackSend(bus, tr)
    if s >= 0 then
        r.SetTrackSendInfo_Value(bus, 0, s, "I_SRCCHAN", -1)
        r.SetTrackSendInfo_Value(bus, 0, s, "I_MIDIFLAGS", 0)
    end
    local fx = r.TrackFX_AddByName(tr, RS5K_ADD, false, -1000)
    if fx >= 0 then
        hideFX(tr, fx)
        if not Kit.DEFAULT_VOL then
            Kit.DEFAULT_VOL = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.VOL)
            Kit.DEFAULT_ATT = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.ATTACK)
            Kit.DEFAULT_REL = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.RELEASE)
            Kit.DEFAULT_DEC = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.DECAY)
            Kit.DEFAULT_SUS = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.SUSTAIN)
        end
        -- chromatic mapping: full note range, freely-configurable mode,
        -- more voices for held/overlapping chords
        r.TrackFX_SetNamedConfigParm(tr, fx, "MODE", 0)
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.NOTE_LO, 0)
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.NOTE_HI, 1)
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.OBEY, 1)   -- honour note length
        r.TrackFX_SetParamNormalized(tr, fx, Kit.P.MAXV, 16 / 64)
    else
        fx = nil
    end
    Kit.instr = { track = tr, fx = fx, path = nil, root = 60,
                  name = "Instrument", fmt = {} }
    applyRoot(Kit.instr)
    Kit.version = Kit.version + 1
    uend("Sampler: create instrument")
    return Kit.instr
end

function Kit.LoadInstrument(path, root)
    if not path or path == "" then return false end
    ubegin()
    local instr = Kit.EnsureInstrument()
    if not instr or not instr.fx then
        uend("Sampler: load instrument")
        return false
    end
    r.TrackFX_SetNamedConfigParm(instr.track, instr.fx, "FILE0", path)
    r.TrackFX_SetNamedConfigParm(instr.track, instr.fx, "DONE", "")
    r.TrackFX_SetNamedConfigParm(instr.track, instr.fx, "MODE", 0)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.NOTE_LO, 0)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.NOTE_HI, 1)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.SOFFS, 0)
    r.TrackFX_SetParamNormalized(instr.track, instr.fx, Kit.P.EOFFS, 1)
    instr.path = path
    instr.name = baseName(path)
    instr.fmt = {}
    if root then instr.root = root end
    setExt(instr.track, "CP_KIT_ROOT", tostring(instr.root))
    applyRoot(instr)
    r.GetSetMediaTrackInfo_String(instr.track, "P_NAME", instr.name, true)
    Kit.version = Kit.version + 1
    uend("Sampler: load instrument " .. instr.name)
    return true
end

function Kit.SetRoot(note)
    if not Kit.instr or not Kit.instr.fx then return end
    note = math.max(0, math.min(127, math.floor(note + 0.5)))
    Kit.instr.root = note
    setExt(Kit.instr.track, "CP_KIT_ROOT", tostring(note))
    applyRoot(Kit.instr)
    last_change = r.GetProjectStateChangeCount(0)
end

-- Isolate the active set: the MIDI bus fans out to BOTH the pads and the
-- instrument track (all note-range 0-127-ish), so without muting they'd
-- sound together. Mute the inactive set's tracks (reversible, undo-safe).
-- Idempotent: only writes B_MUTE when it actually differs, so EnforceMode
-- can run every scan without bumping the project change count (which would
-- retrigger Poll → rescan → mute → … in a loop).
local function setMute(tr, want)
    if not valid(tr) then return end
    if (r.GetMediaTrackInfo_Value(tr, "B_MUTE") >= 0.5) ~= want then
        r.SetMediaTrackInfo_Value(tr, "B_MUTE", want and 1 or 0)
    end
end
local function applyModeMutes()
    local instr_on = Kit.mode == "instrument"
    for _, pad in pairs(Kit.pads) do setMute(pad.track, instr_on) end
    if Kit.instr then setMute(Kit.instr.track, not instr_on) end
end

-- Switch the whole kit between drum and instrument (Simpler/Sampler split).
function Kit.SetMode(mode)
    if mode ~= "drum" and mode ~= "instrument" then return end
    local parent = Kit.Ensure()
    ubegin()
    setExt(parent, "CP_KIT_MODE", mode)
    Kit.mode = mode
    if mode == "instrument" then Kit.EnsureInstrument() end
    applyModeMutes()
    Kit.version = Kit.version + 1
    uend("Sampler: set mode " .. mode)
end

-- Re-assert the active-set mutes (called after Scan, since new pads/
-- instrument tracks are created unmuted and a fresh session must respect
-- the persisted mode).
function Kit.EnforceMode()
    if valid(Kit.parent) then applyModeMutes() end
end

function Kit.InstrParam(pid)
    if not Kit.instr or not Kit.instr.fx then return nil end
    return r.TrackFX_GetParamNormalized(Kit.instr.track, Kit.instr.fx, pid)
end

function Kit.SetInstrParam(pid, v)
    if not Kit.instr or not Kit.instr.fx then return end
    r.TrackFX_SetParamNormalized(Kit.instr.track, Kit.instr.fx, pid, v)
    Kit.instr.fmt[pid] = nil
    last_change = r.GetProjectStateChangeCount(0)
end

function Kit.InstrParamFmt(pid)
    local instr = Kit.instr
    if not instr or not instr.fx then return "" end
    local s = instr.fmt[pid]
    if s then return s end
    local ok, buf = r.TrackFX_GetFormattedParamValue(instr.track, instr.fx, pid, "")
    s = ok and buf or ""
    instr.fmt[pid] = s
    return s
end

function Kit.InstrPeak()
    local instr = Kit.instr
    if not instr or not instr.path or not valid(instr.track) then return 0 end
    local a = r.Track_GetPeakInfo(instr.track, 0)
    local b = r.Track_GetPeakInfo(instr.track, 1)
    if b > a then a = b end
    return a
end

function Kit.FloatInstrRS5K()
    if Kit.instr and Kit.instr.fx then
        r.TrackFX_Show(Kit.instr.track, Kit.instr.fx, 3)
    end
end

-- ---------------------------------------------------------------------------
-- Params
-- ---------------------------------------------------------------------------
function Kit.Param(note, pid)
    local pad = Kit.pads[note]
    if not pad or not pad.fx then return nil end
    return r.TrackFX_GetParamNormalized(pad.track, pad.fx, pid)
end

function Kit.SetParam(note, pid, v)
    local pad = Kit.pads[note]
    if not pad or not pad.fx then return end
    r.TrackFX_SetParamNormalized(pad.track, pad.fx, pid, v)
    pad.fmt[pid] = nil
    -- Swallow our own change: FX param writes bump the project state
    -- counter, and a knob drag must not trigger a full Scan per frame.
    last_change = r.GetProjectStateChangeCount(0)
end

-- Native formatted value ("−6.0dB", "12st"…), cached until the param moves
-- (the per-frame control strip must not allocate result strings).
function Kit.ParamFmt(note, pid)
    local pad = Kit.pads[note]
    if not pad or not pad.fx then return "" end
    local s = pad.fmt[pid]
    if s then return s end
    local ok, buf = r.TrackFX_GetFormattedParamValue(pad.track, pad.fx, pid, "")
    s = ok and buf or ""
    pad.fmt[pid] = s
    return s
end

function Kit.SetOffsets(note, soffs, eoffs)
    Kit.SetParam(note, Kit.P.SOFFS, soffs)
    Kit.SetParam(note, Kit.P.EOFFS, eoffs)
end

-- ---------------------------------------------------------------------------
-- Choke groups
-- ---------------------------------------------------------------------------
function Kit.Choke(note)
    if not choke_fx or not valid(choke_tr) then return 0 end
    local v = r.TrackFX_GetParamNormalized(choke_tr, choke_fx, note - Kit.BASE)
    return math.floor(v * 8 + 0.5)
end

function Kit.SetChoke(note, grp)
    if not valid(Kit.parent) then return end
    if not choke_fx or not valid(choke_tr) then
        if not ensureChokeFile() then return end
        local bus = Kit.EnsureBus()
        local fi = findChoke(bus) or r.TrackFX_AddByName(bus, CHOKE_ADD, false, -1000)
        if not fi or fi < 0 then return end
        choke_fx, choke_tr = fi, bus
        hideFX(bus, fi)
    end
    r.TrackFX_SetParamNormalized(choke_tr, choke_fx, note - Kit.BASE, grp / 8)
    last_change = r.GetProjectStateChangeCount(0)
    -- Choke members need obey-note-offs ON (the synthesized note-off is the
    -- cut) + a small release so the cut doesn't click. Non-members go back
    -- to pure one-shot.
    local pad = Kit.Pad(note)
    if pad and pad.fx then
        if grp > 0 then
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.OBEY, 1)
            local rel = r.TrackFX_GetParamNormalized(pad.track, pad.fx, Kit.P.RELEASE)
            if rel < 0.008 then
                r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.RELEASE, 0.008)
            end
        else
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.OBEY, 0)
        end
        pad.fmt[Kit.P.OBEY] = nil
        pad.fmt[Kit.P.RELEASE] = nil
    end
    last_change = r.GetProjectStateChangeCount(0)
end

-- ---------------------------------------------------------------------------
-- Live helpers
-- ---------------------------------------------------------------------------
-- Pad output level (for the grid glow). Linear peak, max of both channels.
function Kit.PadPeak(note)
    local pad = Kit.pads[note]
    if not pad or not pad.path then return 0 end
    if not valid(pad.track) then return 0 end
    local a = r.Track_GetPeakInfo(pad.track, 0)
    local b = r.Track_GetPeakInfo(pad.track, 1)
    if b > a then a = b end
    return a
end

-- Pad trigger through the real engine: virtual-keyboard MIDI queue →
-- armed MIDI bus → choke JSFX → sends → pad RS5Ks.
function Kit.StuffNote(note, on, vel)
    r.StuffMIDIMessage(0, on and 0x90 or 0x80, note, on and (vel or 100) or 0)
end

function Kit.Armed()
    if not valid(Kit.bus) then return false end
    return r.GetMediaTrackInfo_Value(Kit.bus, "I_RECARM") == 1
       and r.GetMediaTrackInfo_Value(Kit.bus, "I_RECMON") > 0
end

function Kit.SetArmed(on)
    if not valid(Kit.bus) then
        if not valid(Kit.parent) then return end
        Kit.EnsureBus()
    end
    r.SetMediaTrackInfo_Value(Kit.bus, "I_RECARM", on and 1 or 0)
    r.SetMediaTrackInfo_Value(Kit.bus, "I_RECMON", on and 1 or 0)
end

-- One-shot migration + self-heal: move a legacy choke off the folder
-- parent, drop the feedback-muted parent→pad sends, disarm parent and
-- pads (arming pads was the user workaround for the muted sends), and
-- guarantee exactly one MIDI send bus → every pad.
function Kit.Repair()
    if not valid(Kit.parent) then return end
    ubegin()
    local bus = Kit.EnsureBus()

    local pc = findChoke(Kit.parent)
    if pc then
        local bc = findChoke(bus)
        if bc then
            for i = 0, Kit.MAX - 1 do
                r.TrackFX_SetParamNormalized(bus, bc, i,
                    r.TrackFX_GetParamNormalized(Kit.parent, pc, i))
            end
        end
        r.TrackFX_Delete(Kit.parent, pc)
    end
    r.SetMediaTrackInfo_Value(Kit.parent, "I_RECARM", 0)

    for si = r.GetTrackNumSends(Kit.parent, 0) - 1, 0, -1 do
        local dest = r.GetTrackSendInfo_Value(Kit.parent, 0, si, "P_DESTTRACK")
        if dest and getExt(dest, "CP_KIT_NOTE") then
            r.RemoveTrackSend(Kit.parent, 0, si)
        end
    end

    local have = {}
    for si = 0, r.GetTrackNumSends(bus, 0) - 1 do
        local dest = r.GetTrackSendInfo_Value(bus, 0, si, "P_DESTTRACK")
        if dest then
            local _, guid = r.GetSetMediaTrackInfo_String(dest, "GUID", "", false)
            have[guid] = true
        end
    end
    for _, pad in pairs(Kit.pads) do
        if valid(pad.track) then
            r.SetMediaTrackInfo_Value(pad.track, "I_RECARM", 0)
            local _, guid = r.GetSetMediaTrackInfo_String(pad.track, "GUID", "", false)
            if not have[guid] then
                local s = r.CreateTrackSend(bus, pad.track)
                if s >= 0 then
                    r.SetTrackSendInfo_Value(bus, 0, s, "I_SRCCHAN", -1)
                    r.SetTrackSendInfo_Value(bus, 0, s, "I_MIDIFLAGS", 0)
                end
            end
        end
    end
    choke_fx = findChoke(bus)
    choke_tr = choke_fx and bus or nil
    uend("Sampler: repair kit routing")
end

function Kit.FloatRS5K(note)
    local pad = Kit.Pad(note)
    if pad and pad.fx then r.TrackFX_Show(pad.track, pad.fx, 3) end
end

-- Group several Kit ops into ONE undo point (slice-to-pads etc.) — the
-- undo-depth counter makes the nested per-op blocks free.
function Kit.Batch(desc, fn)
    ubegin()
    local ok, err = pcall(fn)
    uend(desc)
    return ok, err
end

-- First pad slot (note) without an instrument, or nil when the kit is full.
function Kit.FirstEmpty(from)
    for n = (from or Kit.BASE), Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.pads[n]
        if not (pad and pad.fx) then return n end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Kit presets (paths + params, saved as plain Lua files)
-- ---------------------------------------------------------------------------
local SAVE_PIDS = { 0, 1, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 23, 24, 25 }

function Kit.PresetDir()
    local dir = r.GetResourcePath() .. "/Scripts/CP_Scripts/CP_Config/Kits"
    r.RecursiveCreateDirectory(dir, 0)
    return dir
end

function Kit.SavePreset(filepath)
    local f = io.open(filepath, "w")
    if not f then return false end
    f:write("-- CP_Sampler kit preset\nreturn {\n  version = 1,\n  pads = {\n")
    for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.Pad(note)
        if pad and pad.path then
            f:write(string.format("    { note = %d, path = %q, name = %q, choke = %d,\n      p = { ",
                                  note, pad.path, pad.name, Kit.Choke(note)))
            for _, pid in ipairs(SAVE_PIDS) do
                local v = Kit.Param(note, pid)
                if v then f:write(string.format("[%d] = %.6f, ", pid, v)) end
            end
            f:write("} },\n")
        end
    end
    f:write("  },\n}\n")
    f:close()
    return true
end

function Kit.LoadPreset(filepath)
    local chunk = loadfile(filepath, "t", {})
    if not chunk then return false end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.pads) ~= "table" then
        return false
    end
    ubegin()
    -- Replace semantics: silence every current pad first (keep the tracks
    -- and their FX chains), then load the preset's samples.
    for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        if Kit.Pad(note) then
            Kit.SetChoke(note, 0)
            Kit.ClearPad(note)
        end
    end
    for _, p in ipairs(data.pads) do
        if type(p) == "table" and type(p.note) == "number"
           and type(p.path) == "string" then
            Kit.LoadSample(p.note, p.path)
            if type(p.p) == "table" then
                for pid, v in pairs(p.p) do
                    if type(pid) == "number" and type(v) == "number" then
                        Kit.SetParam(p.note, pid, v)
                    end
                end
            end
            if type(p.choke) == "number" and p.choke > 0 then
                Kit.SetChoke(p.note, p.choke)
            end
        end
    end
    Kit.version = Kit.version + 1
    uend("Sampler: load kit preset")
    return true
end

return Kit
