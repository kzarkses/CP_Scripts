-- CP_Engine / Loop.lua — engine bridge (no UI)
--
-- THE ROUTER TRACK IS GONE (roadmap phase 6).
--
-- This module used to own a dedicated, armed, input-monitored REAPER track
-- carrying CP_MidiLooper.jsfx, plus one channel-filtered MIDI send per lane,
-- and it talked to that JSFX through a shared gmem block whose map both sides
-- kept by hand. All of it is replaced by CP_Native: the lanes live in the
-- extension, each writes into its OWN port — a permanent preview poured into
-- its destination track, pre-FX — and this file is the wire.
--
-- What that removes, and it is not only tidiness:
--
--   * a track appearing in someone's project because they opened a window;
--   * the FOUR-COLUMN CEILING, which never came from MAX_LANES: it came from
--     the budget of sixteen MIDI channels on one router track. Ports are not
--     channels, and the engine now serves 32 lanes;
--   * gmem as a protocol — two copies of one memory map, and a constant wrong
--     on one side looked exactly like a Lua bug;
--   * the whole arm/disarm dance. The router had to be the ONE armed thing so
--     live input would not double-trigger; with it gone, monitoring is
--     REAPER's own, on the destination track, at zero added latency.
--
-- THE SURFACE DID NOT CHANGE. Every window calls the same functions it always
-- called. That is deliberate: a backend swap that also moves the furniture is
-- two changes debugged as one.
--
-- WHERE STATE LIVES NOW. The router track carried the recall blob and the lane
-- destinations in its P_EXT. With no track to carry them they move to
-- ProjExtState — still inside the .RPP, still travelling with the project,
-- still readable by a REAPER that has none of this installed.

local Loop = {}
local r = reaper

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
-- A musical TRACK is a PAIR of lanes: the half you hear and a silent twin, so
-- a clip change lands exactly on the quantize boundary.
--
-- SEIZE LANES = HUIT COLONNES (2026-08-02). Le moteur n'a jamais contraint ce
-- nombre — il en sert 32 — et ce n'est pas non plus l'ecran qui decide : c'est
-- LA CARTE DES PORTS, et huit est exactement son plafond.
--
--   audio  : port = t              → 0 .. TRACKS-1
--   MIDI   : port = PORT_BASE + t  → 8 .. 8+TRACKS-1
--
-- A TRACKS = 8 les deux plages se touchent sans se recouvrir (0..7 et 8..15) ;
-- a neuf, le son de la colonne 8 prendrait le port 8, qui est le MIDI de la
-- colonne 0. Aller plus loin demande donc de monter `PORT_BASE` a 16, et le
-- plafond devient alors 15 colonnes — au-dela, le MIDI atteint le port 31, qui
-- est l'audition partagee. Deux nombres, deux raisons, et aucune n'est
-- l'ecran : c'est ecrit ici parce que c'est ici qu'on viendra le changer.
--
-- ⚠️ LE PAS DE LA PAIRE EST LE NOMBRE DE COLONNES, donc il vient de bouger.
-- Tout ce qui est range PAR LANE dans un projet — les destinations `dest<lane>`
-- et le bloc de rappel — a ete ecrit avec l'ancien pas. `Loop.MigrateLayout`
-- et le format 8 s'en occupent ; ne pas toucher a l'un sans l'autre.
Loop.MAX_LANES   = 16
Loop.MAX_NOTES   = 1024
Loop.NOTE_STRIDE = 4       -- start, length, pitch, vel (kept: callers use it)
Loop.TRACKS      = Loop.MAX_LANES // 2

-- Which port a column's MIDI goes out on. Sound cells hold ports 0..TRACKS-1
-- (Engine/Cells) and the shared audition holds 31. BOTH halves of a pair use
-- the same port: a pair is one musical track, and a clip swap must not move the
-- sound to another instrument halfway through.
Loop.PORT_BASE = 8

-- ---------------------------------------------------------------------------
-- LA TROISIEME BANDE DE NUMEROS — les lanes du Looper, qui ne sont pas des cases
-- ---------------------------------------------------------------------------
-- `Ident` en declare deux : les tags POSITIONNELS d'avant (t*1000 + s + 1, donc
-- 1 .. 15008 meme a seize colonnes) et les IDENTITES (`Ident.BASE + n`, avec
-- n >= 1 et croissant). Une lane du Looper n'est ni l'une ni l'autre : elle n'a
-- pas de case, mais il lui faut un tag non nul pour que l'editeur sache y
-- revenir.
--
-- ⚠️ ELLE VALAIT `1000000 + lane`, ET C'ETAIT `Ident.BASE + lane`. La toute
-- premiere identite d'un projet est `BASE + 1` : la lane 1 du Looper portait
-- donc EXACTEMENT le meme numero que le premier clip cree dans la grille, et
-- deux clips repondaient a un seul tag. Le commentaire d'origine affirmait
-- l'inverse — « ne peut collisionner avec aucun autre » — ce qui est la
-- meilleure facon de ne jamais verifier.
--
-- La bande est donc SOUS `Ident.BASE`, ou le compteur ne peut par construction
-- jamais descendre, et au-dessus de tout tag positionnel possible : `Ident.Get`
-- la refuse (elle est sous BASE), `Ident.CellOf` la decode en colonne 999, qui
-- n'existe pas et ne peut pas exister — le plafond des ports est a quinze.
Loop.LANE_TAG_BASE = 999000

-- 1.7 and not 1.6: this file now reads CP_ClockPos, and an engine that predates
-- it does not merely lack a function — it anchors the transport on the
-- what-you-hear position, which puts every note out late by the device's output
-- latency. Running against it would sound broken while claiming to work, so the
-- honest answer is to decline the engine.
-- 2.4, et ce n'est pas de la prudence : ce fichier APPELLE des surfaces qui
-- n'existent qu'a partir de la. `CP_LaneSetNote` avec son septieme argument
-- (2.2), `CP_LaneSet(lane, "tsnum")` (2.3), `CP_LaneSet(lane, "umute")` (2.4).
-- Contre un moteur plus ancien, aucune de ces trois n'echoue bruyamment : la
-- probabilite est perdue, la signature de boucle ne prend pas, et le mute
-- musical ne tait rien. Trois fonctionnalites qui ont l'air de marcher. Refuser
-- le moteur est la seule reponse honnete, et les fenetres le DISENT deja.
local ABI_MIN = 2.4
local NATIVE  = false

local EXT_SEC    = "CP_Loop"
local DATA_KEY   = "data"
-- Combien de lanes le dernier ecrivain avait. Il n'existait pas avant le
-- 2026-08-02 : absent veut donc dire HUIT, la seule valeur qui ait jamais ete
-- livree. Ce marqueur est ce qui rend la remontee sure DANS LES DEUX SENS et
-- pour n'importe quel nombre futur — un simple « c'est ancien / c'est recent »
-- aurait recasse au changement suivant.
local LAYOUT_KEY    = "lanes"
local LEGACY_LANES  = 8
-- The mark the router track wore. It exists here for ONE reason: finding that
-- track in an old project so it can be read and then removed.
local LEGACY_TAG = "CP_LOOPER"

local Tracks  -- optional Engine/Tracks

-- ---------------------------------------------------------------------------
-- Lua-side note store
--
-- gmem used to BE the store: the JSFX played it and the editor wrote it. The
-- engine now holds a published copy it only ever reads, so the editable truth
-- has to live somewhere — here. Writing goes through publish(), which hands
-- the whole list over in one atomic swap; that is the contract the double
-- buffer needs, and it is what an editor does anyway.
-- ---------------------------------------------------------------------------
-- `pr` est la CHANCE DE JOUER en pourcent, 0..100. Cent est le defaut partout,
-- et il faut y penser a chaque ecriture : le moteur lit un octet dont le zero
-- veut dire « jamais », donc omettre le champ rend la lane muette au lieu de la
-- laisser telle quelle. C'est le seul champ de cette liste dont l'absence n'est
-- pas neutre.
local notes = {}          -- [lane] = { s={}, l={}, p={}, v={}, pr={}, n=0 }
local evtver = {}         -- [lane] = bumped on every change
local seen_recgen = {}    -- [lane] = the take generation we last acted on

local function store(lane)
    local t = notes[lane]
    if not t then
        t = { s = {}, l = {}, p = {}, v = {}, pr = {}, n = 0 }
        notes[lane] = t
    end
    return t
end

local function publish(lane)
    if not NATIVE then return end
    local t = store(lane)
    for i = 1, t.n do
        r.CP_LaneSetNote(lane, i - 1, t.s[i], t.l[i], t.p[i], t.v[i],
                         t.pr[i] or 100)
    end
    r.CP_LanePublish(lane, t.n)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function Loop.init(reaper_api, tracks_module)
    r = reaper_api
    Tracks = tracks_module
    -- A CAPABILITY, and a minimum rather than an equality: ReaPack has no
    -- dependency mechanism (measured: 89 indexes, 5993 packages, zero
    -- dependency element), so a script can perfectly well be installed
    -- without the binary, or with one that does not speak this language.
    NATIVE = (r.CP_EngineABI ~= nil) and (r.CP_EngineABI() >= ABI_MIN)
             and (r.CP_LaneCount ~= nil)
    Loop.track = nil
    for lane = 0, Loop.MAX_LANES - 1 do
        notes[lane] = nil
        evtver[lane] = 0
        seen_recgen[lane] = nil
    end
    Loop.reconnect()
end

-- ---------------------------------------------------------------------------
-- Destinations
--
-- A lane's destination is a project track, remembered by GUID in ProjExtState.
-- It used to be remembered on the router; there is no router, and a GUID in
-- the project is a better place for it anyway — it survives the track being
-- moved, renamed, or the window never being opened.
-- ---------------------------------------------------------------------------
Loop.dest = {}    -- [lane] = resolved MediaTrack or nil (UI cache)

-- Combien de fois les destinations ont ete relues. Un compteur, pas un
-- horodatage : une fenetre s'en sert pour savoir qu'une COLONNE a pu changer de
-- piste sans qu'elle ait rien demande — l'adoption automatique d'un slot libere
-- par la suppression d'une piste. Verifier a chaque frame couterait un GUID par
-- colonne, donc une chaine par colonne et par frame.
local dest_ver = 0
function Loop.DestVersion() return dest_ver end

local function valid(tr) return tr and r.ValidatePtr2(0, tr, "MediaTrack*") end

local function destKey(lane) return "dest" .. lane end

local function getDestGUID(lane)
    local _, g = r.GetProjExtState(0, EXT_SEC, destKey(lane))
    return g or ""
end

local function setDestGUID(lane, guid)
    r.SetProjExtState(0, EXT_SEC, destKey(lane), guid or "")
end

-- ---------------------------------------------------------------------------
-- LE PAS DE LA PAIRE — la seule regle de remontee, ecrite une fois
-- ---------------------------------------------------------------------------
-- Une lane basse `t` est la moitie VIVANTE de la colonne t ; la haute
-- `t + TRACKS` est sa jumelle silencieuse. Le pas vaut donc le nombre de
-- colonnes — et quand ce nombre change, TOUT ce qui est range par lane dans un
-- projet designe autre chose qu'avant.
--
-- Le mode d'echec est le pire qui soit : un projet ecrit a quatre colonnes range
-- ses jumelles en 4..7, la ou huit colonnes rangent les moities VIVANTES des
-- colonnes 4 a 7. Relu tel quel, il rend quatre colonnes muettes et quatre qui
-- rejouent la jumelle de quelqu'un d'autre. Rien ne plante, rien ne se dit.
--
-- `srcOfLane` repond a la question dans le bon sens : « cette lane-ci, ou
-- etait-elle ecrite ? ». Nil veut dire « cette colonne n'existait pas », ce qui
-- n'est pas la meme chose que « elle etait vide » — voir Deserialize.
local function srcOfLane(lane, old_lanes)
    local ot = old_lanes // 2
    if lane < ot then return lane end               -- moitie vivante, conservee
    if lane >= Loop.TRACKS then
        local k = lane - Loop.TRACKS
        if k < ot then return ot + k end            -- la jumelle d'alors
    end
    return nil
end

-- Et dans l'autre sens, pour ce qui ne designe QU'UNE lane (la lane armee).
local function newOfLane(lane, old_lanes)
    local ot = old_lanes // 2
    if lane < ot then return lane end
    local k = lane - ot
    return (k < Loop.TRACKS) and (Loop.TRACKS + k) or nil
end

