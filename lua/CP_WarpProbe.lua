-- CP_WarpProbe — le dernier argument irreductible du dossier, mesure.
--
-- Le warp est la SEULE raison pour laquelle ce projet est natif : preserver la
-- hauteur pendant un changement de vitesse demande un etireur, et tout etireur a
-- une latence de fenetre qu'aucune API Lua ne rapporte. D'ou un decalage constant
-- que rien ne pouvait corriger.
--
-- IReaperPitchShift n'expose AUCUN accesseur de latence (§11.9). Mais c'est une
-- interface push/pull : on pousse une impulsion, on compte ce qui sort avant
-- elle. Deux nombres, parce qu'un etireur a fenetre ETALE une impulsion :
--
--   premier  quand la sortie commence a exister
--   pic      ou l'energie est reellement arrivee -> c'est LUI qui sert a compenser
--
-- Et le cout : 16 voix etirees sur un PC de 2005 n'existent peut-etre pas, quel
-- que soit le code. Mieux vaut le savoir avant d'ecrire le moteur autour.

local r = reaper

local LOG = r.GetResourcePath() .. "/CP_NativeProbe.log"
local fh = io.open(LOG, "a")
local function log(s) if fh then fh:write(tostring(s), "\n") end end
local function both(s) log(s); r.ShowConsoleMsg(tostring(s) .. "\n") end
if fh then
    fh:write("\n\n########################################################\n")
    fh:write("# CP_WarpProbe " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    fh:write("########################################################\n")
end

if not r.APIExists("CP_WarpProbe") then
    r.MB("Moteur trop ancien ou absent : il faut l'ABI 1.4.", "CP_Native", 0)
    if fh then fh:close() end
    return
end

r.ClearConsole()
both("=== CP_WarpProbe ===")
both("")
both("A. LATENCE ET COUT SELON LE TAUX")
both("   (1,0000 = pas d'etirement ; 1,0667 = 120 -> 128 BPM ; 0,75 = 160 -> 120)")
both("")

-- Des taux realistes pour un lanceur de clips, pas des extremes de laboratoire.
local TAUX = { 1.0, 1.0667, 0.9375, 0.75, 1.3333, 2.0 }
for _, t in ipairs(TAUX) do
    local s = r.CP_WarpProbe(t, 1)
    both(string.format("  taux %.4f", t))
    both("    " .. s)
end

both("")
both("B. COUT SELON LE NOMBRE DE VOIX (taux 1,0667)")
both("")
for _, n in ipairs({ 1, 2, 4, 8, 16 }) do
    local s = r.CP_WarpProbe(1.0667, n)
    -- On ne garde que la partie cout : la latence ne depend pas du nombre.
    local cout = s:match("cout: (.+)$") or s
    both(string.format("  %2d voix : %s", n, cout))
end

both("")
both("=========== LECTURE ===========")
both("AMORCE = combien d'echantillons il faut POUSSER dans l'etireur avant que")
both("le premier ne sorte. C'est LA latence, et la premiere campagne la cherchait")
both("au mauvais endroit : elle ne se manifeste pas par des zeros en tete de")
both("sortie mais par une sortie qui n'existe pas encore.")
both("")
both("Que l'impulsion ressorte a l'index 0 est la BONNE nouvelle : la sortie")
both("commence bien a l'echantillon source 0. Il n'y a donc rien a jeter ni a")
both("decaler -- il faut seulement pre-remplir l'etireur AVANT l'instant de")
both("lancement. Nos clips sont en RAM : cet amorcage est gratuit.")
both("")
both("Si AMORCE est stable d'un taux a l'autre, l'amorcage est une constante.")
both("S'il varie, il se recalcule a chaque changement de taux.")
both("")
both("Le COUT se compare directement au 3,39 % des 64 voix NON etirees : meme")
both("unite, une part de temps reel. Le rapport entre les deux dit combien de")
both("clips peuvent etre warpes en direct, et combien doivent etre cuits.")
both("")
both("Rappel du §12.1 : le taux CONSTANT se cuit hors ligne et ne coute alors")
both("plus rien du tout. Ce cout ne concerne que le taux VARIABLE -- rampe de")
both("tempo, warp markers, tempo qui bouge pendant le jeu.")
both("===============================")
both("journal : " .. LOG)
if fh then fh:close() end
