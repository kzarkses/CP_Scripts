-- CP_Sampler — Kit
--
-- THIS IS NOT A LEFTOVER. The suite moved its clip playback to a native engine
-- and deleted every infrastructure track it used to create; the question "why
-- does the sampler still make tracks with an RS5K in them" is therefore fair,
-- and the answer is that a PAD IS NOT A CLIP. The engine plays voices: a
-- position, a rate, a gain, two linear fades. A pad is an instrument — full
-- ADSR, choke groups resolved in the audio thread, velocity zones, per-pad
-- polyphony, its own FX chain and mixer strip and meter, constant-duration
-- pitch through ReaPitch, and it keeps sounding when this script is closed and
-- when the extension is absent. Thirteen of the seventeen parameters used here
-- have no equivalent in the engine. Migrating would be a net loss, not a
-- simplification.
--
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
-- MIDI flow — READ THIS ONE, it is the part that used to be incomprehensible.
--
-- TWO ROADS REACH THE KIT, AND THEY ARE NOT THE SAME ROAD.
--   1. What YOU play. A pad click, a key on the chromatic keyboard, a note
--      auditioned in the editor: CP_Engine/Notes writes it into ONE engine
--      port, and that port is poured into the kit's MIDI bus track, pre-FX.
--      Nothing else in the project hears it. No track is armed for this, ever.
--   2. What the PROJECT plays. A recorded MIDI item on the bus, a looper lane
--      routed here, a keyboard you monitor because you armed the track — all
--      of it is REAPER's own MIDI, arriving the way it arrives on any
--      instrument track.
-- Both land in the same FX chain: the generated choke JSFX, then per-pad
-- MIDI-only sends whose RS5K note range does the filtering.
--
-- WHAT THIS MODULE NO LONGER DOES, and it is the whole point: it does not arm
-- anything of its own accord. It used to force I_RECARM, I_RECMON and
-- "all inputs / all channels" onto the bus, and re-assert them every time
-- REAPER cleared them — which meant it was not ignoring your armed tracks, it
-- was COMPETING with them and winning. Road 1 needed an armed track because it
-- travelled by StuffMIDIMessage, a broadcast. Road 1 has an address now, so
-- the arm goes back to meaning what REAPER means by it, and Kit.Armed() is a
-- reading, not an intent.
--
-- The chromatic INSTRUMENT is a second instrument on a track of its own, with
-- its own input and its own output. Both can sound at once — and now they
-- really can, because a pad click no longer reaches anything but the kit.
-- Kit.mode says which one is on screen, and the live port follows it.
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

-- « Faire sonner une note DANS cette piste ». Deux modules, une capacite : Voice
-- sait si le moteur peut adresser une note, Notes tient la cible et les notes
-- tenues. Meme raison qu'au-dessus pour `reaper` plutot que `r`.
local Voice = dofile(reaper.GetResourcePath()
                     .. "/Scripts/CP_Scripts/CP_Engine/Voice.lua")
local Notes = dofile(reaper.GetResourcePath()
                     .. "/Scripts/CP_Scripts/CP_Engine/Notes.lua")

-- « Un kit est un effet ». KitFX tient le contrat avec CP_KitSampler.jsfx :
-- les index de gmem, la carte des champs d'un pad, et les courbes qui relient
-- une position de bouton a des millisecondes. Kit ne connait rien de tout ca.
local KitFX = dofile(reaper.GetResourcePath()
                     .. "/Scripts/CP_Scripts/CP_Engine/KitFX.lua")

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

    -- AU-DESSUS DE 100 : CE QUE LE RS5K N'AVAIT PAS, et qui n'existe que sur
    -- le moteur JSFX. Les numeros commencent haut pour ne jamais croiser un
    -- index de parametre du RS5K, y compris ceux qu'une version future
    -- ajouterait. Sur un kit RS5K, Kit.Param(note, PORTA) rend nil — et
    -- l'interface a le droit de s'en servir pour griser le bouton.
    PORTA = 100, ROFF = 101, ROFFMS = 102, BEND = 103,
    MUTE = 104, SOLO = 105, OUT = 106, PROB = 107, RR = 108,
    MINVOL = 109, MIDICHAN = 110, CHROMATIC = 111, PADROOT = 112,
    XFADE = 113,
}

-- Les reglages qu'un preset emporte sur le moteur JSFX. Le RS5K a sa propre
-- liste (SAVE_PIDS, tout en bas) : deux moteurs, deux jeux de reglages, et
-- ecrire un preset de l'un avec la liste de l'autre perdrait en silence
-- exactement ce que le nouveau moteur a de plus.
Kit.FX_PIDS = { 0, 1, 3, 4, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 23, 24, 25,
                100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
                112, 113 }

-- Ceux du RS5K. DECLARE ICI ET NON PLUS AVEC LES PRESETS : la migration s'en
-- sert pour relever un kit source, et elle vit plus haut dans le fichier —
-- en Lua, une locale declaree plus bas est simplement invisible, et l'appel
-- serait parti sur nil sans un mot.
local SAVE_PIDS = { 0, 1, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 23, 24, 25 }

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
Kit.bus    = nil       -- "CP Kit MIDI" child track — the kit's MIDI track.
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

-- « La piste qu'on joue » — le bus du kit, ou la piste de l'instrument quand
-- c'est lui qui est a l'ecran. Declaree ici parce que le cycle de vie du kit
-- (SetActive, SetMode) doit pouvoir y renvoyer les notes tenues, et que son
-- corps vit avec les helpers de jeu, tout en bas.
local playTarget

-- Le moteur JSFX : declare ici, rempli plus bas. Sans ces lignes, Kit.Scan
-- appellerait des globales nil — l'erreur silencieuse la plus couteuse de Lua.
local fx_slot, fx_index, fx_dirty = 0, nil, false
local findKitFX, fxEnsure, fxDeserialize, fxSave
local fxPad, fxLoadSample, fxClearPad, fxParam, fxSetParam
local fxQueueLoad, fxPumpLoads, fxReconcile

local Tracks  -- optional Engine/Tracks module (common P_EXT:CP mark + folder)

function Kit.init(reaper_api, tracks_module)
    r = reaper_api
    Tracks = tracks_module
    SrcTempo.init(r)
    Voice.init(r)
    Notes.init(r, Voice, Voice.PLAY_PORT_SAMPLER)
    KitFX.init(r)
end

-- Comment une note jouee ici atteint le kit : « targeted » (un port, une piste)
-- ou « broadcast » (le repli sans le moteur, qui reveille toute piste armee).
-- Une fenetre l'affiche telle quelle : c'est la premiere chose a savoir quand
-- un routage surprend.
function Kit.PlayLabel() return Notes.Label() end

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

