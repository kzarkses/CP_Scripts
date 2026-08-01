-- CP_Sampler — Kit
--
-- UN KIT EST UNE PISTE. Une seule.
--
-- Sa chaine d'effets porte le JSFX de choke, puis un ReaSamplOmatic5000 par
-- pad, et c'est tout le kit. Il n'y a plus de dossier « CP Kit », plus de piste
-- « CP Kit MIDI », plus une piste par pad : soixante-quatre pads pouvaient
-- faire soixante-cinq pistes dans le projet de quelqu'un qui voulait une
-- batterie, et c'est exactement le « bordel » qu'on a retire.
--
-- CE QUE LE REPLI A SUPPRIME PLUTOT QU'AJOUTE. Le fan-out d'envois MIDI
-- filtres vers les pads n'existait QUE parce que les pads etaient des pistes
-- separees. Dans une seule chaine, tous les RS5K voient le meme MIDI et chacun
-- ne repond qu'a SA plage de notes — le filtrage etait deja le sien. Les envois
-- ne faisaient que lui apporter ce qu'il allait de toute facon trier.
--
-- THIS IS NOT A LEFTOVER. Le moteur natif joue des VOIX : une position, un
-- taux, un gain, deux fondus lineaires. Un pad est un INSTRUMENT : ADSR
-- complet, groupes de choke resolus dans le fil audio, zones de velocite,
-- polyphonie par pad, transposition a duree constante par ReaPitch, et il
-- continue de sonner quand ce script est ferme et quand l'extension est
-- absente. Treize des dix-sept parametres utilises ici n'ont aucun equivalent
-- dans le moteur. La sortie propre est un plugin CLAP autour de src/core, pas
-- une migration a moitie.
--
-- IDENTITE D'UN PAD : SA PLAGE DE NOTES. lo == hi == la touche. C'est la seule
-- identite qui ne puisse pas mentir, parce que c'est elle qui decide sur quelle
-- touche il sonne ; un tag range a cote pouvait diverger de ce qu'on entendait.
-- Un pad qui a des effets a lui vit dans un CONTENEUR (REAPER 7) et son index
-- est alors encode — mais il se lit et s'ecrit comme les autres, donc le reste
-- du module ne sait pas lequel des deux il tient.
--
-- Identification, en P_EXT (dans le projet, sur du undo) :
--   le kit : P_EXT:CP_KIT = "1"
--   ce qu'un pad sait de lui-meme : P_EXT:CP_KIT_<CLE>_<note> sur le kit
--   l'instrument chromatique : P_EXT:CP_KIT_INSTR = "1", sur sa propre piste
--
-- MIDI flow — READ THIS ONE, it is the part that used to be incomprehensible.
--
-- TWO ROADS REACH THE KIT, AND THEY ARE NOT THE SAME ROAD.
--   1. What YOU play. A pad click, a key on the chromatic keyboard, a note
--      auditioned in the editor: CP_Engine/Notes writes it into ONE engine
--      port, and that port is poured into the kit track, pre-FX. Nothing else
--      in the project hears it. No track is armed for this, ever.
--   2. What the PROJECT plays. A recorded MIDI item on the kit track, a looper
--      lane routed here, a keyboard you monitor because you armed the track —
--      all of it is REAPER's own MIDI, arriving the way it arrives on any
--      instrument track.
-- Both land in the same chain: the choke JSFX, then every RS5K, each answering
-- to its own note.
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
-- CE QU'ON A PERDU, ET QUI EST ASSUME : le fader, le mute/solo et le VU PAR
-- PAD dans le mixer de REAPER. Les effets par pad, non — les conteneurs les
-- gardent. Pour le pad qui a vraiment besoin de sa tranche, l'eclatement vers
-- une piste est la reponse, et il sera explicite.
--
-- The chromatic INSTRUMENT is still a second instrument on a track of its own.
-- Le replier en pad (une plage de notes qui couvre le clavier) est la suite du
-- chantier 2 ; ce n'est pas fait, et c'est une refonte d'interface, pas de
-- routage.
--
-- RS5K param indices (verified against mpl_RS5K_manager_functions.lua):
--   0 vol · 1 pan · 3/4 note range · 8 max voices · 9 attack · 10 release
--   11 obey note-offs · 12 loop · 13/14 sample start/end · 15 tune
--   17/18 min/max vel · 23 loop offset · 24 decay · 25 sustain
--
-- This module owns PROJECT state only (no UI): CP_Sampler renders it, and
-- CP_SampleEditor dofiles it too (slice-to-pads) — keep it dependency-free.

local Kit = {}

local r  -- reaper, injected (Kit.init)

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

-- Les envois MIDI bus -> pad vivaient ici, avec leur masque de canal. Ils
-- n'existent plus : dans une seule chaine d'effets, chaque RS5K voit le meme
-- MIDI et ne repond qu'a sa plage de notes. Le filtrage etait deja le sien ;
-- les envois ne faisaient que lui apporter ce qu'il allait de toute facon
-- trier. Replier a donc SUPPRIME de la machinerie, pas deplace.

Kit.parent = nil       -- folder MediaTrack (validated on access)
Kit.bus    = nil       -- "CP Kit MIDI" child track — the kit's MIDI track.
                       -- CRITICAL: MIDI fan-out sends must come from a
                       -- separate child track, NOT the folder parent: a
                       -- parent→child send + the child's audio returning
                       -- through the folder is a feedback loop and REAPER
                       -- silently mutes the send (mpl's "MIDI bus" design
                       -- exists for exactly this reason).
Kit.pads   = {}        -- [note] = { track, fx, box, path, name, note, fmt = {} }
                       -- track = la piste du kit, fx = l'index de son RS5K
                       -- (encode quand il est dans un conteneur), box = ce
                       -- conteneur ou nil
Kit.legacy_bus = nil   -- l'ancienne piste « CP Kit MIDI », le temps du repli
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