-- ---------------------------------------------------------------------------
-- La remontee des DESTINATIONS. Le bloc de rappel porte son propre nombre de
-- lanes (format 8) et se relit donc sans etre reecrit ; les cles `dest<lane>`,
-- elles, n'ont nulle part ou le porter. On les deplace, une fois, et le
-- marqueur rend le geste idempotent — trois fenetres peuvent appeler ceci.
--
-- POURQUOI LE MARQUEUR S'ECRIT MEME QUAND IL N'Y A RIEN A BOUGER. Sans lui, un
-- projet cree par la version a huit colonnes serait relu comme un projet a
-- quatre — il a des cles `dest`, il n'a pas de marqueur — et on le remonterait
-- une seconde fois, ce qui le casserait pour de bon. Le marqueur ne dit pas
-- « ce projet a ete migre », il dit « ce projet a ete ecrit par une version qui
-- range comme ceci », et c'est la seule formulation qui tienne dans les deux
-- sens.
-- ---------------------------------------------------------------------------
function Loop.MigrateLayout()
    local _, v = r.GetProjExtState(0, EXT_SEC, LAYOUT_KEY)
    local old = math.floor(tonumber(v) or 0)
    if old == Loop.MAX_LANES then return false end
    if old <= 0 then old = LEGACY_LANES end
    local moved = false
    if old ~= Loop.MAX_LANES then
        -- ON LIT TOUT AVANT D'ECRIRE. Les deux plages se recouvrent des que le
        -- nombre de colonnes change, donc ecrire en avancant ecraserait la
        -- source de l'entree suivante.
        local g = {}
        for l = 0, old - 1 do g[l] = getDestGUID(l) end
        local hi = (old > Loop.MAX_LANES) and old or Loop.MAX_LANES
        for l = 0, hi - 1 do
            if getDestGUID(l) ~= "" then setDestGUID(l, "") end
        end
        for l = 0, Loop.MAX_LANES - 1 do
            local src = srcOfLane(l, old)
            local guid = src and g[src] or nil
            if guid and guid ~= "" then
                setDestGUID(l, guid)
                moved = true
            end
        end
    end
    r.SetProjExtState(0, EXT_SEC, LAYOUT_KEY, tostring(Loop.MAX_LANES))
    return moved
end

-- resolveGUID vivait ici et parcourait tout le projet pour UN identifiant.
-- Appele une fois par lane, il faisait seize balayages complets a chaque
-- rafraichissement. Loop.RefreshDests construit desormais la carte une fois et
-- lit dedans — meme resultat, un balayage.

-- What each column's port is CURRENTLY bound to. Not a cache for speed: a
-- rebind detaches the preview, which cuts whatever it was carrying. Rebinding
-- on every poll would have cut the MIDI twice a second, and the symptom
-- (stuttering notes, no error anywhere) is the kind you chase for an evening.
local bound = {}

local function bindPort(t, track, force)
    if not NATIVE then return false end
    if not force and bound[t] == (track or false) then return track ~= nil end
    local port = Loop.PORT_BASE + t
    -- Always DETACH first. The engine outlives the script, so a port left
    -- attached by a previous run would make the idempotent attach answer
    -- "already done" without rebinding — the same trap the audio cells fell
    -- into, and it costs an evening every time.
    r.CP_PortDetach(port)
    bound[t] = track or false
    if not valid(track) then
        r.CP_LaneBind(t, -1, 0)
        r.CP_LaneBind(t + Loop.TRACKS, -1, 0)
        return false
    end
    if not r.CP_PortAttach(track, port) then bound[t] = false return false end
    -- Channel 1 for every lane. Channels were how the router told lanes apart
    -- on ONE wire; each lane has its own wire now, so the channel goes back to
    -- meaning what a channel means — and an omni instrument hears it.
    r.CP_LaneBind(t, port, 0)
    r.CP_LaneBind(t + Loop.TRACKS, port, 0)
    return true
end

-- ---------------------------------------------------------------------------
-- A COLUMN IS A TRACK — and until now nothing said so.
--
-- A column used to exist whether or not anything was behind it: four of them,
-- always drawn, bound to nothing until someone opened a menu and routed them
-- by hand. Drop a sample into one and no sound came out, with no visible
-- reason. That is not a missing feature, it is a missing RELATION: the window
-- showed slots where the user reads tracks.
--
-- So the relation is stated. A column ADOPTS a project track, and remembers it
-- by GUID — the same `dest<lane>` key that already existed, because the storage
-- was never the problem. What is new is that an empty slot goes looking.
--
-- ADOPTION IS BY SLOT, DISPLAY IS BY TRACK ORDER. Two different things, and
-- keeping them apart is what makes this safe: a slot is a lane, it owns clips
-- and a port binding, so it must NOT move when the user reorders their tracks.
-- Only the drawing order follows the project. Reorder and nothing is cut;
-- delete a track and its slot is freed, the others keep their clips.
--
-- ELIGIBLE = a TOP-LEVEL track carrying no CP mark. A folder parent qualifies:
-- it has a fader, a chain and a meter, which is everything a destination needs.
-- A folder CHILD does not — it is that destination's internals, and audioDest
-- creates children itself, so accepting them would grow a column every time a
-- column played a sound. The suite's own infrastructure is excluded by its
-- mark, which Engine/Tracks declares the sole discovery authority.
-- ---------------------------------------------------------------------------
local order = {}          -- [i] = slot, sorted by project track order
local norder = 0

-- The suite's own tracks, for the ones that predate the shared mark. Engine
-- /Tracks is the discovery authority for everything born since, but a kit
-- built before it existed — or by a caller that had no Tracks module — is a
-- top-level, unmarked folder head, and it would walk straight into the grid as
-- a column. Three string reads per track, behind the same half-second debounce
-- as the rest of this.
local LEGACY_OWN = { "P_EXT:CP_KIT", "P_EXT:CP_KIT_INSTR", "P_EXT:" .. LEGACY_TAG }

local function eligible(tr)
    if r.GetParentTrack(tr) ~= nil then return false end
    -- UN KIT-INSTRUMENT EST UNE COLONNE COMME UNE AUTRE, et c'est tout le
    -- chantier 2 : il est devenu une piste ordinaire qui recoit du MIDI et
    -- fait du son. Il etait exclu parce qu'un kit-DOSSIER ne peut pas etre une
    -- colonne — le MIDI verse dans le parent n'atteint pas les pistes des
    -- pads. Cette raison a disparu avec les pistes des pads.
    local eok, eng = r.GetSetMediaTrackInfo_String(tr, "P_EXT:CP_KIT_ENGINE",
                                                   "", false)
    if eok and eng == "jsfx" then return true end
    if Tracks and Tracks.MarkOf and Tracks.MarkOf(tr) then return false end
    for i = 1, #LEGACY_OWN do
        local ok, v = r.GetSetMediaTrackInfo_String(tr, LEGACY_OWN[i], "", false)
        if ok and v ~= "" then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- UN SLOT QUI TIENT QUELQUE CHOSE NE SE FAIT PAS ADOPTER
-- ---------------------------------------------------------------------------
-- Supprimer la piste de la colonne 1 LIBERE son slot, et la premiere piste sans
-- colonne l'adoptait — en arrivant avec les huit clips de l'ancienne. Le
-- mecanisme d'adoption avait ete ecrit pour que les clips restent AU SLOT ; il
-- n'avait pas prevu qu'un slot libere change de piste.
--
-- ON N'EFFACE PAS, ON N'ADOPTE PAS. Effacer aurait ete plus simple et aurait
-- detruit du travail pour reparer un rangement ; ici le slot reste, ses clips
-- restent, et sa colonne se dessine en disant « no track » — ce qui est
-- exactement l'etat des choses, et ce que l'en-tete sait deja montrer. Cedric
-- la re-route ou la cache ; c'est son choix, pas celui d'un balayage.
--
-- Seul l'hote sait ce qu'un slot tient : `Loop` ne connait pas les cases.
local held = {}
function Loop.SetSlotHeld(t, on) held[t] = on and true or nil end
function Loop.IsSlotHeld(t) return held[t] == true end

-- Rebuilt in place, every refresh. No table is created here: this runs behind a
-- half-second debounce, but it runs for the life of the window.
local claimed = {}
local function syncColumns()
    local n = Loop.TRACKS
    for k in pairs(claimed) do claimed[k] = nil end
    for t = 0, n - 1 do
        local tr = Loop.dest[t]
        if tr then claimed[tr] = t end
    end

    -- Fill free slots, lowest first, with unclaimed eligible tracks in project
    -- order. A track already held by a slot keeps it — that is the whole point.
    local slot = 0
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        if not claimed[tr] and eligible(tr) then
            while slot < n and (Loop.dest[slot] or held[slot]) do slot = slot + 1 end
            if slot >= n then break end
            local guid = r.GetTrackGUID(tr)
            setDestGUID(slot, guid)
            setDestGUID(slot + n, guid)
            Loop.dest[slot] = tr
            Loop.dest[slot + n] = tr
            claimed[tr] = slot
        end
    end

    -- The drawing order: occupied slots, sorted the way the project reads.
    -- Built from the SLOTS and not from the tracks, so that two columns
    -- deliberately pointed at the same instrument both keep a place — walking
    -- the tracks would have silently dropped one of them.
    norder = 0
    for t = 0, n - 1 do
        if Loop.dest[t] then norder = norder + 1 order[norder] = t end
    end
    -- Insertion sort: at most a handful of columns, behind a half-second
    -- debounce. Anything cleverer would cost more to read than it saves.
    for a = 2, norder do
        local v  = order[a]
        local kv = r.GetMediaTrackInfo_Value(Loop.dest[v], "IP_TRACKNUMBER")
        local b  = a - 1
        while b >= 1
              and r.GetMediaTrackInfo_Value(Loop.dest[order[b]], "IP_TRACKNUMBER") > kv do
            order[b + 1] = order[b]
            b = b - 1
        end
        order[b + 1] = v
    end
    -- LES SLOTS ORPHELINS EN DERNIER, et apres le tri : ils n'ont pas de piste,
    -- donc pas de numero de piste, donc aucune place dans un ordre qui suit le
    -- projet. Les mettre a la fin les rend visibles sans pretendre savoir ou ils
    -- vont — et une colonne qu'on ne dessine pas est un travail qu'on croit
    -- perdu.
    for t = 0, n - 1 do
        if held[t] and not Loop.dest[t] then
            norder = norder + 1
            order[norder] = t
        end
    end
end

-- How many columns to draw, and which slot each one is. A window iterates
-- 1..ColumnCount() and asks ColumnAt(i) for the slot — the slot is what every
-- other call still takes, so nothing downstream learns a second vocabulary.
function Loop.ColumnCount() return norder end
function Loop.ColumnAt(i) return order[i] end

-- ONE PASS OVER THE PROJECT, NOT ONE PER LANE. resolveGUID walks every track
-- looking for one GUID; calling it for each of sixteen lanes made this
-- sixteen full sweeps, and it runs twice a second on a project the user is
-- editing. Building the map once turns 16xN into N.
local byguid = {}

function Loop.RefreshDests()
    -- LA REMONTEE DE DISPOSITION SE FAIT ICI, ET PAS A L'INITIALISATION. Un
    -- `defer` survit a un changement d'onglet de projet : la fenetre ouverte
    -- passe d'un projet a l'autre sans repasser par `init`, et le second serait
    -- donc lu avec la disposition du premier. Ce rafraichissement, lui, est
    -- rejoue des que le compteur d'etat du projet bouge — donc pour chaque
    -- projet que cette fenetre voit. Le marqueur rend l'appel gratuit : une
    -- lecture de ProjExtState, deux fois par seconde au plus.
    Loop.MigrateLayout()
    for k in pairs(byguid) do byguid[k] = nil end
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        byguid[r.GetTrackGUID(tr)] = tr
    end
    for lane = 0, Loop.MAX_LANES - 1 do
        local g = getDestGUID(lane)
        Loop.dest[lane] = (g ~= "") and byguid[g] or nil
    end
    syncColumns()
    for t = 0, Loop.TRACKS - 1 do bindPort(t, Loop.dest[t]) end
    dest_ver = dest_ver + 1
end

-- Kept for callers: there are no sends left to synchronise, only ports to
-- point at the right track. Healing the pair is still worth doing — projects
-- routed before the pairing existed have a twin pointing nowhere, which is why
-- they fell silent on every other launch.
function Loop.SyncSends()
    local n = Loop.TRACKS
    for t = 0, n - 1 do
        local g = getDestGUID(t)
        if getDestGUID(t + n) ~= g then setDestGUID(t + n, g) end
    end
    Loop.RefreshDests()
end

function Loop.reconnect()
    -- `RefreshDests` remonte la disposition avant de lire quoi que ce soit :
    -- lire les cles `dest<lane>` d'abord ferait adopter huit colonnes pointant
    -- sur quatre pistes, et l'adoption serait ecrite par-dessus l'ancienne.
    Loop.RefreshDests()
    return nil
end

function Loop.Reattach() end   -- there is no gmem block to re-select any more

function Loop.GetLaneDest(lane)
    local tr = Loop.dest[lane]
    if tr and not valid(tr) then Loop.dest[lane] = nil return nil end
    return tr
end

function Loop.TrackName()
    return nil     -- there is no router track to name
end

-- Route a TRACK to a destination instrument (nil = unroute). BOTH halves of
-- the pair go to the same instrument in one gesture: routing only the sounding
-- half looks fine until a clip swaps, and then the track goes silent for no
-- visible reason.
function Loop.SetLaneDest(lane, track)
    local t = Loop.TrackOfLane(lane)
    local guid = valid(track) and r.GetTrackGUID(track) or ""
    r.Undo_BeginBlock2(0)
    setDestGUID(t, guid)
    setDestGUID(t + Loop.TRACKS, guid)
    Loop.dest[t] = valid(track) and track or nil
    Loop.dest[t + Loop.TRACKS] = Loop.dest[t]
    bindPort(t, Loop.dest[t], true)
    r.Undo_EndBlock2(0, "CP Looper: route track " .. (t + 1), -1)
end

