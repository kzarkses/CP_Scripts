-- CP_SoakProbe — LA SESSION LONGUE.
--
-- Tout ce que le moteur a prouve jusqu'ici, il l'a prouve sur des fenetres de
-- vingt secondes. Ce n'est pas la meme question. Une fuite d'un emplacement
-- toutes les mille allocations ne se voit pas en vingt secondes ; elle se voit
-- au bout d'une heure, sous la forme « il n'y a plus de voix », et on la
-- cherche alors n'importe ou sauf a l'endroit ou elle est.
--
-- Cette sonde fait tourner le moteur sans repit et surveille des INVARIANTS,
-- pas des impressions. Elle note la PREMIERE violation avec l'instant exact, et
-- continue : savoir qu'une chose casse a la 43e minute et jamais avant vaut
-- beaucoup plus qu'un arret sec.
--
-- Ce qu'elle malmene, et pourquoi :
--   lancements incessants     le cycle prise/remise d'un emplacement, celui qui
--                             portait la course fermee en session 19
--   deplacements et boucles   les commandes a la volee pendant que ca sonne
--   enchainements dates       le chemin de la voix « suivante »
--   rechargement du clip      la matiere retiree SOUS une voix vivante — c'est
--                             ce scenario qui a revele qu'une voix privee de sa
--                             matiere restait vivante a jamais
--   rebranchement d'un port   port_reset pendant que des voix sonnent
--   panique                   tout couper, puis reprendre
--
-- Sortie materielle : aucune piste creee, aucun projet touche. Le volume est
-- volontairement bas — c'est fait pour tourner une heure a cote d'un humain.

local r = reaper

-- ---------------------------------------------------------------------------
-- Reglages
-- ---------------------------------------------------------------------------
local DUREE_MIN   = 60      -- minutes ; redemandee au lancement
local NPORTS      = 4
local VOIX_PORT   = 6
local VOLUME      = 0.02    -- -34 dB. Une heure a plein volume n'est pas un test.

local EV_LANCE    = 0.15    -- s entre deux lancements
local EV_REGLE    = 0.35    -- s entre deux reglages a la volee
local EV_CHAINE   = 1.10    -- s entre deux enchainements
local EV_RECHARGE = 13.0    -- s entre deux rechargements de clip
local EV_REBRANCHE= 41.0    -- s entre deux rebranchements de port
local EV_PANIQUE  = 97.0    -- s entre deux paniques
local EV_JOURNAL  = 10.0    -- s entre deux lignes de journal

local NULL = 4294967295

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------
local LOG = r.GetResourcePath() .. "/CP_NativeProbe.log"
local fh = io.open(LOG, "a")
local function log(s) if fh then fh:write(tostring(s), "\n"); fh:flush() end end

if not r.APIExists("CP_EngineABI") or r.CP_EngineABI() < 1.5 then
    r.MB("Moteur absent ou trop ancien : il faut l'ABI 1.5.", "CP_SoakProbe", 0)
    if fh then fh:close() end
    return
end

-- ---------------------------------------------------------------------------
-- Le fichier
-- ---------------------------------------------------------------------------
local defaut = ""
local it = r.GetSelectedMediaItem(0, 0)
if it then
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
        defaut = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(tk))
    end
end

local ok, csv = r.GetUserInputs("CP_SoakProbe", 2,
    "Fichier audio (extrait,4096),Duree en minutes", defaut .. "," .. DUREE_MIN)
if not ok then if fh then fh:close() end return end
local path, mins = csv:match("^(.*),([^,]*)$")
if not path or path == "" then if fh then fh:close() end return end
DUREE_MIN = tonumber(mins) or DUREE_MIN

local clip = r.CP_ClipLoad(path)
if clip == -2 then
    r.MB("Ce fichier depasse le plafond de 64 s. Prends une boucle.", "CP_SoakProbe", 0)
    if fh then fh:close() end return
elseif clip < 0 then
    r.MB("Fichier non decode.", "CP_SoakProbe", 0)
    if fh then fh:close() end return
end
local _, frames, srate = r.CP_ClipInfo(clip)
frames = frames or 1
srate  = srate or 48000
local clip_mo = frames * 2 * 4 / 1048576

log("\n\n########################################################")
log("# CP_SoakProbe " .. os.date("%Y-%m-%d %H:%M:%S"))
log(string.format("# fichier %s (%.3f s, %.2f Mo) — %d minutes, %d ports x %d voix",
                  path, frames / srate, clip_mo, DUREE_MIN, NPORTS, VOIX_PORT))
log("########################################################")