-- Ce qu'un pad sait de lui-meme (tempo de source, sync, accord mis de cote).
-- Range sur la piste du kit, suffixe par la note — le corps vit avec la
-- synchro de tempo, plus bas, mais l'echange de pads en a besoin avant.
local padExt, setPadExt, padState, putState

local Tracks  -- optional Engine/Tracks module (common P_EXT:CP mark + folder)

function Kit.init(reaper_api, tracks_module)
    r = reaper_api
    Tracks = tracks_module
    SrcTempo.init(r)
    Voice.init(r)
    Notes.init(r, Voice, Voice.PLAY_PORT_SAMPLER)
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
-- LE RESCAN DIFFERE. Toute modification de STRUCTURE de la chaine (un pad qui
-- naît, un pad qu'on retire, une boite qu'on cree) decale l'index encode des
-- pads ranges en conteneur : les laisser perimes ferait ecrire un reglage dans
-- le mauvais pad. Il faut donc rescanner — mais une seule fois par geste, pas
-- soixante-quatre fois pendant le chargement d'un preset. Le rescan attend
-- donc la fin du bloc d'annulation, qui est exactement la definition d'un geste.
local rescan_due = false
local function ubegin()
    if undo_depth == 0 then r.Undo_BeginBlock() end
    undo_depth = undo_depth + 1
end
local function uend(desc)
    undo_depth = undo_depth - 1
    if undo_depth == 0 then
        r.Undo_EndBlock(desc, -1)
        if rescan_due then
            rescan_due = false
            Kit.Scan()
        end
        last_change = r.GetProjectStateChangeCount(0)
    end
end

local function rescan()
    if undo_depth > 0 then rescan_due = true return end
    Kit.Scan()
    last_change = r.GetProjectStateChangeCount(0)
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

-- ---------------------------------------------------------------------------
-- CONTENEURS (REAPER 7)
-- ---------------------------------------------------------------------------
-- Un conteneur est un effet qui en contient d'autres. On l'adresse par un index
-- ENCODE : 0x2000000 + (sous_index+1) * (nombre_d_effets_de_la_chaine + 1) +
-- (index_du_conteneur+1). Toutes les fonctions TrackFX_* l'acceptent, ce qui
-- veut dire qu'un pad dans un conteneur se lit et s'ecrit EXACTEMENT comme un
-- pad posé a plat : aucun appelant de ce module n'a a savoir lequel des deux
-- il regarde.
--
-- ATTENTION, ET C'EST LE PIEGE : l'encodage depend du NOMBRE d'effets de la
-- chaine. Ajouter un pad decale tous les index encodes des autres. Toute
-- modification de structure doit donc rescanner — c'est la regle, et elle est
-- appliquee par Kit.Scan appele en fin de chaque operation structurelle.
local FX_CONTAINER = 0x2000000

local function isContainer(tr, i)
    local ok = r.TrackFX_GetNamedConfigParm(tr, i, "container_count")
    return ok and true or false
end

-- Index encode du j-ieme effet (0-base) du conteneur a l'index `ci`. REAPER
-- 7.06+ le donne directement ; en dessous on refait le calcul a la main, ce
-- qui est la meme chose et evite de dependre d'une version pour une
-- multiplication.
local function containerItem(tr, ci, j)
    local ok, id = r.TrackFX_GetNamedConfigParm(tr, ci, "container_item." .. j)
    if ok and id and id ~= "" then
        local v = tonumber(id)
        if v then return math.floor(v) end
    end
    return FX_CONTAINER + (j + 1) * (r.TrackFX_GetCount(tr) + 1) + (ci + 1)
end

local function containerCount(tr, ci)
    local ok, n = r.TrackFX_GetNamedConfigParm(tr, ci, "container_count")
    return (ok and tonumber(n)) or 0
end

-- La plage de notes d'un RS5K, en notes MIDI. C'est LA VERITE d'un pad : ce
-- qui le fait sonner sur cette touche et pas une autre. On ne range donc pas
-- son numero a cote (une etiquette peut mentir, une plage de notes non).
local function noteRangeOf(tr, fx)
    local lo = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.NOTE_LO)
    local hi = r.TrackFX_GetParamNormalized(tr, fx, Kit.P.NOTE_HI)
    if not lo or not hi then return nil end
    return math.floor(lo * 127 + 0.5), math.floor(hi * 127 + 0.5)
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

-- LE CHOKE EST TOUJOURS PREMIER DE LA CHAINE, et il y reste.
--
-- C'est la seule piece capable de couper une note a l'echantillon tant que le
-- RS5K est le moteur, et elle doit voir le MIDI AVANT les pads : place apres,
-- elle couperait des notes que les RS5K ont deja jouees. `-1000` est la
-- position zero (voir TrackFX_AddByName : <= -1000 est une position, -1000 le
-- premier element). Elle est cachee : la grille de pads est l'interface.
local function ensureChoke(tr)
    if not valid(tr) then return nil end
    local fi = findChoke(tr)
    if not fi then
        if not ensureChokeFile() then return nil end
        fi = r.TrackFX_AddByName(tr, CHOKE_ADD, false, -1000)
        if fi < 0 then return nil end
        hideFX(tr, fi)
    elseif fi > 0 then
        -- Il existe mais pas en tete : un kit d'avant le portait sur le dossier,
        -- ou quelqu'un a range sa chaine a la main. Place apres un RS5K, il
        -- couperait des notes que celui-ci a deja jouees. On le remonte.
        if r.TrackFX_CopyToTrack(tr, fi, tr, 0, true) then fi = 0 end
    end
    choke_fx, choke_tr = fi, tr
    return fi
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

-- Le fichier charge dans un RS5K. FILE0 partout, FILE sur certains builds.
local function rs5kFile(tr, fx)
    local ok, fn = r.TrackFX_GetNamedConfigParm(tr, fx, "FILE0")
    if ok and fn ~= "" then return fn end
    ok, fn = r.TrackFX_GetNamedConfigParm(tr, fx, "FILE")
    if ok and fn ~= "" then return fn end
    return nil
end