-- L'IDENTITE TEMPORELLE D'UN PAD EST A CE PAD. Sur le montage RS5K, chaque
-- pad a SA piste : une cle nue suffit. Sur l'instrument, les soixante-quatre
-- partagent la meme, donc la cle doit porter la note — sinon « synchroniser
-- ce pad » synchronise le kit ENTIER et le repitche selon le BPM source d'un
-- seul, toute la batterie change de hauteur, et rien ne dit qui l'a demande.
-- La cle nue reste celle des kits RS5K : la changer casserait les projets
-- existants pour rien.
local function padKey(base, note)
    if Kit.IsFX() then return base .. "_" .. tostring(note) end
    return base
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
    -- Kit.engine AUSSI. Le laisser perime faisait parler la fenetre a un kit
    -- neuf comme a un instrument : les reglages partaient dans une boite aux
    -- lettres morte et n'arrivaient nulle part.
    Kit.parent, Kit.bus, Kit.instr, choke_fx = nil, nil, nil, nil
    Kit.engine = nil
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
        -- QUEL MOTEUR EST CE KIT. La question se pose avant tout le reste :
        -- un kit JSFX n'a ni dossier, ni bus, ni piste par pad, donc le
        -- balayage qui suit n'aurait rien a visiter et effacerait ses pads.
        Kit.engine = getExt(Kit.parent, "CP_KIT_ENGINE") or Kit.ENGINE_RS5K
        if Kit.engine == Kit.ENGINE_FX then
            fx_slot = tonumber(getExt(Kit.parent, "CP_KIT_SLOT") or "") or 0
            fx_index = findKitFX(Kit.parent)
            Kit.bus, Kit.instr = nil, nil
            choke_fx, choke_tr = nil, nil
            Kit.mode = "drum"
            fxDeserialize(getExt(Kit.parent, "CP_KIT_PADS"))
            -- L'effet manque : il a ete supprime a la main, ou la piste vient
            -- d'une migration. On le repose et on lui rend le miroir — c'est
            -- le seul cas ou Lua ecrase l'instrument, et il est vide.
            if not fx_index then fxEnsure(Kit.parent) end
            for _, pad in pairs(Kit.pads) do
                if pad.path then pad.fx = fx_index end
                pad.track = Kit.parent
            end
            Kit.version = Kit.version + 1
            last_change = r.GetProjectStateChangeCount(0)
            return
        end
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

-- `enforceSingleListener` vivait ici. Il desarmait le bus de tous les autres
-- kits du projet, en boucle, parce qu'un clic de pad etait un broadcast et
-- aurait sinon fait sonner les deux. Ce n'etait donc pas une regle musicale
-- mais un pansement sur l'absence d'adresse — et il avait un effet de bord
-- durable : il ecrasait l'armement d'une piste que l'utilisateur avait pu
-- armer pour tout autre chose.
--
-- Ce qui reste de l'idee est vrai et suffisant : UN SEUL KIT EST LA CIBLE DU
-- SAMPLER a la fois. C'est `Kit.active_guid`, une propriete de la fenetre, et
-- elle ne touche a l'etat d'aucune piste.

-- Choose which kit this module drives — and builds its MIDI bus if it never
-- had one. The choice is saved per project.
function Kit.SetActive(track)
    if not valid(track) then return false end
    Kit.active_guid = r.GetTrackGUID(track)
    r.SetProjExtState(0, "CP_Sampler", "ACTIVE_KIT", Kit.active_guid)
    Kit.Scan()
    if not valid(Kit.bus) then Kit.EnsureBus() end
    -- ce qui sonnait sonnait dans l'ancien kit : on l'y relache
    Notes.SetTrack(playTarget())
    return true
end

-- A brand-new, empty kit next to the existing ones (multi-kit). Becomes
-- the active kit; the pads fill it from then on.
-- LE NOUVEAU MOTEUR EST LE DEFAUT, et l'ancien reste accessible. Un kit
-- neuf n'a aucune raison de naitre en soixante-cinq pistes ; un kit existant
-- n'a aucune raison d'etre converti sans qu'on le demande.
function Kit.NewKit(name, engine)
    if engine ~= Kit.ENGINE_RS5K then return Kit.NewKitFX(name) end
    return Kit.NewKitRS5K(name)
end

function Kit.NewKitRS5K(name)
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
    -- La file de chargement avance ici : Poll est deja appele une fois par
    -- passage par CP_Sampler et CP_Editor, et rien d'autre dans ce module
    -- n'a de battement.
    if Kit.IsFX() then
        KitFX.Heartbeat(fx_slot)
        fxPumpLoads()
        fxReconcile()
        -- fx_dirty ETAIT POSE ET JAMAIS LU : tourner un bouton changeait le
        -- son et le miroir en memoire, mais rien ne l'ecrivait sur la piste.
        -- Le premier evenement qui refaisait un scan rendait tous les boutons
        -- a leur valeur d'avant, pendant que le pad continuait de sonner avec
        -- les nouvelles — et le fxSave suivant gravait les PERIMEES.
        if fx_dirty then fxSave() end
    end
    local c = r.GetProjectStateChangeCount(0)
    if c == last_change then return false end
    last_change = c
    Kit.Scan()
    -- Le kit a pu changer de forme (undo, edition manuelle, autre script) :
    -- la cible de jeu suit, et ce qui sonnait est relache la ou il sonnait.
    -- C'est tout ce que ce poll ecrit — plus aucun armement n'est reaffirme.
    Notes.SetTrack(playTarget())
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
    -- « Ce kit est-il un instrument » se demande AVANT de batir quoi que ce
    -- soit : Ensure est le point d'entree de TOUT le montage RS5K (dossier,
    -- bus, piste par pad), et l'appeler sur un kit JSFX referait exactement
    -- ce qu'on vient de supprimer.
    if not valid(Kit.parent) then Kit.Scan() end
    if valid(Kit.parent) then
        if Kit.IsFX() then
            fxEnsure(Kit.parent)
        end
        return Kit.parent
    end

    -- AUCUN KIT : ON EN FAIT UN, ET C'EST UN INSTRUMENT. Glisser un
    -- echantillon sur un pad passe par ici, et cette fonction fabriquait
    -- l'ancien montage : un dossier, un bus, une piste par pad. On retombait
    -- donc sur le moteur RS5K en croyant essayer le nouveau, sans que rien ne
    -- le dise. Un kit neuf nait sur le nouveau moteur, comme dans le menu.
    local tr = Kit.NewKitFX("CP Kit")
    if tr then return tr end

    -- Repli : sans gmem ni instrument, un kit RS5K vaut mieux que rien.
    ubegin()
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
    Kit.engine = Kit.ENGINE_RS5K
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

-- The kit's MIDI bus: hosts the choke JSFX and fans MIDI out to the pads.
-- Recording lands MIDI performances as items HERE — their playback drives the
-- kit too.
--
-- IT IS BORN LIKE ANY OTHER INSTRUMENT TRACK: not armed, not monitoring, with
-- whatever input REAPER gives a new track. It used to be born armed on all
-- inputs and all channels, and that was not a convenience — it was the whole
-- reason live MIDI was impossible to reason about. Playing it is arming it,
-- yourself, once, like anything else in REAPER.
function Kit.EnsureBus()
    -- Un instrument n'a personne a qui envoyer du MIDI : il EST le
    -- destinataire. Le bus n'existait que pour distribuer aux pistes des pads.
    if Kit.IsFX() then return nil end
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
    -- LE KIT D'ABORD, LE MOTEUR ENSUITE. Kit.Ensure peut CREER le kit — et
    -- depuis qu'il en cree un instrument, demander « suis-je un instrument »
    -- avant lui repondait non, puis on rebatissait l'ancien montage dans la
    -- piste qu'on venait de faire. L'ordre est la moitie de la correction.
    local parent = Kit.Ensure()
    if Kit.IsFX() then return fxPad(note, true) end

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
    -- MEME ORDRE QU'AILLEURS : le kit peut naitre ici, et depuis qu'il nait
    -- instrument, tester le moteur avant Kit.Ensure faisait poser un RS5K
    -- dans la chaine du kit-instrument qu'on venait de creer.
    Kit.Ensure()
    if Kit.IsFX() then
        ubegin()
        local ok = fxLoadSample(note, path, opts)
        uend("Sampler: load " .. baseName(path))
        return ok
    end
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
    if Kit.IsFX() then
        ubegin()
        fxClearPad(note)
        uend("Sampler: clear pad")
        return
    end
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
    -- Sur le JSFX il n'y a pas de piste a supprimer : effacer un pad EST le
    -- supprimer. C'est un des trois cents gestes que le montage RS5K rendait
    -- differents sans qu'aucune raison musicale ne le demande.
    if Kit.IsFX() then
        ubegin()
        fxClearPad(note)
        Kit.pads[note] = nil
        fxSave()
        uend("Sampler: delete pad")
        return
    end
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
-- Echanger deux pads sur le JSFX : deux enregistrements du miroir, et deux
-- rechargements. Aucune piste ne bouge — sur le montage RS5K, cet echange
-- etait le SEUL endroit qui deplacait des pistes, et c'est exactement le
-- genre de geste qui a coute des echantillons le 1er aout.
function Kit.SwapPadsFX(a, b)
    local pa, pb = Kit.pads[a], Kit.pads[b]
    if not (pa or pb) then return end
    ubegin()
    Kit.pads[a], Kit.pads[b] = pb, pa
    for note, pad in pairs({ [a] = Kit.pads[a], [b] = Kit.pads[b] }) do
        if pad then
            pad.note = note
            pad.p = pad.p or {}
            pad.p[Kit.P.NOTE_LO] = note / 127
            pad.p[Kit.P.NOTE_HI] = note / 127
            pad.fmt = {}
        end
    end
    for _, note in ipairs({ a, b }) do
        local idx = note - Kit.BASE
        local pad = Kit.pads[note]
        if pad and pad.path then
            fxQueueLoad(note, pad.path)
            for pid, v in pairs(pad.p) do
                local f = KitFX.Field(pid)
                if f then KitFX.Set(fx_slot, idx, f, KitFX.ToFX(pid, v)) end
            end
            KitFX.Set(fx_slot, idx, KitFX.F.CHOKE, pad.choke or 0)
        else
            KitFX.Clear(fx_slot, idx)
        end
    end
    fxSave()
    Kit.version = Kit.version + 1
    uend("Sampler: swap pads")