-- Create a fresh instrument track for a lane and route it there. Selects it so
-- the user can drop their synth on it.
function Loop.NewDestTrack(lane)
    r.Undo_BeginBlock2(0)
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, true)
    local tr = r.GetTrack(0, idx)
    local t = Loop.TrackOfLane(lane)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "Track " .. (t + 1) .. " inst", true)
    local guid = r.GetTrackGUID(tr)
    setDestGUID(t, guid)
    setDestGUID(t + Loop.TRACKS, guid)
    Loop.dest[t] = tr
    Loop.dest[t + Loop.TRACKS] = tr
    bindPort(t, tr, true)
    r.SetOnlyTrackSelected(tr)
    r.Undo_EndBlock2(0, "CP Looper: new instrument track", -1)
    return tr
end

-- ---------------------------------------------------------------------------
-- Kit view: the pads of the CP kit a lane is routed to, shaped like the Kit
-- module's surface so Rows.Build / Rows.Label can consume either.
-- ---------------------------------------------------------------------------
-- `mode` dit CE QU'EST le kit — « drum » ou « instrument ». Un editeur qui
-- ouvre un clip a besoin de le savoir : un kit de batterie se regarde en
-- rangees de pads, un instrument chromatique en clavier. Le champ voyage avec
-- les pads parce que c'est la meme question posee a la meme piste, et que
-- l'aller-retour est deja paye.
local kitview = { BASE = 0, MAX = 128, pads = {}, version = 0, n = 0,
                  mode = "drum" }
local kv_change, kv_lane = -1, -1

local function kitParentOf(tr)
    local hops = 0
    while tr and hops < 16 do
        local _, v = r.GetSetMediaTrackInfo_String(tr, "P_EXT:CP_KIT", "", false)
        if v and v ~= "" then return tr end
        tr = r.GetParentTrack(tr)
        hops = hops + 1
    end
    return nil
end

function Loop.KitViewOfTrack(tr)
    local c = r.GetProjectStateChangeCount(0)
    if c == kv_change and tr == kv_lane then
        return kitview.n > 0 and kitview or nil
    end
    kv_change, kv_lane = c, tr
    local pads, n = kitview.pads, 0
    for k in pairs(pads) do pads[k] = nil end
    kitview.mode = "drum"
    local parent = kitParentOf(tr)
    -- UN KIT JSFX N'A PAS D'ENFANTS. Ses pads vivent dans le miroir que Kit
    -- persiste sur la piste elle-meme (P_EXT:CP_KIT_PADS, un enregistrement
    -- par ligne : note, chemin, nom, reglages). Sans ce chemin, ouvrir un
    -- clip MIDI sur une colonne de kit ne montrait plus aucun nom de pad —
    -- la grille redevenait une grille de notes anonymes.
    if parent then
        local _, eng = r.GetSetMediaTrackInfo_String(parent,
                           "P_EXT:CP_KIT_ENGINE", "", false)
        -- SEUL UN KIT JSFX A UN GENRE. Sur l'ancien moteur, CP_KIT_MODE note
        -- quelle VUE le Sampler affichait en dernier — un reglage de fenetre,
        -- pose sur la piste faute d'un meilleur endroit. Le lire comme un genre
        -- ferait ouvrir en clavier les clips de batterie de tout projet qu'on a
        -- quitte sur la page instrument.
        if eng == "jsfx" then
            local _, md = r.GetSetMediaTrackInfo_String(parent,
                              "P_EXT:CP_KIT_MODE", "", false)
            if md == "instrument" then kitview.mode = "instrument" end
            local _, blob = r.GetSetMediaTrackInfo_String(parent,
                                "P_EXT:CP_KIT_PADS", "", false)
            for line in (blob or ""):gmatch("[^\n]+") do
                local note, _, nm = line:match("^(%d+)\t([^\t]*)\t([^\t]*)")
                note = tonumber(note)
                if note and note >= 0 and note <= 127 then
                    pads[note] = { fx = true, name = (nm ~= "" and nm) or "" }
                    n = n + 1
                end
            end
            kitview.n = n
            kitview.version = kitview.version + 1
            return n > 0 and kitview or nil
        end
        local i = math.floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
        local depth, cnt = 1, r.CountTracks(0)
        while depth > 0 and i < cnt do
            local ch = r.GetTrack(0, i)
            local _, nv = r.GetSetMediaTrackInfo_String(ch, "P_EXT:CP_KIT_NOTE", "", false)
            local note = tonumber(nv or "")
            if note and note >= 0 and note <= 127
               and r.TrackFX_GetCount(ch) > 0 then
                local _, nm = r.GetSetMediaTrackInfo_String(ch, "P_NAME", "", false)
                pads[note] = { fx = true, name = nm }
                n = n + 1
            end
            depth = depth + r.GetMediaTrackInfo_Value(ch, "I_FOLDERDEPTH")
            i = i + 1
        end
    end
    kitview.n = n
    kitview.version = kitview.version + 1
    return n > 0 and kitview or nil
end

function Loop.KitView(lane)
    return Loop.KitViewOfTrack(Loop.GetLaneDest(lane))
end

-- ---------------------------------------------------------------------------
-- Engine lifecycle
--
-- There is nothing to install, nothing to copy into an Effects folder, no
-- plugin instance that can be out of date with the script that drives it, and
-- no track to create. `Ensure` therefore asks one question — is the binary
-- here and does it speak our language — and it is honest when the answer is no.
-- ---------------------------------------------------------------------------
function Loop.IsAttached() return NATIVE end
function Loop.EngineAlive() return NATIVE end
function Loop.EngineLanes() return NATIVE and r.CP_LaneCount() or 0 end
function Loop.EngineBuild() return NATIVE and r.CP_EngineABI() or 0 end
Loop.ENGINE_BUILD = ABI_MIN
function Loop.EngineCurrent() return NATIVE end
function Loop.InitCount() return 0 end
function Loop.ReloadEngine() return NATIVE end

-- ---------------------------------------------------------------------------
-- MIGRATION — a project from the router era must LOSE that track, not keep it
--
-- This is not tidiness. An old project still carries CP_MidiLooper.jsfx on an
-- armed router track, and that JSFX still plays its lanes out of gmem. Leave
-- it there and the same set plays twice, from two engines, a few milliseconds
-- apart — which sounds like a broken instrument rather than like a leftover.
--
-- So the router is read, then removed: its recall blob and its lane
-- destinations move to ProjExtState, and the track goes. The CP folder goes
-- with it when nothing else is left inside.
--
-- Returns true when something was actually migrated, so the caller can say so.
-- ---------------------------------------------------------------------------
function Loop.MigrateLegacy()
    local router, moved = nil, false
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local _, mark = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. LEGACY_TAG, "", false)
        if mark == "router" then router = tr break end
    end
    if not valid(router) then return false end

    r.Undo_BeginBlock2(0)
    local _, blob = r.GetSetMediaTrackInfo_String(
        router, "P_EXT:" .. LEGACY_TAG .. "_DATA", "", false)
    local _, cur = r.GetProjExtState(0, EXT_SEC, DATA_KEY)
    if blob and blob ~= "" and (not cur or cur == "") then
        r.SetProjExtState(0, EXT_SEC, DATA_KEY, blob)
        moved = true
    end
    -- LA PISTE ROUTEUR RANGEAIT SES DESTINATIONS AU PAS DE HUIT LANES, et ce
    -- pas n'est plus le notre. Cette remontee-ci ne peut pas s'appuyer sur
    -- `MigrateLayout` : elle arrive APRES lui (le marqueur est pose des
    -- l'ouverture de la fenetre, la migration du routeur attend un `Setup`),
    -- donc elle doit traduire elle-meme ou elle n'aurait jamais lieu.
    for lane = 0, Loop.MAX_LANES - 1 do
        local src = srcOfLane(lane, LEGACY_LANES)
        if src then
            local _, g = r.GetSetMediaTrackInfo_String(
                router, "P_EXT:" .. LEGACY_TAG .. "_DEST" .. src, "", false)
            if g and g ~= "" and getDestGUID(lane) == "" then
                setDestGUID(lane, g)
                moved = true
            end
        end
    end
    r.DeleteTrack(router)
    if Tracks and Tracks.DropFolderIfEmpty then Tracks.DropFolderIfEmpty() end
    r.Undo_EndBlock2(0, "CP: retire the router track", -1)
    return true, moved
end

function Loop.Setup()
    if not NATIVE then
        return nil, "The CP engine extension is missing (or older than ABI "
                    .. ABI_MIN .. ")."
    end
    Loop.MigrateLegacy()
    -- "Point every unrouted column at the selected track" used to live here. It
    -- is now the opposite of the rule: a free column adopts a project track by
    -- itself, in project order, and pouring four of them into whichever track
    -- happened to be selected would undo that on the first setup.
    Loop.RefreshDests()
    Loop.SetFreeRun(true)
    Loop.AdoptArmedLane(nil)   -- nothing monitors until YOU arm something
    -- One bar, as in Ableton, and for the same reason: the launch quantize is
    -- what makes a clip swap, a scene and a TAKE land on the grid instead of
    -- wherever the mouse happened to be.
    Loop.SetLaunchQ(Loop.TsNum())
    return true
end

function Loop.Ensure(create)
    if not NATIVE then
        return false, "The CP engine extension is missing — MIDI lanes need it."
    end
    if create then
        local ok, err = Loop.Setup()
        if not ok then return false, err end
        return true, "Looper engine ready"
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- Commands
--
-- Everything written before the next audio block is drained TOGETHER: one
-- gesture is one block. Swapping a clip is two commands (stop this half,
-- launch that one) and a scene is one pair per column — trickled out one per
-- frame they could land on either side of a quantize boundary, and half a
-- scene starting a bar before the other half is not a quantize, it is a bug
-- with good manners.
-- ---------------------------------------------------------------------------
local function cmd(c, lane, arg)
    if NATIVE then r.CP_LaneCmd(lane or 0, c, arg or 0) end
end

function Loop.Rec(lane)      cmd(1, lane) end
function Loop.Stop(lane)     cmd(2, lane) end
function Loop.Clear(lane)
    Loop.SetLaneTag(lane, 0)
    local t = store(lane); t.n = 0
    publish(lane)
    evtver[lane] = (evtver[lane] or 0) + 1
    cmd(3, lane)
end
function Loop.Panic()        if NATIVE then r.CP_LanesPanic() end end
function Loop.Play(lane)     cmd(5, lane) end
function Loop.StopClip(lane) cmd(6, lane) end
function Loop.ClearAll()
    for l = 0, Loop.MAX_LANES - 1 do
        Loop.SetLaneTag(l, 0)
        local t = store(l); t.n = 0
        publish(l)
        evtver[l] = (evtver[l] or 0) + 1
    end
    cmd(7, 0)
end
function Loop.Overdub(lane)  cmd(8, lane) end

function Loop.ToggleRec(lane)
    if Loop.Pending(lane) == 3 then Loop.Rec(lane) return end
    local m = Loop.Mode(lane)
    if m == 1 or m == 4 or m == 5 then Loop.Stop(lane) else Loop.Rec(lane) end
end

function Loop.ToggleClip(lane)
    local p = Loop.Pending(lane)
    if p == 1 then Loop.StopClip(lane) return end
    if p == 2 then Loop.Play(lane) return end
    local m = Loop.Mode(lane)
    if m == 3 then Loop.StopClip(lane) elseif m == 2 then Loop.Play(lane) end
end

-- ---------------------------------------------------------------------------
-- Session settings
-- ---------------------------------------------------------------------------
function Loop.SetLaunchQ(beats) if NATIVE then r.CP_SetLaunchQ(beats or 0) end end
function Loop.GetLaunchQ()      return NATIVE and r.CP_GetLaunchQ() or 0 end
function Loop.SetFreeRun(on)    if NATIVE then r.CP_SetFreeRun(on and 1 or 0) end end
function Loop.GetFreeRun()      return NATIVE and r.CP_GetFreeRun() or false end

-- "Something of MINE is sounding" — said by a host that plays audio cells,
-- which the lane engine cannot see. The free clock is the SESSION's transport
-- and it sits at zero while the session is silent, so a sample playing with no
-- lane running would otherwise take its phase reference with it.
local audio_run = false
function Loop.SetAudioRun(on)
    audio_run = on and true or false
    if NATIVE then r.CP_SetAudioRun(audio_run and 1 or 0) end
end
function Loop.GetAudioRun() return audio_run end

-- ---------------------------------------------------------------------------
-- Monitoring
--
-- THE ARM IS REAPER'S NOW. The router had to be the one armed thing so a note
-- would not reach an instrument twice — directly, and again through a lane
-- send. With no router there is no second path, so monitoring goes back to
-- being what REAPER does: arm the destination track, hear it with no added
-- latency and no defer frame in the way.
--
-- Capture does NOT depend on it. MIDI_GetRecentInputEvent reads the global
-- input history, so a take records whether or not anything is armed — which
-- is one fewer state to be in the wrong one of.
-- ---------------------------------------------------------------------------
local armed_lane = nil

local function setMonitor(tr, on)
    if not valid(tr) then return end
    r.SetMediaTrackInfo_Value(tr, "I_RECARM", on and 1 or 0)
    r.SetMediaTrackInfo_Value(tr, "I_RECMON", on and 1 or 0)
end

-- UN GESTE, UNE ECRITURE. Cette fonction ecrit I_RECARM sur une piste du
-- projet : elle n'a donc le droit d'exister qu'au bout d'un clic. Tout ce qui
-- RESTITUE un etat (chargement de projet, relecture du blob) passe par
-- AdoptArmedLane et n'ecrit rien — meme discipline que le kit du sampler, et
-- pour la meme raison : un armement qu'on n'a pas demande est indistinguable
-- d'un armement qui se defend tout seul.
function Loop.SetArmedLane(lane)
    if armed_lane then setMonitor(Loop.GetLaneDest(armed_lane), false) end
    armed_lane = lane
    r.SetProjExtState(0, EXT_SEC, "armed", tostring(lane or -1))
    if lane then setMonitor(Loop.GetLaneDest(lane), true) end
end

-- Se SOUVENIR de la lane armee sans toucher a une seule piste. Ce que la
-- session avait note reste vrai si la piste l'est encore ; sinon la memoire est
-- simplement fausse, et une memoire fausse est moins couteuse qu'un projet qui
-- se rearme tout seul a l'ouverture.
function Loop.AdoptArmedLane(lane)
    armed_lane = nil
    if not lane then return end
    local tr = Loop.GetLaneDest(lane)
    if not valid(tr) then return end
    if r.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then armed_lane = lane end
end

function Loop.GetArmedLane()
    if armed_lane and armed_lane >= 0 and armed_lane < Loop.MAX_LANES then
        return armed_lane
    end
    return nil
end

-- Live listening is now a property of the armed track, so these two answer
-- from it. Kept because two windows drive them.
function Loop.SetListen(on)
    if not on then Loop.SetArmedLane(nil) end
end

function Loop.GetListen()
    local tr = armed_lane and Loop.GetLaneDest(armed_lane)
    if not valid(tr) then return false end
    return r.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
end

-- ---------------------------------------------------------------------------
-- Per-lane control
-- ---------------------------------------------------------------------------
function Loop.SetLengthBars(lane, bars)
    if NATIVE then r.CP_LaneSet(lane, "bars", bars or 1) end
end
function Loop.GetLengthBars(lane)
    if not NATIVE then return 1 end
    local b = r.CP_LaneGet(lane, "bars")
    return (b and b > 0) and b or 1
end
-- ---------------------------------------------------------------------------
-- LE MUTE, ET LES DEUX INTENTIONS QU'IL PORTAIT
-- ---------------------------------------------------------------------------
-- Ce mute-la a longtemps voulu dire DEUX choses a la fois, et c'est ce qui
-- rendait le defaut « une lane mutee dans le Looper coupe son MIDI mais pas sa
-- case audio » impossible a corriger sans en fabriquer un pire :
--
--   MECANIQUE — « le MIDI de cette lane ne doit pas sortir ». CP_Session s'en
--   sert pour une case AUDIO : elle arme une lane d'une seule note (le portail
--   de la voix) et la mute pour que cette note ne parte pas dans l'instrument
--   de la colonne. Ce n'est pas un geste musical, c'est du cablage.
--
--   MUSICALE — « tais cette lane ». C'est le bouton du Looper, et il doit taire
--   TOUT ce que la lane produit : le MIDI, et la voix de la case audio, qui est
--   une voix et non une lane.
--
-- Brancher les voix sur le mute unique aurait rendu TOUTE case audio
-- silencieuse, puisque toutes portent le mute mecanique. Les deux vivent donc
-- separement ici, et le moteur recoit leur OU — il n'a qu'une case a cocher, et
-- il n'a pas a savoir pourquoi.
--
-- Le moteur n'apprend rien de neuf : la separation est entierement Lua, parce
-- que c'est ici que les deux intentions se rencontrent.
-- ⚠️ LES DEUX INTENTIONS VIVENT DANS LE MOTEUR (ABI 2.4), PAS ICI.
--
-- La premiere version les tenait dans deux tables Lua de ce fichier, et c'etait
-- FAUX pour une raison qui ne se voit pas a la relecture : `Loop.lua` est charge
-- SEPAREMENT par chaque fenetre — trois ReaScript, trois etats Lua, trois paires
-- de tables — alors que la lane est UNE. Chaque fenetre recomposait donc le OU a
-- partir de la seule moitie des gestes qu'elle avait vue, et l'ecrivait
-- par-dessus celle de l'autre :
--
--   · le mute du Looper n'atteignait jamais la voix de la case audio de la
--     Session — c'est-a-dire exactement le defaut que la separation corrigeait ;
--   · et `armLane`, en posant son mute mecanique, effacait le mute musical qu'un
--     autre script venait de poser.
--
-- Un fait partage se range la ou il est partage. Le moteur fait le OU ; ici il
-- ne reste que deux ecritures et deux lectures, sans etat.
function Loop.SetMute(lane, on)
    if NATIVE then r.CP_LaneSet(lane, "mute", on and 1 or 0) end