-- L'ETIQUETTE d'un pad. Le nom de la piste faisait ce travail ; il n'y a plus
-- de piste par pad, donc c'est le nom renomme de l'effet — visible dans la
-- chaine de REAPER, ce qui est exactement ou on veut le lire quand on ouvre le
-- kit a la main.
local function fxLabel(tr, fx)
    local ok, nm = r.TrackFX_GetNamedConfigParm(tr, fx, "renamed_name")
    if ok and nm and nm ~= "" then return nm end
    return nil
end

local function setFxLabel(tr, fx, name)
    r.TrackFX_SetNamedConfigParm(tr, fx, "renamed_name", name or "")
end

-- UN PAD EST UN RS5K DANS LA CHAINE DU KIT, et son numero est SA PLAGE DE
-- NOTES. C'est la seule identite qui ne puisse pas mentir : c'est elle qui
-- decide sur quelle touche il sonne. Un tag range a cote pouvait diverger de
-- ce qu'on entendait ; ici la question ne se pose plus.
--
-- Un pad qui a des effets a lui vit dans un CONTENEUR : on descend d'un niveau
-- pour trouver son RS5K, et l'index encode qu'on garde se lit et s'ecrit comme
-- n'importe quel autre. Le reste du module ne sait pas lequel des deux il tient.
local function adoptPadFx(tr, fx, pads, box)
    local lo, hi = noteRangeOf(tr, fx)
    if not lo or lo ~= hi then return false end          -- chromatique, pas un pad
    if lo < Kit.BASE or lo >= Kit.BASE + Kit.MAX then return false end
    if pads[lo] then return false end                     -- premier arrive
    local path = rs5kFile(tr, fx)
    pads[lo] = {
        track = tr, fx = fx, box = box, path = path, note = lo,
        name = fxLabel(tr, box or fx) or (path and baseName(path)) or "",
        fmt = {},
    }
    return true
end

-- Toute la chaine du kit, une fois : le choke, puis les pads a plat et les
-- pads en conteneur.
local function scanChain(tr, pads)
    local n = r.TrackFX_GetCount(tr)
    for i = 0, n - 1 do
        if fxMatches(tr, i, "cp_kit_choke") then
            if not choke_fx then choke_fx, choke_tr = i, tr end
        elseif fxMatches(tr, i, "samplomatic") then
            adoptPadFx(tr, i, pads, nil)
        elseif isContainer(tr, i) then
            local cn = containerCount(tr, i)
            for j = 0, cn - 1 do
                local sub = containerItem(tr, i, j)
                if fxMatches(tr, sub, "samplomatic") then
                    adoptPadFx(tr, sub, pads, i)
                    break                 -- un conteneur = un pad
                end
            end
        end
    end
end

-- LA FORME D'AVANT : une piste par pad, taggee CP_KIT_NOTE, dans un dossier.
-- Elle n'est plus produite, mais elle existe dans les projets deja faits et
-- Kit.Fold la replie. On la reconnait donc encore — et uniquement pour ca.
local function scanLegacyPad(tr, pads, in_folder)
    local note = tonumber(getExt(tr, "CP_KIT_NOTE") or "")
    local fx = findRS5K(tr)
    if not note and in_folder and fx then
        local lo, hi = noteRangeOf(tr, fx)
        if lo and lo == hi then note = lo end
    end
    if not note or note < Kit.BASE or note >= Kit.BASE + Kit.MAX
       or pads[note] then
        return
    end
    local _, tname = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local path = fx and rs5kFile(tr, fx) or nil
    pads[note] = {
        track = tr, fx = fx, path = path, note = note, legacy = true,
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
    Kit.legacy_bus, choke_tr = nil, nil
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
        -- LE KIT EST LA PISTE. Sa chaine d'effets porte le choke puis les pads,
        -- et `Kit.bus` n'est plus une piste enfant : c'est la piste elle-meme.
        -- Le nom reste parce que tout le module parle du « bus » quand il veut
        -- dire « la ou le MIDI du kit arrive », et c'est toujours vrai.
        Kit.bus = Kit.parent
        scanChain(Kit.parent, pads)

        -- LA FORME D'AVANT, et uniquement pour la replier (Kit.Fold). Un
        -- dossier avec une piste par pad : on la lit encore, on ne la produit
        -- plus. `legacy = true` sur ces pads dit a tout le monde qu'ils sont en
        -- sursis — et Kit.Fold les fait passer dans la chaine.
        folderWalk(Kit.parent, function(tr)
            if getExt(tr, "CP_KIT_MIDI") then
                Kit.legacy_bus = tr
                if not choke_fx then
                    choke_fx = findChoke(tr)
                    choke_tr = choke_fx and tr or nil
                end
            elseif getExt(tr, "CP_KIT_INSTR") then
                scanInstrument(tr)
            else
                scanLegacyPad(tr, pads, true)
            end
        end)
        if not Kit.legacy_bus and #kits == 1 then
            for i = 0, count - 1 do
                local tr = r.GetTrack(0, i)
                if getExt(tr, "CP_KIT_MIDI") then Kit.legacy_bus = tr break end
            end
        end
        if not choke_fx and Kit.legacy_bus then
            choke_fx = findChoke(Kit.legacy_bus)
            choke_tr = choke_fx and Kit.legacy_bus or nil
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
function Kit.NewKit(name)
    name = (name and name ~= "") and name or "CP Kit"
    ubegin()
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
    if Tracks then Tracks.Mark(tr, "sampler", "kit") end
    setExt(tr, "CP_KIT", "1")
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)
    ensureChoke(tr)
    uend("Sampler: new kit " .. name)
    Kit.SetActive(tr)
    return tr
end

