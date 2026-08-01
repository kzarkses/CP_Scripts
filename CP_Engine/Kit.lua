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
--   instrument: P_EXT:CP_KIT_INSTR = "1"   (its own track, beside the kits)
--
-- MIDI flow: the kit's MIDI bus receives all MIDI inputs (armed + monitoring),
-- its FX chain runs the generated choke JSFX, then per-pad MIDI-only sends fan
-- out to the children whose RS5K note range does the note filtering.
--
-- The chromatic INSTRUMENT is not part of that fan-out: it is a second
-- instrument on a track of its own, with its own input, its own output and no
-- tie to any kit. Both can sound at once (that is the point) — only the LIVE
-- listener is exclusive, because pad clicks are a broadcast on the virtual
-- keyboard queue and would otherwise reach both. Kit.mode says which one is on
-- screen, and the listener follows it.
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

-- « A quelle vitesse va ce fichier » — une seule reponse pour toute la suite
-- (feuille de route phase 3). Les lecteurs de tempo vivaient ici, et c'etait
-- l'exemplaire soigneux des trois : il avait les garde-fous, et il etait le
-- seul a ne jamais demander a REAPER. Il garde ses garde-fous et gagne
-- l'analyse. `reaper` et non le `r` injecte : cette ligne s'execute au
-- CHARGEMENT, l'injection n'a lieu qu'a Kit.init.
local SrcTempo = dofile(reaper.GetResourcePath()
                        .. "/Scripts/CP_Scripts/CP_Engine/SrcTempo.lua")

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

-- Bus → pad sends: take any source channel, deliver on channel 1. I_MIDIFLAGS
-- is (src & 31) | (dest << 5), dest 1..16. Not load-bearing — the kit already
-- sounds correctly on channels 1..8 when a looper lane is routed here, so the
-- pads are demonstrably channel-blind — but pinning the destination keeps new
-- sends deterministic now that previews carry a channel tag (Kit.UI_CHAN) and
-- live play does not. Existing sends are left alone for the same reason.
local MIDI_TO_CH1 = 1 << 5

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
Kit.kits   = {}        -- every CP_KIT parent in the project (Scan fills it)
Kit.active_guid = nil  -- which kit this module drives (nil = the first found)
local choke_fx = nil   -- index of the choke JSFX…
local choke_tr = nil   -- …and the track carrying it (bus; parent = legacy)
local last_change = -1 -- GetProjectStateChangeCount snapshot
local repaired = false -- one routing migration/repair pass per session

local Tracks  -- optional Engine/Tracks module (common P_EXT:CP mark + folder)

function Kit.init(reaper_api, tracks_module)
    r = reaper_api
    Tracks = tracks_module
    SrcTempo.init(r)
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
    local kits = Kit.kits
    for i = #kits, 1, -1 do kits[i] = nil end
    local count = r.CountTracks(0)
    -- every kit parent in the project; the ACTIVE one (by GUID) is the kit
    -- this module drives — the project's saved choice when no choice was
    -- made this session yet, the first found as last resort
    if not Kit.active_guid then
        local _, g = r.GetProjExtState(0, "CP_Sampler", "ACTIVE_KIT")
        if g and g ~= "" then Kit.active_guid = g end
    end
    for i = 0, count - 1 do
        local tr = r.GetTrack(0, i)
        if getExt(tr, "CP_KIT") then
            kits[#kits + 1] = tr
            if not Kit.parent then Kit.parent = tr end
            if Kit.active_guid and r.GetTrackGUID(tr) == Kit.active_guid then
                Kit.parent = tr
            end
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
        -- around, folder depths mangled by hand) are still adopted — but
        -- ONLY while the project has a single kit: a global search with
        -- several kits around would swallow another kit's bus or pads.
        if not Kit.bus and #kits == 1 then
            for i = 0, count - 1 do
                local tr = r.GetTrack(0, i)
                if getExt(tr, "CP_KIT_MIDI") then Kit.bus = tr break end
            end
        end
        if next(pads) == nil and #kits == 1 then
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
    -- The instrument stands on its own track, beside the kits rather than
    -- inside one, so it is found by tag ANYWHERE — the folder walk above only
    -- still catches it where an un-migrated project left it.
    if not Kit.instr then
        for i = 0, count - 1 do
            local tr = r.GetTrack(0, i)
            if getExt(tr, "CP_KIT_INSTR") then scanInstrument(tr) break end
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

-- The input bus (CP_KIT_MIDI child) of an arbitrary kit parent.
local function busOf(parent)
    local bus
    folderWalk(parent, function(tr)
        if not bus and getExt(tr, "CP_KIT_MIDI") then bus = tr end
    end)
    return bus
end

