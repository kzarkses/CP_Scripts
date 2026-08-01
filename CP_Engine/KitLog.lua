-- CP_Engine/KitLog.lua — un journal que l'auteur du bug peut lire
--
-- POURQUOI CE FICHIER EXISTE. Trois soirees ont ete perdues a deviner ou se
-- coupait la chaine entre la fenetre et l'instrument, parce que la seule
-- mesure disponible etait une capture d'ecran decrite au telephone. Chaque
-- fois qu'une mesure a existe, la cause est tombee en une lecture — les mots
-- bruts de gmem ont trouve la virgule en trente secondes.
--
-- Le journal ecrit dans CP_Config/kitsampler.log, qui vit dans le depot mais
-- n'y est pas commite (CP_Config est deliberement hors du suivi). Il est
-- ETEINT par defaut : un fichier qui grossit tout seul est un piege, et
-- personne ne veut d'un acces disque par frame sur un PC de 2005.

local KitLog = {}

local r
local path
local on = false
local n = 0
local MAX_LINES = 4000   -- au-dela, on repart de zero plutot que de gonfler

function KitLog.init(reaper_api)
    r = reaper_api
    path = r.GetResourcePath()
           .. "/Scripts/CP_Scripts/CP_Config/kitsampler.log"
end

function KitLog.Enabled() return on end

function KitLog.SetEnabled(v)
    on = v and true or false
    if on then
        n = 0
        local f = io.open(path, "w")
        if f then
            f:write("-- CP Kit Sampler — journal\n")
            f:close()
        end
    end
end

function KitLog.Path() return path end

-- Une ligne. Le formatage est fait par l'appelant : cette fonction ne doit
-- jamais couter une concatenation quand le journal est eteint, et c'est le
-- seul endroit du moteur ou un io.open est acceptable — il est sous garde.
function KitLog.Write(s)
    if not on then return end
    n = n + 1
    if n > MAX_LINES then
        on = false
        s = s .. "\n-- journal plein, arret automatique"
    end
    local f = io.open(path, "a")
    if not f then return end
    f:write(s, "\n")
    f:close()
end

function KitLog.Line(fmt, ...)
    if not on then return end
    KitLog.Write(string.format(fmt, ...))
end

function KitLog.Section(title)
    if not on then return end
    KitLog.Write("\n=== " .. title .. " ===")
end

return KitLog