end

function Kit.SwapPads(a, b)
    if Kit.IsFX() then return Kit.SwapPadsFX(a, b) end
    if a == b then return end
    local pa, pb = Kit.Pad(a), Kit.Pad(b)
    if not pa and not pb then return end
    ubegin()
    local ga, gb = Kit.Choke(a), Kit.Choke(b)
    local function assign(pad, note)
        if not pad then return end
        setExt(pad.track, "CP_KIT_NOTE", tostring(note))
        if pad.fx then
            if Kit.IsFX() then
                Kit.SetParam(note, Kit.P.NOTE_LO, note / 127)
                Kit.SetParam(note, Kit.P.NOTE_HI, note / 127)
            else
                r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.NOTE_LO, note / 127)
                r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.NOTE_HI, note / 127)
            end
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
    local stored = tonumber(getExt(pad.track, padKey("CP_KIT_BPM", note)) or "")
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
    -- PAR LES ACCESSEURS, PAS PAR LE FX. Sur un kit JSFX, pad.fx designe
    -- l'instrument du kit et non un RS5K du pad : ecrire l'index 15 dedans
    -- viserait un slider quelconque, donc le volume d'un autre pad. Kit.Param
    -- et Kit.SetParamPlain savent, eux, a quel moteur ils parlent.
    local cur = Kit.IsFX() and Kit.ParamPlain(note, Kit.P.TUNE)
                or plainOf(pad.track, pad.fx, Kit.P.TUNE)
    if cur and math.abs(cur - st) <= 0.01 then return false end
    if Kit.IsFX() then
        Kit.SetParamPlain(note, Kit.P.TUNE, st)
    else
        plainSet(pad.track, pad.fx, Kit.P.TUNE, st)
    end
    pad.fmt[Kit.P.TUNE] = nil
    return true
end

function Kit.SetPadSrcBpm(note, bpm)
    local pad = Kit.Pad(note)
    if not pad then return end
    setExt(pad.track, padKey("CP_KIT_BPM", note), bpm and tostring(bpm) or "")
end

function Kit.PadSynced(note)
    local pad = Kit.Pad(note)
    return pad ~= nil and getExt(pad.track, padKey("CP_KIT_SYNC", note)) == "1"
end

-- Turning sync ON parks the user's manual tune in P_EXT and beat-matches
-- IMMEDIATELY (enabling sync IS the request — not "at the next tempo
-- change"); OFF restores the parked tune — the sync must never eat a
-- tuning gesture.
function Kit.SetPadSynced(note, on)
    local pad = Kit.Pad(note)
    if not pad or not pad.fx then return end
    if on then
        local cur = Kit.IsFX() and Kit.Param(note, Kit.P.TUNE)
                    or r.TrackFX_GetParamNormalized(pad.track, pad.fx, Kit.P.TUNE)
        setExt(pad.track, padKey("CP_KIT_TUNE0", note), string.format("%.6f", cur))
        setExt(pad.track, padKey("CP_KIT_SYNC", note), "1")
        applySync(note, pad, r.Master_GetTempo())
    else
        setExt(pad.track, padKey("CP_KIT_SYNC", note), "")
        local t0 = tonumber(getExt(pad.track, padKey("CP_KIT_TUNE0", note)) or "")
        if Kit.IsFX() then
            Kit.SetParam(note, Kit.P.TUNE, t0 or 0.5)
        else
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.TUNE, t0 or 0.5)
        end
        setExt(pad.track, padKey("CP_KIT_TUNE0", note), "")
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
    setExt(pad.track, padKey("CP_KIT_BPM", note), "")
end

-- Re-aim every synced pad at the given tempo. Cheap enough for the host
-- to call whenever Tempo reports a change (writes only on a real delta).
function Kit.ApplyTempoSync(project_bpm)
    if not project_bpm or project_bpm <= 0 then return end
    local wrote = false
    for note, pad in pairs(Kit.pads) do
        if pad.fx and getExt(pad.track, padKey("CP_KIT_SYNC", note)) == "1" then
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
    setExt(pad.track, padKey("CP_KIT_BPM", note), string.format("%.3f", bpm))
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
    -- comme le bus : une piste d'instrument ordinaire, ni armee ni branchee
    -- d'office sur toutes les entrees du systeme
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
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