-- Pad clicks travel over the VKB queue, which reaches EVERY armed bus —
-- so exactly one kit may listen: the ACTIVE one. This runs continuously
-- (from Poll), not just at SetActive time, because project loads restore
-- saved arm states and selection helpers (CP_AutoArmVSTiTrack) re-arm
-- tracks behind our back. Inactive kits still PLAY through channel sends
-- (e.g. CP_Looper lanes; sends ignore arm) — they just stop listening to
-- live input. Only writes on an actual mismatch.
local function enforceSingleListener()
    if #Kit.kits < 2 then return end
    for _, ktr in ipairs(Kit.kits) do
        if ktr ~= Kit.parent and valid(ktr) then
            local bus = busOf(ktr)
            if bus and (r.GetMediaTrackInfo_Value(bus, "I_RECARM") == 1
                     or r.GetMediaTrackInfo_Value(bus, "I_RECMON") ~= 0) then
                r.SetMediaTrackInfo_Value(bus, "I_RECARM", 0)
                r.SetMediaTrackInfo_Value(bus, "I_RECMON", 0)
                last_change = r.GetProjectStateChangeCount(0)
            end
        end
    end
end

-- Choose which kit this module drives. Armed is the working default, so
-- switching kits re-asserts it — and builds the MIDI bus if this kit
-- never had one (a kit without a bus could not arm, which read as the
-- arm state "turning itself off" when coming back to it). The choice is
-- saved per project.
function Kit.SetActive(track)
    if not valid(track) then return false end
    Kit.active_guid = r.GetTrackGUID(track)
    r.SetProjExtState(0, "CP_Sampler", "ACTIVE_KIT", Kit.active_guid)
    Kit.Scan()
    if not valid(Kit.bus) then Kit.EnsureBus() end
    enforceSingleListener()
    Kit.arm_intent = true
    Kit.HoldArm()
    return true
end

-- A brand-new, empty kit next to the existing ones (multi-kit). Becomes
-- the active kit; the pads fill it from then on.
function Kit.NewKit(name)
    name = (name and name ~= "") and name or "CP Kit"
    ubegin()
    local tr
    if Tracks then
        tr = Tracks.NewChild("sampler", "kit", name)
    else
        local idx = r.CountTracks(0)
        r.InsertTrackAtIndex(idx, false)
        tr = r.GetTrack(0, idx)
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
    end
    setExt(tr, "CP_KIT", "1")
    uend("Sampler: new kit " .. name)
    Kit.SetActive(tr)
    return tr
end

-- Adopt an existing kit: mark this folder track as a kit parent, make it
-- the active one and rescan (children with single-note RS5Ks get pad tags
-- healed). Works on mpl RS5K-manager kits and hand-built track-per-pad
-- setups. Other kits keep their tag — multi-kit is the normal state now.
function Kit.Adopt(track)
    if not valid(track) then return false end
    ubegin()
    setExt(track, "CP_KIT", "1")
    uend("Sampler: adopt kit bus")
    Kit.SetActive(track)
    return true
end

-- Per-frame poll: rescan when the project changed (undo, manual edits,
-- other scripts). One native call on the fast path.
function Kit.Poll()
    local c = r.GetProjectStateChangeCount(0)
    if c == last_change then return false end
    last_change = c
    Kit.Scan()
    -- something changed the project: that is exactly when another script may
    -- have disarmed our input bus — or re-armed an inactive kit's — so
    -- re-assert both intents before anything else reads Kit.Armed() (the
    -- audition path branches on it).
    Kit.HoldArm()
    enforceSingleListener()
    -- One-time routing migration/repair per session: kits built before
    -- the MIDI-bus architecture have choke+sends on the folder parent
    -- (feedback-muted) and possibly pads armed as a user workaround.
    if not repaired then
        repaired = true
        if valid(Kit.parent) then Kit.Repair() end
        Kit.SplitInstrument()   -- one-time: the instrument leaves the kit
        Kit.Scan()
    end
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
    local tr
    if Tracks then
        -- Born inside the shared CP folder, with the common ownership mark.
        tr = Tracks.NewChild("sampler", "kit", "CP Kit")
    else
        local idx = r.CountTracks(0)
        r.InsertTrackAtIndex(idx, false)
        tr = r.GetTrack(0, idx)
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Kit", true)
    end
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
        -- The parent may itself be the LAST child of an outer folder (the
        -- shared CP folder): whatever levels it was closing move onto the
        -- new last child, on top of closing the kit itself.
        local pd = r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH")
        if pd > 0 then pd = 0 end
        r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", pd - 1)
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
        r.SetTrackSendInfo_Value(bus, 0, s, "I_MIDIFLAGS", MIDI_TO_CH1)
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
local autoSync   -- sync-by-default; body lives with the tempo-sync section
local clearSyncState