-- Adopt an existing kit: mark this track as a kit, make it the active one and
-- rescan. Works on mpl RS5K-manager kits and hand-built track-per-pad setups —
-- those arrive as a folder of pad tracks, and Kit.Fold pulls them into one
-- chain on the next poll. Other kits keep their tag: multi-kit is normal.
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
    -- Le kit a pu changer de forme (undo, edition manuelle, autre script) :
    -- la cible de jeu suit, et ce qui sonnait est relache la ou il sonnait.
    -- C'est tout ce que ce poll ecrit — plus aucun armement n'est reaffirme.
    Notes.SetTrack(playTarget())
    -- UNE FOIS PAR SESSION : le repli. Un kit construit avant le chantier 2 est
    -- un dossier plein de pistes ; Kit.Fold en fait une piste, en DEPLACANT ce
    -- qu'il contient et sans jamais supprimer une piste dont le contenu n'est
    -- pas arrive. Sur un kit deja replie, c'est une poignee de lectures.
    if not repaired then
        repaired = true
        if valid(Kit.parent) then Kit.Fold() end
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
-- LE KIT EST UNE PISTE ORDINAIRE, et c'est tout le chantier 2 en une phrase.
--
-- Il naissait dans le dossier partage « CP », en dossier lui-meme, avec une
-- piste enfant pour le MIDI et une piste enfant PAR PAD. Soixante-quatre pads,
-- c'etait jusqu'a soixante-cinq pistes dans le projet de quelqu'un qui voulait
-- une batterie. Maintenant : une piste, sa chaine d'effets, et rien d'autre.
--
-- Pas de dossier CP non plus : ce dossier existe pour ranger de
-- l'infrastructure, et un kit n'en est pas — c'est un instrument, il vit ou
-- l'utilisateur le pose. Il porte quand meme la marque commune (P_EXT:CP),
-- parce que la marque est la seule autorite de decouverte de la suite.
function Kit.Ensure()
    if valid(Kit.parent) then return Kit.parent end
    Kit.Scan()
    if valid(Kit.parent) then return Kit.parent end

    ubegin()
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Kit", true)
    if Tracks then Tracks.Mark(tr, "sampler", "kit") end
    setExt(tr, "CP_KIT", "1")
    r.SetMediaTrackInfo_Value(tr, "I_RECMODE", 0)   -- record MIDI input
    ensureChoke(tr)
    Kit.parent, Kit.bus = tr, tr
    Kit.version = Kit.version + 1
    uend("Sampler: create kit")
    return tr
end

-- Le « bus » et le kit sont la meme piste. La fonction reste parce que tout le
-- module parle du bus quand il veut dire « la ou le MIDI du kit arrive », et
-- que c'est toujours exact — seulement, l'endroit ou il arrive est desormais la
-- chaine d'effets du kit, pas une piste enfant.
function Kit.EnsureBus()
    return Kit.Ensure()
end

-- Reglages d'un RS5K qui vient de naitre en pad : sa touche, et le
-- comportement one-shot d'une batterie.
local function initPadFx(tr, fx, note)
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
    setFxLabel(tr, fx, "Pad " .. note)
end

-- UN PAD EST UN RS5K DE PLUS DANS LA CHAINE.
--
-- Le fan-out d'envois MIDI filtres a disparu avec les pistes enfants, et ce
-- n'est pas un compromis : dans une seule chaine, tous les RS5K voient le meme
-- MIDI et chacun ne repond qu'a SA plage de notes — c'est le RS5K lui-meme qui
-- filtre, comme il l'a toujours fait. Replier SUPPRIME de la machinerie.
--
-- Le rescan final n'est pas une precaution de style : ajouter un effet change le
-- nombre d'effets de la chaine, donc l'index encode de tout pad range dans un
-- conteneur. Les laisser perimes ferait ecrire un reglage dans le mauvais pad.
function Kit.EnsurePad(note)
    if note < Kit.BASE or note >= Kit.BASE + Kit.MAX then return nil end
    local pad = Kit.Pad(note)
    if pad then return pad end

    ubegin()
    local tr = Kit.Ensure()
    local fx = r.TrackFX_AddByName(tr, RS5K_ADD, false, -1)
    if fx < 0 then
        uend("Sampler: create pad " .. note)
        return nil
    end
    initPadFx(tr, fx, note)
    -- INSCRIT TOUT DE SUITE, sans attendre le rescan. LoadSample ouvre son
    -- propre bloc d'annulation autour de cet appel, donc le rescan est differe
    -- a la fin du geste : compter dessus rendrait `nil` a l'appelant qui vient
    -- de creer le pad. L'index est de toute facon juste — un effet ajoute EN
    -- BOUT de chaine ne decale aucun de ceux qui le precedent.
    local pad_new = { track = tr, fx = fx, box = nil, path = nil, note = note,
                      name = "Pad " .. note, fmt = {} }
    Kit.pads[note] = pad_new
    Kit.version = Kit.version + 1
    uend("Sampler: create pad " .. note)
    rescan()
    return Kit.pads[note] or pad_new
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
        local fx = r.TrackFX_AddByName(pad.track, RS5K_ADD, false, -1)
        if fx < 0 then
            uend("Sampler: load sample")
            return false
        end
        initPadFx(pad.track, fx, note)
        pad.fx = fx
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
    -- LE NOM DU PAD EST L'ETIQUETTE DE L'EFFET. C'etait le nom de la piste ;
    -- il n'y a plus de piste par pad, et renommer la piste du kit a chaque
    -- chargement d'echantillon serait absurde. Renomme dans la chaine, il se
    -- lit au meme endroit qu'avant : la ou on regarde quand on ouvre le kit.
    setFxLabel(pad.track, pad.box or pad.fx, pad.name)
    if newmat and not (opts and opts.keep_sync) then
        clearSyncState(note, pad)
        if not (opts and opts.no_sync) then autoSync(note) end
    end
    Kit.version = Kit.version + 1
    uend("Sampler: load " .. pad.name)
    return true
end

-- VIDER UN PAD, C'EST RETIRER SON RS5K DE LA CHAINE.
--
-- Il n'y a plus de piste a garder derriere : un pad vide est simplement un pad
-- qui n'est pas la. Si le pad avait un conteneur (donc des effets a lui), on
-- retire le conteneur entier — sinon on laisserait une boite d'effets orpheline
-- traiter du silence, et personne ne saurait plus a quoi elle appartenait.
--
-- Clear et Delete se rejoignent donc, et c'est la simplification qu'on
-- cherchait : sans piste par pad, « vider » et « supprimer » ne different plus.
local function removePadFx(pad)
    if not pad then return end
    if pad.box then
        r.TrackFX_Delete(pad.track, pad.box)
    elseif pad.fx then
        r.TrackFX_Delete(pad.track, pad.fx)
    end