-- Switch what the SAMPLER SHOWS. Nothing is muted, nothing changes hands, and
-- no arm state moves: the pads and the instrument are two instruments on two
-- tracks and both keep playing whatever is sent to them. Only what YOU play
-- follows the view — because you can only play one of them at a time.
function Kit.SetMode(mode)
    if mode ~= "drum" and mode ~= "instrument" then return end
    -- SUR L'INSTRUMENT, LE MODE N'A PLUS D'OBJET. « Chromatique » est devenu
    -- une propriete d'un PAD (Kit.SetPadChromatic), pas une seconde piste avec
    -- son propre RS5K. Laisser passer ici referait naitre exactement la piste
    -- que le chantier 2 supprime.
    if Kit.IsFX() then return end
    local parent = Kit.Ensure()
    ubegin()
    setExt(parent, "CP_KIT_MODE", mode)
    Kit.mode = mode
    if mode == "instrument" then Kit.EnsureInstrument() end
    Kit.version = Kit.version + 1
    uend("Sampler: set mode " .. mode)
    Notes.SetTrack(playTarget())   -- ce qu'on joue suit la vue
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
    if not (next(feeds) or owner or #unmute > 0) then
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

    -- L'etape « lui donner sa propre entree » a disparu d'ici. Elle posait
    -- INPUT_ALL, c'est-a-dire toutes les entrees MIDI du systeme, et ce n'etait
    -- une reparation que dans un monde ou s'entendre exigeait d'etre arme.
    -- Couper l'envoi (etape 1) suffit a le rendre independant ; l'entree qu'il
    -- ecoute est celle que REAPER lui a donnee, comme pour toute piste.

    -- 2. out of the kit folder, to just before it — a sibling, at the same
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

    -- 3. the mode mutes go. They were how the two took turns; there are no
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


-- ===========================================================================
-- LE MOTEUR JSFX — un kit est UNE piste portant UN effet
-- ===========================================================================
-- Les deux moteurs cohabitent, et ce n'est pas de l'indecision : les kits
-- existants sont faits de RS5K sur des pistes, et les casser pour essayer le
-- nouveau serait exactement la faute du 1er aout. Un kit dit lequel il est
-- (P_EXT:CP_KIT_ENGINE) ; tout le reste de ce fichier demande a Kit.IsFX().
--
-- CE QUI EST AUTORITAIRE. Le JSFX possede l'etat qui fait le SON : reglages
-- et chemins sont dans son @serialize, donc dans le .RPP, donc un projet
-- rouvert sonne sans qu'aucun script tourne. Kit tient un MIROIR pour
-- l'affichage, persiste dans P_EXT — la fenetre doit pouvoir dessiner un pad
-- sans interroger le fil audio soixante fois par seconde. Si les deux
-- divergent, le JSFX gagne pour le son et le miroir se refait au scan.
Kit.ENGINE_RS5K = "rs5k"
Kit.ENGINE_FX   = "jsfx"

-- Le slot gmem de ce kit. Il vit sur la piste : deux kits d'un meme projet ne
-- doivent jamais partager une boite aux lettres, et l'oublier ferait qu'un
-- reglage du premier atterrit dans le second.
-- fx_index : index de l'effet sur la piste du kit (declare plus haut)
-- fx_dirty : le miroir a change et n'est pas encore ecrit

function Kit.IsFX()
    -- L'AIGUILLAGE NE DOIT PAS DEPENDRE D'UN CHAMP EN MEMOIRE. Kit.engine
    -- n'est rempli que par Kit.Scan ; si une creation est interrompue, ou si
    -- un geste arrive avant le premier scan, le kit repondrait « rs5k » et
    -- l'ancien montage repartirait — on l'apprend soixante-cinq pistes plus
    -- tard. LA PISTE PORTE LA REPONSE : on la lui demande.
    if Kit.engine == nil and valid(Kit.parent) then
        Kit.engine = getExt(Kit.parent, "CP_KIT_ENGINE") or Kit.ENGINE_RS5K
    end
    return Kit.engine == Kit.ENGINE_FX
end

local load_q, load_head = {}, 1

function fxQueueLoad(note, path)
    load_q[#load_q + 1] = { note = note, path = path }
end

-- Combien de pads attendent encore leur matiere. Zero veut dire « tout ce
-- qu'on a demande est arrive » — et c'est la seule chose qu'une migration ait
-- le droit de croire.
function Kit.FXLoading()
    if not Kit.IsFX() then return 0 end
    local n = #load_q - load_head + 1
    if n < 0 then n = 0 end
    if n == 0 and not KitFX.LoadIdle(fx_slot) then return 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- LA RECONCILIATION, ET C'EST LE TROU QUE J'AVAIS VU PUIS ECARTE
-- ---------------------------------------------------------------------------
-- J'avais ecrit : « le JSFX possede l'etat qui fait le son, Kit tient un
-- miroir pour l'affichage, et s'ils divergent le JSFX gagne — le miroir se
-- refait au prochain scan ». La deuxieme moitie est FAUSSE : le miroir ne
-- peut pas se refaire depuis l'instrument, qui ne publie ni chemins ni noms.
-- Et l'instrument ne recevait le miroir que si l'effet venait d'etre cree.
--
-- Resultat : un pad qui existe dans la fenetre, dessine avec son nom et sa
-- forme d'onde, et un instrument vide. Rien ne rapprochait les deux, et rien
-- ne le disait. C'est litteralement ce qu'on a passe la soiree a regarder.
--
-- La regle devient : QUAND L'INSTRUMENT EN A MOINS QUE LA FENETRE, LA FENETRE
-- RENVOIE TOUT. On ne compare que dans ce sens — l'instrument peut
-- legitimement en avoir plus pendant qu'il se recharge tout seul apres une
-- ouverture de projet, et l'ecraser alors serait le defaut inverse.
local rec_wait = 0
local RECONCILE_EVERY = 90        -- passages, soit une seconde et demie

fxReconcile = function()
    if not KitFX.Ready() then return end
    rec_wait = rec_wait + 1
    if rec_wait < RECONCILE_EVERY then return end
    rec_wait = 0
    -- Jamais pendant un chargement : « ce pad n'a pas de matiere » voudrait
    -- alors dire « pas encore », et on renverrait tout en boucle.
    if Kit.FXLoading() > 0 then return end
    local want = 0
    for _, pad in pairs(Kit.pads) do
        if pad.path then want = want + 1 end
    end
    if want == 0 then return end
    local have = KitFX.LoadedCount(fx_slot)
    if have < 0 or have >= want then return end
    Kit.SyncAll()
end

-- Un chargement par passage de la boucle, et seulement quand le precedent est
-- fini. Soixante-quatre pads mettent donc une seconde a arriver — c'est aussi
-- ce qui evite de lancer soixante-quatre lectures de disque d'un coup.
function fxPumpLoads()
    if load_head > #load_q then
        if load_head > 1 then load_q, load_head = {}, 1 end
        return
    end
    if not KitFX.LoadIdle(fx_slot) then return end
    local e = load_q[load_head]
    load_head = load_head + 1
    if e then KitFX.Load(fx_slot, e.note - Kit.BASE, e.path) end
end

function Kit.FXReady()
    return KitFX.Ready()
end

-- Comment l'instrument repond, en un mot, pour la zone de statut de la
-- fenetre. Meme raison d'etre que « engine native 1.8 » dans la Session : la
-- question qu'on se pose vraiment est « est-ce que ce que je vois est ce qui
-- sonne ».
function Kit.EngineLabel()
    if not Kit.IsFX() then return "rs5k/" .. Notes.Label() end
    if not KitFX.Ready() then return "jsfx (no gmem)" end
    -- COMBIEN DE PADS SONNENT, ET PAR OU ARRIVE LA NOTE. Les deux moities de
    -- la question « je n'entends rien » : zero pad charge accuse le
    -- chargement, un compte juste accuse le routage. Sans ce chiffre il n'y a
    -- que le silence, et le silence ne dit rien.
    local n = KitFX.LoadedCount(fx_slot)
    local st = KitFX.Status(fx_slot)
    local why = (st == KitFX.ST_FAILED) and " load failed"
             or (st == KitFX.ST_TRUNCATED) and " truncated"
             or (st == KitFX.ST_BUSY) and " loading"
             or ""
    return string.format("jsfx/%s %d loaded%s", Notes.Label(), n, why)
end

function Kit.FXSlot() return fx_slot end

-- --- le miroir, persiste sur la piste ---------------------------------------
-- Un enregistrement par pad : note, chemin, nom, puis les reglages. Les
-- separateurs sont des caracteres de controle qu'un chemin ne peut pas
-- contenir — un chemin Windows accepte les espaces et les accents, pas les
-- tabulations ni les sauts de ligne.
local function fxSerialize()
    local out = {}
    for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.pads[note]
        if pad and pad.path then
            local ps = {}
            for _, pid in ipairs(Kit.FX_PIDS) do
                local v = pad.p and pad.p[pid]
                if v then ps[#ps + 1] = pid .. "=" .. string.format("%.6f", v) end
            end
            -- LE CHOKE AUSSI. Il n'est ni un Kit.P ni une entree de
            -- Kit.FX_PIDS : il vit a part sur le pad, et il ne se serialisait
            -- pas. Tout Kit.Scan le remettait a zero — les pads continuaient
            -- de se couper a l'oreille pendant que le menu disait « aucun
            -- groupe » — et le premier echange de pads le detruisait pour de
            -- bon.
            ps[#ps + 1] = "choke:" .. tostring(pad.choke or 0)
            out[#out + 1] = table.concat({ note, pad.path, pad.name or "",
                                           table.concat(ps, ",") }, "\t")
        end
    end
    return table.concat(out, "\n")
end

function fxDeserialize(blob)
    Kit.pads = {}
    if not blob or blob == "" then return end
    for line in blob:gmatch("[^\n]+") do
        local note, path, name, ps = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t?(.*)$")
        note = tonumber(note)
        if note and path and path ~= "" then
            local p = {}
            for pid, v in (ps or ""):gmatch("(%d+)=([%-%d%.eE]+)") do
                p[tonumber(pid)] = tonumber(v)
            end
            local ck = tonumber((ps or ""):match("choke:(%d+)") or "") or 0
            Kit.pads[note] = { note = note, path = path,
                               name = (name ~= "" and name) or baseName(path),
                               track = Kit.parent, fx = fx_index,
                               p = p, choke = ck, fmt = {} }
        end
    end
end

function fxSave()
    if not (Kit.IsFX() and valid(Kit.parent)) then return end
    setExt(Kit.parent, "CP_KIT_PADS", fxSerialize())
    fx_dirty = false
end

-- --- l'effet sur la piste ---------------------------------------------------
function findKitFX(tr)
    local n = r.TrackFX_GetCount(tr)
    for i = 0, n - 1 do
        if fxMatches(tr, i, "cp_kitsampler") then return i end
    end
    return nil
end

-- Rend l'index de l'effet, en le posant s'il manque. LE SLOT EST ECRIT DANS
-- LE SLIDER a chaque fois : c'est la seule chose que le JSFX ne peut pas
-- deviner, et un effet copie-colle d'un kit a l'autre arriverait sinon avec
-- la boite aux lettres de son origine.
function fxEnsure(tr)
    if not valid(tr) then return nil end
    local i = findKitFX(tr)
    if not i then
        local ok, why = KitFX.Install()
        i = r.TrackFX_AddByName(tr, KitFX.ADD, false, -1000)
        if i < 0 then
            -- ON LE DIT. Sans instrument, le kit accepte les depots, dessine
            -- les pads, et ne sonne jamais : le seul indice etait « 0 loaded »
            -- dans une zone de statut. Arrive des que l'installation du .jsfx
            -- echoue — dossier en lecture seule, source deplacee.
            Kit.fx_error = "instrument introuvable"
                           .. (ok and "" or (" (" .. (why or "install") .. ")"))
            return nil
        end
        Kit.fx_error = nil
        hideFX(tr, i)
        -- Un effet neuf n'a rien : on lui redonne tout le miroir. C'est le
        -- seul moment ou Lua ecrase le JSFX, et c'est justifie — il est vide.
        fx_index = i
        Kit.SyncAll()
    end
    fx_index = i
    r.TrackFX_SetParamNormalized(tr, i, 0, fx_slot / 15)
    return i
end

function Kit.FXIndex() return fx_index end

-- Reverse tout le miroir dans l'instrument : chemins d'abord, puis reglages.
-- Sert quand l'effet vient de naitre, et depuis le menu quand on soupconne
-- une divergence.
function Kit.SyncAll()
    if not (Kit.IsFX() and KitFX.Ready()) then return false end
    KitFX.ClearAll(fx_slot)
    for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.pads[note]
        if pad and pad.path then
            local idx = note - Kit.BASE
            fxQueueLoad(note, pad.path)
            for pid, v in pairs(pad.p or {}) do
                local f = KitFX.Field(pid)
                if f then KitFX.Set(fx_slot, idx, f, KitFX.ToFX(pid, v)) end
            end
        end
    end
    return true
end

-- --- eclater un pad vers une piste -----------------------------------------
-- LA REPONSE AU PAD QUI VEUT VRAIMENT SA TRANCHE DE MIXER. Le pad sort sur sa
-- paire de canaux, un envoi la porte vers une piste, et cette piste a son
-- fader, son mute, son solo et son VU — tout ce que le montage RS5K donnait
-- d'office aux soixante-quatre, rendu a la demande a celui qui en a besoin.
--
-- On ne cree la piste QUE si on est appele : creer une piste dans le dos de
-- quelqu'un est precisement ce qu'on a passe la journee a supprimer.
function Kit.BreakoutPad(note)
    if not Kit.IsFX() then return nil, "moteur RS5K" end
    local pad = Kit.pads[note]
    if not (pad and pad.path) then return nil, "pad vide" end
    local out = math.floor((Kit.ParamPlain(note, Kit.P.OUT) or 0) + 0.5)
    if out < 1 then return nil, "ce pad sort dans le mixer interne" end
    if not valid(Kit.parent) then return nil, "aucun kit" end

    ubegin()
    -- La piste du kit doit porter assez de canaux pour la paire demandee.
    -- Deux par sortie, et REAPER veut un nombre pair.
    local want = (out + 1) * 2
    if r.GetMediaTrackInfo_Value(Kit.parent, "I_NCHAN") < want then
        r.SetMediaTrackInfo_Value(Kit.parent, "I_NCHAN", want)
    end

    local idx = trackIdx(Kit.parent) + 1
    r.InsertTrackAtIndex(idx, true)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", pad.name or ("Pad " .. note), true)
    setExt(tr, "CP_KIT_BREAKOUT", tostring(note))

    local si = r.CreateTrackSend(Kit.parent, tr)
    if si >= 0 then
        r.SetTrackSendInfo_Value(Kit.parent, 0, si, "I_SRCCHAN", out * 2)
        r.SetTrackSendInfo_Value(Kit.parent, 0, si, "I_DSTCHAN", 0)
        r.SetTrackSendInfo_Value(Kit.parent, 0, si, "I_MIDIFLAGS", 1 << 22)
    end
    Kit.version = Kit.version + 1
    uend("Sampler: break out pad to a track")
    return tr
end

-- --- le pad chromatique -----------------------------------------------------
-- L'INSTRUMENT CHROMATIQUE N'EST PLUS UN OBJET A PART, c'est un pad dont la
-- plage couvre le clavier. C'etait une piste, un singleton, un mode de fenetre
-- et trois chemins de code ; c'est desormais deux champs. Personne ne modelise
-- « un kit » et « un instrument » comme deux objets differents — ni Ableton,
-- ou un pad de Drum Rack contient un Simpler, ni FL, ou l'objet kit n'existe
-- pas.
function Kit.PadChromatic(note)
    if not Kit.IsFX() then return false end
    local v = Kit.Param(note, Kit.P.CHROMATIC)
    return v ~= nil and v >= 0.5
end

function Kit.SetPadChromatic(note, on, root)
    if not Kit.IsFX() then return end
    local pad = Kit.pads[note]
    if not (pad and pad.path) then return end
    ubegin()
    fxSetParam(note, Kit.P.CHROMATIC, on and 1 or 0)
    if on then
        fxSetParam(note, Kit.P.PADROOT, (root or note) / 127)
        fxSetParam(note, Kit.P.NOTE_LO, 0)
        fxSetParam(note, Kit.P.NOTE_HI, 1)
    else
        fxSetParam(note, Kit.P.NOTE_LO, note / 127)
        fxSetParam(note, Kit.P.NOTE_HI, note / 127)
    end
    fxSave()
    Kit.version = Kit.version + 1
    uend("Sampler: pad chromatic")
end

-- --- creation ---------------------------------------------------------------
-- UNE PISTE. Pas de dossier, pas de bus, pas d'enfant, pas d'envoi. C'est
-- tout le chantier 2, et il tient en dix lignes une fois que l'instrument
-- existe — la difficulte n'a jamais ete le rangement des pistes.
function Kit.NewKitFX(name)
    ubegin()
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, true)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", name or "CP Kit", true)
    setExt(tr, "CP_KIT", "1")
    setExt(tr, "CP_KIT_ENGINE", Kit.ENGINE_FX)

    -- L'IDENTITE AVANT TOUT LE RESTE. Cette fonction fait ensuite une
    -- douzaine d'appels a REAPER, et si l'un d'eux leve, ce qui suit ne
    -- s'execute pas : un kit a moitie cree qui ne sait pas encore qu'il est
    -- un instrument fait repartir l'ancien montage au geste suivant. C'est
    -- exactement ce qui est arrive avec Tracks.Mark appele a un argument.
    Kit.parent = tr
    Kit.engine = Kit.ENGINE_FX
    Kit.bus    = nil
    Kit.pads   = {}
    fx_index   = nil

    if Tracks and Tracks.Mark then Tracks.Mark(tr, "sampler", "kit") end

    -- Le slot libre le plus bas : seize kits par projet, ce qui est deja
    -- au-dela de ce qu'on peut mixer.
    local used = {}
    for i = 0, r.CountTracks(0) - 1 do
        local t = r.GetTrack(0, i)
        local v = getExt(t, "CP_KIT_SLOT")
        if v then used[tonumber(v) or -1] = true end
    end
    local slot = 0
    while used[slot] and slot < KitFX.SLOTS do slot = slot + 1 end
    if slot >= KitFX.SLOTS then
        -- LE DIX-SEPTIEME KIT NE PARTAGE PAS LA BOITE DU SEIZIEME EN SILENCE.
        -- Deux kits sur un meme slot, c'est un reglage de l'un qui atterrit
        -- dans l'autre et une demande de chargement acquittee par le voisin.
        -- Mieux vaut refuser et le dire.
        Kit.fx_error = "seize kits par projet, c'est le maximum"
        slot = KitFX.SLOTS - 1
    end
    setExt(tr, "CP_KIT_SLOT", tostring(slot))

    fx_slot = slot
    local fi = fxEnsure(tr)
    Kit.SetActive(tr)
    Kit.version = Kit.version + 1
    uend("Sampler: new kit (jsfx)")
    -- L'INSTRUMENT N'A PAS PU ETRE POSE : la piste existe et porte les
    -- marques, mais elle ne sonnera jamais. Mieux vaut le dire tout de suite
    -- que laisser deposer soixante-quatre echantillons dedans.
    if not fi then return nil end
    return tr
end

-- --- pads -------------------------------------------------------------------
function fxPad(note, create)
    local pad = Kit.pads[note]
    if pad or not create then return pad end
    pad = { note = note, path = nil, name = "Pad " .. note,
            track = Kit.parent, fx = nil, p = {}, fmt = {} }
    Kit.pads[note] = pad
    return pad
end

function fxLoadSample(note, path, opts)
    if not valid(Kit.parent) then return false end
    fxEnsure(Kit.parent)
    local pad = fxPad(note, true)
    local idx = note - Kit.BASE
    if not KitFX.Ready() then return false end
    fxQueueLoad(note, path)
    pad.path = path
    -- « Il y a quelque chose ici ». CP_Sampler lit pad.fx a sept endroits
    -- comme un booleen de presence ; sur le montage RS5K c'etait l'instance
    -- du pad, ici c'est l'instrument du kit. Le laisser nil ferait dessiner
    -- un pad vide alors qu'il sonne.
    pad.fx = fx_index
    pad.name = baseName(path)
    pad.fmt = {}
    -- Un pad neuf ne joue QUE sa note. Le RS5K s'en moquait : il etait seul
    -- sur sa piste. Ici les soixante-quatre partagent le meme flux, et un pad
    -- qui naitrait sur 0..127 ferait sonner le kit entier a chaque touche.
    pad.p[Kit.P.NOTE_LO] = note / 127
    pad.p[Kit.P.NOTE_HI] = note / 127
    KitFX.Set(fx_slot, idx, KitFX.F.NLO, note)
    KitFX.Set(fx_slot, idx, KitFX.F.NHI, note)
    fx_dirty = true
    fxSave()
    Kit.version = Kit.version + 1
    return true
end

function fxClearPad(note)
    local pad = Kit.pads[note]
    if not pad then return end
    KitFX.Clear(fx_slot, note - Kit.BASE)
    pad.path, pad.fx = nil, nil
    pad.name = "Pad " .. note
    pad.fmt = {}
    fxSave()
    Kit.version = Kit.version + 1
end

-- --- reglages ---------------------------------------------------------------
function fxParam(note, pid)
    local pad = Kit.pads[note]
    if not (pad and pad.path) then return nil end
    local v = pad.p and pad.p[pid]
    if v then return v end
    -- La racine par defaut est la note du pad : seul cet endroit connait la
    -- note, donc c'est ici que la reponse se donne.
    if pid == Kit.P.PADROOT then return note / 127 end
    -- Jamais reglee : on rend le defaut de l'instrument plutot que nil, sinon
    -- un bouton naitrait a zero alors que le son, lui, part du defaut.
    return Kit.FXDefault(pid)
end

function fxSetParam(note, pid, v)
    local pad = Kit.pads[note]
    if not (pad and pad.path) then return end
    local f = KitFX.Field(pid)
    if not f then return end
    pad.p[pid] = v
    pad.fmt[pid] = nil
    KitFX.Set(fx_slot, note - Kit.BASE, f, KitFX.ToFX(pid, v))
    fx_dirty = true
end

-- Les defauts du JSFX, en positions de bouton. Ils DOIVENT dire la meme chose
-- que pad_defaults() dans le .jsfx : c'est le seul endroit du couple ou une
-- divergence ne se verrait pas — le son serait juste, l'affichage faux.
local FX_DEFAULT = {
    [0]  = nil,     -- volume : rempli plus bas (0 dB)
    [1]  = 0.5,     -- pan centre
    [8]  = 4 / 64,  -- 4 voix
    [11] = 0,       -- obey note-offs : un pad est un one-shot
    [12] = 0,       -- loop
    [13] = 0,       -- start offset
    [14] = 1,       -- end offset
    [15] = 0.5,     -- tune : 0 demi-ton
    [17] = 1 / 127, -- velocite min
    [18] = 1,       -- velocite max
    [23] = 0,       -- loop start offset
    -- 0 dB, en POSITION DE BOUTON. Poser 1 ici voulait dire +12 dB, donc un
    -- pad neuf affichait « +12.0 dB » et le sixieme haut du bouton etait
    -- inerte : on redescendait a 0 dB sans que rien ne change dans le son.
    [25] = (0 - (-60)) / (12 - (-60)),
    [100] = 0,      -- portamento
    [101] = 0,      -- note-off release override
    [104] = 0, [105] = 0, [106] = 0,
    [107] = 1,      -- probabilite : toujours
    [108] = 0,      -- round-robin : desarme
    [110] = 0,      -- canal MIDI : tous
    [111] = 0,      -- mode chromatique : non
    [113] = 0,      -- xfade
}

function Kit.FXDefault(pid)
    if pid == 0 then return KitFX.FromPlain(0, 0) end          -- 0 dB
    if pid == 9 or pid == 10 then return KitFX.FromPlain(pid, 1) end   -- 1 ms
    if pid == 24 then return KitFX.FromPlain(24, 250) end      -- decay 250 ms
    if pid == 102 then return KitFX.FromPlain(102, 1) end
    if pid == 103 then return KitFX.FromPlain(103, 2) end      -- bend 2 st
    if pid == 109 then return 0 end                            -- pas de plancher
    -- La racine d'un pad neuf est SA note, pas do central : l'instrument pose
     -- NOTE_BASE + index, et rendre 60 pour les soixante-quatre faisait mentir
     -- l'ecran sur l'etat du moteur.
    if pid == 112 then return nil end
    if pid == 3 or pid == 4 then return nil end                -- pose au chargement
    return FX_DEFAULT[pid]
end

-- ---------------------------------------------------------------------------
-- Params
-- ---------------------------------------------------------------------------
function Kit.Param(note, pid)
    if Kit.IsFX() then return fxParam(note, pid) end
    local pad = Kit.pads[note]
    if not pad or not pad.fx then return nil end
    return r.TrackFX_GetParamNormalized(pad.track, pad.fx, pid)
end

function Kit.SetParam(note, pid, v)
    if Kit.IsFX() then return fxSetParam(note, pid, v) end
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
    if Kit.IsFX() then
        if not (pad and pad.path) then return "" end
        local v = fxParam(note, pid)
        if not v then return "" end
        local s = pad.fmt[pid]
        if s then return s end
        s = KitFX.Format(pid, v)
        pad.fmt[pid] = s
        return s
    end
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
    if Kit.IsFX() then
        local pad = Kit.pads[note]
        return (pad and pad.choke) or 0
    end
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
    if Kit.IsFX() then
        local pad = Kit.pads[note]
        if not (pad and pad.path) then return end
        pad.choke = grp
        KitFX.Set(fx_slot, note - Kit.BASE, KitFX.F.CHOKE, grp)
        fx_dirty = true
        fxSave()
        return
    end
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
    if Kit.IsFX() then
        -- LE CONFLIT QUI EXISTAIT ICI N'EXISTE PLUS, et il vaut la peine de
        -- dire pourquoi : sur le RS5K, boucler ET choker se disputaient le
        -- meme « obey note-offs », parce que le choke coupait en fabriquant
        -- une note-off. Le JSFX coupe la voix directement. Boucler ne veut
        -- donc plus rien dire d'autre que boucler.
        fxSetParam(note, Kit.P.LOOP, on and 1 or 0)
        fxSave()
        return
    end
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
    if Kit.IsFX() then
        local v = fxParam(note, pid)
        return v and KitFX.ToPlain(pid, v) or nil
    end
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
    if Kit.IsFX() then
        local n = KitFX.FromPlain(pid, v)
        if n then fxSetParam(note, pid, n) end
        return
    end
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
    if Kit.IsFX() then return KitFX.FromPlain(pid, v) end
    local pad = Kit.Pad(note)
    if not (pad and pad.fx) then return nil end
    return plainNorm(pad.track, pad.fx, pid, v)
end

-- Current shift in semitones (0 while no ReaPitch exists — nothing is
-- created by reading).
function Kit.PadPitch(note)
    -- PAS ENCORE SUR LE JSFX, ET ON REND ZERO PLUTOT QUE DE MENTIR. Le pitch
    -- a duree constante demande un etirement, que l'instrument ne fait pas :
    -- TUNE (Kit.P.TUNE) transpose en changeant la duree, comme un vinyle.
    -- L'etirement hors ligne existe deja ailleurs (Warp) et c'est la qu'il
    -- faudra le brancher, pas dans le fil audio d'un PC de 2005.
    if Kit.IsFX() then return 0 end
    local pad = Kit.Pad(note)
    if not pad then return 0 end
    local fx, pi = padReaPitch(pad, false)
    if not fx then return 0 end
    return plainOf(pad.track, fx, pi) or 0
end

function Kit.SetPadPitch(note, st)
    if Kit.IsFX() then return end
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
    -- Sur le JSFX, la crete vient de l'instrument lui-meme : il n'y a plus de
    -- piste par pad dont on pourrait lire le VU. C'est le meme chiffre, pris
    -- une case avant.
    if Kit.IsFX() then
        local pad = Kit.pads[note]
        if not (pad and pad.path) then return 0 end
        return KitFX.Peak(fx_slot, note - Kit.BASE)
    end
    local pad = Kit.pads[note]
    if not pad or not pad.path then return 0 end
    if not valid(pad.track) then return 0 end
    local a = r.Track_GetPeakInfo(pad.track, 0)
    local b = r.Track_GetPeakInfo(pad.track, 1)
    if b > a then a = b end
    return a
end

-- LE CANAL RESERVE N'A PLUS DE RAISON D'ETRE, et il vaut la peine de dire
-- laquelle il avait : StuffMIDIMessage etant un broadcast, une note d'apercu
-- arrivait partout et il fallait apprendre aux autres a l'ignorer. Le canal
-- etait ce mot manquant. Une note adressee n'a plus besoin de se signaler ;
-- il ne survit que pour le repli sans moteur, qui reste un broadcast.
Kit.UI_CHAN = 15                        -- MIDI channel 16, 0-based in the status byte

-- Valeur d'entree « MIDI, toutes entrees, tous canaux ». Elle etait POSEE DE
-- FORCE sur le bus a la creation, ce qui faisait du kit un aspirateur : toute
-- source MIDI du systeme y entrait, sans que rien ne l'ait demande. Elle reste
-- ici parce qu'un utilisateur peut vouloir exactement ca, et que c'est alors
-- son choix — Kit.SetInputAll l'ecrit, sur demande.
-- `INPUT_UI_ONLY` (canal 16 du clavier virtuel) vivait a cote. Il servait au
-- Looper a retrecir l'entree du bus pendant qu'il monitorait lui-meme une lane,
-- sans quoi une touche jouee atteignait le kit deux fois : en direct, et par le
-- routeur. Le routeur n'existe plus, et personne ne l'appelait plus.
Kit.INPUT_ALL     = 4096 + (63 << 5)            -- MIDI, any channel, any input

-- OU VA CE QU'ON JOUE. Les pads et l'instrument chromatique sont deux
-- instruments sur deux pistes ; celui qui est A L'ECRAN est celui qu'on joue.
-- Ce n'est plus un arbitrage (les deux entendaient le meme broadcast, il en
-- fallait un), c'est une simple adresse.
playTarget = function()
    -- Un kit JSFX n'a pas de bus : la piste du kit porte l'instrument, donc
    -- c'est elle qu'on joue. C'etait le dernier endroit ou « le kit » et « la
    -- piste qui sonne » etaient deux objets differents.
    if Kit.IsFX() then
        return valid(Kit.parent) and Kit.parent or nil
    end
    if Kit.mode == "instrument" then
        local t = Kit.instr and Kit.instr.track
        return valid(t) and t or nil
    end
    return valid(Kit.bus) and Kit.bus or nil
end

-- Une note jouee ICI : port du moteur -> piste du kit, pre-FX -> choke JSFX ->
-- envois -> RS5K des pads. Elle traverse donc la chaine d'effets du pad, ce qui
-- est la seule reponse honnete a « fais-moi entendre ce pad » : ce qu'on entend
-- au clic est ce que le pad sonne.
function Kit.PlayNote(note, on, vel)
    Notes.SetTrack(playTarget())
    if on then
        -- Le repli n'a pas d'adresse : il garde le canal reserve, qui est tout
        -- ce qu'un broadcast peut offrir en guise de destinataire.
        if Notes.IsTargeted() then Notes.On(note, vel)
        else Notes.On(note, vel, Kit.UI_CHAN) end
    else
        if Notes.IsTargeted() then Notes.Off(note)
        else Notes.Off(note, Kit.UI_CHAN) end
    end
end

-- Tout relacher, et rendre la sortie. A appeler a la fermeture de la fenetre :
-- un apercu permanent laisse sur la piste de l'utilisateur survivrait au script.
function Kit.PlayClose() Notes.Close() end

-- ---------------------------------------------------------------------------
-- L'ARMEMENT — UNE LECTURE, PLUS UNE VOLONTE
-- ---------------------------------------------------------------------------
-- Il y avait ici un `Kit.arm_intent` et un `Kit.HoldArm()` appele a chaque
-- poll, qui reecrivaient I_RECARM/I_RECMON des que REAPER les avait bouges. Ce
-- n'etait pas de la robustesse, c'etait une competition : l'utilisateur armait
-- une piste, REAPER desarmait la notre en changeant de selection, et nous la
-- rearmions dans la foulee. Les deux etats du projet s'ecrasaient a tour de
-- role et personne ne pouvait dire lequel gagnerait.
--
-- Ce que ca achetait : un clic de pad audible, parce que le broadcast n'atteint
-- qu'une piste armee en monitoring. Ca ne l'achete plus — le clic a une adresse
-- — donc l'armement redevient ce que REAPER en dit : « cette piste enregistre
-- et se monitore ». On le LIT, et on ne l'ecrit que si on nous le demande.
function Kit.Armed()
    local tr = playTarget()
    if not tr then return false end
    return r.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
       and r.GetMediaTrackInfo_Value(tr, "I_RECMON") > 0
end

-- Un geste, une ecriture. On ne touche PAS a l'autre instrument : desarmer une
-- piste que l'utilisateur a armee lui-meme n'est pas de notre ressort, et il n'y
-- a plus de raison technique de le faire.
function Kit.SetArmed(on)
    if Kit.mode == "instrument" then
        Kit.EnsureInstrument()
    elseif not valid(Kit.bus) then
        if not valid(Kit.parent) then return end
        Kit.EnsureBus()
    end
    local tr = playTarget()
    if not tr then return end
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", on and 1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", on and 1 or 0)
    -- notre propre ecriture ne doit pas ressembler a un changement externe du
    -- projet, sinon le prochain Poll rescanne tout le kit pour rien
    last_change = r.GetProjectStateChangeCount(0)