-- opts (all optional) — how this load relates to the pad's TEMPO IDENTITY,
-- which lives on the track (P_EXT) and therefore outlives the sample:
--   no_sync   derived material (a slice, a selection, a preset recall):
--             drop the previous sample's tempo identity, sync nothing.
--   keep_sync same musical material in a new file (a bake): touch nothing.
--   (default) new material: the old identity is void, re-derive from the
--             new file and beat-match it if it declares a tempo.
-- Getting this wrong is audible — inheriting the previous loop's BPM
-- repitches the new sample against a tempo it never had.
function Kit.LoadSample(note, path, opts)
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
    local newmat = (pad.path ~= path)
    pad.path = path
    pad.name = baseName(path)
    pad.fmt = {}
    r.GetSetMediaTrackInfo_String(pad.track, "P_NAME", pad.name, true)
    if newmat and not (opts and opts.keep_sync) then
        clearSyncState(note, pad)
        if not (opts and opts.no_sync) then autoSync(note) end
    end
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
    local pad_d = r.GetMediaTrackInfo_Value(pad.track, "I_FOLDERDEPTH")
    if pad_d < 0 and valid(parent) then
        -- Hand the WHOLE closing depth to the previous track if it is
        -- still inside the folder (the pad may close outer folders too —
        -- the shared CP folder — hence += pad_d, not -1); when the last
        -- pad goes, the parent stops being a folder and takes over the
        -- outer closures itself.
        local idx = trackIdx(pad.track)
        local prev = idx > 0 and r.GetTrack(0, idx - 1) or nil
        if prev and prev ~= parent then
            r.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH",
                r.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH") + pad_d)
        elseif prev == parent then
            r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", pad_d + 1)
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
-- Plain-unit param access. Cockos VST params (RS5K, ReaPitch) expose their
-- RAW values normalized 0..1 — the real units (ms, dB, semitones) only
-- exist through the format API. Reads parse the formatted display; writes
-- binary-search the normalized position whose formatted value lands on the
-- target (FormatParamValueNormalized is a pure query — only the final
-- position is written). Self-calibrating: no range or taper is assumed.
-- ---------------------------------------------------------------------------
local function parsePlain(s)
    if not s then return nil end
    -- "-inf dB" (a silent gain) carries no digits: it is a real value, not a
    -- parse failure — surfaces that map dB to pixels must see the floor.
    if s:find("inf", 1, true) then
        return s:find("-", 1, true) and -150 or 150
    end
    local num, unit = s:match("([%-%+]?%d+%.?%d*)%s*(%a*)")
    local v = tonumber(num)
    if not v then return nil end
    if unit == "s" or unit == "sec" then v = v * 1000 end  -- time stays in ms
    return v
end

local function plainAt(tr, fx, pid, norm)
    local ok, buf = r.TrackFX_FormatParamValueNormalized(tr, fx, pid, norm, "")
    return ok and parsePlain(buf) or nil
end

local function plainOf(tr, fx, pid)
    local ok, buf = r.TrackFX_GetFormattedParamValue(tr, fx, pid, "")
    return ok and parsePlain(buf) or nil
end

-- Normalized position whose DISPLAY reads v — the inverse of plainAt.
-- Pure query (FormatParamValueNormalized writes nothing), so it also
-- serves surfaces that need the conversion without moving the param:
-- typing "-6" into a knob has to become a position before anything is set.
local function plainNorm(tr, fx, pid, v)
    -- endpoints may format as "-inf": probe just inside if an edge fails
    local f0 = plainAt(tr, fx, pid, 0) or plainAt(tr, fx, pid, 0.001)
    local f1 = plainAt(tr, fx, pid, 1) or plainAt(tr, fx, pid, 0.999)
    if not (f0 and f1) or f0 == f1 then return nil end
    local asc = f1 > f0
    if v <= math.min(f0, f1) then return asc and 0 or 1 end
    if v >= math.max(f0, f1) then return asc and 1 or 0 end
    -- Write a PROBED position, never the final midpoint: the bisection
    -- converges onto the boundary where the DISPLAY flips buckets, and on a
    -- stepped or coarsely-formatted param that boundary sits half a quantum
    -- from the target, on whichever side float rounding lands. Keeping the
    -- best probe makes the write idempotent — read it back through the same
    -- format call and you get the value you asked for.
    local lo, hi = 0, 1
    local best, bestd
    for _ = 1, 24 do
        local mid = (lo + hi) * 0.5
        local fv = plainAt(tr, fx, pid, mid)
        if fv == nil then break end
        local d = math.abs(fv - v)
        if not bestd or d < bestd then best, bestd = mid, d end
        if d == 0 then break end          -- exact on the display: done
        if (fv < v) == asc then lo = mid else hi = mid end
    end
    return best or (lo + hi) * 0.5
end

local function plainSet(tr, fx, pid, v)
    local n = plainNorm(tr, fx, pid, v)
    if not n then return false end
    r.TrackFX_SetParamNormalized(tr, fx, pid, n)
    return true
end

