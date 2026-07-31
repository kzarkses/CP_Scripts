-- CP_LoadProbe — la montee en charge.
--
-- Un port ne dit rien de huit, et « ca a l'air fluide » ne dit rien du tout.
-- Cette sonde monte 8 colonnes x 8 voix en boucle, a taux tous differents pour
-- qu'aucune ne partage son chemin d'interpolation avec une autre, et elle
-- mesure :
--
--   ratio_min  le port le PLUS mal servi. S'il descend sous 1,000, le service
--              d'apercu commence a manquer des blocs, et c'est la limite.
--   cpu        la part du fil audio que le moteur consomme reellement. C'est le
--              seul chiffre qui dise si la contrainte « PC de 2005 » tient : sur
--              une machine moderne, il faut lire ce nombre en se souvenant qu'un
--              CPU de 2005 est 6 a 10 fois plus lent en mono-fil.
--   dropped    commandes perdues. Doit rester a zero.
--
-- Elle cree ses propres pistes, nommees « CP LOAD n », et les supprime a la fin.
-- Elle ne touche a aucune piste existante.

local r = reaper

local LOG = r.GetResourcePath() .. "/CP_NativeProbe.log"
local fh = io.open(LOG, "a")
local function log(s) if fh then fh:write(tostring(s), "\n") end end
local function both(s) log(s); r.ShowConsoleMsg(tostring(s) .. "\n") end
if fh then
    fh:write("\n\n########################################################\n")
    fh:write("# CP_LoadProbe " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    fh:write("########################################################\n")
end

if not r.APIExists("CP_LoadDiag") then
    r.MB("Moteur trop ancien ou absent : il faut l'ABI 1.3.", "CP_Native", 0)
    if fh then fh:close() end
    return
end

local NPORTS = 8
local NVOIX  = 8       -- par port -> 64 voix

local defaut = ""
local it = r.GetSelectedMediaItem(0, 0)
if it then
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
        defaut = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(tk))
    end
end

local ok, path = r.GetUserInputs("CP_LoadProbe", 1, "Fichier audio (extrait,4096)", defaut)
if not ok or path == "" then if fh then fh:close() end return end

r.ClearConsole()
both("=== CP_LoadProbe ===")

local clip = r.CP_ClipLoad(path)
if clip < 0 then both("ECHEC : fichier non decode"); if fh then fh:close() end return end
local _, frames, srate = r.CP_ClipInfo(clip)
both(string.format("clip    : %.3f s, %.2f Mo", (frames or 0) / (srate or 1),
                   (frames or 0) * 2 * 4 / 1048576))

-- --- les pistes, creees et reprises ----------------------------------------
r.Undo_BeginBlock2(0)
r.PreventUIRefresh(1)

local pistes = {}
local n0 = r.CountTracks(0)
for i = 1, NPORTS do
    r.InsertTrackAtIndex(n0 + i - 1, false)
    local tr = r.GetTrack(0, n0 + i - 1)
    r.GetSetMediaTrackInfo_String(tr, "P_NAME", "CP LOAD " .. i, true)
    pistes[i] = tr
end

r.PreventUIRefresh(-1)
r.Undo_EndBlock2(0, "CP_LoadProbe : pistes de mesure", -1)

local voix = {}
local n_att, n_voix = 0, 0

-- UN seul instant pour les 64 voix : c'est ce que fait un lancement de scene.
-- Prendre l'horloge dans la boucle donnait a chaque voix un depart decale de
-- quelques echantillons, ce qui simulait mal l'usage reel.
local depart = r.CP_ClockNow() + srate * 0.5