end

function Kit.ClearPad(note)
    local pad = Kit.Pad(note)
    if not pad then return end
    ubegin()
    removePadFx(pad)
    Kit.pads[note] = nil
    Kit.version = Kit.version + 1
    uend("Sampler: clear pad")
    rescan()        -- les index encodes des autres pads ont bouge
end

function Kit.DeletePad(note)
    Kit.ClearPad(note)
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
    -- La plage de notes EST l'identite du pad : la deplacer suffit, et il n'y
    -- a plus de tag range a cote qui pourrait diverger de ce qu'on entend.
    local function assign(pad, note)
        if not pad then return end
        if pad.fx then
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.NOTE_LO, note / 127)
            r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.NOTE_HI, note / 127)
        end
        pad.note = note
        pad.fmt = {}
    end
    local sa, sb = padState(a), padState(b)
    assign(pa, b)
    assign(pb, a)
    Kit.pads[a], Kit.pads[b] = pb, pa
    Kit.SetChoke(a, gb or 0)
    Kit.SetChoke(b, ga or 0)
    -- L'identite de tempo appartient au SLOT elle aussi : elle voyage avec le
    -- pad, sinon un echange rendrait la boucle calee sur le tempo de l'autre.
    putState(b, sa)
    putState(a, sb)
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
-- CE QU'UN PAD SAIT DE LUI-MEME, ET OU C'EST RANGE
-- ---------------------------------------------------------------------------
-- Le tempo de source, le drapeau de sync et l'accord manuel mis de cote
-- vivaient dans le P_EXT de LA PISTE DU PAD. Il n'y a plus de piste par pad :
-- ils vivent maintenant sur la piste du kit, suffixes par la note. Toujours
-- dans le .RPP, toujours voyageant avec le projet, toujours lisibles par un
-- REAPER qui n'a rien de tout ceci installe.
--
-- La lecture retombe sur l'ancienne place quand elle ne trouve rien : un kit
-- pas encore replie doit continuer a sonner juste en attendant Kit.Fold.
local function padKey(note, key) return "CP_KIT_" .. key .. "_" .. note end

padExt = function(note, key)
    local kt = Kit.parent
    if valid(kt) then
        local v = getExt(kt, padKey(note, key))
        if v then return v end
    end
    local pad = Kit.pads[note]
    if pad and pad.legacy and valid(pad.track) then
        return getExt(pad.track, "CP_KIT_" .. key)
    end
    return nil
end

setPadExt = function(note, key, val)
    local kt = Kit.parent
    if valid(kt) then setExt(kt, padKey(note, key), val) end
    local pad = Kit.pads[note]
    if pad and pad.legacy and valid(pad.track) then
        setExt(pad.track, "CP_KIT_" .. key, val)
    end
end

-- L'identite de tempo d'un SLOT, prise et reposee d'un bloc (echange de pads,
-- repli). Trois champs, et les trois doivent voyager ensemble : garder le BPM
-- sans le drapeau de sync, ou l'inverse, produit un pad qui se re-accorde sur
-- un tempo qu'il n'a jamais eu.
local ST_KEYS = { "BPM", "SYNC", "TUNE0" }

padState = function(note)
    local st = {}
    for i = 1, #ST_KEYS do st[ST_KEYS[i]] = padExt(note, ST_KEYS[i]) end
    return st
end

putState = function(note, st)
    for i = 1, #ST_KEYS do
        setPadExt(note, ST_KEYS[i], (st and st[ST_KEYS[i]]) or "")
    end
end