-- ---------------------------------------------------------------------------
-- Tempo sync (refonte chantier 8): repitch a pad's loop to the project
-- tempo through the TUNE offset — rate follows pitch, the vinyl trade-off
-- the analysis accepted (true time-stretch is the bake's job). Source BPM
-- and the sync flag persist on the pad track (P_EXT), so they travel with
-- the project like everything else about a pad.
-- ---------------------------------------------------------------------------
-- Stored BPM wins; everything else is a guess and is ranked as one. The store
-- is written when a tempo is DECIDED (the user typing one, autoSync engaging
-- sync) and cleared by LoadSample when the material changes.
function Kit.PadSrcBpm(note)
    local pad = Kit.Pad(note)
    if not pad then return nil end
    local stored = tonumber(getExt(pad.track, "CP_KIT_BPM") or "")
    if stored and stored > 0 then return stored end
    return (SrcTempo.FromName(pad.path))
end

-- Aim one pad's TUNE at the project tempo. Display-unit write (plainSet):
-- the RS5K pitch slider's real range/taper never has to be assumed.
local function applySync(note, pad, project_bpm)
    if not (pad and pad.fx) then return false end
    local src = Kit.PadSrcBpm(note)
    if not (src and src > 0 and project_bpm and project_bpm > 0) then
        return false
    end
    local st = 12 * math.log(project_bpm / src, 2)
    if st > 80 then st = 80 elseif st < -80 then st = -80 end
    local cur = plainOf(pad.track, pad.fx, Kit.P.TUNE)
    if cur and math.abs(cur - st) <= 0.01 then return false end
    plainSet(pad.track, pad.fx, Kit.P.TUNE, st)
    pad.fmt[Kit.P.TUNE] = nil
    return true
end

function Kit.SetPadSrcBpm(note, bpm)
    local pad = Kit.Pad(note)
    if not pad then return end
    setExt(pad.track, "CP_KIT_BPM", bpm and tostring(bpm) or "")
end

function Kit.PadSynced(note)
    local pad = Kit.Pad(note)
    return pad ~= nil and getExt(pad.track, "CP_KIT_SYNC") == "1"
end

-- Turning sync ON parks the user's manual tune in P_EXT and beat-matches
-- IMMEDIATELY (enabling sync IS the request — not "at the next tempo
-- change"); OFF restores the parked tune — the sync must never eat a
-- tuning gesture.
function Kit.SetPadSynced(note, on)
    local pad = Kit.Pad(note)
    if not pad or not pad.fx then return end
    if on then
        local cur = r.TrackFX_GetParamNormalized(pad.track, pad.fx, Kit.P.TUNE)
        setExt(pad.track, "CP_KIT_TUNE0", string.format("%.6f", cur))
        setExt(pad.track, "CP_KIT_SYNC", "1")
        applySync(note, pad, r.Master_GetTempo())
    else
        setExt(pad.track, "CP_KIT_SYNC", "")
        local t0 = tonumber(getExt(pad.track, "CP_KIT_TUNE0") or "")
        r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.TUNE, t0 or 0.5)
        setExt(pad.track, "CP_KIT_TUNE0", "")
        pad.fmt[Kit.P.TUNE] = nil
    end
    last_change = r.GetProjectStateChangeCount(0)
end

-- New material on the pad: the stored source tempo described the PREVIOUS
-- sample and must not survive it (stored BPM wins over the filename, so a
-- leftover would beat-match the new loop against the old one's tempo).
-- Un-syncing also gives the parked manual tune back. (Assigned into the
-- forward-declared local the Samples section calls.)
clearSyncState = function(note, pad)
    if not pad then return end
    if Kit.PadSynced(note) then Kit.SetPadSynced(note, false) end
    setExt(pad.track, "CP_KIT_BPM", "")
end

-- Re-aim every synced pad at the given tempo. Cheap enough for the host
-- to call whenever Tempo reports a change (writes only on a real delta).
function Kit.ApplyTempoSync(project_bpm)
    if not project_bpm or project_bpm <= 0 then return end
    local wrote = false
    for note, pad in pairs(Kit.pads) do
        if pad.fx and getExt(pad.track, "CP_KIT_SYNC") == "1" then
            if applySync(note, pad, project_bpm) then wrote = true end
        end
    end
    if wrote then last_change = r.GetProjectStateChangeCount(0) end
end

-- Sync by default — but only for material that really is a loop at a known
-- tempo, because being wrong here silently repitches a sample the user
-- never asked to touch. Two tiers, deliberately unequal:
--   DECLARED (the filename says "128bpm") — trusted, any amount of
--   repitch, as long as the file is long enough to BE a loop at that
--   tempo ("808 Kick 120bpm.wav" is a one-shot, not a bar).
--   INFERRED (from the length alone) — trusted only when unambiguous AND
--   the correction stays small (±2 st): a big shift means the inference
--   picked the wrong bar count far more often than it means a 174 BPM
--   break landed in a 120 BPM project (which the filename would declare).
-- The resolved tempo is then STORED: from here on it is a decision, not a
-- guess, and LoadSample clears it whenever the material changes.
-- (Assigned into the forward-declared local the Samples section calls.)
autoSync = function(note)
    local pad = Kit.Pad(note)
    if not (pad and pad.fx and pad.path) then return end
    local ref = r.Master_GetTempo()
    if not ref or ref <= 0 then return end
    -- SrcTempo applies exactly the two tiers this pad always used — a named
    -- tempo only when the file is long enough to be a loop at it, an inferred
    -- one only when unambiguous AND within two semitones — plus REAPER's own
    -- analysis, which this window never asked for and which reads an embedded
    -- tempo when the file carries one. No answer means: do not touch it.
    local bpm = SrcTempo.Bpm(pad.path)
    if not bpm then return end
    setExt(pad.track, "CP_KIT_BPM", string.format("%.3f", bpm))
    if Kit.PadSynced(note) then
        applySync(note, pad, ref)   -- already synced: just re-aim
    else
        Kit.SetPadSynced(note, true)
    end
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

-- The instrument is an INSTRUMENT OF ITS OWN, not a page of the kit: its own
-- track, its own MIDI input, its own output. It used to be a child of the kit
-- folder fed by the kit's bus, which meant the two could only take turns —
-- looking at one MUTED the other, so a kit could not play while an instrument
-- was on screen, and neither could be mixed apart from the other.
function Kit.EnsureInstrument()
    if Kit.instr and valid(Kit.instr.track) then return Kit.instr end
    local count = r.CountTracks(0)
    for i = 0, count - 1 do
        local tr = r.GetTrack(0, i)
        if getExt(tr, "CP_KIT_INSTR") then
            scanInstrument(tr)
            return Kit.instr
        end
    end
    ubegin()
    local tr
    if Tracks then
        -- born beside the kits in the shared CP folder, not inside one
        tr = Tracks.NewChild("sampler", "instrument", "CP Instrument")
    else
        local idx = r.CountTracks(0)
        r.InsertTrackAtIndex(idx, false)
        tr = r.GetTrack(0, idx)
        r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Instrument", true)
    end
    setExt(tr, "CP_KIT_INSTR", "1")
    setExt(tr, "CP_KIT_ROOT", "60")
    -- listens for itself (the kit bus fans out to the PADS and stops there)
    r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", Kit.INPUT_ALL)
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", 0)
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

-- Switch what the SAMPLER SHOWS. Nothing is muted, nothing changes hands:
-- the pads and the instrument are two instruments on two tracks and both keep
-- playing whatever is sent to them. Only the LIVE LISTENER follows the view
-- (see armTarget) — the keyboard has to reach one of them, not both.
function Kit.SetMode(mode)
    if mode ~= "drum" and mode ~= "instrument" then return end
    local parent = Kit.Ensure()
    ubegin()
    setExt(parent, "CP_KIT_MODE", mode)
    Kit.mode = mode
    if mode == "instrument" then Kit.EnsureInstrument() end
    Kit.version = Kit.version + 1
    uend("Sampler: set mode " .. mode)
    Kit.HoldArm()          -- the listener moves with the view
end

-- One-time separation, for projects built while the instrument was a page of
-- the kit: cut the bus → instrument MIDI send, give it its own input, move it
-- out of the kit folder and lift the mode mutes. Everything here is a no-op
-- once done, and the whole pass runs once per session (Kit.Poll).
local function guidOf(tr)
    local _, g = r.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    return g
end

-- The kit folder this track sits in, or nil when it stands on its own.
local function kitFolderOf(track)
    local want = guidOf(track)
    for _, ktr in ipairs(Kit.kits) do
        if valid(ktr) then
            local found = folderWalk(ktr, function(tr)
                return guidOf(tr) == want
            end)
            if found then return ktr end
        end
    end
end

function Kit.SplitInstrument()
    local instr = Kit.instr
    if not instr or not valid(instr.track) then return false end
    local tr = instr.track
    local guid = guidOf(tr)

    -- What is still to do — READS ONLY, so an already-separated project pays
    -- a handful of queries once per session and opens no undo block at all.
    local feeds = {}                      -- [bus] = true, buses sending to it
    for _, ktr in ipairs(Kit.kits) do
        local bus = valid(ktr) and busOf(ktr) or nil
        if bus then
            for si = 0, r.GetTrackNumSends(bus, 0) - 1 do
                local dest = r.GetTrackSendInfo_Value(bus, 0, si, "P_DESTTRACK")
                if dest and valid(dest) and guidOf(dest) == guid then
                    feeds[bus] = true
                end
            end
        end
    end
    local wants_input = r.GetMediaTrackInfo_Value(tr, "I_RECINPUT") ~= Kit.INPUT_ALL
    local owner = kitFolderOf(tr)
    local unmute = {}
    if Kit.mode == "instrument" then
        for _, pad in pairs(Kit.pads) do
            if valid(pad.track)
               and r.GetMediaTrackInfo_Value(pad.track, "B_MUTE") >= 0.5 then
                unmute[#unmute + 1] = pad.track
            end
        end
    elseif r.GetMediaTrackInfo_Value(tr, "B_MUTE") >= 0.5 then
        unmute[1] = tr
    end
    if not (next(feeds) or wants_input or owner or #unmute > 0) then
        return false
    end

    ubegin()

    -- 1. no kit bus feeds it any more
    for bus in pairs(feeds) do
        for si = r.GetTrackNumSends(bus, 0) - 1, 0, -1 do
            local dest = r.GetTrackSendInfo_Value(bus, 0, si, "P_DESTTRACK")
            if dest and valid(dest) and guidOf(dest) == guid then
                r.RemoveTrackSend(bus, 0, si)
            end
        end
    end

    -- 2. its own MIDI input (arming is a choice, and the view owns it)
    if wants_input then
        r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", Kit.INPUT_ALL)
        r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
    end

    -- 3. out of the kit folder, to just before it — a sibling, at the same
    -- level, so its audio stops flowing through the kit's fader. The closing
    -- depth it may have been carrying goes back to the child above it, which
    -- becomes the folder's last one; both cases (only child, middle child)
    -- fall out of that single line.
    if owner then
        local idx = trackIdx(tr)
        local depth = r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
        if depth < 0 and idx > 0 then
            local prev = r.GetTrack(0, idx - 1)
            r.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH",
                r.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH") + depth)
        end
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
        -- the selection is the user's; it travels by POINTER because the
        -- indices are exactly what the move is about to change
        local sel, n = {}, 0
        for i = 0, r.CountTracks(0) - 1 do
            local t = r.GetTrack(0, i)
            if r.IsTrackSelected(t) then n = n + 1 sel[n] = t end
            r.SetTrackSelected(t, false)
        end
        r.SetTrackSelected(tr, true)
        pcall(r.ReorderSelectedTracks, trackIdx(owner), 0)
        r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
        r.SetTrackSelected(tr, false)
        for i = 1, n do
            if valid(sel[i]) then r.SetTrackSelected(sel[i], true) end
        end
    end

    -- 4. the mode mutes go. They were how the two took turns; there are no
    -- turns any more, so what the saved mode had silenced comes back — and
    -- ONLY that: a pad the user muted by hand in drum mode is his own.
    for i = 1, #unmute do
        r.SetMediaTrackInfo_Value(unmute[i], "B_MUTE", 0)
    end

    uend("Sampler: separate instrument from kit")
    Kit.version = Kit.version + 1
    return true
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

-- Real-unit access for the instrument, mirroring the pad side (same
-- reason: RS5K's raw values are normalized whatever the display says).
function Kit.InstrParamPlain(pid)
    local instr = Kit.instr
    if not instr or not instr.fx then return nil end
    return parsePlain(Kit.InstrParamFmt(pid))
end

function Kit.InstrNormForPlain(pid, v)
    local instr = Kit.instr
    if not instr or not instr.fx then return nil end
    return plainNorm(instr.track, instr.fx, pid, v)
end

-- Voices — the instrument's answer to a pad's choke group. At 1 the RS5K is
-- monophonic: every note cuts the one before it, which IS a choke, and the
-- only form of it a single chromatic instrument can have. RS5K's max-voices
-- param runs 0..64 over the normalized range.
Kit.MAX_VOICES = 16

function Kit.InstrVoices()
    local v = Kit.InstrParam(Kit.P.MAXV)
    if not v then return Kit.MAX_VOICES end
    local n = math.floor(v * 64 + 0.5)
    if n < 1 then n = 1 elseif n > Kit.MAX_VOICES then n = Kit.MAX_VOICES end
    return n
end

function Kit.SetInstrVoices(n)
    if n < 1 then n = 1 elseif n > Kit.MAX_VOICES then n = Kit.MAX_VOICES end
    Kit.SetInstrParam(Kit.P.MAXV, n / 64)
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

-- OBEY (note-offs) is owned by TWO features and they must not stomp each
-- other: choke needs the synthesized note-off as its cut, loop needs it as
-- its gate. One resolver: obey is ON while the pad chokes OR loops, pure
-- one-shot otherwise. The small release floor keeps the cut from clicking.
local function refreshObey(note, pad)
    if not (pad and pad.fx) then return end
    local looped = (r.TrackFX_GetParamNormalized(pad.track, pad.fx, Kit.P.LOOP) or 0) >= 0.5
    if looped or Kit.Choke(note) > 0 then
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
    refreshObey(note, Kit.Pad(note))
    last_change = r.GetProjectStateChangeCount(0)
end

-- Loop needs obey-note-offs ON: with note-offs ignored a looped voice never
-- ends — the ADSR fires once at note-on, every later iteration plays as raw
-- sustain and the release never comes (the "first hit has the envelope, the
-- loop doesn't" bug). A looped pad therefore GATES: hold it and the loop
-- runs under the sustain stage, let go and the release fades it out.
function Kit.SetLoop(note, on)
    local pad = Kit.Pad(note)
    if not (pad and pad.fx) then return end
    r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.LOOP, on and 1 or 0)
    refreshObey(note, pad)
    pad.fmt[Kit.P.LOOP] = nil
    last_change = r.GetProjectStateChangeCount(0)
end

-- ---------------------------------------------------------------------------
-- Pitch that KEEPS the length (ReaPitch, élastique) — the complement of
-- TUNE, which is RS5K resample (pitch and duration coupled, the vinyl
-- move). The FX is inserted on the pad's track after RS5K on first use;
-- the semitone-shift param is found BY NAME and cached on the pad (param
-- indices have moved across REAPER versions, names haven't).
-- ---------------------------------------------------------------------------
local RP_ADD = "ReaPitch (Cockos)"

local function padReaPitch(pad, create)
    if not (pad and valid(pad.track)) then return nil end
    if pad.rp_fx and pad.rp_param then
        local a, b = r.TrackFX_GetFXName(pad.track, pad.rp_fx, "")
        local nm = type(a) == "string" and a or b
        if nm and nm:find("ReaPitch", 1, true) then
            return pad.rp_fx, pad.rp_param
        end
        pad.rp_fx, pad.rp_param = nil, nil   -- chain changed under us
    end
    local fx = -1
    for i = 0, r.TrackFX_GetCount(pad.track) - 1 do
        local a, b = r.TrackFX_GetFXName(pad.track, i, "")
        local nm = type(a) == "string" and a or b
        if nm and nm:find("ReaPitch", 1, true) then fx = i break end
    end
    if fx < 0 then
        if not create then return nil end
        fx = r.TrackFX_AddByName(pad.track, RP_ADD, false, -1)
        if fx < 0 then return nil end
        hideFX(pad.track, fx)
    end
    -- Bind the CONTINUOUS "Shift (full range)" slider, not the stepped
    -- integer "Shift (semitones)" one: a stepped param snaps every small
    -- knob drag back to the last whole value, which reads as a dead —
    -- then jumpy — knob. Semitones kept as a fallback for old ReaPitch
    -- builds that may name things differently.
    local full, semi
    for i = 0, r.TrackFX_GetNumParams(pad.track, fx) - 1 do
        local _, pn = r.TrackFX_GetParamName(pad.track, fx, i, "")
        local low = pn and pn:lower() or ""
        if not low:find("formant", 1, true) then
            -- no break: BOTH are needed (semitones comes after full range)
            if not full and low:find("full range", 1, true) then full = i end
            if not semi and low:find("semitone", 1, true) then semi = i end
        end
    end
    local best = full or semi
    if best then
        -- One-shot migration: an earlier build drove the stepped slider —
        -- fold any leftover shift into the continuous param so the audible
        -- pitch and the knob agree again. DISPLAY units throughout: the raw
        -- values are normalized, where 0.5 (not 0) means "no shift".
        if full and semi and semi ~= full then
            local sv = plainOf(pad.track, fx, semi)
            if sv and math.abs(sv) > 0.005 then
                local cur = plainOf(pad.track, fx, full) or 0
                plainSet(pad.track, fx, full, cur + sv)
                plainSet(pad.track, fx, semi, 0)
            end
        end
        pad.rp_fx, pad.rp_param = fx, best
        return fx, best
    end
    return nil
end

-- Plain-value access to a pad's RS5K params (ms / dB — what the sliders
-- show), for surfaces that think in real units: the ADSR overlay on the
-- waveform maps pixels to milliseconds, not to normalized positions.
-- NEVER TrackFX_GetParam here: Cockos VST raw values are normalized 0..1
-- whatever the display says — real units go through the format API.
function Kit.ParamPlain(note, pid)
    local pad = Kit.Pad(note)
    if not (pad and pad.fx) then return nil end
    -- The parse is cached against the formatted string it came from (which
    -- ParamFmt already caches and invalidates): the per-frame ADSR overlay
    -- reads four of these every frame and must not allocate.
    local s = Kit.ParamFmt(note, pid)
    local pv, ps = pad.pv, pad.ps
    if not pv then pv, ps = {}, {}; pad.pv, pad.ps = pv, ps end
    if ps[pid] ~= s then
        ps[pid] = s
        pv[pid] = parsePlain(s)
    end
    return pv[pid]
end

function Kit.SetParamPlain(note, pid, v)
    local pad = Kit.Pad(note)
    if not (pad and pad.fx) then return end
    plainSet(pad.track, pad.fx, pid, v)   -- clamps into the real range
    pad.fmt[pid] = nil
    last_change = r.GetProjectStateChangeCount(0)
end

-- Where a real-world value SITS on the 0..1 axis, without moving anything.
-- What a knob needs when the user types "-6": the widget speaks positions,
-- the user speaks dB.
function Kit.NormForPlain(note, pid, v)
    local pad = Kit.Pad(note)
    if not (pad and pad.fx) then return nil end
    return plainNorm(pad.track, pad.fx, pid, v)
end

-- Current shift in semitones (0 while no ReaPitch exists — nothing is
-- created by reading).
function Kit.PadPitch(note)
    local pad = Kit.Pad(note)
    if not pad then return 0 end
    local fx, pi = padReaPitch(pad, false)
    if not fx then return 0 end
    return plainOf(pad.track, fx, pi) or 0
end

function Kit.SetPadPitch(note, st)
    local pad = Kit.Pad(note)
    if not pad then return end
    local fx, pi = padReaPitch(pad, true)
    if not fx then return end
    plainSet(pad.track, fx, pi, st)   -- clamps into the param's real bounds
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

-- Every note the suite plays for PREVIEW — a sampler pad, an editor audition,
-- a dragged note in a piano roll — goes out on this channel, and nothing else
-- does. StuffMIDIMessage is a BROADCAST: it reaches every armed, input-
-- monitored track at once, and the suite deliberately arms two (this bus, so
-- pads sound; the looper router, so you can record what you play). Nothing in
-- the message said which of them was meant, so one pad click sounded the kit
-- AND whatever instrument the looper's armed lane routed to. The channel is
-- that missing word: the looper engine ignores it — neither monitored nor
-- captured — so a preview reaches the kit and stops there.
--
-- Chosen as the last channel because the engine spends 1..MAX_LANES on its
-- lanes; keep the two in sync if MAX_LANES ever reaches 16.
Kit.UI_CHAN = 15                        -- MIDI channel 16, 0-based in the status byte

-- I_RECINPUT values for the bus. ALL is the normal state; UI_ONLY (channel 16
-- of the virtual keyboard) is what the looper narrows it to while it monitors
-- an armed lane itself — see Loop.lua. Without that, playing a keyboard while
-- a column routed HERE is armed hit the kit twice: once direct, once through
-- the router.
Kit.INPUT_ALL     = 4096 + (63 << 5)            -- MIDI, any channel, any input
Kit.INPUT_UI_ONLY = 4096 + (Kit.UI_CHAN + 1) + (62 << 5)  -- MIDI, chan 16, VKB

-- Pad trigger through the real engine: virtual-keyboard MIDI queue →
-- armed MIDI bus → choke JSFX → sends → pad RS5Ks.
function Kit.StuffNote(note, on, vel)
    r.StuffMIDIMessage(0, (on and 0x90 or 0x80) + Kit.UI_CHAN, note,
                       on and (vel or 100) or 0)
end

-- WHO HEARS THE KEYBOARD. Pad clicks travel over the VKB queue, which reaches
-- every armed track at once, so the two instruments cannot both listen: the
-- one ON SCREEN does. That is the only thing the view still decides — both
-- tracks keep sounding whatever is sent to them (items, sends, looper lanes),
-- which is what makes them usable at the same time.
local function armTarget()
    if Kit.mode == "instrument" then
        local t = Kit.instr and Kit.instr.track
        return valid(t) and t or nil
    end
    return valid(Kit.bus) and Kit.bus or nil
end

local function idleTarget()
    if Kit.mode == "instrument" then return valid(Kit.bus) and Kit.bus or nil end
    local t = Kit.instr and Kit.instr.track
    return valid(t) and t or nil
end

function Kit.Armed()
    local tr = armTarget()
    if not tr then return false end
    return r.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
       and r.GetMediaTrackInfo_Value(tr, "I_RECMON") > 0
end

-- The arm is an INTENT, not just a track value. Armed is the working default
-- (pad clicks travel through StuffMIDIMessage, which only reaches an armed +
-- monitored track), and other scripts disarm tracks behind our back — CP_Looper
-- used to do it when routing a lane here, and CP_AutoArmVSTiTrack does it on
-- selection changes. Kit.HoldArm() re-asserts the intent whenever the track
-- drifted, so the sampler stops silently falling back to raw file preview.
Kit.arm_intent = true

function Kit.SetArmed(on)
    if Kit.mode == "instrument" then
        Kit.EnsureInstrument()
    elseif not valid(Kit.bus) then
        if not valid(Kit.parent) then return end
        Kit.EnsureBus()
    end
    Kit.arm_intent = on and true or false
    local tr = armTarget()
    if not tr then return end
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", on and 1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", on and 1 or 0)
    local idle = on and idleTarget() or nil
    if idle then
        r.SetMediaTrackInfo_Value(idle, "I_RECARM", 0)
        r.SetMediaTrackInfo_Value(idle, "I_RECMON", 0)
    end
    -- our own write must not look like an external project change, or the next
    -- Poll rescans the whole kit for nothing
    last_change = r.GetProjectStateChangeCount(0)
end

-- Re-assert the intent if something moved it. Cheap: two reads, and it only
-- writes on an actual mismatch. The other instrument is pushed out of the way
-- ONLY while we claim the input — disarmed, we have no business touching a
-- track the user armed himself.
function Kit.HoldArm()
    local tr = armTarget()
    if not tr then return false end
    local want = Kit.arm_intent and 1 or 0
    local wrote = false
    local arm  = r.GetMediaTrackInfo_Value(tr, "I_RECARM")
    local mon  = r.GetMediaTrackInfo_Value(tr, "I_RECMON")
    if arm ~= want or ((want == 0) ~= (mon == 0)) then
        r.SetMediaTrackInfo_Value(tr, "I_RECARM", want)
        r.SetMediaTrackInfo_Value(tr, "I_RECMON", want)
        wrote = true
    end
    if want == 1 then
        local idle = idleTarget()
        if idle and (r.GetMediaTrackInfo_Value(idle, "I_RECARM") == 1
                  or r.GetMediaTrackInfo_Value(idle, "I_RECMON") ~= 0) then
            r.SetMediaTrackInfo_Value(idle, "I_RECARM", 0)
            r.SetMediaTrackInfo_Value(idle, "I_RECMON", 0)
            wrote = true
        end
    end
    if wrote then last_change = r.GetProjectStateChangeCount(0) end
    return wrote
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
    -- never disarm the input bus: an adopted kit can have the parent and the
    -- bus be the SAME track, and disarming it kills every pad click
    if Kit.parent ~= bus then
        r.SetMediaTrackInfo_Value(Kit.parent, "I_RECARM", 0)
    end

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
            if pad.track ~= bus then
                r.SetMediaTrackInfo_Value(pad.track, "I_RECARM", 0)
            end
            local _, guid = r.GetSetMediaTrackInfo_String(pad.track, "GUID", "", false)
            if not have[guid] then
                local s = r.CreateTrackSend(bus, pad.track)
                if s >= 0 then
                    r.SetTrackSendInfo_Value(bus, 0, s, "I_SRCCHAN", -1)
                    r.SetTrackSendInfo_Value(bus, 0, s, "I_MIDIFLAGS", MIDI_TO_CH1)
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
            -- a preset restores its own TUNE below: auto-sync would both
            -- fight that write and outlive it (the next ApplyTempoSync
            -- would re-aim a pad the preset had tuned by hand)
            Kit.LoadSample(p.note, p.path, { no_sync = true })
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