end

-- L'intention MUSICALE — le bouton du Looper. `Cells` la lit pour taire la voix
-- de la case audio de la meme colonne : c'est la moitie qui manquait.
--
-- ELLE VAUT POUR LA PAIRE ENTIERE. La bande du Looper montre une PISTE, pas une
-- lane, et la moitie vivante bascule sur sa jumelle a chaque echange de clip :
-- n'ecrire que celle qu'on voit ferait disparaitre le mute au premier
-- changement de case, sans que personne n'ait rien demande.
function Loop.SetUserMute(lane, on)
    if not NATIVE then return end
    local n = Loop.TRACKS
    local a = (lane or 0) % n
    r.CP_LaneSet(a, "umute", on and 1 or 0)
    r.CP_LaneSet(a + n, "umute", on and 1 or 0)
    -- IL EST PERSISTE (format 10), DONC IL SALIT. L'autosave ne surveille que
    -- les notes et le mode : sans ceci, un mute pose puis sauve avec le projet
    -- n'etait tout simplement pas ecrit.
    Loop.MarkDirty()
end

-- RESTITUER N'EST PAS UN GESTE. Le rappel repose le mute musical sans salir
-- l'etat — sinon charger un projet declencherait aussitot une reecriture de ce
-- qu'on vient de lire — et sans propager a la paire, parce que le blob dit
-- lane par lane ce que chacune valait. Meme raison, meme forme que
-- `Loop.AdoptArmedLane`.
function Loop.AdoptUserMute(lane, on)
    if NATIVE then r.CP_LaneSet(lane, "umute", on and 1 or 0) end
end

function Loop.GetUserMute(lane)
    return NATIVE and r.CP_LaneGet(lane, "umute") >= 0.5
end
function Loop.GetMechMute(lane)
    return NATIVE and r.CP_LaneGet(lane, "mute") >= 0.5
end

-- Ce que le moteur fait EFFECTIVEMENT, c'est-a-dire le OU des deux.
function Loop.GetMute(lane)
    if not NATIVE then return false end
    return r.CP_LaneGet(lane, "mute") >= 0.5
        or r.CP_LaneGet(lane, "umute") >= 0.5
end

-- The sound channel is gone with the router: a sound cell is a CP voice on its
-- own port, and it never travelled a MIDI wire to begin with. These two stay
-- as no-ops so a window that still calls them is not punished for it.
-- ---------------------------------------------------------------------------
-- LIRE A PARTIR D'ICI — le decalage de phase d'une lane (ABI 1.9)
-- ---------------------------------------------------------------------------
-- La phase d'une lane est ancree sur le beat ZERO du projet : c'est ce qui
-- verrouille toutes les boucles sur la meme grille. Un decalage CONSTANT ne
-- casse pas ce verrou, il le DEPLACE — la lane reste sur la grille, a distance
-- fixe, et rien ne derive. Le harnais le prouve sur vingt passes.
--
-- Le moteur le lit au meme endroit pour le portail MIDI et pour la phase
-- publiee, donc les notes et le son bougent ensemble.
function Loop.SetLaneOffset(lane, beats)
    if NATIVE then r.CP_LaneSet(lane, "offset", beats or 0) end
end
function Loop.GetLaneOffset(lane)
    return NATIVE and r.CP_LaneGet(lane, "offset") or 0
end

-- LE SON DOIT RENTRER TOUT DE SUITE, LUI AUSSI.
--
-- Le MIDI saute a l'instant meme : le portail relit la phase a chaque bloc.
-- Une case AUDIO, non — sa voix a recu une date de depart et une duree en
-- frames, et elle finirait tranquillement sa passe avant de se raccrocher a la
-- nouvelle phase. On entendrait donc les notes sauter et le son rester, ce qui
-- est pire que de ne rien faire.
--
-- Un compteur suffit a le dire, et il reste en Lua : le moteur n'a pas a
-- connaitre une decision d'interface. `Cells` le relit par frame et, quand il
-- bouge, coupe sa voix — la frame suivante la fait rentrer sur la phase
-- courante, ce que ce module sait deja faire depuis toujours.
local reseat = {}
function Loop.ReseatVersion(lane) return reseat[lane] or 0 end

-- ARMER UN DEPART, plutot que de poser un decalage apres coup.
--
-- Poser `offset` depuis ici ne peut pas marcher pour un lancement : on ne voit
-- le depart qu'APRES coup — le premier bloc a deja sonne a l'ancien endroit,
-- d'ou le sursaut d'une frame — et on ne peut pas le PREVOIR non plus,
-- puisque la frontiere de quantize est choisie dans le moteur exactement pour
-- qu'il n'y ait pas deux horloges qui divergent.
--
-- On arme donc l'intention. Le moteur la consomme a l'instant ou il choisit la
-- frontiere, contre CETTE frontiere et non contre le debut du bloc.
function Loop.ArmPlayFrom(lane, beat)
    if NATIVE then r.CP_LaneSet(lane, "playfrom", beat or -1) end
end
function Loop.GetPlayFrom(lane)
    return NATIVE and r.CP_LaneGet(lane, "playfrom") or -1
end

function Loop.PlayClipFrom(lane, beat)
    if not NATIVE or not lane then return false end
    -- LA ZONE, PAS LA LONGUEUR DE LA CASE. Sous accolade, la phase court dans
    -- la zone : reduire le deplacement modulo la longueur du CLIP donnerait un
    -- decalage juste a une longueur de clip pres et faux a une longueur de zone
    -- pres — c'est-a-dire faux, sauf quand l'une divise l'autre.
    local _, slen = Loop.Span(lane)
    if not slen or slen <= 0 then return false end
    local ph  = Loop.Phase(lane) or 0
    local off = Loop.GetLaneOffset(lane)
    Loop.SetLaneOffset(lane, (off + (beat - ph)) % slen)
    reseat[lane] = (reseat[lane] or 0) + 1
    return true
end

-- ---------------------------------------------------------------------------
-- L'INSTANTANE DE FRAME — huit lectures par lane, et non des centaines
-- ---------------------------------------------------------------------------
-- Ces huit champs sont demandes en boucle de dessin : `drawCell` en lisait deux
-- a sept PAR CASE, `resolveLive` deux par lane, le motion cinq par colonne. A
-- huit colonnes et huit scenes, une frame franchissait le pont d'ABI trois a
-- quatre CENTS fois — et c'est un pont, pas un acces memoire.
--
-- Ils sont donc lus UNE FOIS PAR LANE au debut de `Loop.Poll`, et tout ce qui
-- suit lit la table. Le cout devient CONSTANT (huit fois seize) au lieu de
-- croitre avec la grille : c'est la propriete qui compte, parce que le nombre de
-- colonnes vient de doubler.
--
-- LA FRAICHEUR NE CHANGE PAS, et c'est ce qui rend l'echange gratuit : ces
-- champs sont publies par le FIL AUDIO en fin de bloc, et une frame de defer
-- dure plus longtemps qu'un bloc. Les relire au milieu d'une frame rendait
-- exactement la meme valeur. La seule exception est le TAG, qui s'ecrit depuis
-- Lua : `SetLaneTag` met donc l'instantane a jour en meme temps que le moteur,
-- sans quoi une case armee puis dessinee dans la meme frame clignoterait au
-- mauvais endroit pendant une frame.
local sn_tag, sn_mode, sn_pend = {}, {}, {}
local sn_len, sn_sa, sn_slen   = {}, {}, {}

local function snapshot()
    for lane = 0, Loop.MAX_LANES - 1 do
        if NATIVE then
            sn_tag[lane]  = math.floor(r.CP_LaneGet(lane, "tag") + 0.5)
            sn_mode[lane] = math.floor(r.CP_LaneGet(lane, "mode") + 0.5)
            sn_pend[lane] = math.floor(r.CP_LaneGet(lane, "pending") + 0.5)
            sn_len[lane]  = r.CP_LaneGet(lane, "lenbeats")
            sn_sa[lane]   = r.CP_LaneGet(lane, "spana")
            sn_slen[lane] = r.CP_LaneGet(lane, "spanlen")
        else
            sn_tag[lane], sn_mode[lane], sn_pend[lane] = 0, 0, 0
            sn_len[lane] = 4
            sn_sa[lane], sn_slen[lane] = 0, 4
        end
    end
end

-- Pose l'instantane pour une fenetre qui n'a pas encore appele `Poll` — sinon
-- son premier dessin lirait des nil. Une fois, au chargement du module.
snapshot()

