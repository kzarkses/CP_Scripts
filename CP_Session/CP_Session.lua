-- @description Session (CP) — Ableton-style clip grid over the CP Looper engine
-- @version 0.2 (tracks × scenes)
-- @author Cedric Pamalio
-- @about
--   The session grid: one COLUMN per track, one ROW per scene, one clip per
--   cell. A track plays exactly one clip at a time — launching a cell stops
--   whatever that track was playing, which is the whole feel of a session
--   view (see ANALYSE_Ableton_Session.md).
--
--   The engine (CP_Native, ABI 1.6) is untouched: each track owns TWO lanes,
--   a playing one and a silent twin. Launching writes the clip into the twin
--   (inaudible, so timing doesn't matter) then asks the engine for Play+Stop
--   — both quantized — so the swap lands exactly on the boundary.
--
--   Cells are edited ONLY in CP_Editor (double-click, or right-click → Edit):
--   they are stored as CPC1 descriptors in the project, and edits come back
--   live over the bus.
--
--   The engine is shared, and this window can create it: no other script has
--   to be opened first.

local r = reaper

-- ---------------------------------------------------------------------------
-- Toolkit + engine
-- ---------------------------------------------------------------------------
local cp_root = r.GetResourcePath() .. "/Scripts/CP_Scripts/"
local UI     = dofile(cp_root .. "CP_Toolkit/CP_Toolkit.lua")
local Tracks = dofile(cp_root .. "CP_Engine/Tracks.lua")
local Loop   = dofile(cp_root .. "CP_Engine/Loop.lua")
local Clip   = dofile(cp_root .. "CP_Engine/Clip.lua")
local Ident  = dofile(cp_root .. "CP_Engine/Ident.lua")
local Mix    = dofile(cp_root .. "CP_Engine/Mix.lua")
local DragBus = dofile(cp_root .. "CP_Toolkit/DragBus.lua")
local Bus    = dofile(cp_root .. "CP_Engine/Bus.lua")
-- for its tempo-match routine ONLY: the browser decides how fast a file is,
-- and this grid must reach the same answer for the same file. Its playback
-- half is never used here (sound cells own their previews).
local Preview = dofile(cp_root .. "CP_Engine/Preview.lua")
-- « A quelle vitesse va ce fichier » — une seule reponse pour toute la suite.
local SrcTempo = dofile(cp_root .. "CP_Engine/SrcTempo.lua")
-- La cuisson du warp : un etirement se rend une fois dans un fichier, il ne
-- se calcule pas a chaque bloc dans le fil audio.
local Bake   = dofile(cp_root .. "CP_Engine/Bake.lua")
local Warp   = dofile(cp_root .. "CP_Engine/Warp.lua")
-- The engine that makes a SOUND cell sound. With the CP extension installed it
-- is a CP voice, dated on the engine's own launch boundary and entering the
-- column pre-FX — no child track unless the column also holds an instrument,
-- no sampler plugin, nothing in anyone's FX chain.
local Voice  = dofile(cp_root .. "CP_Engine/Voice.lua")
local Cells  = dofile(cp_root .. "CP_Engine/Cells.lua")
local Keymap = dofile(cp_root .. "CP_Engine/Keymap.lua")
-- QUI RECOIT LA BARRE D'ESPACE. Cliquer une case ouvre le clip dans CP_Editor —
-- c'est le geste meme — mais le focus clavier reste ICI, et une fenetre gfx ne
-- recoit les touches que si elle a le focus. Space ne faisait donc rien : celle
-- qui savait quoi jouer ne la recevait pas, celle qui la recevait n'avait rien a
-- en faire. Cette grille est la DERNIERE de l'ordre — elle a son propre
-- transport, les cases — donc elle ne reclame jamais la touche : elle la passe.
local Focus  = dofile(cp_root .. "CP_Engine/Focus.lua")
-- UNE SEULE QUESTION POSEE A LA TOUCHE : quelle action ? Ce qui suit ne teste
-- plus jamais un code, donc changer une liaison ne demande de toucher a aucune
-- ligne de `handleKeys` — c'est tout l'objet du tableau, et c'est ce qui rend
-- la fenetre de reglages possible.
local KM = Keymap.Register("session",
                           dofile(cp_root .. "CP_Engine/Keymaps/session.lua"))
Tracks.init(r)
Focus.init(r)
Ident.init(r, Clip)
Loop.init(r, Tracks)
Mix.init(r)
DragBus.init(r)
Bus.init(r, DragBus, Clip)
Preview.init(r)
SrcTempo.init(r, Preview)   -- le cache de PCM_source, pour ne pas rouvrir le disque
Bake.init(r)
Warp.init(r, Bake)
Voice.init(r, Preview)

local Core = UI.Core
local sin, floor = math.sin, math.floor

-- One track = two engine lanes (playing + silent twin). That pairing is the
-- ENGINE's, not this window's: Loop.LiveLane / Loop.TwinLane answer for it,
-- so CP_Looper and CP_Editor see the same picture without a copy of the
-- rule living here to drift out of date.
local TRACKS = Loop.TRACKS
local SCENES = 8

-- Le compteur de fins de cuisson qu'on a deja vu passer (Warp.Version).
local warp_seen = 0

-- A sound cell IS a CP voice. There is no second path any more: the RS5K wiring
-- — a child track per column, two plugin instances in it, a filtered send and a
-- reserved MIDI channel — is gone, and with it the reason a launcher project
-- filled up with tracks nobody asked for.
--
-- The consequence, stated rather than discovered: without the engine extension,
-- sound cells do not sound. MIDI cells are untouched, and every arm says so in
-- one line instead of failing quietly.
local ENGINE_OK = Cells.init(r, Voice, Loop, TRACKS)

local cells = {}     -- [t][s] = clip descriptor or nil
local cur   = {}     -- [t] = scene whose clip is loaded, or nil
local cdrag = nil    -- { t, s } source cell while a Ctrl-drag copy is in flight
-- La derniere case effacee, et ou la reposer. UNE seule, pas une pile : ce
-- geste se fait une fois et on le regrette tout de suite ; une pile aurait
-- fait croire a une annulation generale de la grille, qui elle n'existe pas.
local erased = nil   -- { t, s, clip }
-- La case selectionnee, pour le clavier. Elle ne remplace aucun clic : elle
-- suit le dernier, et les fleches la deplacent.
local sel = { t = 0, s = 0 }
-- Geometry of each mixer strip as it was last drawn. Declared up here because
-- the drop consumer runs before the strips do: what lands on a strip has to be
-- resolved against where that strip WAS, which is the only place it can be.
local mix_col = {}   -- [t] = { x, y, w, h, fx_y, fx_rows }
for t = 0, TRACKS - 1 do cells[t] = {} end

local state = {
    flash_msg = "", flash_until = 0,
    recalled = false,      -- one-shot auto-recall after the first attach
    registered = false,    -- DragBus target registration
    grid = nil,            -- grid geometry (drop hit-testing)
    arow = nil,            -- audio-cell row geometry
    engine_checked = false,   -- one-shot "is the loaded engine current" probe
    engine_tried   = false,   -- one-shot auto-create (opening this window IS the ask)
}

local function flash(msg)
    state.flash_msg = msg
    state.flash_until = r.time_precise() + 2.5
end

-- "?" overlay content (standard help affordance, one per app)
local HELP_TEXT = [[
## What a column is
A COLUMN IS A TRACK OF YOUR PROJECT. Make a track in REAPER and a
column appears, bound to it; the columns follow the project's own
order. Click a column's NAME to point it somewhere else, to make a
new track, or to hide the column. There is nothing to route: a column
that has a track plays into it, through its FX and its fader.

## The grid
A column per track, a row per scene, one clip per cell. Every cell
carries the button that says what a click does: TRIANGLE launches,
SQUARE stops what is playing, CIRCLE records. Launching is QUANTIZED
(the Q button) and whatever that track was playing stops by itself —
a track only ever plays one clip.
The row of squares under the grid stops one track (or all of them,
the one on the left); the triangle beside a row launches that whole
scene, and tracks with no clip in it stop, as in Ableton.
CTRL-CLICK THE TRIANGLE to launch the scene ADDITIVELY: columns the
scene does not fill keep playing. That is how a pad or a drone
survives a scene change without being duplicated into all eight rows.

## Motion — what a column does at the end of a pass
Right-click a column NAME and pick Motion. Seven behaviours, one per
column: STAY (loop, the default), ONE SHOT (play once and stop),
MARCH & WRAP / & STAY / & STOP (step down to the next filled cell of
that column, then wrap, hold the last one, or stop), RANDOM and
EXCLUSIVE RANDOM (which never picks the cell that just played).
Empty cells are skipped, so a column with three clips marches on three.
A column whose motion is not Stay says so in its header: 1x, M>, M=,
M., R? or R!. The playing cell counts its passes on the right — xN.
The step is QUANTIZED like any launch: it is asked for inside the last
Q window so the engine lands it on the loop end. That only falls on
the loop end when the clip length is a MULTIPLE of Q — at Q: Bar a
three-beat clip steps on the next bar, which is what quantize means.
THIS RULE IS LUA, SO IT STOPS WITH THIS WINDOW. Close CP_Session while
a column is marching and the current clip keeps looping: the sound
carries on, the chaining does not.

## Keyboard
Arrows move the selection, PAGE UP / PAGE DOWN jump to the top and the
bottom of the column, ENTER launches the cell (an empty cell stops that
column), DELETE erases it. SHIFT+ENTER launches the whole SCENE and
steps down one — hit it again and again and you walk the set.
CTRL+ENTER does the same ADDITIVELY. CTRL+SHIFT+I captures whatever is
playing into the first empty scene row, with no audible interruption:
the clips are copied and the lanes simply answer that they now hold the
new row. Nothing is retriggered.
CTRL+Z puts back the last cell you erased — Alt-click and Delete are
one-handed shortcuts that destroy, so they have their way back. The
selection follows your last click, so the mouse and the keyboard never
disagree about where you are.

## Recording into a cell
1. ARM the track — the circle in its header. That is REAPER's own
   record-arm on that track: arming is how you choose which instrument
   you are playing, and nothing here arms or disarms behind your back.
2. Click the circle in any EMPTY cell of that track.
3. Play. A MIDI keyboard, or REAPER's virtual keyboard. Clicking pads in
   CP_Sampler does NOT record — a pad click is addressed to the kit's
   track and reaches nothing else, so it cannot land in a take.

The take does not start on your click: it waits for the next Q boundary,
and the cell counts the beats down so you can come in on time. It then
records for "Rec: N bars" and closes itself — there is nothing to press
to end it. A second click on the blinking button finalizes a take early,
or drops one that has not started.

With Clock: Follow and the transport stopped, the cell says PLAY: it is
armed and waiting for the transport. Press play and the take begins at
the next boundary. With Clock: Free the engine has its own clock, so it
starts without touching REAPER's transport.

## Editing
The button strip on the left of a cell is the transport; clicking
ANYWHERE ELSE in the cell opens it in CP_Editor (launched if needed) —
looking at a clip never changes what is playing, and launching is never
a side effect of wanting to edit. CP_Editor is the only place a cell is
edited: notes, loop length, playhead and transport live there, and the
edits come back here live. Right-click: edit, rename, COLOR, clear,
stop. A clip's colour is its own and travels with it — copy a cell and
the copy keeps it.

## Sound or MIDI, same cell
Any cell takes either. Drop a sound from the Media Explorer and it
loops TEMPO-MATCHED through that column's track. Drop or write MIDI
and it plays through the engine.

## How a sound follows the tempo — right-click, Tempo
THE LINE UNDER A SOUND CELL SAYS WHAT IT DECIDED, and where the number
came from: "128 BPM · name" (the filename said so), "· read" (REAPER
read the file, including an embedded tempo), "· set" (you or the
project decided it), "· guess" (worked out from the length alone, and
only when it is unambiguous). "no tempo found" means the file plays
untouched — which is worth knowing before wondering why it drifts.

SOURCE TEMPO… in the same menu is how you say it yourself. It beats
every other source, and the pass length is worked out again with it.

REPITCH is the default and it is the one that is in time: the sampler
reads faster or slower, which moves the pitch with it, exactly as every
hardware sampler has always done.

STRETCH keeps the key. A sampler cannot stretch without a window of
latency, so a stretched cell is RENDERED once to a file and played back
at normal speed. Until that file exists it plays as a repitch — in
time, which is what the launch was for, with only the key wrong — and
the cell says "repitch, rendering". When the render lands, the cell
picks it up by itself. If it fails, it says so, and the menu offers to
try again.

DON'T FOLLOW plays the file at its own tempo.

## Where a sound comes out
Through the column's own track: its FX chain, its fader, its meter.
There is no sampler track and no send — the engine pours the sound
straight into that track, and MIDI cells pour their notes into the same
one. That is why an instrument and sound cells share a column without
hearing each other.

## The mixer
The zone under the grid (toggle it beside the "?") is a channel strip
per column, acting on the track that column is routed to — so it is
also the level of whatever CP_Sampler or CP_Editor sends there.

DRAG ITS SEAM (the three dots) to say how tall you want it. The two
lists take exactly what they hold and never more than half the strip;
the FADER TAKES EVERYTHING ELSE, so a taller zone is mostly a taller
fader — which is what a console is.

Fader, meter, pan, M and S: Shift for fine, double-click for 0 dB (or
centre), wheel to step. Solo is REAPER's solo — the arrangement goes
quiet too, exactly as in Ableton. Ctrl-click it for exclusive.

FX CHAIN. Click a plugin to open it, Ctrl-click to bypass, Alt-click
to remove, right-click for all three. DRAG one to reorder it, or onto
another column to MOVE it there (Ctrl: copy). An FX dragged from the
Media Explorer lands in the strip you drop it on. Clicking an EMPTY
SLOT selects that column's track and opens REAPER's FX browser, so
what you pick lands in the slot you clicked; right-click it for
CP_FX Browser or the track's own chain. When the chain is longer than
the slots on screen, the thin bar on the right says so and the wheel
walks it.

SENDS. Each row is the send itself: DRAG it to set its level, CLICK it
to open REAPER's routing window (pre/post, channels, MIDI), right-
click to mute or remove it. To create one, drag an EMPTY SLOT onto the
column you want to send TO — the gesture says from here to there.
Clicking an empty slot instead lists the destinations.

## Clock, and what a launch waits for
The button says WHO OWNS THE CLOCK. Lit = FOLLOW: REAPER's transport,
which locks to an external MIDI clock when REAPER is slaved. Unlit =
FREE: the session runs on its own.

One rule, both clocks, and the whole of it:

STARTING needs a downbeat. Following a transport that is not running
there is none yet, so a launch WAITS FOR THE TRANSPORT — the cell says
so. The moment it rolls, the wait becomes an ordinary one: the launch
takes the next Q boundary from wherever the transport started. Press
play on a bar line with Q: Bar and it goes now; press it between two
bars and it waits for the next one, because that is what Q: Bar says.
Clips, sounds and takes all wait together, and all land together.

STOPPING needs no downbeat. On a running clock a clip finishes its bar;
with no clock there is nothing left to finish, so it stops now.

FREE RUN is the session's own transport, and it SITS STILL while the
session is silent. So the first thing you launch starts at once and is
itself the downbeat — a quantize is an agreement between clips, and it
costs nothing when there is no one to agree with. Everything launched
after it lands on the Q, against what is already playing.

## One engine
This grid, CP_Looper and CP_Editor drive the SAME engine and read the
same state — a clip launched in one shows as playing in the others.
CP_Looper's lane N is this grid's column N, and CP_Editor's playhead is
that clip's own. Whichever window you opened first can create the
engine.
]]

-- ---------------------------------------------------------------------------
-- Lane pairing — resolved by the engine (Loop.Poll re-derives it each frame)
-- ---------------------------------------------------------------------------
local liveLane  = Loop.LiveLane
local twinLane  = Loop.TwinLane
local isRunning = Loop.IsRunning

-- Every cell carries a numeric identity, so the lane holding it can say so
-- and any window can find that clip again after the halves swapped.
--
-- The identity belongs to the CLIP now (Engine/Ident), not to the coordinates
-- it happens to sit at. That is what makes a clip survive being moved, and
-- what stops a lane still holding last week's clip from answering yes when
-- asked whether it holds the one that took its place.
--
-- An empty cell has nothing to name, so it answers 0 — "untagged" — exactly
-- as an unrecorded slot always did. Recording is the one gesture that needs a
-- name BEFORE there is a clip; recCell reserves one.
local function cellTag(t, s)
    local c = cells[t] and cells[t][s]
    if not c then return 0 end
    return Ident.Of(c)
end

-- Which scene of track t a lane is holding, straight from the engine's tag.
-- This is how the grid follows a launch fired from CP_Looper or CP_Editor
-- instead of arguing with it. Ident.CellOf reads both number spaces, so a
-- project written before identities existed still resolves.
local function sceneOfLane(lane, t)
    local tt, ss = Ident.CellOf(Loop.GetLaneTag(lane))
    if tt ~= t then return nil end
    return ss
end

-- ---------------------------------------------------------------------------
-- Display caches (zero allocation per frame: strings rebuilt only when the
-- underlying fact changes)
-- ---------------------------------------------------------------------------
local track_name = {}   -- [t] = { tr = ptr|false, s = "name" }
local bars_lbl   = {}   -- [bars] = "N bars"
local cell_lbl   = {}   -- [t*SCENES+s] = { src = "name", w = width, s = "cut" }
-- Primed with the ANSWER FOR AN UNROUTED COLUMN, not with a guess. It used to
-- be primed with "Track N", and since the cache only recomputes when the
-- destination CHANGES, an unrouted column kept printing a name for a track it
-- had never been connected to — false > false is never true, so the branch that
-- would have said "no track" never ran. The header lied exactly where its own
-- comment says it must not.
for t = 0, TRACKS - 1 do track_name[t] = { tr = nil, known = false, s = "no track" } end

-- A column is a LANE, and a lane plays into whatever track it is routed to
-- (CP_Looper's routing, shared). Saying "Track 1" when nothing is routed
-- would be a lie — an unrouted column plays into nothing, and the header
-- has to admit it.
local function trackName(t)
    local c = track_name[t]
    local tr = Loop.GetLaneDest(t)
    -- Three symptoms, one cause, and the gate has to close all three:
    --   · `known` — without it the very first computation is skipped whenever
    --     the answer happens to equal the primed value, and the primed value is
    --     precisely the one we have not verified yet;
    --   · the pointer — a column routed somewhere else;
    --   · the project's change count — RENAMING the track changes neither of
    --     the first two, so the header kept the old name until something else
    --     happened to invalidate it.
    -- The count is one integer read per column per frame, and it is what every
    -- other cache in this window watches.
    local chg = r.GetProjectStateChangeCount(0)
    if not c.known or tr ~= c.tr or chg ~= c.chg then
        c.known = true
        c.tr = tr
        c.chg = chg
        if tr then
            local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            if nm and nm ~= "" then
                c.s = nm
            else
                local n = math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
                c.s = "Track " .. n
            end
        else
            c.s = "no track"
        end
    end
    return c.s
end

-- ---------------------------------------------------------------------------
-- LE MOTION — ce qu'une colonne fait a la fin d'une passe
-- ---------------------------------------------------------------------------
-- FL appelle ca Motion, et c'est PAR PISTE : Stay, One shot, March & wrap,
-- March & stay, March & stop, Random, Exclusive random. Ableton fait la meme
-- chose PAR CLIP, avec dix Follow Actions et deux probabilites. Le grain
-- COLONNE d'abord, deliberement : il faut savoir s'il suffit avant de
-- construire un panneau par case.
--
-- CE QUI CHANGE DE NATURE ICI. Jusqu'a maintenant la grille EXECUTE des ordres :
-- on clique, ca part. Avec le motion elle en PRODUIT — une colonne descend ses
-- huit cases toute seule, et ce qu'on entend cesse d'etre la somme des clics.
-- C'est le seul chantier de cette fenetre qui change ce qu'elle EST.
--
-- ⚠️ CETTE REGLE EST EN LUA, DONC ELLE S'ARRETE AVEC LA FENETRE. Ableton et FL
-- n'ont pas ce probleme parce que leur moteur porte la regle. Fermer CP_Session
-- pendant qu'une colonne marche laisse la case en cours tourner en boucle : le
-- SON continue, l'enchainement s'arrete. Descendre la regle dans le C++ est un
-- autre chantier, et il se decide a l'usage — la question est de savoir si on
-- ferme cette fenetre en jouant, et elle n'a pas de reponse theorique.
local MOTION_STAY, MOTION_ONCE  = 0, 1
local MOTION_WRAP, MOTION_MSTAY, MOTION_MSTOP = 2, 3, 4
local MOTION_RAND, MOTION_XRAND = 5, 6
local MOTION_LAST = 6

local MOTION_LABEL = {
    [0] = "Stay",
    "One shot",
    "March & wrap",
    "March & stay",
    "March & stop",
    "Random",
    "Exclusive random",
}
-- Deux caracteres dans l'en-tete de colonne, parce que c'est tout ce qu'il y a.
-- Ils ne sont pas devinables et n'ont pas a l'etre : ils disent « cette colonne
-- ne fait pas que boucler », et le nom entier est a un clic dans le menu.
-- Stay ne dessine rien — le defaut n'a pas a se signaler.
local MOTION_TAG = { [0] = "", "1x", "M>", "M=", "M.", "R?", "R!" }

local motion = {}    -- [t] = un des sept
-- L'etat de suivi d'une colonne. `pz` est la phase DANS LA ZONE de la passe
-- precedente : c'est son repli qui date une fin de passe, et il n'y a rien
-- d'autre a stocker.
local mot = {}       -- [t] = { lane, tag, pz, armed, plays }
for t = 0, TRACKS - 1 do
    motion[t] = MOTION_STAY
    mot[t] = { lane = -1, tag = 0, pz = 0, armed = false, plays = 0 }
end
-- Un tirage qui rend la meme suite a chaque ouverture de REAPER n'est pas un
-- tirage. Une fois, ici : `math.random` est global au script.
math.randomseed(floor((r.time_precise() * 1000) % 2147483647))

local function saveMotion()
    local out = {}
    for t = 0, TRACKS - 1 do
        if motion[t] ~= MOTION_STAY then
            out[#out + 1] = t .. "=" .. motion[t]
        end
    end
    r.SetProjExtState(0, "CP_Session", "motion", table.concat(out, ","))
end

local function loadMotion()
    local _, blob = r.GetProjExtState(0, "CP_Session", "motion")
    if not blob or blob == "" then return end
    for ts, ms in blob:gmatch("(%d+)=(%d+)") do
        local t, m = tonumber(ts), tonumber(ms)
        if t and m and t < TRACKS and m >= 0 and m <= MOTION_LAST then
            motion[t] = m
        end
    end
end

local function motionMenu(t)
    local items = {}
    for m = 0, MOTION_LAST do
        items[#items + 1] = {
            label = MOTION_LABEL[m],
            checked = (motion[t] == m),
            action = function()
                motion[t] = m
                saveMotion()
                -- Le suivi repart : changer de regle en cours de passe ne doit
                -- pas tirer sur une fenetre qu'on a deja traversee.
                local f = mot[t]
                f.lane, f.armed = -1, false
                flash(trackName(t) .. " — motion: " .. MOTION_LABEL[m])
            end,
        }
    end
    return items
end

-- Route this column: pick any project track, or make one. This is the same
-- routing CP_Looper edits — one truth, two windows.
local function trackMenu(t)
    local items = {}
    local n = r.CountTracks(0)
    local cur_tr = Loop.GetLaneDest(t)
    for i = 0, n - 1 do
        local tr = r.GetTrack(0, i)
        -- Every project track is offerable now. The router used to be in this
        -- list and had to be filtered out — it hosted the engine and sent
        -- nothing to itself, so choosing it silently unrouted the column.
        do
            local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            items[#items + 1] = {
                label = (i + 1) .. ": " .. ((nm and nm ~= "") and nm or "(unnamed)"),
                checked = (tr == cur_tr),
                action = function()
                    Loop.SetLaneDest(t, tr)      -- routes BOTH halves of the pair
                    track_name[t].known = false  -- force the cached name to refresh
                end,
            }
        end
    end
    if #items > 0 then items[#items + 1] = { separator = true } end
    items[#items + 1] = { label = "New track for this column", action = function()
        Loop.NewDestTrack(t)
        track_name[t].known = false
    end }
    -- "Unroute" is gone, and its absence is the point: it manufactured exactly
    -- the state the window now refuses to show — a column wired to nothing.
    -- What replaces it says what someone actually wants: keep the track, stop
    -- giving it a column. The mark travels in the project, so the choice
    -- survives closing the window.
    if cur_tr and Tracks and Tracks.Mark then
        items[#items + 1] = { label = "Hide this column", action = function()
            Tracks.Mark(cur_tr, "session", "hidden")
            Loop.SetLaneDest(t, nil)
            track_name[t].known = false
        end }
    end
    -- CE QUE CETTE COLONNE FAIT A LA FIN D'UNE PASSE. Le menu est celui du nom
    -- de colonne parce que le motion est une propriete de la COLONNE, pas d'une
    -- case : le declarer huit fois serait le declarer nulle part.
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Motion", children = motionMenu(t) }
    UI.NativeMenu(items)
end

-- QUI FAIT LE SON, EN CLAIR ET EN PERMANENCE.
--
-- « Impossible de savoir si c'est le nouveau moteur ou pas » : c'etait vrai.
-- Voice.Backend(), Voice.Diag(), Audition.Backend() et Audition.Diag()
-- existaient et n'etaient appelees nulle part, et le seul affichage de la suite
-- etait garde par `if ENGINE_OK` — donc muet exactement dans le cas qu'on
-- cherchait a detecter.
--
-- Construite une fois : elle part dans une boucle de dessin.
local ENGINE_BADGE = "engine " .. Voice.Label() .. " · cells: "
                     .. (ENGINE_OK and "voices" or "silent")
local function engineBadge() return ENGINE_BADGE end

-- UNE PASSE PLUS COURTE QU'UNE MESURE A UN NOM, et c'est un nom de musicien.
-- « 0.25 bars » se lit comme un reglage rate ; « 1/4 bar » se lit comme une
-- figure. Le plancher est le huitieme de mesure : celui du moteur.
local BAR_FRACTION = { [0.125] = "1/8 bar", [0.25] = "1/4 bar", [0.5] = "1/2 bar" }
local function barsLabel(bars)
    local s = bars_lbl[bars]
    if not s then
        s = BAR_FRACTION[bars] or (bars == 1 and "1 bar" or (bars .. " bars"))
        bars_lbl[bars] = s
    end
    return s
end

-- Le compteur de passes, en chaine. Bati une fois par valeur et plafonne a 99,
-- ce qui borne la table : ce texte part dans une boucle de dessin qui tourne en
-- continu pendant qu'une case joue, et une concatenation par frame et par case
-- est exactement ce que ce fichier passe son temps a eviter.
local plays_lbl = { [0] = "" }
local function playsLabel(n)
    if n > 99 then n = 99 end
    local s = plays_lbl[n]
    if not s then
        s = (n >= 99) and "x99+" or ("x" .. n)
        plays_lbl[n] = s
    end
    return s
end

-- Truncation allocates, so the cut string is cached against (name, width).
--
-- LA CLE RESERVE UNE LIGNE DE PLUS QUE LA GRILLE, et ce n'est pas de la marge :
-- l'EN-TETE de colonne appelle cette fonction avec `s = SCENES`, donc a
-- `t * SCENES + s` il calculait exactement l'emplacement de la case (t+1, 0).
-- Les deux s'invalidaient l'un l'autre a chaque frame — une troncature par
-- colonne et par frame, dans la boucle de dessin que ce cache existe pour
-- vider. A huit colonnes le defaut passait de trois collisions a sept.
local function cellLabel(t, s, name, w)
    local k = t * (SCENES + 1) + s
    local c = cell_lbl[k]
    if not c then c = {}; cell_lbl[k] = c end
    if c.src ~= name or c.w ~= w then
        c.src, c.w = name, w
        c.s = (Core.TruncateText(name, w))
    end
    return c.s
end

-- Launch quantize and take length are CHOICES among a handful, not buttons
-- that cycle. As combos the wheel walks them, the current setting reads
-- without clicking, and you land on the one you want instead of pressing four
-- times. Both lists are stored in beats / bars so the engine never needs to
-- know about the words.
local Q_ITEMS = { "Q: Off", "Q: Beat", "Q: Bar", "Q: 2 bars", "Q: 4 bars" }
local Q_OPTS  = { w = 3 }
local TITLE_OPTS = { title = "Session" }

local function qIndex()
    local q, tsn = Loop.GetLaunchQ(), Loop.TsNum()
    if q <= 0 then return 1 end
    if q == 1 then return 2 end
    if q == tsn then return 3 end
    if q == tsn * 2 then return 4 end
    if q == tsn * 4 then return 5 end
    return 1
end

local function setQIndex(i)
    local tsn = Loop.TsNum()
    local nq = 0
    if i == 2 then nq = 1
    elseif i == 3 then nq = tsn
    elseif i == 4 then nq = tsn * 2
    elseif i == 5 then nq = tsn * 4 end
    Loop.SetLaunchQ(nq)
end

-- How long a take runs. The engine records for the lane's length and closes
-- the take itself (one click in, nothing to press to end it) — so unlike
-- Ableton, where a session recording is open-ended until you stop it, the
-- length has to be known BEFORE the take. Leaving it to whatever the lane
-- happened to hold made it unknowable; it is a stated setting now, next to
-- the quantize that says when the take starts. Saved with the project.
local REC_BARS  = { 1, 2, 4, 8 }
local REC_ITEMS = { "Rec: 1 bar", "Rec: 2 bars", "Rec: 4 bars", "Rec: 8 bars" }
local rec_bars = 1

local function recBarsIndex()
    for i = 1, #REC_BARS do
        if REC_BARS[i] == rec_bars then return i end
    end
    return 1
end

local function setRecBarsIndex(i)
    rec_bars = REC_BARS[i] or 1
    r.SetProjExtState(0, "CP_Session", "rec_bars", tostring(rec_bars))
end

-- The status line carries the transport, so it changes — but only when the
-- transport does. Cached on (playing, tempo): string.format in a frame path
-- allocates, and this one runs on every frame of a window that redraws
-- continuously while clips play.
local stat = { play = nil, bpm = -1, s = "" }
-- Le pire ecart d'attaque, mis en forme une fois par valeur. Voir la zone de
-- statut : ce nombre existait et n'etait affiche nulle part.
local onset_lbl = { ms = nil, n = -1, s = "" }
local STAT_HINT =
    "  ·  left strip = launch/stop/record · click the cell = edit in CP_Editor · triangle = scene"

local function statusLine()
    local playing = Loop.Playing() and true or false
    local bpm = Loop.Tempo() or 0
    if stat.play ~= playing or stat.bpm ~= bpm then
        stat.play, stat.bpm = playing, bpm
        stat.s = string.format("%s   %.1f BPM%s", playing and "PLAY" or "STOP",
                               bpm, STAT_HINT)
    end
    return stat.s
end

-- ---------------------------------------------------------------------------
-- The grid, stored with the project (CPC1 per cell, one per line — the
-- descriptor escapes newlines, so the split is safe)
-- ---------------------------------------------------------------------------
-- QUELS SLOTS TIENNENT QUELQUE CHOSE. Seul l'hote le sait — `Loop` ne connait
-- pas les cases — et c'est ce qui empeche un slot LIBERE par la suppression de
-- sa piste d'etre adopte par la piste suivante, qui arriverait avec les huit
-- clips de l'ancienne. Ici plutot que dans une boucle de frame : ca ne change
-- que quand la grille change, et c'est exactement ce que `saveGrid` signale.
local function syncHeld()
    for t = 0, TRACKS - 1 do
        local any = false
        for s = 0, SCENES - 1 do
            if cells[t][s] then any = true break end
        end
        Loop.SetSlotHeld(t, any)
    end
end

local function saveGrid()
    local out = {}
    for t = 0, TRACKS - 1 do
        for s = 0, SCENES - 1 do
            local c = cells[t][s]
            if c then
                out[#out + 1] = t .. ":" .. s .. ":" .. Clip.serialize(c)
            end
        end
    end
    r.SetProjExtState(0, "CP_Session", "grid", table.concat(out, "\n"))
    syncHeld()
end

local function loadGrid()
    local _, blob = r.GetProjExtState(0, "CP_Session", "grid")
    if not blob or blob == "" then return end
    for line in blob:gmatch("[^\n]+") do
        local t, s, body = line:match("^(%d+):(%d+):(.*)$")
        t, s = tonumber(t), tonumber(s)
        if t and s and t < TRACKS and s < SCENES and body then
            local c = Clip.deserialize(body)
            -- Register the identity the descriptor carries: a lane that was
            -- already holding this clip when the project closed comes back
            -- tagged with a number, and nothing would resolve it otherwise.
            if c then cells[t][s] = c; Ident.Bind(c) end
        end
    end
    -- AVANT LA PREMIERE ADOPTION, sinon elle a deja eu lieu : `Loop.reconnect`
    -- tourne a l'initialisation du module, mais `RefreshDests` repasse toutes
    -- les demi-secondes, et c'est ce passage-la qui doit trouver les slots deja
    -- declares occupes.
    syncHeld()
end

-- ---------------------------------------------------------------------------
-- Audio cells. A cell holds EITHER a MIDI clip or a sound — same grid, same
-- gestures, interchangeable. Both are CLIPS in an engine lane now: the MIDI
-- one plays through the column's instrument, the sound one through a sampler
-- on the column's own sampler track, on a channel of its own. Exclusivity
-- falls out of that instead of being enforced twice — a lane plays one thing.
-- ---------------------------------------------------------------------------
-- HOW FAST a sound must run to sit at the project's tempo, and whether that
-- rate is allowed to move its pitch. The clip's own announced tempo wins when
-- it carries one; otherwise the SAME routine the browser used to audition this
-- file decides. Two windows disagreeing about how fast a file is was one of the
-- ways a sound could be in time in the arrange and out of it here: the browser
-- falls back to the BPM written in the filename when REAPER's tempo-match
-- declines to guess, and this window did not.
--
-- One answer for the whole window: the launch asks it when it opens the file,
-- the cell menu asks it again when the mode changes under a sound that is
-- already playing. Costly (REAPER analyses the source), so it is asked once
-- per open and once per menu click, never per frame.
local function rateFor(c)
    local mode = c.tempo_mode or "repitch"
    if mode == "none" then return 1.0, false end
    -- ONE answer for the whole suite (Engine/SrcTempo, roadmap phase 3). The
    -- clip's own announced tempo is the "declared" source and still wins; what
    -- changed is that when it has none, the browser, this grid and the sampler
    -- now reach the SAME conclusion about the same file instead of three.
    local rt, bpm, why = SrcTempo.Rate(c.path, { declared = c.src_bpm })
    -- LA RAISON FAIT PARTIE DE LA REPONSE. SrcTempo la rend depuis toujours
    -- (« declared », « analysed », « named », « inferred ») et l'en-tete du
    -- module explique pourquoi ; ici on la jetait. « Je ne suis jamais sur que
    -- le sample soit bien tempo-matche » etait un probleme d'affichage.
    return rt, (mode == "stretch"), bpm, why
end

-- WHAT to play, and AT WHAT RATE — the two halves of the same answer.
--
-- A repitch reads the file faster and the key moves with it: nothing to
-- prepare, and the rate goes straight to the voice. A STRETCH keeps the key,
-- and REAPER's live stretcher costs 2.3 % of the audio thread per voice plus
-- 85 to 139 ms before its first sample comes out — a clip that has to land on
-- the boundary cannot spend a tenth of a second thinking. So the stretch is
-- COOKED once to a file (Engine/Warp) and played back at 1.0, which costs
-- what any other sample costs.
--
-- Until the cooked file exists the cell plays as a repitch: in time, which is
-- what the launch was for, with only the key wrong and only for one pass.
-- Silence would have been purer and useless.
local function soundFor(c)
    local rate, stretch = rateFor(c)
    return Warp.Resolve(c, rate, stretch)
end

local function isAudio(c) return c and c.kind == "audio" and c.path end

-- Pass lengths a musical loop lands on. A file that misses all of them by more
-- than 6 % is not a loop at this tempo, whatever its name claims.
local BAR_GRID = { 0.5, 1, 2, 4, 8, 16, 32 }

-- HOW LONG A SOUND'S PASS IS — read from the FILE, not from a default.
--
-- This was the defect behind "it plays the kick, then lasts some length I do
-- not understand": nothing ever wrote `bars` on a sound. Bus.TakeDrop builds an
-- audio clip carrying only its path, and cellBars answers 4 for anything
-- without one. Four bars is sixteen beats — eight seconds at 120 — so a 0.4 s
-- kick played once and went quiet for 7.6 s, forever, on a period nothing in
-- the interface named.
--
-- The rule has three answers, in this order:
--   1. DECLARED — the cell already carries a length (edited, or reloaded from a
--      saved project). Nothing to guess.
--   2. A MUSICAL LOOP — SrcTempo believes a tempo AND the file is long enough
--      to BE a loop at it. SrcTempo's own guard is two beats, which is enough
--      to trust a name and not enough to fill a bar; here it is one bar.
--   3. A ONE-SHOT — the pass stays one bar, because a lane is a grid and a
--      sub-bar lane pollutes the phase, the countdown and the display. It is
--      the MATERIAL that loops inside the voice (see Cells.playAt).
--
-- Costly: SrcTempo opens the source. Called once when a cell is filled, never
-- per frame.
local function soundBars(c)
    local len = SrcTempo.Length(c.path)
    local tsn = Loop.TsNum() or 4
    if not len or len <= 0 then return 1 end
    -- LA REGION, PAS LE FICHIER. Une tranche de deux temps prise dans un break
    -- de quatre mesures fait deux temps, pas quatre mesures — et c'est la
    -- longueur de la REGION qui decide de la passe. Mesurer le fichier faisait
    -- qu'une case decoupee occupait la place de son fichier entier, ce qui est
    -- exactement ce qui rendait le decoupage inutilisable.
    if c.len and c.len > 0 then
        len = c.len
    elseif c.offs and c.offs > 0 then
        len = len - c.offs
        if len <= 0 then return 1 end
    end
    local mode = c.tempo_mode or "repitch"
    local bpm = (mode ~= "none") and SrcTempo.Bpm(c.path, c.src_bpm) or nil
    if bpm and bpm > 0 and len >= (60 / bpm) * tsn * 0.9 then
        local bars = (len * bpm / 60) / tsn
        for i = 1, #BAR_GRID do
            local g = BAR_GRID[i]
            if bars >= g * 0.94 and bars <= g * 1.06 then return g end
        end
        local w = floor(bars + 0.5)
        return (w >= 1) and w or 1
    end
    return 1
end

-- LE TEMPO RETENU ET SA RAISON, calcules UNE FOIS et gardes sur la case.
--
-- Couteux : SrcTempo ouvre la source. Appele la ou soundBars l'est deja — au
-- depot, a la migration, a l'armement — jamais par frame. Les deux champs sont
-- de l'affichage : ils ne sont pas serialises, et ils se recalculent a
-- l'ouverture du projet par le meme chemin.
local function ensureTempo(c)
    if not (c and c.path) then return end
    local mode = c.tempo_mode or "repitch"
    if mode == "none" then
        c.bpm_seen, c.bpm_why = nil, "off"
        return
    end
    local bpm, why = SrcTempo.Bpm(c.path, c.src_bpm)
    c.bpm_seen, c.bpm_why = bpm, why
end

-- Comment le dire en trois mots sous une case. Volontairement court : la ligne
-- fait douze pixels de haut et partage la case avec le nom du clip.
local WHY_SHORT = {
    declared = "set",       -- quelqu'un l'a decide, ici ou dans le projet
    analysed = "read",      -- REAPER a lu le fichier (tempo embarque compris)
    named    = "name",      -- le nom du fichier l'annonce
    inferred = "guess",     -- deduit de la seule duree, et sous garde
}

-- Memo par case : cette ligne part dans une boucle de dessin, et la construire
-- par frame allouerait une chaine par case et par frame. Elle ne change que
-- quand un de ses termes change, ce qui arrive au clic, pas au rafraichissement.
local sub_txt = setmetatable({}, { __mode = "k" })
-- `sub_key[c]` tient les QUATRE COMPOSANTES separement, et non une chaine qui
-- les concatene : construire la cle coutait exactement ce que le cache existait
-- pour eviter — une allocation par case audio et par frame.
local sub_key = setmetatable({}, { __mode = "k" })

-- L'ETAT DE CUISSON NE SE REDEMANDE PAS PAR FRAME. Warp.State ouvre un
-- fichier (PathFor puis io.open) : c'est un acces DISQUE dans une boucle de
-- dessin, pour chaque case en stretch, soixante fois par seconde. Il ne change
-- qu'a la fin d'une cuisson, et Warp.Version() dit exactement quand — c'est
-- pour ca qu'elle existe. On le relit donc quand la version bouge, et jamais
-- entre deux.
local st_cache = setmetatable({}, { __mode = "k" })
local st_ver   = -1

local function audioSub(c)
    local mode = c.tempo_mode or "repitch"
    local st = "none"
    local wv = Warp.Version and Warp.Version() or 0
    if wv ~= st_ver then
        st_ver = wv
        st_cache = setmetatable({}, { __mode = "k" })
    end
    if mode == "stretch" then
        local s0 = c.offs or 0
        st = st_cache[c]
        if st == nil then
            st = Warp.State(c.path, s0, c.len and (s0 + c.len) or 0,
                            r.Master_GetTempo() or 120) or "none"
            st_cache[c] = st
        end
    end
    local bpm = c.bpm_seen
    -- LA CLE ETAIT UNE CHAINE, CONSTRUITE A CHAQUE FRAME. Trois concatenations
    -- et un `string.format` par case audio et par frame, uniquement pour savoir
    -- s'il fallait reconstruire un texte qui ne change jamais. On compare les
    -- QUATRE COMPOSANTES : aucune allocation tant que rien ne bouge, ce qui est
    -- le cas de toutes les frames sauf une sur mille.
    local e = sub_key[c]
    if not e then e = {}; sub_key[c] = e end
    if e.mode ~= mode or e.st ~= st or e.bpm ~= bpm or e.why ~= c.bpm_why then
        e.mode, e.st, e.bpm, e.why = mode, st, bpm, c.bpm_why
        local txt
        if mode == "none" then
            txt = "audio · free"
        elseif not bpm then
            -- ET ON LE DIT. Sans tempo, la case joue le fichier tel quel, et
            -- l'utilisateur avait le droit de croire qu'elle etait calee.
            txt = "audio · no tempo found"
        else
            txt = string.format("%g BPM · %s", bpm,
                                WHY_SHORT[c.bpm_why or ""] or "?")
        end
        if mode == "stretch" then
            if st == "ready" then txt = txt .. " · stretched"
            elseif st == "queued" or st == "baking" then
                txt = txt .. " · repitch, rendering"
            elseif st == "failed" then txt = txt .. " · stretch failed"
            else txt = txt .. " · repitch" end
        end
        sub_txt[c] = txt
    end
    return sub_txt[c]
end

-- A length in BARS, and fractions are legitimate: half a bar is a real loop,
-- and the engine goes down to an eighth. Rounding to whole bars here is what
-- used to turn a two-beat loop into a four-bar one.
local function cellBars(c)
    local b = c and c.bars or 4
    if not b or b <= 0 then b = 4 end
    if b < 0.125 then b = 0.125 end
    return b
end

-- A sound cell whose length was never established gets one, once. Called from
-- the two places a cell is FILLED, plus a safety net at arm time for projects
-- saved before this existed.
local function ensureBars(c)
    if c and c.kind == "audio" and c.path then
        -- Le tempo d'abord : soundBars s'en sert pour decider si le fichier est
        -- assez long pour ETRE une boucle a ce tempo-la.
        if c.bpm_why == nil then ensureTempo(c) end
        if not c.bars then c.bars = soundBars(c) end
    end
    return c
end

local function cellNotes(c)
    local n = c and c.notes
    return (n and n.s and #n.s) or 0
end

-- ---------------------------------------------------------------------------
-- A SOUND CELL IS A CLIP OF ONE NOTE, AND A SAMPLER THAT HOLDS THE FILE.
--
-- The whole reason: a preview is read on demand inside the audio thread, and at
-- a 64-sample buffer — which is what anyone performing actually uses — it misses
-- its deadlines and simply STOPS ADVANCING. Measured at 0.54x real time, against
-- 1.0000x at 1024. A sampler cannot be starved: its sample is in memory and it
-- runs in the normal render pass, which is exactly why a MIDI clip measured 1 ms
-- through the same track, the same card and the same buffer.
--
-- So a sound stops being a second engine and becomes CONTENT for the one that
-- already works. Everything a clip gets for free comes with it: the quantized
-- launch, the queued stop, the swap on one boundary, the scene, the countdown —
-- none of it written twice. And everything the preview needed in order to guess
-- where it was (elapsed, offsets, the phase lock, the early fire, the frame
-- measurement) goes away, because you only compensate for what you could not
-- place.
--
-- The note is a FIXED root on every column. Columns are told apart by CHANNEL,
-- not by pitch, so nothing in the clip is column-specific — which is what lets a
-- cell be copied, pasted or dragged to another column and still be right.
-- ---------------------------------------------------------------------------
-- The live half plays the root; the twin answers one semitone up, so the two
-- clips in flight during a queued swap never share a voice. Fixed on every
-- column — columns are told apart by CHANNEL — which is what lets a cell be
-- copied or dragged to another column and still be right.
local AUDIO_NOTE = 60
local function laneNote(lane)
    return AUDIO_NOTE + ((lane >= TRACKS) and 1 or 0)
end
-- The note stops slightly before the loop does, and the SOUND stops with it:
-- obeying the note-off is what lets a sample release before the next pass
-- instead of being cut by the pass that follows.
local AUDIO_GATE = 0.97

local function samplerGuid(t)
    local _, g = r.GetProjExtState(0, "CP_Session", "smp" .. t)
    return (g ~= "" ) and g or nil
end

local function trackByGuid(g)
    if not g then return nil end
    for i = 0, r.CountTracks(0) - 1 do
        local tr = r.GetTrack(0, i)
        if r.GetTrackGUID(tr) == g then return tr end
    end
    return nil
end

-- A FOLDER CHILD of the column's own track, so its audio passes through that
-- column's fader, FX and meter. A sibling would reach the master while skipping
-- all three — which is the defect the preview had, not a fix for it.
--
-- It exists for ONE reason, and only when that reason applies: a track whose
-- chain holds an instrument SWALLOWS audio put into it, because the instrument
-- writes its own output over the buffer. A column that only plays sounds needs
-- nothing at all — see audioDest. It holds no plugin now: it is a receiver.
local function soundChild(t, make)
    local tr = trackByGuid(samplerGuid(t))
    if tr and r.ValidatePtr2(0, tr, "MediaTrack*") then return tr end
    if not make then return nil end
    local dest = Loop.GetLaneDest(t)
    if not (dest and r.ValidatePtr2(0, dest, "MediaTrack*")) then return nil end
    local idx = floor(r.GetMediaTrackInfo_Value(dest, "IP_TRACKNUMBER") + 0.5)
    if idx < 1 then return nil end
    local depth = r.GetMediaTrackInfo_Value(dest, "I_FOLDERDEPTH") or 0
    r.InsertTrackAtIndex(idx, false)          -- IP_TRACKNUMBER is 1-based: this IS "just after"
    local child = r.GetTrack(0, idx)
    if not child then return nil end
    if depth < 1 then
        -- the column becomes a folder and this child closes it — plus whatever
        -- the column itself used to close, or the folders above lose their end
        r.SetMediaTrackInfo_Value(dest, "I_FOLDERDEPTH", 1)
        r.SetMediaTrackInfo_Value(child, "I_FOLDERDEPTH", depth - 1)
    end
    local nm = trackName(t)
    r.GetSetMediaTrackInfo_String(child, "P_NAME",
                                  (nm ~= "" and nm or ("Track " .. (t + 1))) .. " smp", true)
    r.SetProjExtState(0, "CP_Session", "smp" .. t, r.GetTrackGUID(child))
    return child
end

-- WHERE A SOUND CELL'S AUDIO GOES, in the voice path.
--
-- A track whose chain holds an instrument SWALLOWS audio put into it — the
-- instrument writes its own output over the buffer. That is why the RS5K wiring
-- used a child track, and it was not a whim. So: a column with no instrument
-- receives the sound directly and costs no extra track at all; a column that
-- also plays notes keeps a child, but an EMPTY one — no RS5K, no plugin window,
-- no parameter write per arm.
local function audioDest(t)
    local dest = Loop.GetLaneDest(t)
    if not (dest and r.ValidatePtr2(0, dest, "MediaTrack*")) then return nil end
    if r.TrackFX_GetInstrument(dest) < 0 then return dest end
    return soundChild(t, true)
end
Cells.SetDestResolver(audioDest)

-- The one-note clip, synthesized and never stored: a cell keeps its PATH, and
-- the note is an implementation of playing it. Reused in place, so arming costs
-- no allocation.
local AUDIO_CLIP = { kind = "midi", bars = 4,
                     notes = { s = { 0 }, l = { 4 }, p = { AUDIO_NOTE }, v = { 127 } } }
local function audioClip(c, lane)
    local bars = cellBars(c)
    AUDIO_CLIP.bars = bars
    -- ⚠️ CE QUE LA CASE PORTE DOIT VOYAGER AVEC ELLE, ET C'EST TOUT LE DEFAUT.
    --
    -- Ce descripteur synthetique est le SEUL que la lane recoive pour une case
    -- audio, et `Loop.ApplyClip` ecrit TOUJOURS la signature et l'accolade —
    -- exprès, pour effacer celles de l'occupant precedent d'une lane partagee.
    -- Ne pas les recopier ici les effacait donc a chaque armement : regler la
    -- signature d'une case audio « ne changeait rien », parce que le lancement
    -- suivant la remettait a zero. Le reglage marchait une seconde, puis plus.
    AUDIO_CLIP.tsnum  = c.tsnum
    AUDIO_CLIP.loop_a = c.loop_a
    AUDIO_CLIP.loop_b = c.loop_b
    -- La signature de LA CASE ici aussi : c'est elle qui decide de la longueur
    -- en beats, donc de la porte de la note unique.
    AUDIO_CLIP.notes.l[1] = bars * (c.tsnum or Loop.TsNum() or 4) * AUDIO_GATE
    AUDIO_CLIP.notes.p[1] = laneNote(lane)
    return AUDIO_CLIP
end

-- REPOUSSER CE QU'UNE CASE PORTE DANS LA LANE QUI LA TIENT, TOUT DE SUITE.
--
-- Attendre le prochain lancement donne un reglage qui « ne fait rien » jusqu'a
-- ce qu'on relance, c'est-a-dire un reglage qu'on croit casse. Une case qu'aucune
-- lane ne tient n'a rien a pousser : elle partira juste au prochain armement.
local function pushCell(t, s)
    local c = cells[t] and cells[t][s]
    if not c then return end
    local lane = Loop.LaneOfTag(t, cellTag(t, s))
    if not lane then return end
    if isAudio(c) then
        -- Une case audio passe par son clip synthetique : c'est lui qui porte
        -- la longueur, la signature et l'accolade jusqu'a la lane.
        Loop.ApplyClip(lane, audioClip(c, lane))
    else
        Loop.SetLengthBars(lane, cellBars(c))
        Loop.SetLaneTsNum(lane, c.tsnum)
    end
end

-- ---------------------------------------------------------------------------
-- Launching — the heart of the thing
-- ---------------------------------------------------------------------------
-- Write a clip into a lane WITHOUT playing it (the lane is the silent twin,
-- so the write timing is free) and leave it "stopped with content", which is
-- the state the engine can launch from.
--
-- A SOUND cell passes through here like any other: its file is loaded into THIS
-- HALF's voices, its clip is the one note the lane speaks, and both halves of
-- the pair are flagged so the engine speaks them on the column's sound channel.
-- Both halves for the channel, because a swap moves the clip to the twin and the
-- sound must not change channel halfway through a bar — but voices EACH, because
-- during that swap two clips exist and only one of them is still sounding.
local function armLane(lane, c, t, s)
    local audio = isAudio(c)
    if audio then
        -- The safety net: a project saved before sounds carried a length gets
        -- one here, at the last moment where asking is still free.
        ensureBars(c)
        local path, rate = soundFor(c)
        local ok, why = Cells.Arm(t, lane, path, rate, c.lmode == "loop",
                                  c.offs, c.len, c.gain)
        if not ok then
            -- Say WHICH of the four things was missing. "no sound" with no
            -- reason costs an evening; the reason costs a string.
            flash(why == "no_engine" and "Sound cells need the CP engine extension"
                  or why == "too_long" and "Sound is longer than the 64 s ceiling"
                  or why == "failed" and "Could not decode this file"
                  or "No track for this column — click its name to route it")
            return false
        end
    else
        -- This half stopped carrying a sound. Say so, or its voice keeps
        -- answering the lane's passes with a file nobody asked for.
        Cells.Disarm(t, lane)
    end
    -- The lane still speaks its one-note clip — the clip IS the state machine —
    -- and now nobody hears it at all. The sound channel and its filtered send
    -- went with the router; a sound cell is a CP voice on its own port, and the
    -- column's instrument is on another one entirely. Not a convention to keep:
    -- two wires that never meet.
    Loop.ApplyClip(lane, audio and audioClip(c, lane) or c)
    -- AND THE LANE MUST NOT BE HEARD WHEN IT CARRIES A SOUND.
    --
    -- The comment below used to say nobody hears this one-note clip. That was
    -- true of the AUDIO — a sound cell is a voice on port t, the column's
    -- instrument is on another. It was never true of the MIDI: the lane still
    -- speaks on PORT_BASE + t, which is attached to the column's destination
    -- track. On a column that holds both an instrument and sound cells — the
    -- exact case audioDest builds a child for — the instrument was getting a
    -- middle C on every pass.
    --
    -- Muting is the right instrument and it already existed: run_gate emits
    -- nothing for a muted lane while keeping it PLAYING, so the state machine,
    -- the phase and the countdown all carry on untouched.
    Loop.SetMute(lane, audio)
    Loop.SetLengthBars(lane, cellBars(c))
    -- stamp WHICH cell this lane now holds: it is how CP_Editor finds the
    -- clip again after a swap moved it to the other half, and how it knows
    -- to stop writing when the lane got reused for something else
    Loop.SetLaneTag(lane, cellTag(t, s))
    if (audio or cellNotes(c) > 0) and floor(Loop.Mode(lane) + 0.5) == 0 then
        Loop.SetMode(lane, 2)
    end
    return true
end

-- UN GESTE HUMAIN SE QUANTIFIE ; UN ENCHAINEMENT SE DONNE RENDEZ-VOUS.
--
-- Cliquer une case veut dire « a la prochaine frontiere » — c'est tout l'interet
-- de la grille, et `at` est alors nil. Un motion, lui, connait sa date : la fin
-- de la passe en cours. La faire arrondir par une grille qui ne connait pas la
-- longueur de la case est ce qui rendait les sept comportements faux (voir
-- pollMotion).
local function playLane(lane, at)
    if at then Loop.PlayAt(lane, at) else Loop.Play(lane) end
end
local function stopLane(lane, at)
    if at then Loop.StopClipAt(lane, at) else Loop.StopClip(lane) end
end

local function stopTrack(t, at)
    local lane = liveLane(t)
    local m = floor(Loop.Mode(lane) + 0.5)
    if m == 3 or m == 5 then stopLane(lane, at)
    -- Annuler une file est immediat par nature : il n'y a rien a finir.
    elseif Loop.Pending(lane) == 1 then Loop.StopClip(lane) end
end

-- Launch cell (t, s). Re-launching the cell that is already playing stops it
-- (Ableton's toggle on the same clip); launching a different one swaps the
-- buffers so the change happens on the boundary instead of mid-loop.
local function launchCell(t, s, at)
    local c = cells[t][s]
    -- A sound cell answers a click through the SAME six branches below. The
    -- three answers it used to re-implement — cancel what is only queued, take
    -- back the stop of what plays, swap on one boundary — are the engine's, and
    -- were only ever written twice because a preview was not a clip.
    if not c or (cellNotes(c) == 0 and not isAudio(c)) then
        flash("Empty cell — click the cell to write something in it")
        return
    end
    -- The lane holding THIS cell — which is the SILENT half while its launch
    -- is still queued. Asking the engine for it, instead of assuming the
    -- track's live lane, is what makes a second click cancel the right thing
    -- rather than cancel the outgoing clip's stop and leave two playing.
    local mine = Loop.LaneOfTag(t, cellTag(t, s))
    if mine then
        -- A queued swap arms BOTH halves: the outgoing one is queued to stop
        -- and the incoming one to play, on the same boundary. Cancelling one
        -- alone leaves the other's queue to fire — two clips on one track, or
        -- none. So every cancel here reconciles the pair.
        local twin = (mine == t) and (t + TRACKS) or t
        local p = Loop.Pending(mine)
        if p == 1 then                                  -- cancel the queued launch
            if Loop.Pending(twin) == 2 then Loop.Play(twin) end   -- …and keep the outgoing clip
            Loop.StopClip(mine)
            return
        end
        if p == 2 then                                  -- take the queued stop back
            if Loop.Pending(twin) == 1 then Loop.StopClip(twin) end -- …and drop the incoming one
            Loop.Play(mine)
            return
        end
        if isRunning(mine) then                         -- playing: this click stops it
            Loop.StopClip(mine)
            return
        end
    end

    local live = liveLane(t)
    -- a launch queued on the other half loses: a track plays ONE clip, and
    -- this click is what chose which
    local other = (live == t) and (t + TRACKS) or t
    if Loop.Pending(other) == 1 then Loop.StopClip(other) end
    local busy = isRunning(live) or Loop.Pending(live) == 1
    if not busy then
        -- nothing to swap: load the live lane directly. This also keeps
        -- ordinary use on the low lanes — the ones CP_Looper shows.
        armLane(live, c, t, s)
        playLane(live, at)
        cur[t] = s
        return
    end
    local twin = twinLane(t)
    armLane(twin, c, t, s)
    playLane(twin, at)      -- queued to the next boundary…
    stopLane(live, at)      -- …and the outgoing one leaves on the same one
    -- which half is live is re-derived from the engine (Loop.Poll), not
    -- flipped here: a launch fired from CP_Editor or CP_Looper would
    -- otherwise leave this window pointing at the wrong lane.
    cur[t] = s
end

-- A whole scene lands together: every track with a clip launches, every
-- track without one STOPS (Ableton's default — a scene is a full picture).
-- `additive` : SUPERPOSER AU LIEU DE REMPLACER. FL le dit mot pour mot —
-- « will replace playing Clips with any new Clips on the same track in the
-- next Scene but leave any Clips on unused tracks playing ». Sans ca, une
-- nappe ne peut pas survivre a un changement de scene : il faut la dupliquer
-- dans les huit lignes, ce qui n'est pas de la composition, c'est de la
-- comptabilite. Cinq lignes, zero stockage.
local function sceneLaunch(s, additive)
    for t = 0, TRACKS - 1 do
        -- a sound counts as a clip here: asking for the NOTES of an audio cell
        -- answers zero, and a scene holding sounds stopped those tracks
        local c = cells[t][s]
        if c and (isAudio(c) or cellNotes(c) > 0) then
            launchCell(t, s)
        elseif not additive then
            stopTrack(t)
        end
    end
end

local function stopAll()
    for t = 0, TRACKS - 1 do stopTrack(t) end
end

-- ---------------------------------------------------------------------------
-- LE MOTION, deuxieme moitie — ce qui AGIT
-- ---------------------------------------------------------------------------
-- Le vocabulaire (les sept noms, le reglage par colonne, sa persistance, son
-- menu) est monte au-dessus de `trackMenu`, qui l'ouvre. Ce qui suit AGIT, et
-- ne peut donc pas etre ailleurs : il lui faut `launchCell` et `stopTrack`.

-- « De quoi jouer » — la meme question que sceneLaunch pose, et pour la meme
-- raison : demander les NOTES d'une case audio repond zero.
local function playable(t, s)
    local c = cells[t] and cells[t][s]
    return (c and (isAudio(c) or cellNotes(c) > 0)) and true or false
end

-- La case suivante EN DESCENDANT qui a de quoi jouer. Les trous sont sautes :
-- une colonne dont seules les cases 0, 3 et 7 sont remplies marche sur trois
-- cases, pas sur huit dont cinq silencieuses.
local function nextPlayable(t, from, wrap)
    for i = 1, SCENES - 1 do
        local s = from + i
        if s >= SCENES then
            if not wrap then return nil end
            s = s - SCENES
        end
        if playable(t, s) then return s end
    end
    return nil
end

-- Le tirage. `excl` interdit la case en cours — c'est tout l'ecart entre Random
-- et Exclusive random chez FL, et sans lui une colonne de deux cases retombe
-- sur elle-meme une fois sur deux, ce qui ne s'entend pas comme un tirage.
-- Deux passages sur huit cases, uniquement a une fin de passe.
local function randomPlayable(t, cur_s, excl)
    local n = 0
    for s = 0, SCENES - 1 do
        if playable(t, s) and not (excl and s == cur_s) then n = n + 1 end
    end
    if n == 0 then return nil end
    local k = math.random(n)
    for s = 0, SCENES - 1 do
        if playable(t, s) and not (excl and s == cur_s) then
            k = k - 1
            if k == 0 then return s end
        end
    end
    return nil
end

local function fireMotion(t, m, s, at)
    if m == MOTION_ONCE then
        stopTrack(t, at)
        return
    end
    local nxt
    if m == MOTION_WRAP then
        nxt = nextPlayable(t, s, true)
    elseif m == MOTION_MSTAY or m == MOTION_MSTOP then
        nxt = nextPlayable(t, s, false)
        if not nxt then
            -- Le bas de la colonne. March & stay y reste en boucle, March &
            -- stop s'y tait : c'est le seul endroit ou les deux different.
            if m == MOTION_MSTOP then stopTrack(t, at) end
            return
        end
    elseif m == MOTION_RAND then
        nxt = randomPlayable(t, s, false)
    elseif m == MOTION_XRAND then
        nxt = randomPlayable(t, s, true)
    end
    -- RETOMBER SUR LA CASE EN COURS VEUT DIRE « CONTINUE ». La relancer la
    -- ferait BASCULER — un second lancement de la case qui joue l'arrete, c'est
    -- le toggle d'Ableton — donc un Random sur une colonne d'une seule case
    -- s'eteindrait des la premiere passe au lieu de tourner.
    if not nxt or nxt == s then return end
    launchCell(t, nxt, at)
end

-- QUAND TIRER — et depuis l'ABI 2.5 ce n'est plus une question difficile.
--
-- ⚠️ CE QUI ETAIT FAUX, ET POURQUOI CA L'ETAIT SUR LES SEPT MODES A LA FOIS.
--
-- On tirait dans la derniere fenetre de Q en comptant sur la quantification du
-- moteur pour poser le depart sur la fin de la passe. Elle ne pouvait pas : elle
-- ne connait pas la longueur de la case, seulement la grille globale. Des que la
-- passe fait plus de deux Q — une case de DEUX MESURES avec Q a la mesure, le
-- cas le plus banal qui soit — la fenetre s'ouvrait PILE sur une frontiere de Q,
-- le moteur repondait « tout de suite », et la colonne changeait de case au
-- milieu du clip. Les sept comportements passent tous par ici : ils etaient donc
-- tous faux, et de la meme facon. C'est ce que Cedric a vu.
--
-- Un enchainement ne demande plus son chemin : il se donne RENDEZ-VOUS a la fin
-- de la passe (`Loop.PlayAt`, ABI 2.5). Il ne reste a choisir que l'AVANCE, et
-- elle ne depend que du temps qu'il faut pour armer la case suivante — un beat,
-- plafonne a la moitie de la passe pour qu'une case courte garde une fenetre.
-- C'est exactement l'avance que `Cells` se donne pour programmer une voix.
--
-- LES TROIS VALEURS VIENNENT DU MEME BLOC. Le beat du moteur, la phase et la
-- zone sont publies ensemble a la fin d'un bloc audio ; la date qu'on pose est
-- leur difference. Les apparier depuis deux blocs differents la fausserait de
-- tout ce qui s'est passe entre les deux lectures — c'est la faute que ce depot
-- a deja payee deux fois.
--
-- Le compteur de tours tombe du repli de phase, gratuitement — Ableton l'affiche
-- dans son Track Status field, et c'est la reponse a « ca fait combien de fois
-- que ca tourne » qu'on se pose en jouant.
local MOTION_LOOK = 1.0     -- un beat d'avance

local function pollMotion()
    -- L'HORLOGE COMPTE AUTANT QUE LA LANE. Sans elle la phase ne bouge plus,
    -- donc `slen - ph` reste fige : un transport arrete pile dans la derniere
    -- fenetre de Q ferait tirer le motion, et la colonne avancerait d'une case
    -- sans qu'une passe se soit terminee. Un enchainement se compte en passes
    -- JOUEES. On remet le suivi a zero plutot que de sortir, sinon la reprise
    -- lirait un repli de phase la ou il n'y a eu qu'une pause.
    local clock = Loop.ClockRunning()
    for t = 0, TRACKS - 1 do
        local f = mot[t]
        local lane = liveLane(t)
        if not clock or not isRunning(lane) then
            f.lane, f.pz, f.armed, f.plays = -1, 0, false, 0
        else
            local tag = Loop.GetLaneTag(lane)
            local sa, slen = Loop.Span(lane)
            if not slen or slen <= 0 then slen = 1 end
            -- Le beat AVANT la phase, et les deux du meme bloc : voir l'en-tete.
            local beat = Loop.EngineBeat()
            local ph = (Loop.Phase(lane) or 0) - (sa or 0)
            if ph < 0 then ph = 0 elseif ph > slen then ph = slen end
            if lane ~= f.lane or tag ~= f.tag then
                -- UNE AUTRE CASE A PRIS LA COLONNE. Le compteur compte les
                -- passes de CE clip, donc il repart. Et surtout : la nouvelle
                -- lane part de zero, ce qui ressemble a un repli de phase sans
                -- en etre un — le compter ferait tirer le motion une passe trop
                -- tot a chaque pas de sa propre marche.
                f.lane, f.tag, f.pz, f.armed, f.plays = lane, tag, ph, false, 0
            else
                if ph + 1e-9 < f.pz then
                    f.plays = f.plays + 1
                    f.armed = false
                end
                f.pz = ph
                local m = motion[t]
                -- Une file deja posee gagne : un lancement que Cedric vient de
                -- demander a la main ne se fait pas doubler par la regle.
                if m ~= MOTION_STAY and not f.armed
                   and Loop.Pending(lane) == 0 then
                    local look = MOTION_LOOK
                    if look > slen * 0.5 then look = slen * 0.5 end
                    local rem = slen - ph
                    if rem <= look then
                        -- Arme meme si la case ne se resout pas : un tir rate ne
                        -- doit pas se repeter a chaque frame de la fenetre.
                        f.armed = true
                        local s = sceneOfLane(lane, t)
                        if s then fireMotion(t, m, s, beat + rem) end
                    end
                end
            end
        end
    end
end

-- Combien de fois la case en cours a tourne dans cette colonne, ou 0.
local function motionPlays(t)
    local f = mot[t]
    return f and f.plays or 0
end

-- ---------------------------------------------------------------------------
-- Editing — CP_Editor only, and it must be able to PLAY what it edits
-- ---------------------------------------------------------------------------
-- A cell that is currently playing is edited THROUGH its live lane, so the
-- edits are heard as they are made. Any other cell is loaded into the silent
-- twin first: the editor then has a real lane to drive (playhead, launch)
-- without disturbing what is playing.
local function editCell(t, s)
    local c = cells[t][s]
    if not c then
        c = Clip.new("midi")
        c.notes = { s = {}, l = {}, p = {}, v = {} }
        c.bars = 4
        cells[t][s] = c
        saveGrid()
    end
    -- If the engine already holds this cell (playing, or staged by an
    -- earlier edit) keep that lane: writing anywhere else would edit one
    -- clip and hear another. Otherwise stage it in the silent half, so the
    -- editor gets a real lane to drive without disturbing what is playing.
    local tag = cellTag(t, s)
    if not Loop.LaneOfTag(t, tag) then
        armLane(twinLane(t), c, t, s)
    end
    -- The descriptor names the TRACK. WHICH half holds the clip changes
    -- under it as clips swap, so it is asked for again — never stored.
    c.origin = "looper:" .. t
    c.cell = t .. "," .. s
    c.name = (c.name and c.name ~= "") and c.name
             or (trackName(t) .. " · scene " .. (s + 1))
    Bus.OpenEditor(c)
    flash("Cell opened in CP_Editor")
end

-- Edits coming home. The cell coordinates travel with the clip, so the
-- descriptor lands back in the right cell even if the lanes have swapped
-- since; the live lane is refreshed too when that cell is the one playing.
local function applyEdit(ac)
    local t, s
    if ac.cell then t, s = ac.cell:match("^(%d+),(%d+)$") end
    t, s = tonumber(t), tonumber(s)
    if t and s and t < TRACKS and s < SCENES then
        -- The edited descriptor came back through the bus with its identity in
        -- it, so it replaces the clip it IS rather than the clip that happens
        -- to sit at those coordinates. Re-binding points the registry at the
        -- new table under the same number.
        cells[t][s] = ac
        Ident.Bind(ac)
        saveGrid()
        -- refresh the lane that HOLDS this cell — playing or merely staged —
        -- and not whatever the track happens to be playing right now
        local lane = Loop.LaneOfTag(t, cellTag(t, s))
        if lane then
            Loop.ApplyClip(lane, ac)
            if ac.bars and ac.bars > 0 then Loop.SetLengthBars(lane, ac.bars) end
        end
        return true
    end
    -- no cell tag: a plain lane edit (CP_Looper's own clips)
    local ln = ac.origin and tonumber(ac.origin:match("^looper:(%d+)"))
    if ln and ln >= 0 and ln < Loop.MAX_LANES then
        Loop.ApplyClip(ln, ac)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Recording into a cell — the other half of a session view: an armed track
-- captures into an empty slot, and what comes out lands in that cell.
-- ---------------------------------------------------------------------------
local rec = nil   -- { t, s } while a capture is running

-- Armed is a TRACK fact, not a lane one: the pair swaps buffers as clips
-- change, and the arm must not appear to move with it.
local function isArmed(t)
    local a = Loop.GetArmedLane()
    if not a then return false end
    return (floor(a + 0.5) % TRACKS) == t
end

-- A toggle, and only one track can hold it. Arming is what opens the live
-- input path — the engine hands whatever you play to the armed track's
-- instrument — so being unable to close it again was never defensible: it
-- left every project monitoring something the user had not chosen.
local function armTrack(t)
    if isArmed(t) then
        Loop.SetArmedLane(nil)
        flash("Input off — nothing is monitored")
    else
        Loop.SetArmedLane(liveLane(t))
        flash("Playing goes to " .. trackName(t) .. " · record into an empty slot")
    end
end

-- Recording into an empty slot is a clip SWAP like any other: the track may
-- be playing something else, and that something has to leave on the same
-- boundary the take arrives on. So the take goes into the silent twin
-- whenever the live half is busy, exactly as launchCell does. Sending REC to
-- the live half instead would have cleared the clip the track was playing.
local function recCell(t, s)
    local live = liveLane(t)
    local other = (live == t) and (t + TRACKS) or t
    if Loop.Pending(other) == 1 then Loop.StopClip(other) end
    local busy = isRunning(live) or Loop.Pending(live) == 1
    local lane = busy and twinLane(t) or live
    -- A take needs a NAME before it has a clip: the lane has to be tagged now,
    -- and the thing it names does not exist until the capture ends. So the
    -- identity is minted here and stamped onto whatever comes out — the one
    -- place where a clip's number precedes the clip.
    local id = Ident.NewId()
    Loop.SetArmedLane(lane)                 -- monitor the half that captures
    Loop.SetLaneTag(lane, id)               -- the take lands in THIS cell
    Loop.SetLengthBars(lane, rec_bars)      -- stated, not inherited from the lane
    Loop.Rec(lane)                          -- quantized; auto-stops on the length
    if busy then Loop.StopClip(live) end    -- outgoing clip leaves on that boundary
    rec = { t = t, s = s, lane = lane, id = id, seen = false, t0 = r.time_precise() }
    cur[t] = s
end

-- The capture is the engine's business; we only watch for its end and keep
-- what it produced. Recording finishes into "playing" (the loop rolls on).
--
-- It watches the lane the command was SENT TO, never "the track's live lane":
-- the live half moves as clips swap, and following it made this poll read a
-- different clip halfway through a take.
--
-- `seen` is the other half of the same lesson. A command does not take effect
-- on the frame it is issued — the engine consumes one per audio block — so
-- for a few frames the lane is still mode 0, because the slot was empty.
-- Reading that as "cleared under us" dropped the recording before it had
-- started: the take ran, the notes were captured, the editor showed them, and
-- the grid never grew a clip because nothing was left watching. It also made
-- the red cell appear only when the timing happened to fall the other way,
-- which is what "once in two" was.
local REC_PICKUP_TIMEOUT = 3.0

local function pollRec()
    if not rec then return end
    local m = floor(Loop.Mode(rec.lane) + 0.5)
    if m == 1 or m == 4 or Loop.Pending(rec.lane) == 3 then
        rec.seen = true                     -- the engine has the command
        return
    end
    if not rec.seen then
        if r.time_precise() - rec.t0 < REC_PICKUP_TIMEOUT then return end
        rec = nil
        flash("The engine never took the record command")
        return
    end
    if m == 0 then
        -- The engine settles an empty take back to "no clip". Saying so
        -- matters: with Rec: 1 bar the whole thing is over two seconds after
        -- the transport rolls, and a cell that simply stopped blinking read as
        -- "the recording was deleted" rather than "nothing was played into it".
        rec = nil
        flash("Nothing played — the slot stays empty")
        return
    end
    local c = Loop.LaneToClip(rec.lane)
    if c then
        c.cell = rec.t .. "," .. rec.s
        c.name = trackName(rec.t) .. " · " .. (rec.s + 1)
        c.id = rec.id                       -- the number the lane already wears
        Ident.Bind(c)
        cells[rec.t][rec.s] = c
        saveGrid()
        flash("Captured into " .. c.name)
    else
        flash("Nothing played — the slot stays empty")
    end
    rec = nil
end

-- Second click on a blinking record button, as in a session view: a take in
-- progress is FINALIZED (pollRec keeps what was played), one that has not
-- started yet is dropped. Without this the only way out of a capture you did
-- not mean to start was to wait for its auto-stop.
local function stopRec()
    if not rec then return end
    if floor(Loop.Mode(rec.lane) + 0.5) == 1 then
        Loop.Stop(rec.lane)
    else
        Loop.Clear(rec.lane)
        rec = nil
        flash("Recording cancelled")
    end
end

local function clearCell(t, s)
    if not cells[t][s] then return end
    -- empty the lane that holds it too (and only that one), or the engine
    -- would keep playing a clip the grid no longer has
    local lane = Loop.LaneOfTag(t, cellTag(t, s))
    Ident.Forget(cells[t][s].id)
    cells[t][s] = nil
    saveGrid()
    if lane then Loop.Clear(lane) end
    -- a deleted clip stops NOW, boundary or not: there is nothing left to
    -- finish, and waiting would play a cell the grid no longer has
    if cur[t] == s then cur[t] = nil end
end

-- Deep copy of a clip descriptor: the copy must own its notes, or editing one
-- cell would silently rewrite every cell it was ever duplicated from.
local function copyCell(c)
    local d = {}
    for k, v in pairs(c) do d[k] = v end
    local nt = c.notes
    if nt then
        local s, l, p, v, pr = {}, {}, {}, {}, {}
        for i = 1, #(nt.s or {}) do
            s[i], l[i], p[i], v[i] = nt.s[i], nt.l[i], nt.p[i], nt.v[i]
            -- La copie doit emporter la probabilite, sinon dupliquer une case
            -- rend une case qui joue tout : le champ manquant vaut cent, et
            -- « cent » est precisement la valeur que l'original n'avait pas.
            pr[i] = (nt.pr and nt.pr[i]) or 100
        end
        d.notes = { s = s, l = l, p = p, v = v, pr = pr }
    end
    d.cell, d.origin = nil, nil   -- it belongs to wherever it lands, not here
    -- A COPY IS ANOTHER CLIP. Carrying the identity across would give two
    -- clips one name — worse than the positional tag it replaced, because
    -- they would then be indistinguishable everywhere instead of only in one
    -- grid. It gets its own the first time something asks.
    Ident.Clear(d)
    return d
end

-- Drop a copy into (t, s), replacing what was there.
local function pasteCell(t, s, c)
    local d = copyCell(c)
    d.cell = t .. "," .. s
    if cells[t][s] then clearCell(t, s) end
    cells[t][s] = d
    saveGrid()
end

-- ---------------------------------------------------------------------------
-- CAPTURE AND INSERT SCENE — Ableton, Ctrl+Shift+I
-- ---------------------------------------------------------------------------
-- « Copier ce qui joue dans une nouvelle scene, with no audible interruption. »
-- Ici c'est EXACT par construction, et ce n'est pas une chance : le tag de lane
-- est de la METADONNEE PURE. Recopier les descripteurs puis reposer les tags
-- fait changer de ligne a la lane sans toucher a ce qu'elle joue — pas une note
-- redeclenchee, pas une phase remise a zero, pas un fondu.
--
-- Ableton INSERE une ligne ; cette grille en a huit, fixes. La cible est donc la
-- premiere ligne ENTIEREMENT VIDE en descendant depuis la selection, et quand il
-- n'y en a plus on le dit — ecraser une ligne pleine serait detruire une scene
-- pour en garder une autre, ce que personne ne demande en tapant « capture ».
local function sceneEmpty(s)
    for t = 0, TRACKS - 1 do
        if cells[t] and cells[t][s] then return false end
    end
    return true
end

local function captureScene()
    -- CE QUI JOUE, RELEVE AVANT D'ECRIRE. La copie repose les tags, donc la
    -- releve doit etre finie quand la premiere ecriture a lieu.
    --
    -- Une lane qui ENREGISTRE (mode 1) est exclue : la reetiqueter couperait le
    -- lien que `pollRec` suit pour ranger la prise dans sa case, et une capture
    -- ne doit jamais faire perdre un take en cours.
    local src, n = {}, 0
    for t = 0, TRACKS - 1 do
        local lane = liveLane(t)
        local m = floor(Loop.Mode(lane) + 0.5)
        if m == 3 or m == 5 then
            local s = sceneOfLane(lane, t)
            if s and cells[t][s] then
                src[t] = { s = s, lane = lane }
                n = n + 1
            end
        end
    end
    if n == 0 then
        flash("Nothing is playing — there is nothing to capture")
        return
    end
    local dst
    for i = 0, SCENES - 1 do
        local s = (sel.s + i) % SCENES
        if sceneEmpty(s) then dst = s break end
    end
    if not dst then
        flash("Every scene row is full — clear one to capture into")
        return
    end
    for t = 0, TRACKS - 1 do
        local it = src[t]
        if it then
            pasteCell(t, dst, cells[t][it.s])
            -- LE TAG, ET RIEN D'AUTRE. La lane continue sa passe ; elle repond
            -- simplement qu'elle tient desormais la case de la nouvelle ligne.
            Loop.SetLaneTag(it.lane, cellTag(t, dst))
            cur[t] = dst
        end
    end
    saveGrid()
    sel.s = dst
    flash("Captured " .. n .. " clip(s) into scene " .. (dst + 1))
end

local function renameCell(t, s)
    local c = cells[t][s]
    if not c then return end
    local ok, v = r.GetUserInputs("Rename clip", 1, "Name:,extrawidth=180",
                                  c.name or "")
    if not ok then return end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    c.name = (v ~= "") and v or nil
    saveGrid()
    -- the label cache is keyed on the old text
    cell_lbl[t * SCENES + s] = nil
end

-- The clip's colour is an index into the Engine's palette, so the cell, the
-- editor and anything else that ever shows this clip agree without agreeing
-- on anything. nil = none, which means "the theme's own ground", not black.
local function setCellColor(t, s, i)
    local c = cells[t][s]
    if not c then return end
    c.color = (i and i > 0) and i or nil
    saveGrid()
end

-- HOW A SOUND FOLLOWS THE PROJECT'S TEMPO — and it is a real choice, not a
-- preference, because the two answers are two different machines:
--   repitch  the read pointer moves faster. No window, no latency, exact.
--   stretch  REAPER's time stretcher. Keeps the key, and is late by the
--            window that stretcher must fill before it can emit anything —
--            fixed, tens of milliseconds, and reported by no API.
--   none     the file plays at its own tempo.
-- Repitch is the default because a launcher's job is to be in time.
--
-- A running sound takes a new RATE immediately (it is a number). It does not
-- change ENGINE under itself: turning stretch on or off waits for the next
-- launch, which is one boundary away.
-- Aim the sampler of the lane that actually HOLDS this cell — not "the column's
-- sampler", because there are two and the other one may be sounding something
-- else entirely while a swap is queued.
-- Re-aim the sound of the lane that actually HOLDS this cell — not "the
-- column's sound", because during a queued swap the other half may be sounding
-- something else entirely. Costs one number, not a reload.
local function retune(t, s, c)
    local lane = Loop.LaneOfTag(t, cellTag(t, s))
    if not lane then return end
    -- Switching between repitch and stretch changes the FILE, not only the
    -- rate: a cooked clip is another sample on disk. Arm handles both — it
    -- reloads only when the path really moved — so this stays one call, and
    -- a mode change that resolves to the same file still costs one number.
    -- soundFor rend DEUX valeurs : les nommer, sinon un argument place apres
    -- elle la tronque a la premiere et le taux devient le drapeau de boucle.
    local path, rate = soundFor(c)
    Cells.Arm(t, lane, path, rate, c.lmode == "loop", c.offs, c.len, c.gain)
end

local function setCellTempoMode(t, s, mode)
    local c = cells[t][s]
    if not c then return end
    c.tempo_mode = (mode ~= "repitch") and mode or nil
    ensureTempo(c)
    saveGrid()
    -- A sound already playing takes the new rate at once — it is one parameter
    -- on the sampler, not a reload and not a relaunch.
    if isAudio(c) then retune(t, s, c) end
end

-- DIRE A UNE CASE QUE CE FICHIER FAIT 128.
--
-- `src_bpm` est le champ PRIORITAIRE du modele — il bat l'analyse, le nom et la
-- deduction — et il n'avait AUCUN ecrivain dans tout le depot : deux lectures,
-- zero ecriture. On pouvait donc lire le format et croire que la fonctionnalite
-- existait. Un champ de saisie suffit, et la longueur de la passe se recalcule
-- avec, puisqu'elle depend du tempo retenu.
local function setCellSrcBpm(t, s)
    local c = cells[t][s]
    if not (c and c.path) then return end
    local cur_bpm = c.src_bpm and string.format("%g", c.src_bpm) or ""
    local ok, v = r.GetUserInputs("Source tempo", 1,
                                  "BPM (empty = work it out):,extrawidth=90", cur_bpm)
    if not ok then return end
    v = v:gsub("%s", "")
    local bpm = tonumber(v)
    if v == "" then
        c.src_bpm = nil
    elseif bpm and bpm > 20 and bpm < 400 then
        c.src_bpm = bpm
    else
        flash("A source tempo is a number between 20 and 400")
        return
    end
    c.bpm_seen, c.bpm_why, c.bars = nil, nil, nil
    ensureBars(c)                       -- le tempo change la longueur de passe
    saveGrid()
    if isAudio(c) then retune(t, s, c) end
end

-- One-shot / loop. Stored as `lmode`, which the CPC1 format has always carried
-- and nothing has ever written. nil means one-shot, so an existing project
-- keeps the behaviour a dropped file should have had from the start.
local function setCellLoop(t, s, on)
    local c = cells[t][s]
    if not c then return end
    c.lmode = on and "loop" or nil
    saveGrid()
    if isAudio(c) then retune(t, s, c) end
end

-- LA SIGNATURE DE CETTE CASE, en beats par mesure. `nil` = suivre le projet.
--
-- Elle se pousse dans la lane TOUT DE SUITE quand la lane tient cette case :
-- c'est la longueur de boucle qui change, donc ce qu'on entend, et attendre le
-- prochain lancement pour l'appliquer donnerait un reglage qui « ne marche pas »
-- jusqu'a ce qu'on relance — le genre de latence qu'on attribue a un bug.
local function setCellTsNum(t, s, n)
    local c = cells[t][s]
    if not c then return end
    c.tsnum = n
    saveGrid()
    pushCell(t, s)
end

-- LA LONGUEUR DE LA PASSE — le reglage qui manquait, et qu'on cherchait ailleurs.
--
-- « Je depose un kick, il joue une fois par mesure. Si je mets 4 fois par bar il
-- devrait sortir quatre coups, et la, ca ne change rien. » C'etait exact : la
-- SIGNATURE multiplie la passe (mesures x beats), elle ne la divise pas ; et
-- « Loop the material » repete a la duree DU FICHIER, donc hors de toute grille
-- — 0,4 s de kick sortent cinq fois par mesure a 120 BPM, ce qui n'est pas un
-- rythme, c'est une mitraillette.
--
-- Ce qu'il faut dire est plus simple, et c'est le vocabulaire d'un lanceur de
-- boucles : une case joue UNE FOIS PAR PASSE. Un kick qui doit sortir quatre
-- fois par mesure a une passe d'un QUART DE MESURE, et il tombe sur la grille
-- parce que la grille est ce qu'une passe est.
--
-- Le plancher est le huitieme de mesure : celui du moteur (`lane_len_beats`),
-- en dessous duquel une boucle cesse d'etre une boucle.
local function setCellBars(t, s, bars)
    local c = cells[t][s]
    if not c then return end
    c.bars = bars
    saveGrid()
    pushCell(t, s)
end

local function cellMenu(t, s)
    local c = cells[t][s]
    local has = c ~= nil
    local cur_col = has and c.color or nil
    local cols = {}
    for i = 1, #Clip.COLOR_NAMES do
        cols[i] = { label = Clip.COLOR_NAMES[i], checked = (cur_col == i),
                    action = function() setCellColor(t, s, i) end }
    end
    cols[#cols + 1] = { separator = true }
    cols[#cols + 1] = { label = "None", checked = (cur_col == nil),
                        action = function() setCellColor(t, s, nil) end }
    local snd = has and c.kind ~= "midi" and c.path ~= nil
    local tm  = snd and (c.tempo_mode or "repitch") or nil
    -- « Stretch (keeps the key, plays late) » : les deux moities etaient
    -- fausses. Il ne joue pas en retard — il joue EN TEMPS, en repitch, le
    -- temps qu'une version etiree soit cuite sur disque ; et il ne garde la
    -- tonalite qu'une fois cette cuisson finie. Le libelle le dit maintenant,
    -- et la ligne sous la case dit ou en est la cuisson.
    local wfail = nil
    if snd and tm == "stretch" then
        local s0 = c.offs or 0
        wfail = Warp.Failure(c.path, s0, c.len and (s0 + c.len) or 0,
                             r.Master_GetTempo() or 120)
    end
    local tmodes = snd and {
        { label = "Repitch — faster is higher, always in time",
          checked = (tm == "repitch"),
          action = function() setCellTempoMode(t, s, "repitch") end },
        { label = "Stretch — keeps the key, repitches until it is rendered",
          checked = (tm == "stretch"),
          action = function() setCellTempoMode(t, s, "stretch") end },
        { label = wfail and ("Retry the stretch (" .. tostring(wfail) .. ")")
                        or "Retry the stretch",
          disabled = wfail == nil,
          action = function()
            local s0 = c.offs or 0
            Warp.Retry(c.path, s0, c.len and (s0 + c.len) or 0,
                       r.Master_GetTempo() or 120)
            retune(t, s, c)
          end },
        { separator = true },
        { label = "Don't follow the tempo", checked = (tm == "none"),
          action = function() setCellTempoMode(t, s, "none") end },
        { separator = true },
        { label = c.src_bpm and string.format("Source tempo: %g BPM…", c.src_bpm)
                            or "Source tempo…",
          action = function() setCellSrcBpm(t, s) end },
    } or nil
    -- ONE-SHOT OU BOUCLE — le champ `lmode` existe dans le format CPC1 depuis le
    -- premier jour et n'avait jamais eu de lecteur. Un fichier depose joue une
    -- fois par passe ; une matiere plus COURTE que sa passe qu'on veut voir
    -- tourner (un shaker d'un temps sous une mesure) demande la boucle. C'est le
    -- seul reglage qui distingue un crash d'un shaker, et il n'existait pas.
    local lmodes = snd and {
        { label = "One-shot — plays once per pass",
          checked = ((c.lmode or "oneshot") ~= "loop"),
          action = function() setCellLoop(t, s, false) end },
        -- LE LIBELLE DIT CE QUE CA FAIT, PARCE QUE CE N'EST PAS CE QU'ON CROIT.
        -- La repetition se fait a la duree DU FICHIER, pas sur la grille : sur
        -- un one-shot elle donne cinq coups par mesure a une periode qui n'est
        -- celle de rien. C'est reserve a une matiere qui EST une boucle. Pour
        -- repeter un coup sur la grille, c'est la LONGUEUR qu'on raccourcit.
        { label = "Loop the material — repeats at the FILE's length, not the grid",
          checked = (c.lmode == "loop"),
          action = function() setCellLoop(t, s, true) end },
    } or nil
    -- LA LONGUEUR DE LA PASSE. Une case joue une fois par passe : un quart de
    -- mesure fait sortir un kick quatre fois par mesure, sur la grille.
    local lens = has and {} or nil
    if lens then
        for _, b in ipairs({ 0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32 }) do
            lens[#lens + 1] = {
                label = barsLabel(b) .. ((b < 1) and ("  ·  " .. floor(1 / b + 0.5)
                                                     .. " per bar") or ""),
                checked = (cellBars(c) == b),
                action = function() setCellBars(t, s, b) end,
            }
        end
    end
    -- LA SIGNATURE DE CETTE CASE. La longueur d'une boucle valait
    -- `mesures × la signature SOUS LA TETE DE LECTURE` : une seule mesure en
    -- 3/4 quelque part dans le projet raccourcissait toutes les boucles au
    -- moment ou le transport la traversait, alors que les notes sont en beats
    -- absolus. « Follow project » reste le defaut et le comportement d'avant.
    local sigs = has and { {
        label = "Follow project",
        checked = (c.tsnum == nil),
        action = function() setCellTsNum(t, s, nil) end,
    } } or nil
    if sigs then
        for _, n in ipairs({ 2, 3, 4, 5, 6, 7, 8, 12 }) do
            sigs[#sigs + 1] = {
                label = n .. " beats per bar",
                checked = (c.tsnum == n),
                action = function() setCellTsNum(t, s, n) end,
            }
        end
    end
    UI.NativeMenu({
        { label = "Edit in CP_Editor", action = function() editCell(t, s) end },
        { label = "Rename clip…", disabled = not has,
          action = function() renameCell(t, s) end },
        { label = "Color", disabled = not has, children = cols },
        { label = "Length", disabled = not has, children = lens },
        { label = "Time signature", disabled = not has, children = sigs },
        { label = "Tempo", disabled = not snd, children = tmodes },
        { label = "Playback", disabled = not snd, children = lmodes },
        { label = "Stop this track", action = function() stopTrack(t) end },
        { separator = true },
        { label = "Clear cell", disabled = not has,
          action = function() clearCell(t, s) end },
    })
end

-- ---------------------------------------------------------------------------
-- LE PROJET A CHANGE SOUS LA FENETRE
-- ---------------------------------------------------------------------------
-- Tout ce que cette fenetre tient appartient a UN projet : la grille, les
-- motions, la longueur de prise, les identites de clip, et jusqu'aux caches de
-- noms. Un `defer` survit a un changement d'onglet, donc rien de tout cela ne
-- se recharge tout seul — et le mode d'echec n'est pas un affichage errone,
-- c'est la grille du projet A qui s'ECRIT dans le projet B.
--
-- On relit donc dans l'ordre inverse de la dependance : on vide, on recharge,
-- on invalide. `Loop` a deja suspendu son autosave sur le meme front.
local function reloadProject()
    for t = 0, TRACKS - 1 do
        local row = cells[t]
        for s = 0, SCENES - 1 do row[s] = nil end
        cur[t] = nil
        motion[t] = MOTION_STAY
        local f = mot[t]
        f.lane, f.tag, f.pz, f.armed, f.plays = -1, 0, 0, false, 0
        -- Le cache de nom de colonne est clé sur le POINTEUR de piste, et deux
        -- projets peuvent presenter le meme a des instants differents.
        track_name[t].known = false
    end
    for k in pairs(cell_lbl) do cell_lbl[k] = nil end
    erased, cdrag, rec = nil, nil, nil
    sel.t, sel.s = 0, 0
    -- LES IDENTITES SONT PAR PROJET, et `Loop.LaneOfTag` compare des nombres
    -- bruts. Garder le registre de A ferait resoudre un tag de B sur un clip de
    -- A — deux projets peuvent parfaitement porter le meme numero, puisque le
    -- compteur appartient au projet.
    if Ident.Reset then Ident.Reset() end
    loadGrid()
    loadMotion()
    do
        local _, v = r.GetProjExtState(0, "CP_Session", "rec_bars")
        local n = tonumber(v)
        rec_bars = 1
        if n then
            for i = 1, #REC_BARS do
                if REC_BARS[i] == n then rec_bars = n break end
            end
        end
    end
    state.recalled = false
    flash("Project changed — the grid was reloaded")
end

loadGrid()
loadMotion()

do
    local _, v = r.GetProjExtState(0, "CP_Session", "rec_bars")
    local n = tonumber(v)
    if n then
        for i = 1, #REC_BARS do
            if REC_BARS[i] == n then rec_bars = n break end
        end
    end
end

-- Migration: the old fixed "A" row (four sound slots under the grid) is
-- gone — a sound is a cell like any other now. Whatever was in it moves
-- into the first free scene of the matching column, once.
for i = 1, 4 do
    local _, p = r.GetProjExtState(0, "CP_Session", "audio" .. i)
    if p and p ~= "" then
        local t = i - 1
        if t < TRACKS then
            for s = 0, SCENES - 1 do
                if not cells[t][s] then
                    local c = Clip.new("audio")
                    c.path = p
                    c.name = p:match("([^/\\]+)$") or p
                    ensureBars(c)
                    cells[t][s] = c
                    break
                end
            end
        end
        r.SetProjExtState(0, "CP_Session", "audio" .. i, "")
    end
end

-- ---------------------------------------------------------------------------
-- DragBus: a drop on a cell FILLS that cell — a sound or a MIDI clip, the
-- two are interchangeable. Dropping never launches; that is the button's job.
-- ---------------------------------------------------------------------------
local function busConsume()
    if not state.registered then
        state.registered = DragBus.Register("session")
    end
    DragBus.RectSync("session")
    local clip, sx, sy, kind, payload, fsx, fsy = Bus.TakeDrop("session")
    -- An FX dragged from the Media Explorer or the FX browser is not a clip
    -- and never was: it lands in the CHAIN of the strip it was dropped on,
    -- which is the only thing "here" can mean over a mixer.
    if not clip and kind == "fx" and payload and payload ~= "" then
        local cx, cy = Core.ScreenToClient(fsx, fsy)
        for t = 0, TRACKS - 1 do
            local g = mix_col[t]
            if g and g.y and cx >= g.x and cx < g.x + g.w
               and cy >= g.y and cy < g.y + g.h then
                local tr = Loop.GetLaneDest(t)
                if Mix.Valid(tr) and Mix.FxAdd(tr, payload) >= 0 then
                    flash("FX -> " .. trackName(t))
                else
                    flash("This column has no track to put an FX on")
                end
                break
            end
        end
        return
    end
    if not clip then return end
    local g = state.grid
    if not g then return end
    local cx, cy = Core.ScreenToClient(sx, sy)
    if cx < g.x0 or cy < g.y0 then return end
    -- The x position gives a DRAW index; only the column list turns it into a
    -- slot. Reading it as a slot directly was fine while the two were the same
    -- number, and would drop clips into the wrong column the moment they are
    -- not.
    local t = Loop.ColumnAt(floor((cx - g.x0) / (g.cw + g.gap)) + 1)
    local s = floor((cy - g.y0) / (g.ch + g.gap))
    if not t or s < 0 or s >= SCENES then return end
    if not ((clip.kind == "audio" and clip.path)
            or (clip.kind == "midi" and clip.notes)) then
        return
    end
    if cur[t] == s then stopTrack(t) end   -- replacing what plays there
    clip.cell = t .. "," .. s
    -- The moment a sound enters the grid is the moment to ask how long it is.
    -- Anywhere later and the answer arrives after the first launch has already
    -- been heard on the wrong length.
    ensureBars(clip)
    cells[t][s] = clip
    saveGrid()
    flash((clip.kind == "audio" and "Sound -> " or "Clip -> ")
          .. trackName(t) .. " / scene " .. (s + 1))
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
-- Every cell carries its own transport button, the way a session view is
-- meant to be read: a triangle to launch, a square to stop what is playing,
-- a circle to capture into an empty slot of an armed track. Icons come from
-- the toolkit (baked at 4x, so antialiased like everything else) — never
-- raw gfx primitives.
local BTN_W = 16

-- How far a cell's ground is pulled toward the clip's own colour. See the
-- comment at the mix itself: identity has to be visible without taking the
-- channel that carries state.
local CLIP_TINT = 0.30

-- Countdown labels, precomputed. The waiting cell redraws every frame and a
-- tostring() there would mint one string per frame for nothing.
local CD_LBL = {}
for i = 1, 128 do CD_LBL[i] = tostring(i) end

local function drawCell(theme, t, s, x, y, w, h)
    local C = theme.colors
    local c = cells[t][s]
    local rad = theme.rounding_small or theme.rounding or 0
    local audio = isAudio(c)
    -- A cell reads ITS OWN lane, located by the tag the engine holds — not
    -- "the track's live lane". While a launch is queued those are two
    -- different clips, and reading the live one blinks the wrong cell.
    -- Nil means the engine is not holding this clip at all: stopped, and
    -- honestly so.
    local lane
    if c then
        lane = Loop.LaneOfTag(t, cellTag(t, s))
        if not lane and cur[t] == s and Loop.GetLaneTag(liveLane(t)) == 0 then
            -- Untagged engine state: loops recalled from a project saved
            -- before lanes carried their cell. Nothing claims that lane, so
            -- trusting the grid's own memory cannot point at someone else's
            -- clip — and it keeps a set recalled from an old project visible
            -- instead of showing a silent grid over audible loops.
            lane = liveLane(t)
        end
    end
    local mode = lane and floor(Loop.Mode(lane) + 0.5) or 0
    local pend = lane and Loop.Pending(lane) or 0
    local playing
    -- A queue with no boundary yet: it is waiting for the CLOCK, not for a
    -- beat. The cell has to say which, or "queued" looks like "stuck".
    local wait_clock = false
    -- ONE fork fewer. A sound cell used to answer these three questions from
    -- its own two preview objects, in states that had to be kept parallel to
    -- the engine's by hand. It is a lane now, so it answers the way everything
    -- else does — and a cell that holds a sound blinks, counts down and lights
    -- up because the same three lines say so, not because they were written
    -- twice and happened to agree.
    playing = (mode == 3 or mode == 5)
    if pend == 1 and lane then wait_clock = Loop.PendingWaitsClock(lane) end
    -- A capture ARMS first and turns into a take on the quantize boundary.
    -- Painting both red made a recording that had not started look exactly
    -- like one that had — so a cell could blink for a whole bar, capture
    -- nothing, and give no clue why. They are told apart now.
    -- And the wait says WHAT it waits for: beats counting down to the boundary,
    -- or the transport when the clock follows one that is not running. "Am I
    -- going to start at the right moment" should be answerable by looking.
    local capturing, waiting, cd_beats, cd_play = false, false, nil, false
    local rec_lane = (rec and rec.t == t and rec.s == s) and rec.lane or nil
    if rec_lane then
        local rm = floor(Loop.Mode(rec_lane) + 0.5)
        capturing = (rm == 1)
        waiting   = not capturing
        if waiting then
            if Loop.Pending(rec_lane) == 3 then
                local d = Loop.PendingTarget(rec_lane) - Loop.EngineBeat()
                if d > 0 then cd_beats = d end
            elseif rm == 4 then
                cd_play = true            -- armed: the clock has to run first
            end
        end
    end

    -- A cell is a canvas surface, and its state is that surface MIXED toward
    -- the role colour — never a hand-typed grey nor an accent multiplied down.
    -- The mix keeps the cell readable at any theme brightness, and the role
    -- (play / record / pending) stays the theme's to redefine.
    local base = c and C.canvas_row or C.canvas_row_dark
    local br, bg_, bb = base[1], base[2], base[3]
    -- The clip's own colour, mixed GENTLY into that ground. Gently on purpose:
    -- in this suite hue is the STATE channel (play, record, pending), and a
    -- cell painted at full saturation would spend it on identity, leaving the
    -- state nothing to speak with. At this strength eight clips are still told
    -- apart at a glance, and a playing one still reads as playing — helped by
    -- the two carriers state has besides the ground: the lit edge and the
    -- button's own glyph.
    local kr, kg, kb = Clip.ColorOf(c)
    if kr then
        br  = br  + (kr - br)  * CLIP_TINT
        bg_ = bg_ + (kg - bg_) * CLIP_TINT
        bb  = bb  + (kb - bb)  * CLIP_TINT
    end
    local role, k
    if capturing then role, k = C.record, 0.42
    elseif waiting then role, k = C.pending, 0.30
    elseif playing then role, k = C.play, 0.34 end
    if role then
        br = br + (role[1] - br) * k
        bg_ = bg_ + (role[2] - bg_) * k
        bb = bb + (role[3] - bb) * k
    end
    Core.DrawRoundRectFilled(x, y, w, h, rad, br, bg_, bb, 1)
    -- and a real edge, so a cell is an object on the grid rather than a
    -- slightly different shade of it
    local ec = C.border
    Core.DrawRect(x, y, w, h, ec[1], ec[2], ec[3], (ec[4] or 1) * 0.9, false)

    -- The transport button owns its own strip on the left. Clicking the REST
    -- of the cell opens it in CP_Editor — editing must never cost a play
    -- state, and launching must never be a side effect of wanting to look
    -- at the notes.
    local bw = BTN_W + 6
    local bx, by = x + 3, y + floor((h - BTN_W) / 2)
    local tc = C.text
    local mc = C.text_mute or C.text_disabled
    local btn_hot = Core.MouseInRect(x, y, bw, h) and not Core.HasPopup()
    if btn_hot then
        Core.DrawRoundRectFilled(x + 1, y + 1, bw - 1, h - 2,
                                 theme.rounding_small or 0, 1, 1, 1, 0.10)
    end
    local lit = playing or capturing or waiting or pend == 1
    if capturing or waiting then
        -- waiting blinks slower and dimmer than a take in progress: the button
        -- says "counting to the boundary", not "your playing is being kept"
        local a = 0.5 + 0.5 * math.abs(sin(r.time_precise() * (capturing and 5 or 2)))
        local d = C.danger or C.accent
        UI.Icons.Record(bx, by, BTN_W, d[1], d[2], d[3], capturing and a or a * 0.6)
        UI.RequestRedraw()
    elseif c then
        if playing or pend == 1 then
            UI.Icons.Stop(bx, by, BTN_W, tc[1], tc[2], tc[3], 1)
        else
            UI.Icons.Play(bx, by, BTN_W, tc[1], tc[2], tc[3],
                          btn_hot and 1 or 0.7)
        end
    elseif isArmed(t) then
        -- empty slot on the armed track: this is where a take lands
        local d = C.danger or C.accent
        UI.Icons.Record(bx, by, BTN_W, d[1], d[2], d[3], btn_hot and 0.9 or 0.5)
    end
    -- the lit state reads as a lit button, not only as a coloured cell
    if lit and not capturing then
        Core.DrawRect(x + 1, y + 1, 2, h - 2, C.accent[1], C.accent[2], C.accent[3], 0.9)
    end

    if c then
        -- queued launch / stop blinks, exactly as in the Looper
        if pend == 1 or pend == 2 then
            local a = 0.45 + 0.55 * math.abs(sin(r.time_precise() * 5))
            local pc = (pend == 2) and C.text or C.accent
            Core.DrawRect(x, y, w, h, pc[1], pc[2], pc[3], a, false)
            UI.RequestRedraw()
        end
        if playing then
            local a = C.accent
            local prog
            -- LE SON D'ABORD, LA GRILLE ENSUITE. La phase de la lane est une
            -- position sur la GRILLE : elle dit ou en est la mesure, pas ou en
            -- est le fichier. Les deux ne coincident que si la matiere remplit
            -- exactement sa passe — donc presque jamais pour un one-shot, qui
            -- se tait pendant que la barre continue d'avancer. La voix publie
            -- sa position depuis toujours et personne ne la lisait.
            if audio then prog = Cells.Progress(t) end
            if not prog and lane then
                local L = Loop.LenBeats(lane)
                if L > 0 then prog = Loop.Phase(lane) / L end
            end
            if prog then
                Core.DrawRect(x + 2, y + h - 4, (w - 4) * prog, 2,
                              a[1], a[2], a[3], 0.9)
            end
            UI.RequestRedraw()
        end
        local nm = (c.name and c.name ~= "") and c.name or "clip"
        local tw = w - bw - 6
        -- COMBIEN DE FOIS CA A TOURNE. Ableton l'affiche dans son Track Status
        -- field, et c'est la question qu'on se pose en jouant : « ca fait
        -- combien de passes ». Elle tombe gratuitement du meme repli de phase
        -- qui date le motion, donc elle ne coute rien a personne.
        local np = playing and motionPlays(t) or 0
        if np > 0 then
            local pl = playsLabel(np)
            tw = tw - 20
            UI.SetFontCaption()
            Core.DrawText(pl, x + w - 4 - Core.MeasureText(pl), y + 4,
                          mc[1], mc[2], mc[3], 0.75)
            UI.SetFontBody()
        end
        Core.DrawText(cellLabel(t, s, nm, tw), x + bw + 2, y + 3,
                      tc[1], tc[2], tc[3], 0.95)
        UI.SetFontCaption()
        if wait_clock then
            -- it is not late, it is early: the clock it was launched against
            -- has not started yet, and it will start with it
            local pc = C.pending or C.accent
            Core.DrawText("waiting for the transport",
                          x + bw + 2, y + h - 13, pc[1], pc[2], pc[3], 0.9)
        else
            Core.DrawText(audio and audioSub(c) or barsLabel(cellBars(c)),
                          x + bw + 2, y + h - 13, mc[1], mc[2], mc[3], 0.85)
        end
        UI.SetFontBody()
    end

    -- What the queued take is waiting for, in the cell's own body.
    if capturing or waiting then
        local d = C.danger or C.accent
        local head, sub
        if cd_beats then
            -- beats remaining, rounded UP: it reads 4, 3, 2, 1 and the take
            -- starts as it would have said 0
            local n = floor(cd_beats) + 1
            if n < 1 then n = 1 elseif n > 128 then n = 128 end
            head = CD_LBL[n]
            sub  = "beats to go"
        elseif cd_play then
            head, sub = "PLAY", "waiting for the transport"
        elseif capturing then
            head, sub = "REC", barsLabel(Loop.GetLengthBars(rec_lane))
        else
            head, sub = "REC", "queued"
        end
        Core.DrawText(head, x + bw + 3, y + 3, d[1], d[2], d[3], 0.95)
        UI.SetFontCaption()
        Core.DrawText(sub, x + bw + 3, y + h - 13, d[1], d[2], d[3], 0.7)
        UI.SetFontBody()
        -- how much of the take is already in — the same strip a playing clip
        -- uses, so "is it running" reads the same way whatever the cell is doing
        if capturing then
            local L = Loop.LenBeats(rec_lane)
            if L > 0 then
                local p = Loop.Phase(rec_lane) / L
                if p > 0 then
                    Core.DrawRect(x + 2, y + h - 4, (w - 4) * p, 2,
                                  d[1], d[2], d[3], 0.9)
                end
            end
        end
    end

    -- Ctrl-drag copy: the cell being dragged FROM stays lit, the one under the
    -- cursor shows where it would land.
    if cdrag then
        if cdrag.t == t and cdrag.s == s then
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.5, false)
        elseif Core.MouseInRect(x, y, w, h) then
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.18)
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.9, false)
        end
    end

    if Core.MouseInRect(x, y, w, h) and not Core.HasPopup() then
        -- Alt+clic efface, n'importe ou sur la case. Le modificateur le tient
        -- a l'ecart des deux clics simples (lancer sur la bande, editer sur le
        -- contenu) — mais il restait SANS RETOUR : une case pleine de notes
        -- disparaissait sur un raccourci a une main, et rien ne la ramenait.
        -- Le dernier efface est garde ; Ctrl+Z le repose. Une seule case, pas
        -- une pile : ce geste se fait une fois, on le regrette tout de suite,
        -- et une pile aurait fait croire a une annulation generale de la
        -- grille, qui elle n'existe pas.
        if Core.MouseClicked(1) then sel.t, sel.s = t, s end
        if Core.ModAlt() and Core.MouseClicked(1) then
            if c then
                erased = { t = t, s = s, clip = c }
                flash("Cell erased — Ctrl+Z puts it back")
            end
            clearCell(t, s)
        elseif Core.ModCtrl() and c and Core.MouseClicked(1) then
            cdrag = { t = t, s = s }
        elseif btn_hot then
            -- transport strip
            if Core.MouseClicked(1) then
                if capturing or waiting then
                    stopRec()
                elseif c then
                    launchCell(t, s)
                elseif isArmed(t) then
                    recCell(t, s)
                else
                    flash("Arm this track (circle in its header) to record here")
                end
            elseif Core.MouseClicked(2) then
                cellMenu(t, s)
            end
        else
            -- content: opening it must not touch what is playing
            Core.DrawRect(x + bw, y, w - bw, h, 1, 1, 1, 0.05)
            if Core.MouseClicked(1) then
                editCell(t, s)
            elseif Core.MouseClicked(2) then
                cellMenu(t, s)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The mixer — a real channel strip per column
--
-- This started as three controls on the reasoning that a console would
-- re-implement what REAPER already has. That was right about the FORMAT and
-- wrong about the VIEW. Nothing below is a second mixer engine: every value is
-- REAPER's own track state, read and written through REAPER's own API, and the
-- FX chain window that opens is REAPER's. What the session needed was the
-- CHAIN and the SENDS of the thing it is launching, beside the thing it is
-- launching — reaching them meant leaving the window, and not leaving the
-- window is what a session view is for.
--
-- A column mixes the track it is ROUTED TO — the same track its clips play
-- into, so this is also the level of whatever CP_Sampler or CP_Editor sends
-- there. A column with no destination has nothing to mix and says so by being
-- disabled, not by showing a fader that quietly does nothing.
--
-- The zone's HEIGHT is the only control over how much of the strip you see:
-- drag its seam. Short, it is the fader block alone (what it always was);
-- taller, the sends appear, then the chain. No sub-toggles — the height IS
-- the answer, and it is one gesture instead of three checkboxes.
-- ---------------------------------------------------------------------------
local MIX_H     = 18       -- the M/S row
local MIX_PAD   = 4
local MIX_BTN   = 18
local MIX_MET   = 11       -- meter width beside the vertical fader
local MIX_GAP   = 3
local SEC_GAP   = 6        -- BETWEEN sections: FX | sends | fader block
local MIX_FADW  = 21       -- the fader's own width (cap included)
-- One slot. The caption font is 10 px and REAPER reports it about 13 tall, so
-- a 16-px slot leaves a pixel of air above and below the glyphs — text that
-- touches its own border reads as text that overflowed, even when it did not.
local MIX_ROW   = 16
local MIX_BAR   = 5        -- the scroll bar of a list that overflows
local MIX_DB    = 11       -- the level readout, on a line of its own
local MIX_SENDS = 4        -- most send slots shown before the list scrolls
-- Le plancher du bloc de fader vaut desormais la colonne de droite : pan, M et
-- S l'un sur l'autre. En dessous, la colonne deborderait dans les envois.
local MIX_FADMIN = MIX_BTN * 3 + 8
local MIX_ROWS  = 24       -- most rows a list will ever draw (id/label tables)
-- How much of a strip the two LISTS may take. The fader gets everything else:
-- it is the control you reach for a hundred times an hour, and on a console it
-- is the tallest thing in the strip for exactly that reason. A list that grew
-- at its expense would be a directory with a fader stapled to it.
local MIX_LISTS = 0.55
-- The shortest the zone can be: a usable fader block + the readout + padding.
-- Le pan et les deux boutons ne prennent plus de hauteur a eux : ils sont DANS
-- le bloc de fader, en colonne a sa droite.
local MIX_MIN   = MIX_PAD * 2 + MIX_DB + MIX_FADMIN
-- …and what it opens at: enough for a chain, a couple of sends and a fader
-- worth grabbing. It was opening at its MINIMUM, which showed the strip at its
-- least useful and left the seam to be discovered before anything worked.
local MIX_DEF   = 300
local MIX_MAX   = 620
local SEAM_GRAB = 5        -- the band of the seam that resizes the zone

local mix_open  = Core.LoadPersistent("CP_Session", "mix", true)
-- new key on purpose: the old one holds "as small as it goes" for everyone who
-- opened the window before the strip had anything in it
local mix_h     = Core.LoadPersistent("CP_Session", "mixh2", MIX_DEF)
local mix_moved = false    -- did the fader gesture in flight change anything
-- QUELLE COLONNE A SON PAN SOUS LE DOIGT. Un bouton rond ne rend pas de
-- « relache » comme un fader : il faut donc se souvenir qu'on en tourne un pour
-- ne poser QU'UN point d'annulation a la fin du geste, et non un par frame.
local pan_hot   = nil
local mix_hot   = false    -- is any meter still above zero (so still falling)
local mix_seam  = nil      -- { y0, h0 } while the seam is being dragged
local fxdrag    = nil      -- { tr, i, t, x, y } an FX being carried
local snddrag   = nil      -- { t } a send being drawn from this column
if type(mix_h) ~= "number" then mix_h = MIX_MIN end
if mix_h < MIX_MIN then mix_h = MIX_MIN elseif mix_h > MIX_MAX then mix_h = MIX_MAX end

-- Ids are identity, and identity must not be rebuilt every frame.
local mix_id = { v = {}, m = {}, s = {}, p = {}, sd = {} }
for t = 0, TRACKS - 1 do
    mix_id.v[t] = "mixv" .. t
    mix_id.m[t] = "mixm" .. t
    mix_id.s[t] = "mixs" .. t
    mix_id.p[t] = "mixp" .. t
    local row = {}
    for i = 1, MIX_ROWS do row[i] = "mixsd" .. t .. "_" .. i end
    mix_id.sd[t] = row
end

-- Truncation caches, one slot per (column, row): a name is cut once for a
-- width and stays cut until one of the two changes. Built here, never in the
-- draw path — the strip redraws thirty times a second.
local fx_lbl, sd_lbl = {}, {}
local mix_scroll = {}      -- [t] = { fx, sd } first row shown in each list
for t = 0, TRACKS - 1 do
    local a, b = {}, {}
    for i = 1, MIX_ROWS do a[i] = {} b[i] = {} end
    fx_lbl[t], sd_lbl[t] = a, b
    mix_scroll[t] = { fx = 0, sd = 0 }
end

local function fitLabel(cache, s, w)
    if cache.src ~= s or cache.w ~= w then
        cache.src, cache.w = s, w
        cache.s = Core.TruncateText(s, w)
    end
    return cache.s
end

-- Shared option tables: every field is written on every call, so nothing
-- stale survives — and no table is built in a draw path.
local MIX_F_OPTS = { mark = Mix.UNITY, default = Mix.UNITY,
                     disabled = false, accent = nil,
                     tip = "Volume — Shift: fine, double-click: 0 dB, wheel: step" }
-- BIPOLAIRE : l'arc part du CENTRE et non de la butee gauche, et un repere y
-- marque le zero. Sans ca, « fond a gauche » et « au centre » ne different que
-- par la longueur d'une bande qui pousse du meme coin, donc rien ne dit de quel
-- cote du milieu on se trouve — ce qui est la seule chose qu'un pan doit dire.
local MIX_P_OPTS = { mark = 0.5, default = 0.5, text = nil, bipolar = true,
                     disabled = false, accent = nil,
                     tip = "Pan — drag, double-click: centre, right-click: type" }
local MIX_M_OPTS = { accent = nil, tip = "Mute this column's track" }
local MIX_S_OPTS = { accent = nil,
    tip = "Solo — REAPER's solo, so the arrangement goes quiet too. Ctrl: exclusive" }
local MIX_SD_OPTS = { mark = Mix.UNITY, default = Mix.UNITY, accent = nil,
                      disabled = false }

local function fxMenu(tr, i)
    local items = {}
    if i then
        local nm = Mix.Fx(tr, i)
        items[#items + 1] = { label = "Open " .. (nm or "FX"),
                              action = function() Mix.FxShow(tr, i) end }
        items[#items + 1] = { label = "Bypass",
                              checked = select(2, Mix.Fx(tr, i)) and true or false,
                              action = function() Mix.FxToggle(tr, i) end }
        items[#items + 1] = { label = "Delete",
                              action = function() Mix.FxDelete(tr, i) end }
        items[#items + 1] = { separator = true }
    end
    items[#items + 1] = { label = "FX browser (REAPER)",
                          action = function()
                              r.SetOnlyTrackSelected(tr)
                              r.Main_OnCommand(40271, 0)
                          end }
    items[#items + 1] = { label = "CP_FX Browser",
                          action = function()
                              if not Bus.FocusApp("CP_FXBrowser", "FX Browser") then
                                  flash("CP_FX Browser is not registered as an action yet")
                              end
                          end }
    items[#items + 1] = { label = "Open this track's FX chain",
                          action = function() r.TrackFX_Show(tr, 0, 1) end }
    UI.NativeMenu(items)
end

local function sendMenu(t, tr, i)
    local items = {}
    if i then
        items[#items + 1] = { label = "Mute send", checked = Mix.SendMute(tr, i),
                              action = function()
                                  Mix.SetSendMute(tr, i, not Mix.SendMute(tr, i))
                              end }
        items[#items + 1] = { label = "Remove send",
                              action = function() Mix.SendRemove(tr, i) end }
        items[#items + 1] = { separator = true }
    end
    -- Every OTHER column is a candidate: those are the destinations this
    -- window actually knows about, and the ones a session sends to.
    local any = false
    for d = 0, TRACKS - 1 do
        local dtr = (d ~= t) and Loop.GetLaneDest(d) or nil
        if dtr and Mix.Valid(dtr) and dtr ~= tr then
            any = true
            items[#items + 1] = { label = "Send to " .. trackName(d),
                                  action = function()
                                      -- L'ENVOI EXISTAIT PEUT-ETRE DEJA, et le
                                      -- dire vaut mieux qu'annoncer une
                                      -- creation qui n'a pas eu lieu.
                                      local ok, made = Mix.SendCreate(tr, dtr)
                                      if ok then
                                          flash(made
                                                and ("Send -> " .. trackName(d))
                                                or ("Already sending to "
                                                    .. trackName(d)))
                                      end
                                  end }
        end
    end
    if not any then
        items[#items + 1] = { label = "(route another column to a track first)",
                              disabled = true }
    end
    UI.NativeMenu(items)
end

-- ONE SLOT — filled or empty, and both are a real object with a border, the
-- way a console's chain reads. The row IS the hit target (no widget id): slots
-- come and go with the chain, and an id that changes meaning between frames is
-- worse than no id at all. An empty one is drawn hollow: a place where
-- something can go, not a thing that is missing.
local function slotRow(theme, x, y, w, label, dim, lit, hot, empty)
    local C = theme.colors
    local iy, ih = y + 1, MIX_ROW - 2
    if empty then
        local bd = C.border
        Core.DrawRect(x + 2, iy, w - 4, ih, bd[1], bd[2], bd[3],
                      (bd[4] or 1) * (hot and 0.85 or 0.35), false)
        if hot then Core.DrawRect(x + 2, iy, w - 4, ih, 1, 1, 1, 0.07) end
        return
    end
    local sf = C.frame_bg
    Core.DrawRect(x + 2, iy, w - 4, ih, sf[1], sf[2], sf[3], dim and 0.5 or 1)
    if hot then Core.DrawRect(x + 2, iy, w - 4, ih, 1, 1, 1, 0.08) end
    if lit then
        Core.DrawRect(x + 2, iy, 2, ih, C.accent[1], C.accent[2], C.accent[3], 0.9)
    end
    if label then
        local ink = dim and (C.text_disabled or C.text_mute) or C.text
        -- centred in the box it lives in, measured rather than guessed: the
        -- glyph height is the font's business and it changes with the theme
        local _, th = Core.MeasureText(label)
        local ty = iy + floor((ih - th) / 2)
        if ty < iy then ty = iy end
        Core.DrawText(label, x + 7, ty, ink[1], ink[2], ink[3], dim and 0.6 or 0.95)
    end
end

local function drawMix(theme, t, x, y, w, h)
    local C = theme.colors
    local tr = Loop.GetLaneDest(t)
    local live = Mix.Valid(tr)
    local g = mix_col[t]
    if not g then g = {}; mix_col[t] = g end
    g.x, g.w, g.y, g.h = x, w, y, h

    local muted  = live and Mix.IsMute(tr)
    local soloed = live and Mix.IsSolo(tr)
    -- A column can be silent for two reasons, and the second one is not on
    -- this column: its own mute, or somebody else's solo. The level wears the
    -- mute colour either way, so "which of these do I actually hear" is one
    -- glance rather than an audit of four buttons.
    local dulled = live and (muted or (Mix.AnySolo() and not soloed))

    -- ---- geometry. Three sections, each with its own ground and a real gap
    -- between them: FX, then sends, then the fader block. A strip whose parts
    -- touch is a strip you have to decode before you can use it.
    local db_y  = y + h - MIX_DB                 -- the readout has its own line
    local avail = db_y - SEC_GAP - y             -- lists + fader

    local nfx  = live and Mix.FxCount(tr) or 0
    local nsnd = live and Mix.SendCount(tr) or 0
    -- The lists never take more than MIX_LISTS of the strip and the FADER TAKES
    -- EVERYTHING ELSE. Within their share the sends ask for what they hold plus
    -- one empty slot (capped: a session sends to a handful of places, not to
    -- twenty) and the chain takes the rest — as SLOTS, filled or not, exactly
    -- as a console does. What does not fit is reachable by scrolling the list,
    -- which is what the thin bar on its right edge is for.
    local cap = floor(avail * MIX_LISTS)
    if avail - cap < MIX_FADMIN + SEC_GAP then cap = avail - MIX_FADMIN - SEC_GAP end
    if cap < 0 then cap = 0 end
    local fx_rows, sd_rows = 0, 0
    if cap >= MIX_ROW * 2 + SEC_GAP then
        local want_s = nsnd + 1
        if want_s > MIX_SENDS then want_s = MIX_SENDS end
        local room = floor((cap - SEC_GAP) / MIX_ROW)
        sd_rows = want_s
        if sd_rows > room - 1 then sd_rows = room - 1 end
        if sd_rows < 1 then sd_rows = 1 end
        fx_rows = room - sd_rows
    elseif cap >= MIX_ROW then
        fx_rows = floor(cap / MIX_ROW)
    end
    local fx_h = fx_rows * MIX_ROW
    local sd_h = sd_rows * MIX_ROW
    local sd_y = y + fx_h + (sd_rows > 0 and SEC_GAP or 0)
    local fad_h = db_y - SEC_GAP - (sd_y + sd_h)
    if fad_h < MIX_FADMIN then fad_h = MIX_FADMIN end
    local fad_y = db_y - fad_h

    local sc = mix_scroll[t]
    -- clamp the scroll to what the list can actually show, so a chain that
    -- shrank does not leave the view parked past its end
    if sc.fx > nfx - fx_rows + 1 then sc.fx = nfx - fx_rows + 1 end
    if sc.fx < 0 then sc.fx = 0 end
    if sc.sd > nsnd - sd_rows + 1 then sc.sd = nsnd - sd_rows + 1 end
    if sc.sd < 0 then sc.sd = 0 end

    -- where a carried FX can be dropped, remembered for pollMixDrag
    g.fx_y = (fx_rows > 0) and y or nil
    g.fx_rows = fx_rows
    g.fx_scroll = sc.fx

    local mxp, myp = Core.GetMousePos()

    -- ---- the chain, as SLOTS
    local over_fx = nil
    if fx_rows > 0 then
        local bar = (nfx > fx_rows) and MIX_BAR or 0
        local rw = w - bar
        local bg = C.list_bg or C.frame_bg
        local bd = C.border
        Core.DrawRect(x, y, w, fx_h, bg[1], bg[2], bg[3], live and 1 or 0.5)
        local inlist = live and not Core.HasPopup()
            and mxp >= x and mxp < x + w and myp >= y and myp < y + fx_h
        for row = 1, fx_rows do
            local ly = y + (row - 1) * MIX_ROW
            local i  = sc.fx + row
            local hot = inlist and myp >= ly and myp < ly + MIX_ROW
            if i <= nfx then
                local nm, off = Mix.Fx(tr, i)
                slotRow(theme, x, ly, rw, fitLabel(fx_lbl[t][row], nm or "?", rw - 9),
                        off, not off, hot, false)
                if hot then
                    over_fx = row
                    if Core.MouseClicked(1) then
                        if Core.ModAlt() then Mix.FxDelete(tr, i)
                        elseif Core.ModCtrl() then Mix.FxToggle(tr, i)
                        else
                            fxdrag = { tr = tr, i = i, t = t,
                                       x = mxp, y = myp, moved = false }
                        end
                    elseif Core.MouseClicked(2) then
                        fxMenu(tr, i)
                    end
                end
            else
                -- an EMPTY SLOT, and it does what an empty slot does on every
                -- console: it opens the FX browser. REAPER's own — and the
                -- column's track is SELECTED first, because that browser
                -- inserts into the selection, so without it the gesture would
                -- open a browser aimed at whatever was clicked last.
                slotRow(theme, x, ly, rw, nil, true, false, hot, true)
                if hot then
                    over_fx = row
                    if Core.MouseClicked(1) then
                        r.SetOnlyTrackSelected(tr)
                        r.Main_OnCommand(40271, 0)   -- View: Show FX browser
                    elseif Core.MouseClicked(2) then
                        fxMenu(tr, nil)
                    end
                end
            end
        end
        -- the scroll bar, and the wheel that goes with it
        if bar > 0 then
            local th = floor(fx_h * fx_rows / nfx)
            if th < 10 then th = 10 end
            local span = fx_h - th
            local den  = nfx - fx_rows
            local ty = y + ((den > 0) and floor(span * sc.fx / den) or 0)
            local ac = C.text_mute or C.text_disabled
            Core.DrawRect(x + rw + 1, y, bar - 1, fx_h, 0, 0, 0, 0.25)
            Core.DrawRect(x + rw + 1, ty, bar - 1, th, ac[1], ac[2], ac[3], 0.65)
        end
        if inlist and not Core.IsWheelConsumed() then
            local wh = Core.GetState().mouse_wheel
            if wh ~= 0 then
                sc.fx = sc.fx - ((wh > 0) and 1 or -1)
                if sc.fx < 0 then sc.fx = 0 end
                if sc.fx > nfx - fx_rows then sc.fx = nfx - fx_rows end
                if sc.fx < 0 then sc.fx = 0 end
                Core.ConsumeWheel()
            end
        end
        Core.DrawRect(x, y, w, fx_h, bd[1], bd[2], bd[3], (bd[4] or 1) * 0.7, false)
        -- where a carried FX would land
        if fxdrag and fxdrag.moved and over_fx then
            local iy = y + (over_fx - 1) * MIX_ROW
            Core.DrawRect(x, iy, w, 2, C.accent[1], C.accent[2], C.accent[3], 1)
        end
    end

    -- ---- the sends, same grammar
    if sd_rows > 0 then
        local bar = (nsnd > sd_rows) and MIX_BAR or 0
        local rw = w - bar
        local bg = C.list_bg or C.frame_bg
        local bd = C.border
        Core.DrawRect(x, sd_y, w, sd_h, bg[1], bg[2], bg[3], live and 1 or 0.5)
        local inlist = live and not Core.HasPopup()
            and mxp >= x and mxp < x + w and myp >= sd_y and myp < sd_y + sd_h
        for row = 1, sd_rows do
            local ly = sd_y + (row - 1) * MIX_ROW
            local i  = sc.sd + row
            local hot = inlist and myp >= ly and myp < ly + MIX_ROW
            if i <= nsnd and i <= MIX_ROWS then
                local nm, _, lvl = Mix.Send(tr, i)
                MIX_SD_OPTS.accent = Mix.SendMute(tr, i) and C.mute or C.mod
                MIX_SD_OPTS.disabled = not live
                -- The send IS its level: the row is a fader with the
                -- destination written on it, so reading and setting are the
                -- same object rather than a name and a number somewhere else.
                local ch, nv, rel = UI.FaderAt(mix_id.sd[t][i], x + 2, ly + 1,
                                               rw - 4, MIX_ROW - 2, lvl or 0,
                                               MIX_SD_OPTS)
                if ch then Mix.SetSendNorm(tr, i, nv) mix_moved = true end
                if rel then
                    -- A DRAG set the level; a CLICK — released without having
                    -- moved anything — opens REAPER's routing window, which is
                    -- where a send's real parameters live (pre/post, channels,
                    -- MIDI). One gesture each, told apart by what happened
                    -- between press and release.
                    if mix_moved then
                        Mix.CommitSend()
                    else
                        r.SetOnlyTrackSelected(tr)
                        r.Main_OnCommand(40293, 0)   -- Track: routing and I/O
                    end
                    mix_moved = false
                end
                local lbl = fitLabel(sd_lbl[t][row], nm or "send", rw - 12)
                local _, th = Core.MeasureText(lbl)
                Core.DrawText(lbl, x + 6, ly + 1 + floor((MIX_ROW - 2 - th) / 2),
                              C.text[1], C.text[2], C.text[3], 0.95)
                if hot and Core.MouseClicked(2) then sendMenu(t, tr, i) end
            else
                slotRow(theme, x, ly, rw, nil, true, false, hot, true)
                if hot then
                    -- click asks where to, DRAG draws the send to the column
                    -- you drop it on — the gesture says "from here to there",
                    -- which is what a send is
                    if Core.MouseClicked(1) then
                        snddrag = { t = t, tr = tr, x = mxp, y = myp, moved = false }
                    elseif Core.MouseClicked(2) then
                        sendMenu(t, tr, nil)
                    end
                end
            end
        end
        if bar > 0 then
            local th = floor(sd_h * sd_rows / nsnd)
            if th < 10 then th = 10 end
            local span = sd_h - th
            local den  = nsnd - sd_rows
            local ty = sd_y + ((den > 0) and floor(span * sc.sd / den) or 0)
            local ac = C.text_mute or C.text_disabled
            Core.DrawRect(x + rw + 1, sd_y, bar - 1, sd_h, 0, 0, 0, 0.25)
            Core.DrawRect(x + rw + 1, ty, bar - 1, th, ac[1], ac[2], ac[3], 0.65)
        end
        if inlist and not Core.IsWheelConsumed() then
            local wh = Core.GetState().mouse_wheel
            if wh ~= 0 then
                sc.sd = sc.sd - ((wh > 0) and 1 or -1)
                if sc.sd < 0 then sc.sd = 0 end
                if sc.sd > nsnd - sd_rows then sc.sd = nsnd - sd_rows end
                if sc.sd < 0 then sc.sd = 0 end
                Core.ConsumeWheel()
            end
        end
        Core.DrawRect(x, sd_y, w, sd_h, bd[1], bd[2], bd[3], (bd[4] or 1) * 0.7, false)
    end

    -- ---- LE PIED DE TRANCHE : fader et VU cote a cote, et la colonne des
    -- trois choses qu'on attrape en mixant — pan, mute, solo — A LEUR DROITE.
    --
    -- Elles occupaient trois LIGNES sous le fader : une barre de pan pleine
    -- largeur, la lecture en decibels, la paire M/S. Trente-trois pixels pris a
    -- la course du fader, c'est-a-dire a l'endroit meme ou vit sa precision —
    -- et une bande qu'on lit de haut en bas au lieu de la saisir. En colonne a
    -- droite elles ne coutent plus une seule ligne, et le fader recupere tout.
    local col_w = MIX_BTN + 2
    if w - col_w - MIX_GAP < MIX_FADW then col_w = 0 end   -- trop etroit : on renonce
    local body_w = w - ((col_w > 0) and (col_w + MIX_GAP) or 0)
    local fw = MIX_FADW
    local met_w = MIX_MET
    if fw + MIX_GAP + met_w > body_w then met_w = body_w - fw - MIX_GAP end
    if met_w < 4 then met_w = 0 end
    local fx0 = x + floor((body_w - fw - (met_w > 0 and (met_w + MIX_GAP) or 0)) / 2)
    local n = Mix.GetNorm(tr)
    MIX_F_OPTS.disabled = not live
    MIX_F_OPTS.accent = dulled and C.mute or nil
    local ch, nv, rel = UI.VFaderAt(mix_id.v[t], fx0, fad_y, fw, fad_h, n,
                                    MIX_F_OPTS)
    if ch then
        Mix.SetNorm(tr, nv)
        mix_moved = true
    end
    -- One undo point per gesture, and only if the gesture did something: a
    -- click that moved nothing should not enter the history.
    if rel then
        if mix_moved and live then Mix.CommitVol() end
        mix_moved = false
    end
    if met_w > 0 then
        local mx = fx0 + fw + MIX_GAP
        if live then
            local ml, mr, hl, hr = Mix.Meter(t, tr)
            -- A meter still above zero is a meter still FALLING, and it needs
            -- frames to fall in. Without this the strip freezes lit the moment
            -- the transport stops, which reads as "still playing".
            if ml > 0 or mr > 0 or hl > 0 or hr > 0 then mix_hot = true end
            UI.MeterAt(mx, fad_y, met_w, fad_h, ml, mr, true, hl, hr)
        else
            -- Unrouted: clear rather than fade, so nothing is left showing a
            -- level from a track this column no longer plays into.
            Mix.ResetMeter(t)
            UI.MeterAt(mx, fad_y, met_w, fad_h, 0, 0, true)
        end
    end
    -- The number, on a LINE OF ITS OWN under the fader: a strip says its level
    -- in decibels or it is a guess — and it had been sharing a line with the
    -- sends, which is how two readable things become one unreadable one.
    if live then
        local s = Mix.DbLabel(t, n)
        local tw = Core.MeasureText(s)
        local ink = dulled and C.mute or C.text_mute or C.text
        Core.DrawText(s, x + floor((w - tw) / 2), db_y,
                      ink[1], ink[2], ink[3], 0.85)
    end

    -- ---- la colonne de droite : pan, puis M, puis S, alignes sur le BAS du
    -- fader. C'est le pied de tranche d'une console, et c'est la que la main
    -- va. Le pan est un bouton ROND parce qu'il est bipolaire : son arc part du
    -- centre, donc « a gauche » et « a droite » se lisent sans lire un nombre.
    if col_w > 0 then
        -- Les trois ordonnees, du bas vers le haut. Nommees `y_*` et non `my` :
        -- dans ce fichier `mxp, myp` est la souris, et une variable qui s'appelle
        -- `my` a cote se lit comme elle.
        local cx  = x + w - col_w
        local y_s = fad_y + fad_h - MIX_H
        local y_m = y_s - MIX_H - 2
        local y_k = y_m - MIX_BTN - 4
        MIX_M_OPTS.accent = C.mute
        MIX_S_OPTS.accent = C.solo
        MIX_P_OPTS.disabled = not live
        MIX_P_OPTS.accent = dulled and C.mute or C.mod
        local pn = live and Mix.GetPan(tr) or 0.5
        local pch, pnv = UI.KnobAt(mix_id.p[t], cx, y_k, MIX_BTN, pn, 0.5,
                                   MIX_P_OPTS)
        if pch and live then
            Mix.SetPan(tr, pnv)
            pan_hot = t          -- le point d'annulation attend la fin du geste
        end
        if UI.ChipAt(mix_id.m[t], cx, y_m, MIX_BTN, MIX_H, nil, "M", muted,
                     not live, MIX_M_OPTS) then
            Mix.SetMute(tr, not muted)
        end
        if UI.ChipAt(mix_id.s[t], cx, y_s, MIX_BTN, MIX_H, nil, "S",
                     soloed, not live, MIX_S_OPTS) then
            Mix.SetSolo(tr, not soloed, Core.ModCtrl())
        end
    end

    -- what a carried thing would land on
    if (fxdrag and fxdrag.moved and fxdrag.t ~= t)
       or (snddrag and snddrag.moved and snddrag.t ~= t) then
        if mxp >= x and mxp < x + w and myp >= y and myp < y + h then
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.10)
            Core.DrawRect(x, y, w, h, C.accent[1], C.accent[2], C.accent[3], 0.9, false)
        end
    end
end

-- The two carries, resolved once per frame after every strip has drawn (each
-- one knows its own rect by then). A drag only becomes a drag past a few
-- pixels: a click that wandered is still a click.
local function pollMixDrag()
    local mx, my = Core.GetMousePos()
    -- UN SEUL POINT D'ANNULATION PAR GESTE DE PAN. Un bouton rond ne dit pas
    -- « relache » ; on le deduit du bouton de souris, ici, une fois toutes les
    -- bandes dessinees.
    if pan_hot and not Core.MouseDown(1) then
        Mix.CommitPan()
        pan_hot = nil
    end
    if fxdrag then
        if not fxdrag.moved then
            local dx, dy = mx - fxdrag.x, my - fxdrag.y
            if dx * dx + dy * dy > 16 then fxdrag.moved = true end
        end
        if fxdrag.moved then UI.SetCursor("hand") UI.RequestRedraw() end
        if not Core.MouseDown(1) then
            if fxdrag.moved then
                for t = 0, TRACKS - 1 do
                    local g = mix_col[t]
                    if g and mx >= g.x and mx < g.x + g.w then
                        local dst = Loop.GetLaneDest(t)
                        if Mix.Valid(dst) then
                            local to = Mix.FxCount(dst) + 1
                            if g.fx_y and my >= g.fx_y then
                                -- the row under the cursor, offset by what the
                                -- list is scrolled to: the slot you see is the
                                -- slot it lands in
                                local row = floor((my - g.fx_y) / MIX_ROW) + 1
                                if row >= 1 and row <= (g.fx_rows or 0) then
                                    local k = (g.fx_scroll or 0) + row
                                    if k >= 1 and k <= to then to = k end
                                end
                            end
                            if Mix.FxMove(fxdrag.tr, fxdrag.i, dst, to,
                                          Core.ModCtrl()) then
                                flash(Core.ModCtrl() and "FX copied" or "FX moved")
                            end
                        end
                        break
                    end
                end
            elseif fxdrag.tr then
                Mix.FxShow(fxdrag.tr, fxdrag.i)   -- a plain click OPENS it
            end
            fxdrag = nil
        end
    end
    if snddrag then
        if not snddrag.moved then
            local dx, dy = mx - snddrag.x, my - snddrag.y
            if dx * dx + dy * dy > 16 then snddrag.moved = true end
        end
        if snddrag.moved then UI.SetCursor("hand") UI.RequestRedraw() end
        if not Core.MouseDown(1) then
            if snddrag.moved then
                for t = 0, TRACKS - 1 do
                    local g = mix_col[t]
                    if g and t ~= snddrag.t and mx >= g.x and mx < g.x + g.w then
                        local dst = Loop.GetLaneDest(t)
                        if Mix.Valid(dst) then
                            local ok, made = Mix.SendCreate(snddrag.tr, dst)
                            if ok then
                                flash(made and ("Send -> " .. trackName(t))
                                      or ("Already sending to " .. trackName(t)))
                            end
                        end
                        break
                    end
                end
            else
                sendMenu(snddrag.t, snddrag.tr, nil)   -- a plain click asks
            end
            snddrag = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- LE CLAVIER
-- ---------------------------------------------------------------------------
-- CP_Session n'en avait AUCUN. Chez Ableton on descend un set entier en tapant
-- Entree — fleches pour se deplacer, Entree pour lancer — et c'est le geste
-- qui separe une grille qu'on regarde d'une grille dont on joue.

local function handleKeys()
    local char = Core.GetChar()
    if not char or char == 0 then return end

    -- Ctrl+Z repose la derniere case effacee. Alt+clic est un raccourci a une
    -- main qui detruit ; il lui fallait son retour.
    local a = Keymap.Key(KM, char)
    if a == "edit.undo" then
        if erased and erased.clip then
            cells[erased.t][erased.s] = erased.clip
            -- `markDirty` n'a JAMAIS existe dans cette fenetre : ce retour en
            -- arriere plantait a l'appel, et personne ne l'avait vu parce qu'il
            -- faut d'abord effacer une case pour l'atteindre. `saveGrid` est ce
            -- que `clearCell` appelle en face — la reparation doit ecrire par le
            -- meme chemin que la destruction, ou elle ne survit pas au projet.
            saveGrid()
            flash("Cell restored")
            erased = nil
        else
            flash("Nothing to restore")
        end
        Core.ConsumeChar()
        return
    end

    -- ELLE APPARTIENT A CELUI QUI MENE. Cliquer une case ouvre son clip dans
    -- CP_Editor, mais le focus clavier reste ici : sans ce relais, Space ne
    -- faisait rien: la fenetre qui savait quoi jouer ne recevait pas la touche.
    -- Cette grille est la derniere de l'ordre et ne la reclame jamais — elle a
    -- son propre transport, qui est le clic sur une case.
    if a == "play.toggle" then
        if not Focus.Route("session", char, Core.Mods and Core.Mods() or 0) then
            r.Main_OnCommand(40044, 0)   -- Transport: Play/stop
        end
        Core.ConsumeChar()
        return
    end

    if a == "cell.prev_track" then
        sel.t = (sel.t - 1) % TRACKS; Core.ConsumeChar()
    elseif a == "cell.next_track" then
        sel.t = (sel.t + 1) % TRACKS; Core.ConsumeChar()
    elseif a == "cell.prev_scene" then
        sel.s = (sel.s - 1) % SCENES; Core.ConsumeChar()
    elseif a == "cell.next_scene" then
        sel.s = (sel.s + 1) % SCENES; Core.ConsumeChar()
    elseif a == "cell.first_scene" then
        sel.s = 0; Core.ConsumeChar()
    elseif a == "cell.last_scene" then
        sel.s = SCENES - 1; Core.ConsumeChar()
    elseif a == "scene.launch" or a == "scene.launch_add" then
        -- LANCER, PUIS AVANCER. C'est l'avance qui fait le geste : taper Entree
        -- encore et encore descend le set, et sans elle il faudrait une fleche
        -- entre chaque scene. Elle s'arrete en bas plutot que de boucler — on
        -- descend un morceau, on ne le repasse pas en boucle sans le demander.
        sceneLaunch(sel.s, a == "scene.launch_add")
        if sel.s < SCENES - 1 then sel.s = sel.s + 1 end
        Core.ConsumeChar()
    elseif a == "scene.capture" then
        captureScene()
        Core.ConsumeChar()
    elseif a == "cell.launch" then
        -- Entree lance la case ; sur une case vide elle arrete la colonne,
        -- ce qui est ce qu'on veut dire en descendant une grille trouee.
        local c = cells[sel.t] and cells[sel.t][sel.s]
        if c then launchCell(sel.t, sel.s) else stopTrack(sel.t) end
        Core.ConsumeChar()
    elseif a == "cell.erase" then
        local c = cells[sel.t] and cells[sel.t][sel.s]
        if c then
            erased = { t = sel.t, s = sel.s, clip = c }
            clearCell(sel.t, sel.s)
            flash("Cell erased — Ctrl+Z puts it back")
        end
        Core.ConsumeChar()
    end
end

local function frame(theme)
    -- Le clavier d'abord : il peut consommer la touche avant que
    -- quoi que ce soit d'autre la voie, et il ne dessine rien.
    handleKeys()
    local C = theme.colors
    local attached = Loop.IsAttached()

    -- one-shot recall: if this window comes up first in the REAPER session
    -- and the engine is empty, pull the project's saved set (the Looper
    -- does the same; the recall never overwrites a live set)
    --
    -- ⚠️ ET LE RAPPEL FORCE N'EST PAS UN RESTE : un `defer` SURVIT A UN
    -- CHANGEMENT D'ONGLET DE PROJET. Cette fenetre passe du projet A au projet B
    -- sans etre rechargee, et tout ce qu'elle tient — la grille, les motions,
    -- les identites, les caches — appartient encore a A. `RouterChanged` detecte
    -- le front et suspend l'autosave ; ce qui suit relit TOUT depuis le projet
    -- qui est maintenant devant nous.
    local switched = Loop.RouterChanged()
    if switched then reloadProject() end
    if attached and (not state.recalled or switched) then
        state.recalled = true
        local empty = true
        for l = 0, Loop.MAX_LANES - 1 do
            if Loop.HasContent(l) then empty = false break end
        end
        if switched then Loop.LoadState(true)
        elseif empty and Loop.HasSavedState() then Loop.LoadState(false) end
        -- RE-ARM THE SOUND CELLS BEFORE ANYTHING CAN SOUND. The recall puts a
        -- lane that was PLAYING straight back to playing, and a sound cell's
        -- voice does not survive the script — so the file has to be back in it
        -- before the first pass, or the column plays a silence it cannot
        -- explain. The grid knows which cell each lane holds; it says so first.
        for t = 0, TRACKS - 1 do
            local lane = Loop.LaneOfTag(t, Loop.GetLaneTag(liveLane(t)))
            local sc = lane and sceneOfLane(lane, t) or nil
            local audio = sc and isAudio(cells[t][sc]) or false
            if audio then
                local cc = cells[t][sc]
                ensureBars(cc)
                local path, rate = soundFor(cc)
                Cells.Arm(t, lane, path, rate, cc.lmode == "loop",
                          cc.offs, cc.len, cc.gain)
                Loop.SetMute(lane, true)
            end
        end
        -- Adopt what was just recalled, and ARM THE AUTOSAVE. Until this
        -- session, only CP_Looper ever wrote lane state back to the project:
        -- a set built entirely in this window was lost when REAPER closed, and
        -- you found out the next morning.
        Loop.AdoptState()
    end

    -- COMMAND ZONE. Same shape, same height, same right-hand rank as every
    -- other CP window: the point of a primitive is that this stops being a
    -- decision each app makes on its own.
    UI.BeginBar("cmd", TITLE_OPTS)
    UI.BarRight()
    if UI.BarIcon("help", "Help", "Help") then UI.ShowHelp("help", HELP_TEXT) end
    UI.BarSep()
    -- THE WAY BACK. "Hide this column" writes a mark on the track, and a
    -- setting you can turn on but not off is a trap — the more so here, because
    -- hiding the last column leaves no header to right-click on.
    if UI.BarIcon("unhide", "Eye", "Show every hidden column again") then
        local n = 0
        for i = 0, r.CountTracks(0) - 1 do
            local tr = r.GetTrack(0, i)
            local app, role = Tracks.MarkOf(tr)
            if app == "session" and role == "hidden" then
                r.GetSetMediaTrackInfo_String(tr, "P_EXT:CP", "", true)
                n = n + 1
            end
        end
        Loop.RefreshDests()
        flash(n > 0 and (n .. " column(s) back") or "No column is hidden")
    end
    -- A view toggle, so it sits with the meta controls at the right end. The
    -- strip costs 28 px of height permanently, which on a short window is the
    -- last row of the grid: showing it has to stay a choice.
    if UI.BarToggle("mix", "Sliders", nil, mix_open,
                    "Mixer strip: volume, mute and solo per column") then
        mix_open = not mix_open
        Core.SavePersistent("CP_Session", "mix", mix_open)
    end
    UI.BarLeft()
    if attached then
        -- LIT = there is a clock and we follow it. A button called "Clock" that
        -- lights up to mean "no clock, we run free" says the opposite of its
        -- own name, and the eye reads the light before the tooltip.
        local free = Loop.GetFreeRun()
        if UI.BarToggle("clock", "Clock", nil, not free,
                        free and "Free run: the session is its own clock — the first launch starts it"
                              or "Following the host transport: a launch waits for it, then starts with it") then
            Loop.SetFreeRun(not free)
            Loop.MarkDirty()   -- meme raison que Q : c'est de l'etat
        end
        -- Q says WHEN a take starts, Rec says how long it runs. Together they
        -- are the whole answer to "will it start where I mean it to". Both are
        -- choices among a handful, so both are combos: the wheel walks them and
        -- the current setting is readable without clicking.
        local qch, qi = UI.BarCombo("q", qIndex(), Q_ITEMS, false, Q_OPTS)
        if qch then
            setQIndex(qi)
            -- Q EST DE L'ETAT DE SESSION, donc il se sauve. `AutoSave` ne
            -- surveille que la version des notes et le mode par lane : sans ce
            -- marquage, le quantize ne survivait qu'a une fermeture propre de
            -- la fenetre — et CP_Looper, lui, marquait deja. Deux fenetres,
            -- deux comportements pour le meme reglage.
            Loop.MarkDirty()
        end
        local rch, ri = UI.BarCombo("recbars", recBarsIndex(), REC_ITEMS, false, Q_OPTS)
        if rch then setRecBarsIndex(ri) end
        UI.BarSep()
        if UI.BarIcon("stopall", "Stop", "Stop every clip") then stopAll() end
        if UI.BarIcon("panic", "Mute", "Panic: all notes off") then Loop.Panic() end
    end
    UI.EndBar()
    UI.Spacing(4)

    -- This window IS the engine's front end — a grid with no engine can do
    -- nothing at all — so opening it IS the request. It builds the router
    -- itself, once, instead of sending the user to a third script for a step
    -- that holds no decision. The button below stays for the case where that
    -- failed.
    if not attached then
        if not state.engine_tried then
            state.engine_tried = true
            local _, note = Loop.Ensure(true)
            if note then flash(note) end
            attached = Loop.IsAttached()
        end
        if not attached then
            UI.SetFontCaption()
            UI.TextWrapped("No looper engine in this project, and it could not be created.")
            UI.SetFontBody()
            UI.Spacing(2)
            if UI.Button("mkengine", "Create looper engine") then
                state.engine_tried = false
            end
            return
        end
    end

    -- Once per window: is the binary here, and does it speak our language.
    -- There is nothing to install, nothing to refresh and no plugin instance
    -- that can be out of date with the script driving it — the whole class of
    -- "the engine in this project is older than this build" went away with the
    -- JSFX.
    if not state.engine_checked then
        state.engine_checked = true
        local _, note = Loop.Ensure(false)
        if note then flash(note) end
    end
    if not Loop.EngineCurrent() then
        UI.SetFontCaption()
        UI.TextWrapped("The CP engine extension is missing — MIDI lanes and sound cells both need it.")
        UI.SetFontBody()
        UI.Spacing(2)
    end

    -- ONE call: the transport anchor posted, live halves re-derived, live
    -- input drained into whatever is capturing. Everything below reads a
    -- coherent picture.
    Loop.Poll()
    -- Mirror lane state back into the project on a trailing debounce. The
    -- mechanism lives in Loop, so both windows get it from one call.
    Loop.AutoSave()
    -- The sound cells, one frame's worth. It reads the engine's own launch
    -- boundary and its lane phase, and dates every pass to the sample. Inert
    -- when the extension is absent.
    Cells.Tick(AUDIO_GATE)
    -- Cook at most one stretch per frame. The frame that renders DOES hitch —
    -- a four-bar loop is on the order of a tenth of a second — which is why
    -- the cell says "baking" first: a window that freezes without saying why
    -- is a window that looks broken. Every other frame this is a length test
    -- on an empty queue.
    -- UNE CUISSON QUI SE TERMINE DOIT SE FAIRE ENTENDRE. Sans ceci, une case en
    -- stretch restait un repitch jusqu'au prochain lancement manuel — souvent
    -- jusqu'a la fin de la session — alors que le fichier etire etait pret sur
    -- le disque. Warp compte ses fins de cuisson ; on compare, et on rearme les
    -- cases concernees. Un entier par frame, et rien quand rien ne cuit.
    Warp.Tick()
    do
        local wv = Warp.Version()
        if wv ~= warp_seen then
            warp_seen = wv
            for t = 0, TRACKS - 1 do
                for sc = 0, SCENES - 1 do
                    local cc = cells[t] and cells[t][sc]
                    if cc and isAudio(cc) and cc.tempo_mode == "stretch" then
                        sub_key[cc] = nil          -- la ligne sous la case ment
                        if cellTag(t, sc) ~= 0 then retune(t, sc, cc) end
                    end
                end
            end
        end
    end
    -- Follow the engine rather than argue with it: a launch fired from
    -- CP_Looper or CP_Editor moves what a track plays, and the grid has to
    -- know. Sound cells included: they are lanes like any other now.
    for t = 0, TRACKS - 1 do
        local s = sceneOfLane(liveLane(t), t)
        if s and s ~= cur[t] then cur[t] = s end
    end
    -- LA FIN DE PASSE COMME EVENEMENT. Juste apres le poll, parce que c'est lui
    -- qui redonne quelle moitie est vivante — lire la phase avant lui ferait
    -- suivre la lane que la colonne vient de quitter.
    pollMotion()
    pollRec()

    -- edits coming home from CP_Editor (own channel: see the editor's
    -- flushApply — a shared one would let CP_Looper consume our cells)
    local ac = Bus.Recv("editor:apply:cell")
    if ac then applyEdit(ac) end

    -- drops from the Media Explorer / other CP windows
    busConsume()

    -- ---- geometry
    local x, y = UI.GetCursorPos()
    local w = UI.GetAvailableWidth()
    local gap = 3
    local scene_w = 24
    local head_h = 18
    local cell_h = 30

    -- A COLUMN IS A TRACK, so the project decides how many there are and in
    -- what order. An empty project draws no grid at all — which is the honest
    -- picture, and a great deal less confusing than four columns wired to
    -- nothing.
    local ncol = Loop.ColumnCount()
    if ncol < 1 then
        local mc = C.text_mute or C.text_disabled
        Core.DrawText("Add a track in REAPER — a column is a track",
                      x + 2, y + 4, mc[1], mc[2], mc[3], 0.7)
        UI.Layout.AdvanceCursor(w, 24)
        UI.AppStatus(engineBadge())
        return
    end
    local cell_w = floor((w - scene_w - gap * ncol) / ncol)
    if cell_w < 24 then cell_w = 24 end

    -- ---- track headers: name + record arm (the engine monitors ONE track
    -- at a time, so arming is exclusive — clicking the lit one disarms)
    UI.SetFontCaption()
    for ci = 0, ncol - 1 do
        local t = Loop.ColumnAt(ci + 1)
        local cx = x + scene_w + gap + ci * (cell_w + gap)
        local mc = C.text_mute or C.text_disabled
        local routed = Loop.GetLaneDest(t) ~= nil
        -- LE MOTION SE VOIT. Une colonne qui va changer de case toute seule doit
        -- le dire dans son en-tete, sinon la grille se met a bouger sans raison
        -- lisible — et c'est exactement le genre de reglage qu'on oublie avoir
        -- pose. Deux caracteres, et le nom entier dans le menu du nom.
        local mtag = MOTION_TAG[motion[t]] or ""
        local nw = (mtag ~= "") and (cell_w - 42) or (cell_w - 22)
        if nw < 8 then nw = 8 end
        Core.DrawText(cellLabel(t, SCENES, trackName(t), nw), cx + 2, y + 2,
                      mc[1], mc[2], mc[3], routed and 0.9 or 0.45)
        if mtag ~= "" then
            -- La police de cette boucle est DEJA la caption : la reposer ici
            -- laisserait les colonnes suivantes dessiner leur nom en body.
            local a = C.accent
            Core.DrawText(mtag, cx + cell_w - 36, y + 3, a[1], a[2], a[3], 0.9)
        end
        local ax = cx + cell_w - 16
        local armed = isArmed(t)
        local d = C.danger or C.accent
        if armed then
            UI.Icons.Record(ax, y + 1, 14, d[1], d[2], d[3], 0.95)
        else
            UI.Icons.Record(ax, y + 1, 14, mc[1], mc[2], mc[3], 0.4)
        end
        if Core.MouseInRect(ax - 2, y, 18, head_h) and not Core.HasPopup()
           and Core.MouseClicked(1) then
            armTrack(t)
        end
        -- the name itself opens the routing: which track this column plays
        -- into should never be a mystery
        if Core.MouseInRect(cx, y, cell_w - 20, head_h) and not Core.HasPopup() then
            Core.DrawRect(cx, y, cell_w - 20, head_h, 1, 1, 1, 0.05)
            if Core.MouseClicked(1) or Core.MouseClicked(2) then trackMenu(t) end
        end
    end
    UI.SetFontBody()

    local gy = y + head_h
    state.grid = state.grid or {}
    state.grid.x0, state.grid.y0 = x + scene_w + gap, gy
    state.grid.cw, state.grid.ch, state.grid.gap = cell_w, cell_h, gap

    -- ---- scene launchers + cells
    for s = 0, SCENES - 1 do
        local cy = gy + s * (cell_h + gap)
        Core.DrawRoundRectFilled(x, cy, scene_w, cell_h,
                                 theme.rounding_small or 0, 0.17, 0.19, 0.17, 1)
        local a = C.accent
        UI.Icons.Play(x + 5, cy + floor((cell_h - 14) / 2), 14,
                      a[1], a[2], a[3], 0.85)
        if Core.MouseInRect(x, cy, scene_w, cell_h) and not Core.HasPopup() then
            Core.DrawRect(x, cy, scene_w, cell_h, 1, 1, 1, 0.06)
            -- Ctrl (ou Cmd) tient les colonnes que cette scene ne remplit
            -- pas : c'est le « +Scene » de FL, et il se demande au moment du
            -- lancement plutot que de vivre dans un reglage qu'on oublie.
            if Core.MouseClicked(1) then
                sceneLaunch(s, Core.ModCtrl())
            end
        end
        for ci = 0, ncol - 1 do
            local cx = x + scene_w + gap + ci * (cell_w + gap)
            drawCell(theme, Loop.ColumnAt(ci + 1), s, cx, cy, cell_w, cell_h)
        end
    end

    -- Ctrl-drag copy lands here: the grid geometry is known, so the target is
    -- read straight off the cursor. Releasing anywhere else just drops it.
    if cdrag and not Core.MouseDown(1) then
        local src = cells[cdrag.t] and cells[cdrag.t][cdrag.s]
        local mx, my = Core.GetMousePos()
        local dt = Loop.ColumnAt(floor((mx - (x + scene_w + gap)) / (cell_w + gap)) + 1)
        local ds = floor((my - gy) / (cell_h + gap))
        if src and dt and ds >= 0 and ds < SCENES
           and not (dt == cdrag.t and ds == cdrag.s) then
            pasteCell(dt, ds, src)
            flash("Copied to " .. trackName(dt) .. " / scene " .. (ds + 1))
        end
        cdrag = nil
    end

    -- ---- stop row: one square per track, plus the global one on the left
    -- (Ableton's "Stop Clips" footer — a big target, not a corner pixel)
    local sy = gy + SCENES * (cell_h + gap) + 2
    local sh = 16
    do
        local mc = C.text_mute or C.text_disabled
        Core.DrawRoundRectFilled(x, sy, scene_w, sh, theme.rounding_small or 0,
                                 0.17, 0.17, 0.19, 1)
        UI.Icons.Stop(x + 5, sy + 1, 14, mc[1], mc[2], mc[3], 0.8)
        if Core.MouseInRect(x, sy, scene_w, sh) and not Core.HasPopup() then
            Core.DrawRect(x, sy, scene_w, sh, 1, 1, 1, 0.06)
            if Core.MouseClicked(1) then stopAll() end
        end
        for ci = 0, ncol - 1 do
            local t = Loop.ColumnAt(ci + 1)
            local cx = x + scene_w + gap + ci * (cell_w + gap)
            local running = isRunning(liveLane(t))
            Core.DrawRoundRectFilled(cx, sy, cell_w, sh, theme.rounding_small or 0,
                                     0.17, 0.17, 0.19, 1)
            UI.Icons.Stop(cx + floor(cell_w / 2) - 7, sy + 1, 14,
                          mc[1], mc[2], mc[3], running and 0.9 or 0.35)
            if Core.MouseInRect(cx, sy, cell_w, sh) and not Core.HasPopup() then
                Core.DrawRect(cx, sy, cell_w, sh, 1, 1, 1, 0.06)
                if Core.MouseClicked(1) then stopTrack(t) end
            end
        end
    end

    -- ---- mixer zone. Its own ground and its own seam: it is not the grid,
    -- and a zone that shares its neighbour's ground is not a zone. Its seam is
    -- also its GRIP: the height decides how much of a strip is on screen, from
    -- the fader alone to the whole channel, and one drag says which.
    local zone_h = 0
    mix_hot = false
    -- A strip that is not DRAWN this frame must stop claiming its rectangle. A
    -- drop is resolved against where a strip WAS — that is the only place it
    -- can be — so a column that disappeared, or a mixer that was folded away,
    -- would keep catching FX dropped over whatever now occupies that spot.
    -- Clearing the y is enough: every reader tests it.
    for t = 0, TRACKS - 1 do
        local g = mix_col[t]
        if g then g.y = nil end
    end
    if mix_open then
        local my = sy + sh + 4
        local win_w, win_h = Core.GetWindowSize()
        local room = win_h - my - 2 - 22        -- the status zone keeps its own
        if room > MIX_MAX then room = MIX_MAX end
        if room < MIX_MIN then room = MIX_MIN end
        if mix_h > room then mix_h = room end
        zone_h = 2 + mix_h
        local surf = C.surface or C.frame_bg
        UI.SeamH(0, my, win_w)
        local zy = my + 2
        Core.DrawRect(0, zy, win_w, mix_h, surf[1], surf[2], surf[3], 1)

        local _, smy = Core.GetMousePos()
        local on_seam = (not Core.HasPopup())
            and smy >= my - SEAM_GRAB and smy < my + SEAM_GRAB
        if on_seam or mix_seam then UI.SetCursor("size_ns") end
        if on_seam and Core.MouseClicked(1) then
            mix_seam = { y0 = smy, h0 = mix_h }
        end
        if mix_seam then
            if Core.MouseDown(1) then
                local nh = mix_seam.h0 + (mix_seam.y0 - smy)
                if nh < MIX_MIN then nh = MIX_MIN elseif nh > room then nh = room end
                mix_h = nh
                UI.RequestRedraw()
            else
                mix_seam = nil
                Core.SavePersistent("CP_Session", "mixh2", mix_h)
            end
        end
        -- The seam RESIZES, so it says so: three dots is what a grip looks
        -- like everywhere, and a line that can be dragged without looking
        -- draggable is a feature nobody finds.
        local gx = floor(win_w * 0.5) - 7
        local gc = C.text_mute or C.text_disabled
        for i = 0, 2 do
            Core.DrawRect(gx + i * 6, my - 1, 3, 2, gc[1], gc[2], gc[3],
                          (on_seam or mix_seam) and 0.95 or 0.5)
        end

        UI.SetFontCaption()
        for ci = 0, ncol - 1 do
            local cx = x + scene_w + gap + ci * (cell_w + gap)
            drawMix(theme, Loop.ColumnAt(ci + 1), cx, zy + MIX_PAD,
                    cell_w, mix_h - MIX_PAD * 2)
        end
        UI.SetFontBody()
        pollMixDrag()
    end

    UI.Layout.AdvanceCursor(w, head_h + SCENES * (cell_h + gap) + 2 + sh + 4 + zone_h)

    -- status zone
    local msg
    if state.flash_msg ~= "" then
        if r.time_precise() < state.flash_until then
            msg = state.flash_msg
        else
            state.flash_msg = ""
        end
    end
    if not msg then msg = statusLine() end
    -- Ce que le moteur de son fait vraiment, en clair. Le BACKEND est dit en
    -- permanence — il l'etait sous deux gardes, dont l'une le taisait
    -- precisement quand le moteur manquait. Le detail chiffre, lui, n'apparait
    -- que quand il y a quelque chose a compter.
    msg = (msg ~= "" and (msg .. "   ·   ") or "") .. engineBadge()
    if ENGINE_OK and Cells.Armed() then
        msg = msg .. "   ·   " .. Cells.Diag()
        -- L'ECART D'ATTAQUE, AFFICHE. Il etait mesure depuis toujours et
        -- personne ne le lisait : la campagne du moteur a passe une soiree a
        -- chercher un retard constant que ce nombre montrait deja. Le PIRE
        -- depuis l'ouverture, pas le dernier — un ecart qui n'arrive qu'une
        -- passe sur vingt est exactement celui qu'on cherche, et montrer le
        -- dernier le fait disparaitre avant qu'on ait leve les yeux.
        --
        -- Reconstruit seulement quand il CHANGE : une chaine formatee par frame
        -- dans une fenetre qui se redessine en continu est une allocation par
        -- frame, ce que ce fichier passe son temps a eviter.
        local ms, n = Cells.OnsetWorst()
        if ms and n and n > 0 then
            if ms ~= onset_lbl.ms or n ~= onset_lbl.n then
                onset_lbl.ms, onset_lbl.n = ms, n
                onset_lbl.s = string.format("onset %+.2f ms worst / %d", ms, n)
            end
            msg = msg .. "   ·   " .. onset_lbl.s
        end
    end
    UI.AppStatus(msg)

    -- A meter that only moves when the mouse does is worse than no meter, so
    -- the strip asks for frames of its own whenever anything can be making
    -- sound. One question now instead of two: sounds are lanes, so the engine
    -- answers for them as well.
    if Loop.Playing() or mix_hot then
        UI.RequestRedraw()
    elseif mix_open and (r.GetPlayState() & 1) == 1 then
        UI.RequestRedraw()
    end
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
UI.Init("CP Session", 580, 400, {
    persist    = "CP_Session",
    scrollable = false,
})

UI.OnClose(function()
    -- The debounce would drop anything edited in the last half-second, and a
    -- window closing is exactly when that matters.
    pcall(Loop.SaveState)
    -- The voices and their clips go back. Lanes outlive this window on purpose;
    -- a decoded file held in RAM does not.
    pcall(Cells.Destroy)
    -- our sounds are lanes now, and lanes outlive this window on purpose
    if state.registered then pcall(DragBus.Unregister, "session") end
end)

-- Hard termination (Actions-window kill, a runtime error breaking the defer
-- chain): OnClose never runs on those paths, and the set would go with it.
r.atexit(function() pcall(Loop.SaveState) end)

UI.Run(function(theme)
    UI.CheckThemeUpdates()
    frame(theme)
end)