-- ---------------------------------------------------------------------------
-- Tempo sync (refonte chantier 8): repitch a pad's loop to the project
-- tempo through the TUNE offset — rate follows pitch, the vinyl trade-off
-- the analysis accepted (true time-stretch is the bake's job).
-- ---------------------------------------------------------------------------
-- Stored BPM wins; everything else is a guess and is ranked as one. The store
-- is written when a tempo is DECIDED (the user typing one, autoSync engaging
-- sync) and cleared by LoadSample when the material changes.
function Kit.PadSrcBpm(note)
    local pad = Kit.Pad(note)
    if not pad then return nil end
    local stored = tonumber(padExt(note, "BPM") or "")
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
    if not Kit.Pad(note) then return end
    setPadExt(note, "BPM", bpm and tostring(bpm) or "")
end

function Kit.PadSynced(note)
    return Kit.Pad(note) ~= nil and padExt(note, "SYNC") == "1"
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
        setPadExt(note, "TUNE0", string.format("%.6f", cur))
        setPadExt(note, "SYNC", "1")
        applySync(note, pad, r.Master_GetTempo())
    else
        setPadExt(note, "SYNC", "")
        local t0 = tonumber(padExt(note, "TUNE0") or "")
        r.TrackFX_SetParamNormalized(pad.track, pad.fx, Kit.P.TUNE, t0 or 0.5)
        setPadExt(note, "TUNE0", "")
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
    setPadExt(note, "BPM", "")
end

-- Re-aim every synced pad at the given tempo. Cheap enough for the host
-- to call whenever Tempo reports a change (writes only on a real delta).
function Kit.ApplyTempoSync(project_bpm)
    if not project_bpm or project_bpm <= 0 then return end
    local wrote = false
    for note, pad in pairs(Kit.pads) do
        if pad.fx and padExt(note, "SYNC") == "1" then
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
    setPadExt(note, "BPM", string.format("%.3f", bpm))
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
    -- Une piste ordinaire, comme le kit : le dossier « CP » range de
    -- l'infrastructure, et un instrument n'en est pas.
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP Instrument", true)
    if Tracks then Tracks.Mark(tr, "sampler", "instrument") end
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

-- Renommer un pad. C'etait le nom de sa piste ; c'est l'etiquette de son effet
-- dans la chaine du kit — meme endroit dans l'interface de REAPER, meme role.
function Kit.SetPadName(note, name)
    local pad = Kit.Pad(note)
    if not pad then return end
    pad.name = name or ""
    setFxLabel(pad.track, pad.box or pad.fx, pad.name)
    Kit.version = Kit.version + 1
    last_change = r.GetProjectStateChangeCount(0)
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
        if not ensureChoke(Kit.EnsureBus()) then return end
        -- Il vient d'entrer EN TETE de chaine : tous les pads ont recule d'un
        -- cran, et un index encode perime ecrirait dans le mauvais pad.
        rescan()
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
-- UN REAPITCH PAR PAD, DONC DANS LA BOITE DU PAD.
--
-- Il etait ajoute a la chaine de la piste du pad, apres le RS5K, et c'etait
-- juste tant qu'un pad avait une piste. Pose maintenant dans la chaine du kit,
-- il transposerait TOUS les pads places apres lui — et le premier pad qu'on
-- accorde volerait sa hauteur a tous les suivants. Il vit donc dans le
-- conteneur du pad, qui est cree pour l'occasion : accorder un pad, c'est lui
-- donner des effets a lui.
local RP_ADD = "ReaPitch (Cockos)"

-- Ajouter un effet DANS un conteneur : REAPER ne sait pas le faire d'un coup.
-- On l'ajoute au bout de la chaine, puis on le DEPLACE a sa place dans la
-- boite — un aller-retour, et l'index encode de destination fait le reste.
local function addFxToBox(tr, box, addname)
    local tmp = r.TrackFX_AddByName(tr, addname, false, -1)
    if tmp < 0 then return nil end
    local at = containerCount(tr, box)
    local dest = containerItem(tr, box, at)
    if not r.TrackFX_CopyToTrack(tr, tmp, tr, dest, true) then
        r.TrackFX_Delete(tr, tmp)
        return nil
    end
    return containerItem(tr, box, at)
end

-- Le ReaPitch du pad : cherche dans sa boite, cree la boite si besoin.
local function padReaPitch(pad, create)
    if not (pad and valid(pad.track)) then return nil end
    local tr = pad.track
    local box = pad.box
    if not box then
        if not create then return nil end
        box = Kit.EnsurePadBox(pad.note)
        if not box then return nil end
        pad = Kit.Pad(pad.note)          -- le rescan a refait les index
        if not pad then return nil end
        tr, box = pad.track, pad.box
        if not box then return nil end
    end

    local fx = nil
    for j = 0, containerCount(tr, box) - 1 do
        local sub_i = containerItem(tr, box, j)
        local a, b = r.TrackFX_GetFXName(tr, sub_i, "")
        local nm = type(a) == "string" and a or b
        if nm and nm:find("ReaPitch", 1, true) then fx = sub_i break end
    end
    if not fx then
        if not create then return nil end
        fx = addFxToBox(tr, box, RP_ADD)
        if not fx then return nil end
        hideFX(tr, fx)
    end

    -- Bind the CONTINUOUS "Shift (full range)" slider, not the stepped
    -- integer "Shift (semitones)" one: a stepped param snaps every small
    -- knob drag back to the last whole value, which reads as a dead —
    -- then jumpy — knob. Semitones kept as a fallback for old ReaPitch
    -- builds that may name things differently.
    local full, semi
    for i = 0, r.TrackFX_GetNumParams(tr, fx) - 1 do
        local _, pn = r.TrackFX_GetParamName(tr, fx, i, "")
        local low = pn and pn:lower() or ""
        if not low:find("formant", 1, true) then
            -- no break: BOTH are needed (semitones comes after full range)
            if not full and low:find("full range", 1, true) then full = i end
            if not semi and low:find("semitone", 1, true) then semi = i end
        end
    end
    local best = full or semi
    if not best then return nil end
    -- One-shot migration: an earlier build drove the stepped slider —
    -- fold any leftover shift into the continuous param so the audible
    -- pitch and the knob agree again. DISPLAY units throughout: the raw
    -- values are normalized, where 0.5 (not 0) means "no shift".
    if full and semi and semi ~= full then
        local sv = plainOf(tr, fx, semi)
        if sv and math.abs(sv) > 0.005 then
            local cur = plainOf(tr, fx, full) or 0
            plainSet(tr, fx, full, cur + sv)
            plainSet(tr, fx, semi, 0)
        end
    end
    return fx, best
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

-- Le pad a-t-il de quoi transposer sans changer sa duree ? Une fenetre le
-- demande avant de proposer le reglage : creer un conteneur pour repondre
-- « zero » serait creer une boite pour rien.
function Kit.PadHasPitch(note)
    local pad = Kit.Pad(note)
    return pad ~= nil and padReaPitch(pad, false) ~= nil
end

function Kit.SetPadPitch(note, st)
    local pad = Kit.Pad(note)
    if not pad then return end
    local fx, pi = padReaPitch(pad, true)
    if not fx then return end
    pad = Kit.Pad(note) or pad        -- creer la boite a pu rescanner
    plainSet(pad.track, fx, pi, st)   -- clamps into the param's real bounds
    last_change = r.GetProjectStateChangeCount(0)
end

-- ---------------------------------------------------------------------------
-- Live helpers
-- ---------------------------------------------------------------------------
-- LA LUEUR D'UN PAD, ET CE QU'ELLE N'EST PLUS.
--
-- C'etait un VU : Track_GetPeakInfo sur la piste du pad. Les pads partagent
-- desormais la piste du kit, et REAPER ne mesure pas un effet, il mesure une
-- piste — le niveau d'un pad n'existe donc plus comme quantite lisible. C'est
-- la perte assumee du repli, avec le fader et le mute/solo par pad ; le geste
-- « eclater ce pad vers une piste » est la reponse pour celui qui en a besoin.
--
-- Ce qui reste est plus honnete qu'un VU faux : le niveau DU KIT, attribue au
-- pad dont on SAIT qu'il vient d'etre frappe. C'est un retour de geste, pas une
-- mesure — et il ne pretend rien sur les pads declenches par un item ou une
-- lane, qu'on ne voit pas passer. Le decay evite qu'un pad reste allume.
local HIT_S = 0.35
local hit_t = {}

-- Note jouee depuis cette fenetre : c'est le seul instant ou l'on sait quel pad
-- sonne. PlayNote l'appelle ; rien d'autre ne peut le savoir.
local function markHit(note)
    hit_t[note] = r.time_precise()
end

function Kit.PadPeak(note)
    local pad = Kit.pads[note]
    if not pad or not pad.path then return 0 end
    if not valid(pad.track) then return 0 end
    -- Un pad LEGACY a encore sa piste, donc son vrai VU : tant que le repli
    -- n'a pas eu lieu, on le rend plutot que de faire semblant.
    if pad.legacy then
        local a = r.Track_GetPeakInfo(pad.track, 0)
        local b = r.Track_GetPeakInfo(pad.track, 1)
        return (b > a) and b or a
    end
    local t0 = hit_t[note]
    if not t0 then return 0 end
    local age = r.time_precise() - t0
    if age > HIT_S then return 0 end
    local a = r.Track_GetPeakInfo(pad.track, 0)
    local b = r.Track_GetPeakInfo(pad.track, 1)
    if b > a then a = b end
    return a * (1 - age / HIT_S)
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
    if Kit.mode == "instrument" then
        local t = Kit.instr and Kit.instr.track
        return valid(t) and t or nil
    end
    -- Un kit pas encore replie a toujours son ancien bus, et c'est LUI qui
    -- porte le choke et les envois vers les pads : jouer dans la piste du
    -- dossier ne reveillerait rien. Kit.Fold supprime ce cas des le premier
    -- poll, mais la premiere frame existe aussi.
    if valid(Kit.legacy_bus) and Kit.legacy_bus ~= Kit.parent then
        return Kit.legacy_bus
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
        markHit(note)
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

-- ---------------------------------------------------------------------------
-- LE REPLI — d'un dossier plein de pistes vers une seule chaine d'effets
-- ---------------------------------------------------------------------------
-- Un kit deja construit est un dossier « CP Kit », une piste « CP Kit MIDI »
-- portant le choke, et une piste par pad portant un RS5K et parfois des effets.
-- Kit.Fold en fait une piste : le choke reste premier, chaque pad DEMENAGE dans
-- la chaine — dans un CONTENEUR quand il avait des effets a lui, a plat sinon.
--
-- UNE REGLE, ET ELLE COMMANDE TOUT LE RESTE : on ne supprime jamais une piste
-- dont le contenu n'a pas ete deplace avec succes. TrackFX_CopyToTrack en mode
-- MOVE rend le deplacement atomique du point de vue de REAPER ; si un seul
-- effet refuse de partir, la piste reste, avec tout ce qu'elle contient. Un
-- kit a moitie replie est reparable ; un kit a moitie supprime ne l'est pas.
--
-- Et jamais les deux formes en meme temps : un RS5K reste dans l'ancienne
-- piste ET un autre dans la chaine, ce serait le meme pad joue deux fois.
-- C'est pour ca que c'est un DEPLACEMENT et pas une copie.

-- Tous les effets d'une piste, deplaces dans un conteneur neuf du kit. Rend
-- l'index du conteneur, ou nil. Le conteneur porte le nom du pad : ouvrir la
-- chaine du kit doit dire ce qu'on regarde.
local function moveChainIntoBox(src, kit, label)
    local n = r.TrackFX_GetCount(src)
    if n <= 0 then return nil end
    local box = r.TrackFX_AddByName(kit, "Container", false, -1)
    if box < 0 then return nil end
    -- Toujours prendre le PREMIER de la source : chaque deplacement decale ce
    -- qui reste, et viser un index fixe raterait la moitie de la chaine.
    for j = 0, n - 1 do
        local dest = containerItem(kit, box, j)
        if not r.TrackFX_CopyToTrack(src, 0, kit, dest, true) then
            return box, false        -- partiel : l'appelant ne supprime rien
        end
    end
    if label then setFxLabel(kit, box, label) end
    return box, true
end

-- Un pad legacy vers la chaine du kit. `simple` (un seul effet, le RS5K) part a
-- plat ; tout le reste part dans un conteneur, ce qui preserve exactement les
-- effets par pad — c'est la raison d'etre des conteneurs ici.
local function foldOnePad(pad, kit)
    local src = pad.track
    if not valid(src) or src == kit then return true end
    local n = r.TrackFX_GetCount(src)
    if n <= 0 then return true end            -- rien a sauver, la piste peut partir
    if n == 1 and pad.fx == 0 then
        local dest = r.TrackFX_GetCount(kit)
        if not r.TrackFX_CopyToTrack(src, 0, kit, dest, true) then return false end
        setFxLabel(kit, dest, pad.name ~= "" and pad.name or ("Pad " .. pad.note))
        return true
    end
    local _, ok = moveChainIntoBox(src, kit, pad.name ~= "" and pad.name
                                              or ("Pad " .. pad.note))
    return ok == true
end

-- La piste d'un pad, une fois videe. Le pas de fermeture de dossier est repris
-- par le voisin du dessus, exactement comme le faisait DeletePad avant.
local function dropEmptyTrack(tr, parent)
    if not valid(tr) then return end
    if r.TrackFX_GetCount(tr) > 0 then return end   -- il reste quelque chose
    if r.CountTrackMediaItems(tr) > 0 then return end -- et des items encore plus
    local d = r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if d < 0 then
        local idx = trackIdx(tr)
        local prev = idx > 0 and r.GetTrack(0, idx - 1) or nil
        if prev then
            r.SetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH",
                r.GetMediaTrackInfo_Value(prev, "I_FOLDERDEPTH") + d)
        elseif valid(parent) then
            r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", d + 1)
        end
    end
    r.DeleteTrack(tr)