for i = 1, NPORTS do
    if r.CP_PortAttach(pistes[i], i - 1) then
        n_att = n_att + 1
        for j = 1, NVOIX do
            local v = r.CP_VoiceAlloc(i - 1)
            if v ~= 4294967295 then
                -- Taux tous differents : chaque voix emprunte un chemin
                -- d'interpolation distinct, et aucune ne beneficie du
                -- court-circuit « taux exactement 1,0 ».
                local taux = 0.93 + 0.01 * ((i * NVOIX + j) % 15)
                r.CP_VoicePlayAtSample(v, clip, depart, 1, taux, 0.12)
                r.CP_VoiceSet(v, "pan", ((j % 3) - 1) * 0.5)
                n_voix = n_voix + 1
                voix[#voix + 1] = v
            end
        end
    end
end

both(string.format("charge  : %d ports attaches, %d voix lancees", n_att, n_voix))
both("")

-- On laisse une seconde au systeme pour s'installer avant de compter : les
-- premiers blocs apres l'attache ne sont pas representatifs.
local t_start = r.time_precise()
local arme = false
local pire_ratio, pire_cpu = 9.9, 0

local function boucle()
    local t = r.time_precise() - t_start

    if not arme and t > 1.0 then
        r.CP_LoadReset()
        arme = true
        both("compteurs remis a zero, mesure sur 20 s")
    end

    if arme then
        local d = r.CP_LoadDiag()
        log(d)
        local nb = tonumber(d:match("blocs=(%d+)")) or 0
        local rr = tonumber(d:match("ratio_min=([%-%d%.]+)"))
        local cc = tonumber(d:match("cpu=([%d%.]+)"))
        -- Un ratio calcule sur moins de 200 blocs ne veut rien dire : juste
        -- apres la remise a zero, le denominateur vaut zero. C'est ce qui a
        -- produit un faux « un port manque des blocs » a la premiere campagne —
        -- l'instrument mentait, pas le moteur.
        if rr and rr >= 0 and nb >= 200 and rr < pire_ratio then pire_ratio = rr end
        if cc and nb >= 200 and cc > pire_cpu then pire_cpu = cc end
        if math.floor(t) % 3 == 0 and math.floor(t) ~= math.floor(t - 0.05) then
            r.ShowConsoleMsg(string.format("  %2.0f s  %s\n", t, d))
        end
    end

    if t < 21.0 then r.defer(boucle); return end

    both("")
    both("=========== VERDICT ===========")
    both(r.CP_LoadDiag())
    if pire_ratio > 9.0 then
        both("pire ratio observe : mesure trop courte pour conclure")
    else
        both(string.format("pire ratio observe : %.4f", pire_ratio))
        both(pire_ratio > 0.999
             and "  -> AUCUN port ne manque de bloc, meme le plus mal servi."
             or  "  -> *** un port manque des blocs : c'est la limite de la route ***")
    end
    both(string.format("pire cpu observe   : %.2f %% du fil audio", pire_cpu))
    both(string.format("  -> extrapolation grossiere sur un CPU de 2005 (x8) : %.0f %%",
                       pire_cpu * 8))
    both("     (ordre de grandeur, pas une mesure : seule la machine cible tranche)")

    local dr = tonumber(r.CP_LoadDiag():match("dropped=(%d+)")) or 0
    both(string.format("commandes perdues  : %d %s", dr, (dr == 0) and "" or "*** ANORMAL ***"))
    both("===============================")

    -- --- demontage --------------------------------------------------------
    for _, v in ipairs(voix) do r.CP_VoiceRelease(v) end
    r.defer(function()
        for i = 1, NPORTS do r.CP_PortDetach(i - 1) end
        r.CP_ClipUnload(clip)

        r.Undo_BeginBlock2(0)
        r.PreventUIRefresh(1)
        for i = NPORTS, 1, -1 do
            if r.ValidatePtr2(0, pistes[i], "MediaTrack*") then r.DeleteTrack(pistes[i]) end
        end
        r.PreventUIRefresh(-1)
        r.Undo_EndBlock2(0, "CP_LoadProbe : retrait des pistes de mesure", -1)

        both("pistes de mesure supprimees.")
        both("etat final : " .. r.CP_Diag())
        both("journal : " .. LOG)
        if fh then fh:close() end
    end)
end

r.defer(boucle)