-- ---------------------------------------------------------------------------
-- L'ACCOLADE DE BOUCLE (ABI 2.1)
-- ---------------------------------------------------------------------------
-- La sous-region qu'une case joue en boucle, en beats depuis son debut. Ce
-- n'est PAS une porte qui tairait ce qui est autour : c'est une longueur de
-- boucle. La case devient une boucle de deux mesures et revient deux fois plus
-- souvent, au lieu de tourner sur quatre mesures dont deux de silence.
--
-- Poser `b <= a` (ou rien) l'efface. Le bornage — une accolade qui deborde
-- d'une case qu'on vient de raccourcir — appartient au MOTEUR : il le fait une
-- fois par bloc et le publie, et `Loop.Span` rend ce resultat-la. Deux copies
-- de la regle auraient diverge exactement sur le cas ou elle sert.
function Loop.SetLoopRange(lane, a, b)
    if not NATIVE then return end
    if not a or not b or b <= a then
        r.CP_LaneSet(lane, "loopa", 0)
        r.CP_LaneSet(lane, "loopb", -1)
        return
    end
    r.CP_LaneSet(lane, "loopa", a)
    r.CP_LaneSet(lane, "loopb", b)
end

-- Ce que l'utilisateur a DEMANDE, tel quel — pour l'afficher et le modifier.
-- Rend nil quand il n'y a pas d'accolade.
function Loop.GetLoopRange(lane)
    if not NATIVE then return nil end
    local a = r.CP_LaneGet(lane, "loopa")
    local b = r.CP_LaneGet(lane, "loopb")
    if not b or b <= (a or 0) then return nil end
    return a, b
end

-- Ce que le moteur JOUE reellement : debut et longueur, apres bornage dans la
-- case. Sans accolade, (0, longueur de la case) — donc tout appelant peut s'en
-- servir sans jamais tester s'il y en a une.
function Loop.Span(lane)
    local l = sn_slen[lane]
    if not l or l <= 0 then return 0, Loop.LenBeats(lane) end
    return sn_sa[lane] or 0, l
end

-- ---------------------------------------------------------------------------
-- LA SIGNATURE DE LA BOUCLE (ABI 2.3)
-- ---------------------------------------------------------------------------
-- La longueur d'une boucle valait `bars * ts_num`, ou `ts_num` etait la
-- signature rythmique A L'ENDROIT OU LA TETE DE LECTURE SE TROUVE. Une seule
-- mesure en 3/4 quelque part dans le projet changeait donc la longueur de
-- TOUTES les lanes quand le transport la traversait — alors que les notes sont
-- en beats absolus. La musique se decalait toute seule, et il n'existait nulle
-- part de signature DU CLIP a qui demander. Ableton en a une.
--
-- Zero (ou nil) veut dire « suis le projet », donc tout ce qui existe deja se
-- comporte exactement comme avant. C'est ce qui rend cette correction gratuite
-- pour qui ne s'en sert pas.
function Loop.SetLaneTsNum(lane, n)
    if not NATIVE then return end
    r.CP_LaneSet(lane, "tsnum", (n and n >= 1) and n or 0)
end

function Loop.GetLaneTsNum(lane)
    if not NATIVE then return nil end
    local v = r.CP_LaneGet(lane, "tsnum")
    return (v and v >= 1) and v or nil
end

function Loop.SetLaneAudio() end
function Loop.GetLaneAudio() return false end

-- ---------------------------------------------------------------------------
-- Per-lane state (read)
-- ---------------------------------------------------------------------------
-- 0 empty · 1 recording · 2 stopped · 3 playing · 4 armed · 5 overdubbing
function Loop.Mode(lane)       return sn_mode[lane] or 0 end
function Loop.NEv(lane)        return store(lane).n end

-- ⚠️ LA PHASE N'EST PAS DANS L'INSTANTANE, ET C'EST LE CONTRE-EXEMPLE QUI
-- DEFINIT LA REGLE.
--
-- Elle y a ete une heure, et c'etait la faute que ce depot a deja payee 28 ms :
-- APPARIER DEUX INSTANTS DIFFERENTS. La phase et le beat du moteur sont publies
-- ENSEMBLE, a la fin du meme bloc audio ; `Cells.drive` calcule une date de
-- depart en faisant leur difference, et `PlayClipFrom` un decalage de la meme
-- facon. Geler l'un et laisser l'autre vif fait entrer dans le calcul tous les
-- blocs audio qui se terminent entre les deux lectures — soit zero, soit un, soit
-- six selon ce que la frame a fait entre-temps. Ce n'est meme pas un retard
-- constant qu'on pourrait compenser : c'est de la gigue sur le point de boucle.
--
-- LA REGLE, donc : ce que le moteur republie A CHAQUE BLOC et qu'on APPARIE avec
-- un instant se lit VIF. Ce qui ne change qu'a un geste — le tag, le mode, la
-- file, la longueur, la zone — passe par l'instantane. C'est la phase et la
-- cible d'attente, et rien d'autre.
function Loop.Phase(lane)      return NATIVE and r.CP_LaneGet(lane, "phase") or 0 end
function Loop.LenBeats(lane)
    local v = sn_len[lane] or 0
    return v > 0 and v or 4
end
function Loop.EvtVersion(lane) return evtver[lane] or 0 end
function Loop.HasContent(lane) return store(lane).n > 0 end
-- queued launch: 0 none · 1 play · 2 stop · 3 rec · 4 stop-rec · 5 overdub
function Loop.Pending(lane)       return sn_pend[lane] or 0 end
-- Vive, pour la meme raison que la phase : elle se compare a `Loop.EngineBeat()`
-- pour afficher un decompte, et deux instants differents font un decompte faux.
function Loop.PendingTarget(lane)
    return NATIVE and r.CP_LaneGet(lane, "target") or 0
end

-- A queued launch with no date: it is waiting for the CLOCK itself and fires
-- with its first block. The UI says so instead of counting down to a beat that
-- has no date.
function Loop.PendingWaitsClock(lane)
    return NATIVE and r.CP_LaneGet(lane, "target") < -1e8
end

-- ---------------------------------------------------------------------------
-- Tracks = lane pairs
-- ---------------------------------------------------------------------------
local live = {}
for t = 0, Loop.TRACKS - 1 do live[t] = t end

function Loop.IsRunning(lane)
    local m = sn_mode[lane] or 0
    return m == 1 or m == 3 or m == 5
end

-- "busy" = sounding or about to: a queued launch already belongs to the half
-- that will play, otherwise the swap would flicker back for one frame. ARMED
-- and a queued REC count for the same reason — a take waiting on the transport
-- is the half the user is looking at.
local function laneBusy(lane)
    local m = sn_mode[lane] or 0
    if m == 3 or m == 5 or m == 1 or m == 4 then return true end
    local p = sn_pend[lane] or 0
    return p == 1 or p == 3
end

local function resolveLive()
    if not NATIVE then return end
    local n = Loop.TRACKS
    for t = 0, n - 1 do
        local a, b = t, t + n
        local ab, bb = laneBusy(a), laneBusy(b)
        if bb and not ab then live[t] = b
        elseif ab and not bb then live[t] = a end
    end
end

function Loop.LiveLane(t) return live[t] or t end
function Loop.TwinLane(t)
    local n = Loop.TRACKS
    return (live[t] or t) == t and (t + n) or t
end
function Loop.TrackOfLane(lane) return (lane or 0) % Loop.TRACKS end

-- ---------------------------------------------------------------------------
-- Lane occupancy tag — WHICH clip a lane currently holds
-- ---------------------------------------------------------------------------
-- ⚠️ LES DEUX, ET DANS CET ORDRE. Le tag est le seul champ de l'instantane qui
-- s'ecrive depuis Lua : ne mettre a jour que le moteur ferait lire l'ancienne
-- valeur au dessin de la meme frame, et une case qu'on vient d'armer
-- clignoterait a la mauvaise place pendant une frame.
function Loop.SetLaneTag(lane, tag)
    local v = math.floor((tag or 0) + 0.5)
    if NATIVE then r.CP_LaneSet(lane, "tag", v) end
    sn_tag[lane] = v
end
function Loop.GetLaneTag(lane) return sn_tag[lane] or 0 end