end

function Kit.Fold()
    local kit = Kit.parent
    if not valid(kit) then return false end

    -- Y a-t-il quoi que ce soit a replier ? LECTURES SEULES, pour qu'un kit
    -- deja replie paie une poignee de requetes une fois par session et n'ouvre
    -- aucun bloc d'annulation.
    local legacy, nlegacy = {}, 0
    for note, pad in pairs(Kit.pads) do
        if pad.legacy and valid(pad.track) and pad.track ~= kit then
            nlegacy = nlegacy + 1
            legacy[nlegacy] = { note = note, pad = pad }
        end
    end
    local bus = Kit.legacy_bus
    local has_bus = valid(bus) and bus ~= kit
    if nlegacy == 0 and not has_bus then return false end

    ubegin()

    -- 1. Le choke d'abord, pour qu'il soit PREMIER de la chaine avant que les
    --    pads n'arrivent derriere. Ses reglages SONT les groupes de choke de
    --    tout le kit : on ne recree pas une instance neuve, on recupere ceux-la.
    --    Et jamais deux instances — la seconde re-couperait ce que la premiere
    --    vient de laisser passer.
    if has_bus then
        local bc = findChoke(bus)
        if bc then
            local kc = findChoke(kit)
            if kc then
                for i = 0, Kit.MAX - 1 do
                    r.TrackFX_SetParamNormalized(kit, kc, i,
                        r.TrackFX_GetParamNormalized(bus, bc, i))
                end
                r.TrackFX_Delete(bus, bc)   -- sinon le bus ne serait jamais vide
            else
                r.TrackFX_CopyToTrack(bus, bc, kit, 0, true)
            end
        end
    end
    ensureChoke(kit)

    -- 2. Chaque pad, dans l'ordre des notes pour que la chaine se lise comme la
    --    grille. Un pad qui refuse de partir garde sa piste, et le repli
    --    reprendra a la prochaine session.
    table.sort(legacy, function(x, y) return x.note < y.note end)
    for i = 1, nlegacy do
        local e = legacy[i]
        local st = padState(e.note)          -- lu AVANT que la piste ne parte
        if foldOnePad(e.pad, kit) then
            putState(e.note, st)             -- repose sur la piste du kit
            dropEmptyTrack(e.pad.track, kit)
        end
    end

    -- 3. Le bus n'a plus de raison d'etre : il ne portait que le choke et les
    --    envois vers les pads, et les deux viennent de disparaitre. On ne le
    --    supprime que s'il est reellement vide — un utilisateur a pu y poser
    --    autre chose, et ce n'est pas a nous de le jeter.
    if has_bus then
        for si = r.GetTrackNumSends(bus, 0) - 1, 0, -1 do
            r.RemoveTrackSend(bus, 0, si)
        end
        dropEmptyTrack(bus, kit)
    end

    -- LE KIT CESSE D'ETRE UN DOSSIER TOUT SEUL, et il ne faut surtout pas
    -- l'aider : c'est dropEmptyTrack qui rend le pas de fermeture au voisin du
    -- dessus, donc au parent quand le DERNIER enfant part — et sa profondeur
    -- retombe alors a zero d'elle-meme. Forcer la profondeur ici avalerait la
    -- piste suivante du projet dans un dossier qui n'a rien demande, et il
    -- reste peut-etre une piste que l'utilisateur a rangee la exprès.

    uend("Sampler: fold the kit onto one track")
    if Tracks and Tracks.DropFolderIfEmpty then Tracks.DropFolderIfEmpty() end
    Kit.version = Kit.version + 1
    rescan()
    return true
