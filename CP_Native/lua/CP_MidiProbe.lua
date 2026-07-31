-- CP_MidiProbe — la question §12.9.1, et rien d'autre.
--
--   Un apercu de PISTE transmet-il les `midi_events` de son bloc a la chaine
--   de cette piste ?
--
-- Le bloc que REAPER nous tend porte un champ `midi_events` a cote des
-- echantillons (reaper_plugin.h:448). Rien dans le SDK ne dit s'il est lu pour
-- un apercu. La reponse decide si la cible est UN binaire, ou un binaire plus
-- le CP_MidiLooper.jsfx.
--
-- Mode d'emploi : mettre un INSTRUMENT sur une piste (ReaSynth suffit, ou
-- n'importe quel VSTi), selectionner cette piste, lancer.
-- Le script joue une gamme de huit notes, une toutes les demi-secondes.
--
--   tu entends les notes  -> affranchissement TOTAL du JSFX possible
--   silence, evenements_remis monte -> REAPER ne route pas le MIDI d'un apercu
--   silence, midi_events_fourni=0   -> REAPER ne nous tend meme pas de liste
--
-- Les deux derniers cas sont des reponses, pas des echecs.

local r = reaper

local LOG = r.GetResourcePath() .. "/CP_NativeProbe.log"
local fh = io.open(LOG, "a")
local function log(s) if fh then fh:write(tostring(s), "\n") end end
local function both(s) log(s); r.ShowConsoleMsg(tostring(s) .. "\n") end

if fh then
    fh:write("\n\n########################################################\n")
    fh:write("# CP_MidiProbe " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    fh:write("########################################################\n")
end

if not r.APIExists("CP_TestMidiAt") then
    r.MB("Moteur trop ancien ou absent : il faut l'ABI 1.2.\nReconstruis et reinstalle la DLL.",
         "CP_Native", 0)
    if fh then fh:close() end
    return
end

local tr = r.GetSelectedTrack(0, 0)
if not tr then
    r.MB("Selectionne une piste PORTANT UN INSTRUMENT (ReaSynth suffit).", "CP_Native", 0)
    if fh then fh:close() end
    return
end

r.ClearConsole()
both("=== CP_MidiProbe ===")
both("piste : " .. select(2, r.GetTrackName(tr)))

-- Un avertissement plutot qu'un refus : c'est a lui de decider.
local nfx = r.TrackFX_GetCount(tr)
local instrument = r.TrackFX_GetInstrument(tr)
both(string.format("chaine : %d effet(s), instrument a l'index %d", nfx, instrument))
if instrument < 0 then
    both("*** aucun instrument sur cette piste : il n'y a rien pour jouer les notes ***")
end

if not r.CP_PortAttach(tr, 0) then
    both("ECHEC : PlayTrackPreview2Ex a refuse.")
    if fh then fh:close() end
    return
end

local sr = r.CP_Srate()
local t0 = r.CP_ClockNow()

-- Une gamme de do majeur, une note toutes les demi-secondes, la premiere dans
-- une seconde. Une gamme et pas une note unique : si une seule sur huit passe,
-- ce n'est pas la meme conclusion que si les huit passent.
local GAMME = { 60, 62, 64, 65, 67, 69, 71, 72 }
local n_pose = 0
for i, note in ipairs(GAMME) do
    local at = t0 + sr * (1.0 + (i - 1) * 0.5)
    if r.CP_TestMidiAt(0, at, note, 100, sr * 0.4) then n_pose = n_pose + 1 end
    log(string.format("  pose note %d au frame %.0f", note, at))
end
both(string.format("pose  : %d notes sur %d, la premiere dans 1 s", n_pose, #GAMME))
both("")
both("ECOUTE. Entends-tu une gamme ?")
both("")

local t_start = r.time_precise()
local dernier = ""

local function boucle()
    local d = r.CP_TestMidiDiag()
    if d ~= dernier then
        dernier = d
        both("  " .. d)
    end
    log("  " .. r.CP_Diag())

    if r.time_precise() - t_start < 7.0 then
        r.defer(boucle)
        return
    end

    both("")
    both("=========== VERDICT ===========")
    both(r.CP_TestMidiDiag())
    local fourni = tonumber(d:match("midi_events_fourni_par_reaper=(%d+)")) or 0
    local remis  = tonumber(d:match("evenements_remis=(%d+)")) or 0

    if fourni == 0 then
        both("REAPER ne nous tend AUCUNE liste MIDI pour un apercu de piste.")
        both("-> le MIDI ne passera jamais par la. Le CP_MidiLooper.jsfx reste.")
    elseif remis == 0 then
        both("REAPER tend une liste, mais rien n'a ete remis : bug de notre cote.")
    else
        both(string.format("%d evenements remis dans la liste fournie par REAPER.", remis))

        -- L'exactitude de NOTRE placement, comptee et non promise.
        local exacts  = tonumber(d:match("exacts=(%d+)")) or 0
        local retard  = tonumber(d:match("en_retard=(%d+)")) or 0
        local errmax  = tonumber(d:match("erreur_max=(%d+)")) or 0
        both(string.format("placement : %d exacts, %d en retard, erreur max %d echantillon(s)",
                           exacts, retard, errmax))
        both((retard == 0)
             and "  -> chaque note est remise au frame EXACT demande."
             or  string.format("  -> %d note(s) rattrapee(s) a l'offset 0 : audibles, mais plus exactes.", retard))
        both("     (ceci mesure NOTRE placement. Ce que REAPER en fait ensuite se")
        both("      verifie a l'enregistrement — mais ton kick JSFX a 1 ms montre")
        both("      deja qu'il honore les offsets.)")
    end
    both("===============================")

    r.CP_PortDetach(0)
    both("journal : " .. LOG)
    if fh then fh:close() end
end

r.defer(boucle)
