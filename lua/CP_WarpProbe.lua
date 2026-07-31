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
both("La LATENCE (pic) est le nombre d'echantillons a jeter, ou a pre-remplir,")
both("pour qu'un clip warpe demarre pile sur le beat. Si elle est stable d'un")
both("taux a l'autre, la compensation est une constante. Si elle varie, il faut")
both("la remesurer a chaque changement de taux -- toujours faisable, juste plus")
both("de travail.")
both("")
both("Le COUT se compare directement au 3,39 % des 64 voix non etirees : c'est")
both("la meme unite, une part de temps reel. Il dit combien de clips peuvent")
both("etre warpes EN DIRECT, et donc combien doivent etre cuits hors ligne.")
both("")
both("Rappel du §12.1 : le taux CONSTANT se cuit hors ligne et ne coute alors")
both("plus rien du tout. Ce cout ne concerne que le taux VARIABLE -- rampe de")
both("tempo, warp markers, tempo qui bouge pendant le jeu.")
both("===============================")
both("journal : " .. LOG)
if fh then fh:close() end