end

-- `Kit.Repair` vivait ici. Elle reparait le routage d'avant : deplacer un choke
-- pose sur le dossier, retirer les envois parent -> pad que REAPER coupait pour
-- boucle, garantir un envoi bus -> pad par pad. Tout cela portait sur une
-- architecture qui n'existe plus, et Kit.Fold repare mieux : elle la supprime.

-- ---------------------------------------------------------------------------
-- LES EFFETS D'UN PAD — un conteneur, et seulement quand on en veut un
-- ---------------------------------------------------------------------------
-- Un pad a plat est un RS5K dans la chaine du kit : lui ajouter un effet le
-- mettrait sur le chemin de TOUS les pads suivants. Le conteneur est la boite
-- qui rend « les effets de CE pad » possible sans piste par pad — et il n'est
-- cree qu'a la demande, parce qu'une boite vide autour de chaque pad serait
-- soixante-quatre boites a regarder pour rien.
function Kit.PadHasBox(note)
    local pad = Kit.Pad(note)
    return pad ~= nil and pad.box ~= nil
end

function Kit.EnsurePadBox(note)
    local pad = Kit.Pad(note)
    if not pad or not pad.fx then return nil end
    if pad.box then return pad.box end
    ubegin()
    local tr = pad.track
    local box = r.TrackFX_AddByName(tr, "Container", false, -1)
    if box < 0 then
        uend("Sampler: pad FX box")
        return nil
    end
    local dest = containerItem(tr, box, 0)
    local moved = r.TrackFX_CopyToTrack(tr, pad.fx, tr, dest, true)
    if not moved then
        r.TrackFX_Delete(tr, box)
        uend("Sampler: pad FX box")
        return nil
    end
    setFxLabel(tr, box, pad.name ~= "" and pad.name or ("Pad " .. note))
    Kit.version = Kit.version + 1
    uend("Sampler: pad FX box")
    rescan()
    local p2 = Kit.Pad(note)
    return p2 and p2.box or nil
end

-- Ouvrir la boite d'un pad : c'est la ou on ajoute ses effets, avec la chaine
-- de REAPER, sans que ce module ait a savoir ce qu'on y met.
function Kit.ShowPadBox(note)
    local box = Kit.EnsurePadBox(note)
    if not box then return false end
    local pad = Kit.Pad(note)
    if pad then r.TrackFX_Show(pad.track, box, 3) end
    return true
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