-- ---------------------------------------------------------------------------
-- Les ports : sortie MATERIELLE, aucune piste creee
-- ---------------------------------------------------------------------------
local ports_ok = 0
for p = 0, NPORTS - 1 do
    if r.CP_PortAttachOut(p, 0) then ports_ok = ports_ok + 1 end
end
if ports_ok == 0 then
    r.MB("Aucun port n'a pu prendre la sortie materielle.", "CP_SoakProbe", 0)
    r.CP_ClipUnload(clip)
    if fh then fh:close() end return
end

-- ---------------------------------------------------------------------------
-- Etat de la campagne
-- ---------------------------------------------------------------------------
local live = {}                     -- [port] = { handles }
for p = 0, NPORTS - 1 do live[p] = {} end

local n_alloc, n_refus, n_lance, n_release = 0, 0, 0, 0
local n_recharge, n_rebranche, n_panique, n_chaine = 0, 0, 0, 0

local t0 = r.time_precise()
local nxt = { lance = 0, regle = 0, chaine = 0, recharge = EV_RECHARGE,
              rebranche = EV_REBRANCHE, panique = EV_PANIQUE, journal = 1.0 }

local pire = { ratio = 9.9, cpu = 0, ram = 0, gap = 0, owned = 0 }
local clock_prev = -1
local violations = {}               -- { t, texte } — la PREMIERE de chaque type
local vus = {}

local taux = { 1.0, 0.5, 2.0, 0.87, 1.19, 1.0, 0.63, 1.41 }
local ti = 0