-- Which half of track t holds `tag`, or NIL when the engine no longer holds
-- that clip at all. Nil is the honest answer and the safe one: a window that
-- believed otherwise would draw a playhead for someone else's clip and, far
-- worse, write its edits over the clip that IS playing.
-- QUELLE LANE TIENT CE CLIP. Rend nil quand plus personne ne le tient — et
-- c'est le contrat, ecrit dans le commentaire d'origine, que le code ne tenait
-- pas : un tag 0 (« pas d'identite ») rendait la moitie VIVANTE de la paire.
-- L'edition d'un clip sans identite atterrissait donc dans la lane jumelle,
-- par-dessus les notes d'un autre clip. Zero n'est pas une identite, c'est
-- l'absence d'identite, et la reponse honnete est « je ne sais pas ».
function Loop.LaneOfTag(t, tag)
    if not tag or tag == 0 then return nil end
    local n = Loop.TRACKS
    if Loop.GetLaneTag(t) == tag then return t end
    if Loop.GetLaneTag(t + n) == tag then return t + n end
    return nil
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------
function Loop.Tempo() return r.Master_GetTempo() or 120 end
function Loop.Playing() return (r.GetPlayState() & 1) == 1 end

local function nowPos()
    return Loop.Playing() and r.GetPlayPosition() or r.GetCursorPosition()
end

function Loop.Beat() return r.TimeMap2_timeToQN(0, nowPos()) end

function Loop.TsNum()
    local n = r.TimeMap_GetTimeSigAtTime(0, nowPos())
    return (n and n > 0) and n or 4
end

-- The clock the ENGINE is on: the host's beat when following it, its own
-- free-running beat otherwise. PendingTarget is expressed on THIS timeline, so
-- a countdown built on Loop.Beat() would be wrong precisely when the transport
-- is stopped — which is when a countdown is worth the most.
function Loop.EngineBeat() return NATIVE and r.CP_EngineBeat() or 0 end

-- ---------------------------------------------------------------------------
-- Note storage
-- ---------------------------------------------------------------------------
function Loop.NoteCount(lane)
    local n = store(lane).n
    return (n > Loop.MAX_NOTES) and Loop.MAX_NOTES or n
end

function Loop.SetNoteCount(lane, n)
    local t = store(lane)
    t.n = math.floor((n or 0) + 0.5)
    if t.n < 0 then t.n = 0 end
    if t.n > Loop.MAX_NOTES then t.n = Loop.MAX_NOTES end
    publish(lane)
end

-- Restore a lane's playing state on recall (0 empty · 2 stopped · 3 playing).
function Loop.SetMode(lane, m) cmd(9, lane, m or 0) end

-- "The notes of this lane changed" — and therefore also the moment to hand the
-- list to the engine. Every editing path already calls this exactly once at
-- the end of a gesture, which is precisely the granularity the double buffer
-- wants: publishing per NOTE would have made a delete O(n^2) in ABI calls, and
-- publishing never would have made a note drag inaudible.
function Loop.BumpVer(lane)
    evtver[lane] = (evtver[lane] or 0) + 1
    publish(lane)
end

function Loop.GetNote(lane, i)
    local t = store(lane)
    local k = i + 1
    return t.s[k], t.l[k], t.p[k], t.v[k], t.pr[k] or 100
end

-- Write note i (0-based). Does NOT publish: the caller owns the count, and
-- publishing per note would hand the engine a half-written list once per note
-- instead of a whole one once.
function Loop.PutNote(lane, i, start, len, pitch, vel, prob)
    local t = store(lane)
    local k = i + 1
    t.s[k], t.l[k], t.p[k], t.v[k] = start, len, pitch, vel
    -- CENT PAR DEFAUT, EXPLICITEMENT. Un appelant qui ne connait pas encore la
    -- probabilite doit obtenir « joue toujours » et non « ne joue jamais ».
    t.pr[k] = prob or 100
end

function Loop.ReadNotes(lane, out_start, out_len, out_pitch, out_vel, out_prob)
    local t = store(lane)
    local n = Loop.NoteCount(lane)
    for i = 1, n do
        out_start[i] = t.s[i]
        out_len[i]   = t.l[i]
        out_pitch[i] = t.p[i]
        out_vel[i]   = t.v[i]
        if out_prob then out_prob[i] = t.pr[i] or 100 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- LIVE CAPTURE
--
-- The router was armed and monitored so the JSFX could see incoming MIDI in
-- its audio block. There is no router; MIDI_GetRecentInputEvent reads REAPER's
-- global input history from the main thread, and — this is the part that makes
-- it better rather than merely equivalent — every event arrives ALREADY
-- STAMPED in samples relative to now. A defer frame polls late; it does not
-- record late.
--
-- Consequences worth stating:
--   * capture no longer depends on anything being armed. One fewer state to
--     be in the wrong one of;
--   * it sees every device, exactly as the router (armed on all inputs) did;
--   * the suite's own preview notes are tagged on UI_CHAN and swallowed here,
--     so a sampler pad clicked during a take does not land in the take.
-- ---------------------------------------------------------------------------
local UI_CHAN = 15          -- mirror of Kit.UI_CHAN
-- Two tables, not one keyed cleverly: a single table holding both the start
-- phase and the velocity has to encode which is which, and closeHeld would
-- then walk the velocities as though they were pitches — inventing notes at
-- negative pitch out of an iteration order.
local held_st  = {}         -- [lane][pitch] = start phase
local held_vel = {}         -- [lane][pitch] = velocity
local last_seq = nil

local function heldOf(lane)
    local a = held_st[lane]
    if not a then a = {} held_st[lane] = a end
    local b = held_vel[lane]
    if not b then b = {} held_vel[lane] = b end
    return a, b
end

-- Append a finished note to the lane, clamped to its loop.
local function addNote(lane, start, len, pitch, vel)
    local t = store(lane)
    if t.n >= Loop.MAX_NOTES then return end
    local Lb = Loop.LenBeats(lane)
    if len < 0 then len = len + Lb end
    if len < 0.02 then len = 0.05 end
    if len > Lb then len = Lb end
    t.n = t.n + 1
    t.s[t.n], t.l[t.n], t.p[t.n], t.v[t.n] = start, len, pitch, vel
    -- Une note qu'on vient de JOUER sonne toujours. Sans cette ligne, chaque
    -- prise serait enregistree a zero pour cent — donc muette a la relecture,
    -- avec ses notes bien visibles dans l'editeur.
    t.pr[t.n] = 100
end

-- Close every note still held on this lane, at `phase`.
local function closeHeld(lane, phase)
    local a = held_st[lane]
    if not a then return false end
    local b = held_vel[lane] or {}
    local any = false
    for pitch, st in pairs(a) do
        addNote(lane, st, phase - st, pitch, b[pitch] or 100)
        any = true
    end
    held_st[lane], held_vel[lane] = nil, nil
    return any
end

-- Which lanes are capturing right now, and the engine's beat for each.
-- Les lanes en capture de CETTE frame, et ce qu'il faut savoir d'elles pour
-- dater une note. Tables de module, reutilisees : elles vivent dans un chemin
-- qui tourne cent vingt-huit fois pendant une prise.
local cap_lane, cap_sa, cap_slen, cap_off = {}, {}, {}, {}
-- Les evenements bruts, dans deux tableaux paralleles plutot qu'une table par
-- evenement. Cent vingt-huit tables par frame pendant une prise, c'est cent
-- vingt-huit occasions pour le ramasse-miettes de passer pendant qu'on joue.
-- Le numero de sequence n'est pas garde : seul le plus RECENT sert, et il est
-- lu avant la boucle.
local pend_buf, pend_ts = {}, {}

local function pollCapture()
    if not NATIVE then return end

    -- A take that just STARTED wipes the lane: the engine says so by bumping
    -- its take generation. It never touches the notes itself — that is the
    -- whole ownership rule — so this is where "REC clears the lane" happens.
    local capturing = false
    local ncap = 0
    for lane = 0, Loop.MAX_LANES - 1 do
        local g = math.floor(r.CP_LaneGet(lane, "recgen") + 0.5)
        if seen_recgen[lane] ~= g then
            if seen_recgen[lane] ~= nil then
                local t = store(lane)
                t.n = 0
                held_st[lane], held_vel[lane] = nil, nil
                publish(lane)
                evtver[lane] = (evtver[lane] or 0) + 1
            end
            seen_recgen[lane] = g
        end
        -- L'instantane de frame, pose par `Poll` juste avant : un appel d'ABI
        -- de moins par lane, et la meme valeur.
        local m = Loop.Mode(lane)
        if m == 1 or m == 5 then
            capturing = true
            -- ON RETIENT LA LANE ICI, une fois. Le remplissage des evenements
            -- redemandait le mode de CHAQUE lane pour CHAQUE evenement : jusqu'a
            -- 2048 franchissements du pont d'ABI pour 128 evenements, alors que
            -- ce balayage-ci vient de repondre a la question.
            ncap = ncap + 1
            cap_lane[ncap] = lane
        elseif held_st[lane] then
            -- The take ended (auto-stop, boundary, transport stop): close what
            -- was still held so the last note is KEPT rather than lost. A take
            -- that stops mid-note used to strand it in the JSFX's local heap
            -- and lose it entirely.
            local Lb = Loop.LenBeats(lane)
            local ph = Loop.Phase(lane)
            if closeHeld(lane, (ph > 0) and ph or Lb) then
                Loop.BumpVer(lane)
            end
        end
    end

    if not r.MIDI_GetRecentInputEvent then return end

    -- idx = 0 also latches the list, so it must be asked for even when nothing
    -- is capturing — otherwise the first take would receive everything played
    -- since the window opened.
    local seq0, buf0, ts0 = r.MIDI_GetRecentInputEvent(0)
    if not seq0 or seq0 == 0 then return end
    if not capturing then last_seq = seq0 return end

    local tempo = Loop.Tempo()
    if not tempo or tempo <= 0 then tempo = 120 end
    local srate = 48000
    if r.CP_Srate then
        local s = r.CP_Srate()
        if s and s > 1 then srate = s end
    end
    local bps = tempo / (60.0 * srate)      -- beats per sample
    local now_beat = r.CP_EngineBeat()

    -- LA ZONE ET LE DECALAGE DE CHAQUE LANE, UNE FOIS. Ils ne bougent pas
    -- pendant la frame, et les redemander par evenement coutait trois appels
    -- d'ABI de plus a chaque note.
    for i = 1, ncap do
        local l = cap_lane[i]
        local sa, slen = Loop.Span(l)
        if not slen or slen <= 0 then sa, slen = 0, 4 end
        cap_sa[i], cap_slen[i] = sa, slen
        cap_off[i] = Loop.GetLaneOffset(l) or 0
    end

    -- Walk BACK from the newest to the last one we handled, then replay them
    -- oldest-first so a note-on precedes its note-off.
    local npend, idx = 0, 0
    local seq, buf, ts = seq0, buf0, ts0
    while seq and seq ~= 0 and idx < 128 do
        if last_seq and seq <= last_seq then break end
        npend = npend + 1
        pend_buf[npend], pend_ts[npend] = buf, ts
        idx = idx + 1
        seq, buf, ts = r.MIDI_GetRecentInputEvent(idx)
    end
    last_seq = seq0

    local changed = {}
    for k = npend, 1, -1 do
        local ev_ts = pend_ts[k]
        local b = pend_buf[k]
        if b and #b >= 3 then
            local st = b:byte(1)
            local hi = st & 0xF0
            local ch = st & 0x0F
            if ch ~= UI_CHAN and (hi == 0x90 or hi == 0x80) then
                local pitch = b:byte(2)
                local vel   = b:byte(3)
                local on    = (hi == 0x90 and vel > 0)
                -- `ts` is in samples relative to NOW, and negative for the
                -- past. This is the whole reason the capture is not late.
                local beat = now_beat + (ev_ts or 0) * bps
                for i = 1, ncap do
                    local lane = cap_lane[i]
                    do
                        -- LA CAPTURE ECRIT DANS LA ZONE QUE LE MOTEUR JOUE.
                        --
                        -- Elle repliait le beat modulo la longueur de la CASE.
                        -- Sous accolade, le moteur boucle sur la ZONE : une
                        -- note jouee tombait donc hors d'elle et ne sonnait
                        -- JAMAIS — enregistree, visible dans l'editeur, muette.
                        -- Le musicien joue sur la boucle qu'il entend et
                        -- n'entend jamais revenir ce qu'il vient de jouer.
                        --
                        -- Le decalage de phase entre aussi ici, et pour la meme
                        -- raison : la phase de la lane vaut `sa + ((x + off)
                        -- mod Ls)`. Ecrire sans lui posait la note a l'endroit
                        -- ou elle aurait sonne SANS le geste « pars d'ici ».
                        local slen = cap_slen[i]
                        local a = beat + cap_off[i]
                        local ph = cap_sa[i] + (a - math.floor(a / slen) * slen)
                        local hs, hv = heldOf(lane)
                        if on then
                            -- a new note-on closes any pending note of the
                            -- same pitch first
                            if hs[pitch] then
                                addNote(lane, hs[pitch], ph - hs[pitch], pitch,
                                        hv[pitch] or 100)
                                changed[lane] = true
                            end
                            hs[pitch] = ph
                            hv[pitch] = vel
                        elseif hs[pitch] then
                            addNote(lane, hs[pitch], ph - hs[pitch], pitch,
                                    hv[pitch] or 100)
                            hs[pitch] = nil
                            hv[pitch] = nil
                            changed[lane] = true
                        end
                    end
                end
            end
        end
    end
    for lane in pairs(changed) do Loop.BumpVer(lane) end
end

-- ---------------------------------------------------------------------------
-- Per-frame pump — the ONE call every host makes before reading anything
-- ---------------------------------------------------------------------------
local dest_chg, dest_t = -1, 0

-- L'ETAT D'UN CLIP APPARTIENT A CELUI QUI L'A LANCE, PAS AU TRANSPORT.
--
-- On arretait ici chaque lane qui jouait des que le transport de l'hote
-- tombait. Le son se taisait — mais l'ETAT partait avec, et rappuyer sur play
-- ne relancait rien : il fallait recliquer chaque case une par une. En mode
-- Suivre, arreter le transport veut dire « suspends », jamais « oublie ce que
-- je t'ai demande ». C'est la promesse que fait toute grille de session :
-- une case allumee le reste tant que personne ne l'a eteinte.
--
-- Le moteur avait deja raison de son cote. Sur le front descendant de `active`
-- il relache ce qui sonne et ferme les prises en cours, mais il LAISSE une
-- lane en lecture dans son mode (cp_lanes.cpp, « front descendant de
-- `active` »). L'horloge ne bat plus, donc rien ne sort ; et quand elle
-- reprend, la lane se raccroche a la phase du projet comme n'importe quelle
-- passe suivante. Il n'y avait donc rien a defaire.
--
-- Ce qui justifiait cet arret, c'etaient les cases AUDIO : ce sont des voix et
-- non des lanes, elles gardaient leur passe programmee et pouvaient sonner
-- encore une mesure apres le stop. Elles se taisent maintenant d'elles-memes
-- quand l'horloge ne bat plus (`Cells.drive`) — le silence ne se paie plus
-- d'un etat perdu.
--
-- L'HORLOGE BAT : la meme condition que le `active` du moteur. L'horloge libre
-- bat toujours — c'est tout l'objet du mode libre, la session est son propre
-- transport — celle de l'hote bat quand le transport roule.
function Loop.ClockRunning()
    return Loop.GetFreeRun() or Loop.Playing()
end

function Loop.Poll()
    if not NATIVE then return end
    -- THE ANCHOR, first, and it is taken by the ENGINE — CP_ClockSync pairs the
    -- audio clock with the position of the block being PROCESSED, retrying until
    -- the two readings fall inside the same block.
    --
    -- We then build the beat from THAT position rather than from a fresh
    -- GetPlayPosition(). The difference is not cosmetic: GetPlayPosition is the
    -- latency-compensated what-you-hear position, so a beat derived from it
    -- describes an instant that the audio thread produced milliseconds ago, and
    -- every note the engine dates from it lands late by the device's output
    -- latency. Measured before this line existed: up to 28 ms behind the
    -- metronome, constant, no drift.
    r.CP_ClockSync()
    local pos = Loop.Playing() and r.CP_ClockPos() or r.GetCursorPosition()
    r.CP_TransportSync(Loop.Tempo(), r.TimeMap2_timeToQN(0, pos),
                       Loop.Playing() and 1 or 0, Loop.TsNum())
    -- L'INSTANTANE AVANT TOUT LE RESTE : `resolveLive` et `pollCapture` le
    -- lisent, et tout ce que la fenetre demandera ensuite aussi.
    snapshot()
    resolveLive()
    pollCapture()
    local c = r.GetProjectStateChangeCount(0)
    if c ~= dest_chg then
        local now = r.time_precise()
        if now - dest_t >= 0.5 then
            dest_chg, dest_t = c, now
            Loop.RefreshDests()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Clip adapters — a lane IS a MIDI clip
-- ---------------------------------------------------------------------------
-- UN CLIP SANS IDENTITE N'EN EST PAS UN. Le descripteur partait sans `id` ni
-- `cell` : cote editeur `Ident.TagOf` rendait 0, et l'edition ne savait plus
-- revenir a sa lane. On lui donne le tag que la lane porte deja — et on en pose
-- un si elle n'en avait pas, ce qui est le seul moment ou on le peut.
function Loop.LaneToClip(lane)
    local n = Loop.NoteCount(lane)
    if n <= 0 then return nil end
    local s, l, p, v, pr = {}, {}, {}, {}, {}
    Loop.ReadNotes(lane, s, l, p, v, pr)
    local tag = math.floor(Loop.GetLaneTag(lane) or 0)
    if tag == 0 then
        tag = Loop.LANE_TAG_BASE + lane
        Loop.SetLaneTag(lane, tag)
    end
    -- L'ACCOLADE VOYAGE AVEC LA CASE, PAS AVEC LA LANE.
    --
    -- Une lane est un EMPLACEMENT que toutes les cases d'une colonne se
    -- partagent : `armLane` y charge une autre case, et sans ces deux champs
    -- l'accolade de la precedente restait en place. La case suivante n'aurait
    -- alors joue que ses mesures 3 et 4, sans qu'aucun geste ne l'ait demande —
    -- et la meme case, relancee sur la lane jumelle, aurait perdu la sienne.
    -- L'accolade apparaissait et disparaissait selon l'etat de lecture au
    -- moment du lancement, ce qui est la pire facon d'avoir tort.
    local la, lb = Loop.GetLoopRange(lane)
    return {
        kind   = "midi",
        tsnum  = Loop.GetLaneTsNum(lane),
        id     = tag,
        name   = "Lane " .. (lane + 1),
        notes  = { s = s, l = l, p = p, v = v, pr = pr },
        bars   = Loop.GetLengthBars(lane),
        lmode  = "loop",
        loop_a = la,
        loop_b = lb,
    }
end

-- Live-apply an edited clip into a lane: notes + length only — the mode is NOT
-- touched, so a playing lane keeps playing (the engine reconciles the sounding
-- notes against the new list every block).
function Loop.ApplyClip(lane, clip)
    if not NATIVE or not clip or clip.kind ~= "midi" then return false end
    local nt = clip.notes
    local n = (nt and nt.s and #nt.s) or 0
    if n > Loop.MAX_NOTES then return false end
    local t = store(lane)
    local np = nt.pr
    for i = 1, n do
        t.s[i], t.l[i], t.p[i], t.v[i] = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
        -- Un descripteur ecrit avant la probabilite n'a pas de `pr`, et l'ecart
        -- entre « pas de champ » et « zero » est ici l'ecart entre une lane qui
        -- joue et une lane muette.
        t.pr[i] = (np and np[i]) or 100
    end
    t.n = n
    publish(lane)
    if clip.bars and clip.bars > 0
       and clip.bars ~= Loop.GetLengthBars(lane) then
        Loop.SetLengthBars(lane, clip.bars)
    end
    -- LA SIGNATURE AVANT L'ACCOLADE, parce que c'est elle qui decide de la
    -- longueur en beats contre laquelle l'accolade sera bornee. Ecrite TOUJOURS,
    -- pour la meme raison que l'accolade : c'est le seul geste qui efface celle
    -- de l'occupant precedent d'une lane partagee.
    Loop.SetLaneTsNum(lane, clip.tsnum)
    -- TOUJOURS ECRITE, MEME QUAND LA CASE N'EN A PAS. C'est le seul geste qui
    -- efface l'accolade de l'occupant precedent ; ne l'ecrire que si la case en
    -- porte une aurait laisse passer exactement le cas qu'on ferme. Et APRES la
    -- longueur : le moteur borne l'accolade dans la case, la borner contre
    -- l'ancienne longueur la ramenerait a rien.
    Loop.SetLoopRange(lane, clip.loop_a, clip.loop_b)
    Loop.BumpVer(lane)
    return true
end

function Loop.ClipToLane(lane, clip)
    if not Loop.ApplyClip(lane, clip) then return false end
    if clip.bars and clip.bars > 0 then Loop.SetLengthBars(lane, clip.bars) end
    Loop.SetMode(lane, store(lane).n > 0 and 2 or 0)
    return true
end

-- ---------------------------------------------------------------------------
-- Session recall
--
-- The state used to be mirrored into the router track's P_EXT, so it travelled
-- inside the .RPP with that track. With no track it goes to ProjExtState —
-- still inside the .RPP, still travelling with the project, and now it does
-- not depend on a track surviving a copy-paste.
--
-- Wire format, one string, printable separators only:
--   "10;<global>;<lane>;<lane>;…"                  10 = format version
--   global = "freerun|armedlane|launchq|nlanes"
--   lane   = "bars|muted|mode|tag|loopa|loopb|umute|tsnum|n|s,l,p,v[,prob]|…"
-- v1..v4 (the router-track era) are still read: a project saved before this
-- change opens with its loops.
-- ---------------------------------------------------------------------------
local function num(v) return string.format("%.6g", v or 0) end

local function migrateQ(ver, q)
    if (tonumber(ver) or 0) < 4 and (q or 0) <= 0 then return Loop.TsNum() end
    return q or 0
end

function Loop.Serialize()
    -- FORMAT 10 : LE MUTE MUSICAL et LA SIGNATURE entrent dans le bloc de
    -- chaque lane. Deux champs, un seul numero de format : ils sont ecrits dans
    -- le meme changement, et deux versions pour un meme jour n'auraient rien dit
    -- de plus a personne.
    --
    -- Le champ `muted` d'origine porte l'etat EFFECTIF, qui melange les deux
    -- intentions — et l'intention mecanique se refait toute seule au rappel
    -- (`armLane` remute la lane d'une case audio). Ce qui ne se refait pas,
    -- c'est le geste : « j'ai tu cette lane ». Il a donc son champ.
    --
    -- Un projet plus ancien n'en a pas, et l'absence vaut « personne n'a tu
    -- cette lane » — ce qui est exactement ce qu'elle valait avant, puisque le
    -- geste n'existait pas separement.
    --
    -- FORMAT 9 : LA PROBABILITE entre dans l'enregistrement d'une note.
    --
    -- Cinquieme champ, et ecrit SEULEMENT quand il vaut autre chose que cent :
    -- l'immense majorite des notes n'ont pas de probabilite, et un fichier de
    -- projet n'a pas a grossir pour une valeur qui est le defaut. Le lecteur
    -- essaie donc cinq champs, puis quatre.
    --
    -- FORMAT 8 : LE NOMBRE DE LANES entre dans l'en-tete.
    --
    -- Le bloc est ORDONNE PAR LANE, et une lane basse est la moitie vivante
    -- d'une colonne tandis qu'une haute est sa jumelle : le pas qui les separe
    -- vaut le nombre de colonnes. Ce nombre vient de doubler, donc un bloc ecrit
    -- avant ne designe plus les memes lanes — et le relire tel quel est
    -- exactement le genre de perte qui ne dit rien : quatre colonnes muettes,
    -- quatre qui rejouent la jumelle d'une autre.
    --
    -- On ecrit donc le nombre PLUTOT qu'un drapeau « ancien / recent ». Un
    -- drapeau aurait tenu jusqu'au prochain changement ; un nombre se remonte
    -- depuis n'importe quelle valeur passee, et vers n'importe quelle valeur
    -- future, avec la meme ligne de code.
    --
    -- FORMAT 7 : L'ACCOLADE DE BOUCLE entre dans le bloc de chaque lane.
    --
    -- Elle se sauve, contrairement au decalage de phase — et la difference est
    -- de nature, pas de gout. Un decalage est un geste de JEU : le retrouver a
    -- la reouverture serait une surprise. Une accolade est une EDITION, au meme
    -- titre que la longueur de la boucle ou les notes elles-memes ; la perdre a
    -- la fermeture ferait d'elle un brouillon, et personne ne construit sur un
    -- brouillon.
    --
    -- FORMAT 6 : le TAG DE LANE entre dans le bloc de chaque lane.
    --
    -- Il n'etait pas serialise, et c'etait une perte silencieuse : le tag est
    -- ce qui relie une case de la grille au clip que le moteur tient. Apres
    -- reouverture, les lanes rejouaient et la grille montrait tout arrete,
    -- parce que plus personne ne savait quelle case correspondait a quelle
    -- lane. Un lecteur ancien ignore le champ (les champs inconnus sont
    -- ignores), un lecteur neuf sur un projet ancien lit 0 — ce qui est
    -- exactement ce que le tag valait avant.
    local out = { "10",
                  (Loop.GetFreeRun() and "1" or "0") .. "|"
                  .. (Loop.GetArmedLane() or -1) .. "|" .. num(Loop.GetLaunchQ())
                  .. "|" .. Loop.MAX_LANES }
    for lane = 0, Loop.MAX_LANES - 1 do
        local n = Loop.NoteCount(lane)
        local m = math.floor(Loop.Mode(lane) + 0.5)
        -- an in-flight recording (1), arm (4) or overdub (5) is not a state to
        -- restore: store what the lane actually holds
        if m == 1 or m == 4 or m == 5 then m = (n > 0) and 3 or 0 end
        local la, lb = Loop.GetLoopRange(lane)
        -- ⚠️ L'INTENTION MECANIQUE, PAS L'ETAT EFFECTIF. Ce champ portait le OU
        -- des deux, et le relire tel quel remettait le mute MUSICAL sur une
        -- lane qui ne portait que le mecanique : une case audio serait revenue
        -- MUETTE d'un rechargement de projet, et une lane du Looper demutee
        -- serait restee sans MIDI, sans aucun moyen de la debloquer. Chaque
        -- champ porte une seule chose, ou il n'en porte aucune.
        local parts = { num(Loop.GetLengthBars(lane)),
                        Loop.GetMechMute(lane) and "1" or "0",
                        tostring(m),
                        string.format("%d", math.floor(Loop.GetLaneTag(lane) or 0)),
                        num(la or 0), num(lb or -1),
                        Loop.GetUserMute(lane) and "1" or "0",
                        num(Loop.GetLaneTsNum(lane) or 0),
                        tostring(n) }
        for i = 0, n - 1 do
            local s, l, p, v, pr = Loop.GetNote(lane, i)
            local rec = num(s) .. "," .. num(l) .. ","
                     .. string.format("%d,%d", math.floor((p or 0) + 0.5),
                                               math.floor((v or 100) + 0.5))
            pr = math.floor((pr or 100) + 0.5)
            if pr ~= 100 then rec = rec .. "," .. pr end
            parts[#parts + 1] = rec
        end
        out[#out + 1] = table.concat(parts, "|")
    end
    return table.concat(out, ";")
end

function Loop.Deserialize(str)
    if not NATIVE or not str or str == "" then return false end
    local fields = {}
    for f in str:gmatch("[^;]+") do fields[#fields + 1] = f end
    local ver = fields[1]
    -- ⚠️ DEUX CHIFFRES. L'expression enumerait les versions a un chiffre, et
    -- c'est exactement le piege deja paye deux fois sur ce fichier : `"10"` ne
    -- correspond pas a `[1-9]`, donc le format 10 aurait ete refuse EN BLOC —
    -- un set entier qui ne revient pas, sans un mot.
    local vnum = math.floor(tonumber(ver) or 0)
    if vnum < 1 or vnum > 10 then return false end
    local v2 = (ver ~= "1")

    -- Combien de lanes celui qui a ECRIT ceci avait. Le format 8 le dit ; avant
    -- lui, huit est la seule reponse possible, parce que c'est la seule valeur
    -- qui ait jamais ete livree.
    local old_lanes = LEGACY_LANES
    local base = v2 and 2 or 1
    if v2 and fields[2] then
        local fr, arm, lq, nl = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        if not fr then fr, arm, lq = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)$") end
        if not fr then fr, arm = fields[2]:match("^([^|]*)|([^|]*)$") end
        local n = math.floor(tonumber(nl) or 0)
        if n >= 2 then old_lanes = n end
        if fr then
            Loop.SetFreeRun(fr == "1")
            -- Before v4 the arm was not a choice: the engine clamped it to a
            -- lane, so EVERY older save carries 0 whether or not anyone armed
            -- anything. Restoring it would re-arm lane 0 in every existing
            -- project, so it is dropped.
            local a = ((tonumber(ver) or 0) >= 4) and math.floor(tonumber(arm) or -1) or -1
            -- La lane armee designe UNE lane, donc elle subit le meme pas que
            -- le reste. Sans ce passage, rouvrir un projet a quatre colonnes
            -- armerait la jumelle d'une autre colonne.
            if a >= 0 then a = newOfLane(a, old_lanes) or -1 end
            -- ADOPTE, n'arme pas. Restaurer un etat n'est pas un geste de
            -- l'utilisateur : ouvrir un projet ne doit armer aucune piste.
            Loop.AdoptArmedLane(a >= 0 and a or nil)
            if lq then Loop.SetLaunchQ(migrateQ(ver, tonumber(lq))) end
        end
    end

    local loaded = 0
    for lane = 0, Loop.MAX_LANES - 1 do
        -- « Cette lane-ci, ou etait-elle ecrite ? » et non l'inverse : c'est le
        -- sens qui permet de repondre NIL pour une colonne qui n'existait pas
        -- encore, et de la traiter comme telle plus bas.
        local src = srcOfLane(lane, old_lanes)
        local blk = src and fields[base + src + 1] or nil
        if blk then
            local t = {}
            for f in blk:gmatch("[^|]+") do t[#t + 1] = f end
            local bars  = tonumber(t[1]) or 1
            local muted = t[2] == "1"
            local mode  = v2 and math.floor(tonumber(t[3]) or 0) or nil
            -- v6 glisse le TAG entre le mode et le nombre de notes. Avant lui,
            -- le tag n'etait nulle part : zero est donc la reponse juste pour
            -- un projet ancien, et c'est ce que la lane valait deja.
            --
            -- ⚠️ COMPARER DES NOMBRES. Ces deux tests enumeraient les versions
            -- (`ver == "6" or ver == "7"`) et il fallait donc penser a y ajouter
            -- chaque nouvelle — le format 8 les aurait rendus faux en silence,
            -- et une lane aurait relu son tag a la place de son nombre de notes.
            -- C'est la meme lecon que les gardes de version : `"10" < "4"`.
            local vn   = vnum
            local v6   = (vn >= 6)
            local v7   = (vn >= 7)
            local v10  = (vn >= 10)
            local tag  = v6 and math.floor(tonumber(t[4]) or 0) or 0
            -- v7 glisse l'accolade entre le tag et le nombre de notes. Sur un
            -- projet plus ancien elle n'existe pas, et « pas d'accolade » est
            -- exactement ce que la lane valait : rien a migrer.
            local la   = v7 and tonumber(t[5]) or 0
            local lb   = v7 and tonumber(t[6]) or -1
            -- v10 glisse le mute MUSICAL entre l'accolade et le nombre de
            -- notes. Absent avant, et l'absence vaut « personne n'a tu cette
            -- lane » — ce qu'elle valait deja, puisque le geste n'existait pas
            -- separement.
            local umute = v10 and (t[7] == "1") or false
            -- Zero, ou absent, veut dire « suis le projet » — ce que toutes les
            -- lanes valaient avant que ce champ existe.
            local tsn   = v10 and tonumber(t[8]) or nil
            local hdr  = v10 and 9 or (v7 and 7 or (v6 and 5 or (v2 and 4 or 3)))
            local n     = math.floor(tonumber(t[hdr]) or 0)
            if n > Loop.MAX_NOTES then n = Loop.MAX_NOTES end
            local written = 0
            for i = 1, n do
                local rec = t[hdr + i]
                if rec then
                    -- Cinq champs d'abord, quatre ensuite. L'ordre compte :
                    -- l'expression a quatre champs est ancree en fin de chaine,
                    -- donc elle refuserait un enregistrement a cinq — et la
                    -- note serait perdue en silence, ce qui est precisement ce
                    -- que la version doit empecher.
                    local s, l, p, v, pr =
                        rec:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
                    if not s then
                        s, l, p, v = rec:match("^([^,]*),([^,]*),([^,]*),([^,]*)$")
                    end
                    if s then
                        Loop.PutNote(lane, written, tonumber(s) or 0,
                                     tonumber(l) or 0.25, tonumber(p) or 60,
                                     tonumber(v) or 100, tonumber(pr) or 100)
                        written = written + 1
                    end
                end
            end
            Loop.SetLengthBars(lane, bars)
            -- ⚠️ AVANT LE FORMAT 10, LE MUTE NE SE RESTAURE PAS DU TOUT.
            --
            -- Le champ y portait le OU des deux intentions, et rien ne permet
            -- de les separer apres coup. Le reposer comme MUSICAL rendrait
            -- muette toute case audio d'un projet ancien — elles portent toutes
            -- le mute mecanique — et le reposer comme MECANIQUE laisserait une
            -- lane du Looper sans MIDI meme apres l'avoir demutee, puisque le
            -- bouton n'ecrit que l'autre moitie.
            --
            -- On perd donc un mute d'utilisateur a la reouverture d'un projet
            -- ancien, une fois. C'est incomparablement moins cher qu'une lane
            -- coincee sans issue, et le mecanique se refait tout seul :
            -- `armLane` le repose sur chaque case audio, dans la meme frame que
            -- ce rappel, avant qu'un seul bloc audio ne passe.
            if v10 then
                Loop.SetMute(lane, muted)
                Loop.AdoptUserMute(lane, umute)
            else
                Loop.SetMute(lane, false)
                Loop.AdoptUserMute(lane, false)
            end
            -- AVANT l'accolade : c'est elle qui donne la longueur en beats
            -- contre laquelle le moteur borne la zone.
            Loop.SetLaneTsNum(lane, tsn)
            Loop.SetLaneTag(lane, tag)            -- qui joue quoi, apres reouverture
            -- APRES la longueur : le moteur borne l'accolade dans la case, et
            -- la borner contre l'ancienne longueur la ramenerait a zero.
            Loop.SetLoopRange(lane, la, lb)
            Loop.SetNoteCount(lane, written)      -- publishes
            -- mode last: it is what makes the lane sound, so nothing may be
            -- playing off a half-written note list
            if written == 0 then Loop.SetMode(lane, 0)
            elseif mode == 3 then Loop.SetMode(lane, 3)
            else Loop.SetMode(lane, 2) end
            Loop.BumpVer(lane)
            loaded = loaded + written
        else
            -- UNE COLONNE QUI N'EXISTAIT PAS DOIT ETRE VIDE, et non laissee
            -- telle quelle. Le moteur SURVIT AU SCRIPT : une lane qu'on n'ecrit
            -- pas garde ce que le projet precedent y avait mis, et les quatre
            -- colonnes neuves se seraient donc allumees avec le set d'avant.
            -- Le cas n'existait pas tant que le bloc couvrait toujours toutes
            -- les lanes ; il existe des qu'un blob peut en couvrir moins.
            Loop.SetNoteCount(lane, 0)
            Loop.SetLaneTag(lane, 0)
            Loop.SetLoopRange(lane, 0, -1)
            Loop.SetMode(lane, 0)
            Loop.SetMute(lane, false)
            Loop.AdoptUserMute(lane, false)
            Loop.SetLaneTsNum(lane, nil)
            Loop.BumpVer(lane)
        end
    end
    return true, loaded
end

function Loop.SavedState()
    local _, v = r.GetProjExtState(0, EXT_SEC, DATA_KEY)
    if v and v ~= "" then return v end
    -- A project written in the router era: the blob is on whatever track still
    -- carries the marker. Read it once — this is the migration, and it costs a
    -- scan on a project that has no CP state at all.
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        local _, mark = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. LEGACY_TAG, "", false)
        if mark == "router" then
            local _, old = r.GetSetMediaTrackInfo_String(
                tr, "P_EXT:" .. LEGACY_TAG .. "_DATA", "", false)
            if old and old ~= "" then return old end
        end
    end
    return ""
end

-- SANS LE MOTEUR, ON N'ECRIT PAS. Serialize interroge le moteur pour chaque
-- lane ; sans lui il rend huit lanes vides, et les ecrire par-dessus l'etat du
-- projet EFFACE le travail de l'utilisateur — a la fermeture de la fenetre,
-- sans un mot. `Deserialize` refusait deja quand `not NATIVE` : la lecture
-- etait protegee, l'ecriture ne l'etait pas. Trois lignes.
function Loop.SaveState()
    if not NATIVE then return false end
    r.SetProjExtState(0, EXT_SEC, DATA_KEY, Loop.Serialize())
    return true
end

function Loop.HasSavedState() return Loop.SavedState() ~= "" end

-- Recall. Refuses when any lane already holds notes unless forced: a recall
-- must never silently overwrite what is currently playing.
function Loop.LoadState(force)
    if not force then
        for lane = 0, Loop.MAX_LANES - 1 do
            if Loop.NoteCount(lane) > 0 then return false end
        end
    end
    local blob = Loop.SavedState()
    -- ⚠️ UN PROJET SANS ETAT CP N'EST PAS « RIEN A FAIRE », C'EST « TOUT VIDER ».
    --
    -- `Deserialize` sort a sa premiere ligne sur une chaine vide, donc les seize
    -- lanes gardaient le set du projet PRECEDENT — et le moteur survit au
    -- script, donc elles continuaient de jouer. Changer d'onglet vers un projet
    -- neuf laissait la musique de l'ancien tourner dans les pistes du nouveau,
    -- pendant que la grille se dessinait vide. Le cas n'existait pas tant que
    -- personne ne detectait le changement de projet ; il est ne avec lui.
    if blob == "" then
        if not force then return false end
        Loop.ClearAll()
        for lane = 0, Loop.MAX_LANES - 1 do
            Loop.SetMode(lane, 0)
            Loop.SetMute(lane, false)
            Loop.AdoptUserMute(lane, false)
            Loop.SetLoopRange(lane, 0, -1)
            Loop.SetLaneTsNum(lane, nil)
            Loop.SetLaneOffset(lane, 0)
        end
        return true, 0
    end
    return Loop.Deserialize(blob)
end

-- Clock mode and armed lane are SESSION settings, not lane content, so they
-- are restored unconditionally — unlike the notes, which decline to overwrite
-- lanes that already hold something.
-- ⚠️ QUATRE CHAMPS DEPUIS LE FORMAT 8. L'expression n'en appariait que trois,
-- donc cette fonction rendait `false` pour toute sauvegarde recente et ne
-- restituait plus ni l'horloge ni le quantize. Sans consequence visible — son
-- unique appelant enchaine sur `LoadState`, qui refait le meme travail — mais
-- une fonction qui rend toujours faux est un piege arme pour le prochain
-- appelant. Le nombre de lanes est ignore ici : c'est `Deserialize` qui s'en
-- sert, et lui seul en a besoin.
function Loop.LoadGlobals()
    if not NATIVE then return false end
    local str = Loop.SavedState()
    if str == "" then return false end
    local fields = {}
    for f in str:gmatch("[^;]+") do fields[#fields + 1] = f end
    if fields[1] == "1" or not fields[2] then return false end
    -- QUATRE CHAMPS D'ABORD. Depuis le format 8 l'en-tete en porte quatre, et
    -- cette expression n'en appariait que trois : elle rendait `false` pour
    -- TOUTE sauvegarde recente, donc ni l'horloge ni le quantize n'etaient
    -- restitues. Sans consequence visible — son unique appelant enchaine sur
    -- `LoadState`, qui refait le meme travail — mais une fonction qui rend
    -- toujours faux est un piege arme pour le prochain appelant.
    local nl
    local fr, arm, lq, n4 = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if fr then nl = n4 else
        fr, arm, lq = fields[2]:match("^([^|]*)|([^|]*)|([^|]*)$")
    end
    if not fr then fr, arm = fields[2]:match("^([^|]*)|([^|]*)$") end
    if not fr then return false end
    Loop.SetFreeRun(fr == "1")
    local old_lanes = math.floor(tonumber(nl) or 0)
    if old_lanes < 2 then old_lanes = LEGACY_LANES end
    local a = ((tonumber(fields[1]) or 0) >= 4)
              and math.floor(tonumber(arm) or -1) or -1
    -- LE MEME PAS QUE PARTOUT AILLEURS. Une lane armee designe une lane, et le
    -- nombre de colonnes a change : sans traduction, rouvrir un projet a quatre
    -- colonnes armerait la jumelle d'une autre.
    if a >= 0 then a = newOfLane(a, old_lanes) or -1 end
    Loop.AdoptArmedLane(a >= 0 and a or nil)
    if lq then Loop.SetLaunchQ(migrateQ(fields[1], tonumber(lq))) end
    return true
end

-- ---------------------------------------------------------------------------
-- AUTOSAVE
--
-- Persistence is a property of the STATE, not of one window. It used to live
-- privately inside CP_Looper, so a set built entirely in CP_Session was lost
-- when REAPER closed — invisible while you work, obvious the next morning.
--
-- ⚠️ LE DANGER INTER-PROJETS N'AVAIT PAS DISPARU, IL AVAIT DEMENAGE.
--
-- On a longtemps ecrit ici qu'il etait clos : les lanes vivaient dans gmem, qui
-- appartient a la SESSION REAPER et non au projet, et les notes vivent
-- maintenant dans ce module — « une instance par script, par projet ». La
-- premisse est fausse. Un `defer` SURVIT A UN CHANGEMENT D'ONGLET : la fenetre
-- ouverte passe du projet A au projet B sans etre rechargee, donc une seule
-- instance voit les deux. Et ProjExtState ecrit toujours dans le projet ACTIF.
--
-- Trois consequences, toutes silencieuses :
--   · l'autosave ecrit le set de A dans le fichier de B ;
--   · `RefreshDests` relit les destinations de B et rebranche les ports, donc
--     les lanes de A se mettent a jouer dans les pistes de B ;
--   · les identites de clip sont par projet, et `LaneOfTag` compare des nombres
--     bruts : deux projets peuvent porter le meme numero.
--
-- Le changement se DETECTE donc, et il vaut un rechargement complet. Une
-- comparaison de pointeur de projet, une fois par frame, sans allocation.
-- ---------------------------------------------------------------------------
local save_vers = {}
local save_due  = 0
local save_hold = false
local adopted   = false
local proj_seen = nil

-- « Le projet a change sous cette fenetre. » Le front est CONSOMME : l'appelant
-- doit tout recharger, et le lui redire a la frame suivante ferait recharger
-- deux fois. Une fenetre, un appel par frame.
function Loop.RouterChanged()
    local p = r.EnumProjects(-1)
    if proj_seen == nil then proj_seen = p return false end
    if p == proj_seen then return false end
    proj_seen = p
    -- ON CESSE D'ECRIRE AVANT TOUT LE RESTE. L'etat en memoire est celui du
    -- projet PRECEDENT ; un autosave qui partirait maintenant ecraserait le set
    -- du nouveau projet avec celui de l'ancien, ce qui est exactement la perte
    -- que cette detection existe pour empecher. `AdoptState` reprendra la main
    -- une fois le rechargement fait.
    adopted  = false
    save_due = 0
    for lane = 0, Loop.MAX_LANES - 1 do save_vers[lane] = nil end
    return true
end


function Loop.IsAdopted() return adopted end
function Loop.HoldAutoSave(on) save_hold = on and true or false end
function Loop.MarkDirty() if adopted then save_due = -1 end end

-- ADOPT the current state without saving it. Call this right after a recall:
-- otherwise the restore declares itself a modification, and the first save
-- writes over exactly what was just read back.
function Loop.AdoptState()
    for lane = 0, Loop.MAX_LANES - 1 do
        save_vers[lane] = Loop.EvtVersion(lane) * 8 + math.floor(Loop.Mode(lane) + 0.5)
    end
    save_due = 0
    adopted = true
end

function Loop.AutoSave()
    if not adopted or not NATIVE then return end
    local now = r.time_precise()
    if save_due < 0 then save_due = now + 0.4 end
    for lane = 0, Loop.MAX_LANES - 1 do
        -- Mode counts as much as notes do: launching or stopping a clip changes
        -- the state to restore while bumping no event version at all.
        local v = Loop.EvtVersion(lane) * 8 + math.floor(Loop.Mode(lane) + 0.5)
        if v ~= save_vers[lane] then
            save_vers[lane] = v
            save_due = now + 0.4
        end
    end
    if save_due > 0 and now >= save_due and not save_hold then
        save_due = 0
        Loop.SaveState()
    end
end

return Loop