end

-- « Ecoute tout ce qui entre », sur demande. C'etait le reglage impose ; c'est
-- desormais un geste, et il porte son nom. Il n'a pas de reciproque : « quelle
-- entree sinon » n'a pas de reponse par defaut, et c'est le selecteur d'entree
-- de REAPER qui la donne — un menu de plus ici ne ferait que la redire moins
-- bien.
function Kit.SetInputAll()
    local tr = playTarget()
    if not tr then return end
    r.SetMediaTrackInfo_Value(tr, "I_RECINPUT", Kit.INPUT_ALL)
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
    last_change = r.GetProjectStateChangeCount(0)
end

function Kit.InputIsAll()
    local tr = playTarget()
    if not tr then return false end
    return r.GetMediaTrackInfo_Value(tr, "I_RECINPUT") == Kit.INPUT_ALL
end

-- One-shot migration + self-heal: move a legacy choke off the folder parent,
-- drop the feedback-muted parent→pad sends, and guarantee exactly one MIDI
-- send bus → every pad.
--
-- IT NO LONGER DISARMS ANYTHING. It used to disarm the folder parent and every
-- pad track, on the grounds that arming them had been a user workaround for
-- the muted sends. Perhaps it was — but a repair pass that silently rewrites
-- record-arm across a dozen tracks is exactly the behaviour this chantier is
-- removing, and the workaround it undoes has been unnecessary since the sends
-- were fixed. What it fixes now is routing, which is what it is for.
function Kit.Repair()
    -- RIEN A REPARER SUR UN INSTRUMENT. Cette fonction remet d'aplomb les
    -- envois MIDI du bus vers les pistes des pads ; un kit JSFX n'a ni bus,
    -- ni envoi, ni piste de pad, et elle partait sur un bus nil.
    if Kit.IsFX() then repaired = true return end
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
    -- Sur l'instrument il n'y a qu'un effet, et c'est lui qu'on ouvre : le pad
    -- n'a plus de fenetre a lui parce qu'il n'a plus d'effet a lui.
    if Kit.IsFX() then
        if valid(Kit.parent) and fx_index then
            r.TrackFX_Show(Kit.parent, fx_index, 3)
        end
        return
    end
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
-- Migration RS5K -> instrument
-- ---------------------------------------------------------------------------
-- ELLE N'EFFACE RIEN, ET C'EST LE POINT. La migration du 1er aout supprimait
-- les pistes qu'elle croyait avoir vidées : elle verifiait que le geste avait
-- eu lieu, pas qu'il avait marche, et des pads ont perdu leur echantillon.
-- Celle-ci CONSTRUIT A COTE. Le kit d'origine reste entier, muet de rien, et
-- c'est Cedric qui le supprime quand il a entendu que le nouveau sonne.
--
-- Elle rend un compte-rendu plutot qu'un booleen : combien de pads ont ete
-- lus, combien PORTENT REELLEMENT de la matiere dans l'instrument, et
-- lesquels manquent. « Le pad sonne-t-il » est la seule question qui vaille.
function Kit.MigrateToFX()
    if Kit.IsFX() then return nil, "ce kit est deja un instrument" end
    if not valid(Kit.parent) then return nil, "aucun kit actif" end
    if not KitFX.Ready() then return nil, "gmem indisponible" end

    -- 1. Relever le kit source AVANT de toucher a quoi que ce soit.
    local src = {}
    for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.pads[note]
        if pad and pad.path then
            local p = {}
            for _, pid in ipairs(SAVE_PIDS) do
                local v = Kit.Param(note, pid)
                if v then p[pid] = v end
            end
            src[#src + 1] = { note = note, path = pad.path, name = pad.name,
                              p = p, choke = Kit.Choke(note) }
        end
    end
    if #src == 0 then return nil, "le kit source n'a aucun pad charge" end

    local _, oldname = r.GetSetMediaTrackInfo_String(Kit.parent, "P_NAME", "", false)
    local old_guid = r.GetTrackGUID(Kit.parent)

    -- 2. Construire le nouveau, A COTE.
    ubegin()
    local tr = Kit.NewKitFX(((oldname ~= "" and oldname) or "CP Kit") .. " (fx)")
    for _, e in ipairs(src) do
        fxLoadSample(e.note, e.path, { no_sync = true })
        local pad = Kit.pads[e.note]
        if pad then
            pad.name = e.name or pad.name
            for pid, v in pairs(e.p) do
                -- Les identifiants sont les memes des deux cotes : c'est
                -- exactement pour ce moment qu'on les a gardes.
                if KitFX.Field(pid) then fxSetParam(e.note, pid, v) end
            end
            if e.choke and e.choke > 0 then
                pad.choke = e.choke
                KitFX.Set(fx_slot, e.note - Kit.BASE, KitFX.F.CHOKE, e.choke)
            end
        end
    end
    fxSave()
    uend("Sampler: migrate kit to instrument")

    return { track = tr, source_guid = old_guid, asked = #src,
             pending = true, name = oldname }