-- ---------------------------------------------------------------------------
-- Une violation ne s'affiche qu'une fois par TYPE, avec l'instant exact. Un
-- ecran qui defile a cent lignes par seconde ne se lit pas, et la valeur d'une
-- session longue tient entierement dans « la premiere fois, c'etait quand ».
-- ---------------------------------------------------------------------------
local function viol(kind, texte)
    if vus[kind] then return end
    vus[kind] = true
    local t = r.time_precise() - t0
    violations[#violations + 1] = { t = t, txt = texte }
    log(string.format("!!! %7.1f s  %s", t, texte))
end

-- ---------------------------------------------------------------------------
-- La sollicitation
-- ---------------------------------------------------------------------------
local function relacheVieille(p)
    local l = live[p]
    if #l == 0 then return end
    local h = table.remove(l, 1)
    r.CP_VoiceRelease(h)
    n_release = n_release + 1
end

local function lance(p, now)
    local l = live[p]
    if #l >= VOIX_PORT then relacheVieille(p) end
    local h = r.CP_VoiceAlloc(p)
    if h == NULL then n_refus = n_refus + 1 return end
    n_alloc = n_alloc + 1
    ti = ti + 1
    local at = now + math.floor(srate * 0.03)
    local mode = (ti % 3 == 0) and 1 or 0
    if r.CP_VoicePlayAtSample(h, clip, at, mode, taux[(ti % #taux) + 1], VOLUME) then
        n_lance = n_lance + 1
    end
    r.CP_VoiceSet(h, "pan", ((ti % 3) - 1) * 0.6)
    r.CP_VoiceSet(h, "fade_in", 0.003)
    l[#l + 1] = h
end

local function regle(p)
    local l = live[p]
    if #l == 0 then return end
    local h = l[(ti % #l) + 1]
    r.CP_VoiceSet(h, "pos", math.floor(frames * ((ti % 7) / 8)))
    r.CP_VoiceSet(h, "loop", (ti % 2 == 0) and 1 or 0)
    r.CP_VoiceSet(h, "gain", VOLUME * (0.5 + (ti % 4) * 0.25))
end

-- Enchainement : la sortante s'arrete a une date, la suivante prend le relais
-- au frame exact. C'est le chemin qu'aucune boucle Lua ne peut tenir, donc
-- celui qu'il faut faire tourner longtemps.
local function chaine(p, now)
    local l = live[p]
    if #l < 2 then return end
    local a, b = l[1], l[2]
    if r.CP_VoiceQueueNext(a, b, 0) then
        r.CP_VoiceStopAtSample(a, now + math.floor(srate * 0.25), 0)
        n_chaine = n_chaine + 1
    end
end

-- ---------------------------------------------------------------------------
-- Les invariants
-- ---------------------------------------------------------------------------
local function verifie(t)
    local d = r.CP_Diag()

    local clock  = tonumber(d:match("clock=(%d+)")) or 0
    local blocks = tonumber(d:match("blocks=(%d+)")) or 0
    local act, own = d:match("voices=(%d+)/(%d+)")
    act, own = tonumber(act) or 0, tonumber(own) or 0
    local ram    = tonumber(d:match("ram=([%d%.]+)")) or 0
    local gap    = tonumber(d:match("maxgap=([%d%.]+)")) or 0
    local drop   = tonumber(d:match("dropped=(%d+)")) or 0

    if drop > 0 then viol("dropped", "commandes perdues : " .. drop) end
    if clock_prev >= 0 and clock <= clock_prev then
        viol("clock", "l'horloge n'avance plus (clock=" .. clock .. ")")
    end
    clock_prev = clock

    if act > own then
        viol("compte", string.format("plus de voix vivantes (%d) que possedees (%d)", act, own))
    end
    if own > NPORTS * VOIX_PORT + NPORTS then
        viol("fuite", string.format("emplacements possedes : %d, au-dela du plafond attendu %d",
                                    own, NPORTS * VOIX_PORT))
    end
    -- La RAM doit rester celle du clip, a un rechargement pres. Une derive ici
    -- serait le vivier qui ne rend jamais ce qu'il retire.
    if ram > clip_mo * 3 + 1 then
        viol("ram", string.format("RAM du vivier : %.2f Mo pour un clip de %.2f Mo", ram, clip_mo))
    end
    if gap > 0.001 then
        viol("gap", string.format("demandes non contigues : maxgap=%.6f s", gap))
    end

    if own > pire.owned then pire.owned = own end
    if ram > pire.ram then pire.ram = ram end
    if gap > pire.gap then pire.gap = gap end

    local ld = r.CP_LoadDiag()
    local nb = tonumber(ld:match("blocs=(%d+)")) or 0
    local rr = tonumber(ld:match("ratio_min=([%-%d%.]+)"))
    local cc = tonumber(ld:match("cpu=([%d%.]+)"))
    if rr and rr >= 0 and nb >= 400 then
        if rr < pire.ratio then pire.ratio = rr end
        if rr < 0.999 then
            viol("ratio", string.format("un port manque des blocs : ratio_min=%.4f", rr))
        end
    end
    if cc and nb >= 400 and cc > pire.cpu then pire.cpu = cc end

    return d, ld, blocks, act, own
end

-- ---------------------------------------------------------------------------
-- Fenetre
-- ---------------------------------------------------------------------------
gfx.init("CP_SoakProbe — session longue", 620, 300, 0, 200, 200)
gfx.setfont(1, "Consolas", 14)

local dernier_diag, dernier_load = "", ""

local function ligne(y, s)
    gfx.x, gfx.y = 12, y
    gfx.drawstr(s)
end

local function dessine(t, act, own)
    gfx.set(0.09, 0.09, 0.10, 1); gfx.rect(0, 0, gfx.w, gfx.h, 1)
    gfx.set(0.85, 0.86, 0.88, 1)

    local reste = DUREE_MIN * 60 - t
    ligne(14, string.format("ecoule %6.1f s    reste %6.1f s    (%d min demandees)",
                            t, reste > 0 and reste or 0, DUREE_MIN))
    gfx.set(0.45, 0.47, 0.50, 1)
    ligne(36, "----------------------------------------------------------")
    gfx.set(0.85, 0.86, 0.88, 1)
    ligne(56, string.format("voix    vivantes %-4d possedees %-4d  (pire %d)", act, own, pire.owned))
    ligne(76, string.format("cycle   alloc %-7d refus %-6d relache %d", n_alloc, n_refus, n_release))
    ligne(96, string.format("stress  chaines %-5d recharges %-4d rebranchements %d panique %d",
                            n_chaine, n_recharge, n_rebranche, n_panique))
    ligne(120, string.format("pire ratio %s   pire cpu %.2f %%",
                             pire.ratio > 9 and "  —  " or string.format("%.4f", pire.ratio),
                             pire.cpu))
    ligne(140, string.format("pire ram   %.2f Mo    pire gap %.6f s", pire.ram, pire.gap))

    gfx.set(0.45, 0.47, 0.50, 1)
    ligne(166, dernier_diag:sub(1, 72))
    ligne(184, dernier_diag:sub(73))
    ligne(204, dernier_load:sub(1, 72))

    if #violations == 0 then
        gfx.set(0.30, 0.75, 0.40, 1)
        ligne(236, "aucun invariant viole")
    else
        gfx.set(0.90, 0.35, 0.30, 1)
        ligne(236, string.format("%d INVARIANT(S) VIOLE(S) — voir le journal", #violations))
        local v = violations[1]
        ligne(254, string.format("premiere a %.1f s : %s", v.t, v.txt:sub(1, 60)))
    end

    gfx.set(0.40, 0.42, 0.45, 1)
    ligne(278, "Echap ou fermer la fenetre pour arreter proprement")
    gfx.update()
end

-- ---------------------------------------------------------------------------
-- Demontage
-- ---------------------------------------------------------------------------
local function verdict()
    local t = r.time_precise() - t0
    log("")
    log("=========== VERDICT ===========")
    log(string.format("duree            : %.1f s (%.1f min)", t, t / 60))
    log(string.format("cycle            : %d allocations, %d refus, %d liberations",
                      n_alloc, n_refus, n_release))
    log(string.format("stress           : %d chaines, %d recharges, %d rebranchements, %d paniques",
                      n_chaine, n_recharge, n_rebranche, n_panique))
    log(string.format("pire ratio       : %s",
                      pire.ratio > 9 and "mesure trop courte" or string.format("%.4f", pire.ratio)))
    log(string.format("pire cpu         : %.2f %% du fil audio", pire.cpu))
    log(string.format("pire ram         : %.2f Mo (clip = %.2f Mo)", pire.ram, clip_mo))
    log(string.format("pire gap         : %.6f s", pire.gap))
    log(string.format("emplacements     : %d au maximum, plafond attendu %d",
                      pire.owned, NPORTS * VOIX_PORT))
    if #violations == 0 then
        log("invariants       : AUCUNE VIOLATION")
    else
        log(string.format("invariants       : %d VIOLATION(S)", #violations))
        for _, v in ipairs(violations) do
            log(string.format("   a %7.1f s : %s", v.t, v.txt))
        end
    end
    log("etat final       : " .. r.CP_Diag())
    log("===============================")

    r.ShowConsoleMsg("\n=== CP_SoakProbe ===\n")
    r.ShowConsoleMsg(string.format("duree %.1f min, %d allocations, %d violations\n",
                                   t / 60, n_alloc, #violations))
    r.ShowConsoleMsg("journal : " .. LOG .. "\n")
end

local function demonte()
    for p = 0, NPORTS - 1 do
        for _, h in ipairs(live[p]) do r.CP_VoiceRelease(h) end
        live[p] = {}
    end
    r.CP_Panic()
    -- Un tour de defer avant de retirer les ports : les liberations viennent
    -- d'etre postees, et c'est le fil audio qui les execute.
    r.defer(function()
        for p = 0, NPORTS - 1 do r.CP_PortDetach(p) end
        r.CP_ClipUnload(clip)
        verdict()
        if fh then fh:close() end
        gfx.quit()
    end)
end

-- ---------------------------------------------------------------------------
-- Boucle
-- ---------------------------------------------------------------------------
r.CP_LoadReset()

local function boucle()
    local ch = gfx.getchar()
    if ch < 0 or ch == 27 then demonte() return end

    local t = r.time_precise() - t0
    local now = r.CP_ClockSync()

    if t >= nxt.lance then
        nxt.lance = t + EV_LANCE
        lance(math.floor(t / EV_LANCE) % NPORTS, now)
    end
    if t >= nxt.regle then
        nxt.regle = t + EV_REGLE
        regle(math.floor(t / EV_REGLE) % NPORTS)
    end
    if t >= nxt.chaine then
        nxt.chaine = t + EV_CHAINE
        chaine(math.floor(t / EV_CHAINE) % NPORTS, now)
    end

    -- Le rechargement : la matiere est retiree SOUS des voix vivantes. C'est le
    -- scenario qui a montre qu'une voix privee de son clip restait vivante a
    -- jamais et gardait son emplacement.
    if t >= nxt.recharge then
        nxt.recharge = t + EV_RECHARGE
        r.CP_ClipUnload(clip)
        local nc = r.CP_ClipLoad(path)
        if nc >= 0 then clip = nc; n_recharge = n_recharge + 1
        else viol("recharge", "rechargement du clip impossible") end
    end

    -- Le rebranchement : port_reset pendant que des voix sonnent. Les handles
    -- de ce port meurent avec lui, il faut les oublier ici — les garder
    -- reviendrait a mesurer notre propre erreur.
    if t >= nxt.rebranche then
        nxt.rebranche = t + EV_REBRANCHE
        local p = n_rebranche % NPORTS
        r.CP_PortDetach(p)
        live[p] = {}
        if r.CP_PortAttachOut(p, 0) then n_rebranche = n_rebranche + 1
        else viol("rebranche", "rebranchement du port " .. p .. " impossible") end
    end

    if t >= nxt.panique then
        nxt.panique = t + EV_PANIQUE
        r.CP_Panic()
        n_panique = n_panique + 1
    end

    local d, ld, _, act, own = verifie(t)
    dernier_diag, dernier_load = d, ld

    if t >= nxt.journal then
        nxt.journal = t + EV_JOURNAL
        log(string.format("%7.1f s | %s | %s", t, d, ld))
    end

    dessine(t, act, own)

    if t >= DUREE_MIN * 60 then demonte() return end
    r.defer(boucle)
end

r.defer(boucle)
r.atexit(function() if fh then fh:close() end end)