end

-- Le verdict, une fois que l'instrument a eu le temps de lire les fichiers.
-- A appeler depuis la boucle de la fenetre tant que `pending` est vrai :
-- charger soixante-quatre echantillons prend plusieurs dixiemes de seconde,
-- et repondre avant serait repondre sur le geste.
function Kit.MigrationVerdict(report)
    if not (report and Kit.IsFX() and KitFX.Ready()) then return report end
    -- ON N'INTERROGE PAS UN TRAVAIL EN COURS. Tant qu'un pad attend sa
    -- matiere, « ce pad ne sonne pas » voudrait dire « pas encore », et un
    -- compte-rendu qui confond les deux ferait supprimer un kit qui allait
    -- tres bien.
    if Kit.FXLoading() > 0 then return report end
    local ok, missing = 0, {}
    for note = Kit.BASE, Kit.BASE + Kit.MAX - 1 do
        local pad = Kit.pads[note]
        if pad and pad.path then
            if KitFX.Loaded(fx_slot, note - Kit.BASE) then
                ok = ok + 1
            else
                missing[#missing + 1] = pad.name or ("Pad " .. note)
            end
        end
    end
    report.pending = false
    report.loaded = ok
    report.missing = missing
    return report
end

-- ---------------------------------------------------------------------------
-- Kit presets (paths + params, saved as plain Lua files)
-- ---------------------------------------------------------------------------

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
            -- SUR LE JSFX, LA LISTE EST PLUS LONGUE — et ecrire un preset
            -- du nouveau moteur avec la liste de l'ancien perdrait en
            -- silence exactement ce qu'il a de plus : portamento, obey,
            -- override du release, mute, solo, sortie.
            for _, pid in ipairs(Kit.IsFX() and Kit.FX_PIDS or SAVE_PIDS) do
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
