-- CP_Engine — Focus
-- ---------------------------------------------------------------------------
-- QUI RECOIT LA BARRE D'ESPACE.
-- ---------------------------------------------------------------------------
-- Une fenetre gfx ne recoit les touches que si elle a le focus, et REAPER n'en
-- donne qu'un a la fois. « Space doit rester sur CP_Editor pendant que je
-- chipote mes samples dans le Sampler » ne peut donc PAS se resoudre dans
-- CP_Editor : il ne recoit rien. C'est la fenetre qui RECOIT la frappe qui doit
-- passer la main, et il n'y a pas d'autre endroit ou ce code puisse vivre.
--
-- Deux choses suffisent, et aucune n'est un enregistrement.
--
-- LA PRETENTION. Chaque fenetre ecrit « je suis la, et voici mon rang » une
-- fois par demi-seconde, avec l'heure. Une fenetre fermee cesse d'ecrire et sa
-- pretention expire toute seule : rien a desinscrire, donc rien a oublier de
-- desinscrire. C'est ce qui evite le defaut classique de ce genre de couche —
-- une fenetre morte qui garde la touche jusqu'au redemarrage de REAPER, et que
-- personne ne sait deloger.
--
-- LE DEPOT. Celle qui recoit la frappe sans etre la mieux placee la DEPOSE ;
-- la mieux placee la ramasse a sa frame suivante. On depose la touche BRUTE et
-- son masque de modificateurs, pas une action : c'est le proprietaire qui
-- interroge SA table de liaisons, donc Shift+Space veut dire chez lui ce qu'il
-- a decide, et non ce que l'expediteur aurait cru.
--
-- Le retard est d'une frame — trente millisecondes. Sur un geste de transport
-- declenche a la main, il est sous le seuil de ce qu'un doigt distingue, et il
-- est le prix d'une couche qui ne demande a personne de se souvenir de rien.
local Focus = {}

local r  -- reaper, injecte

local SEC = "CP_Focus"
local TTL = 2.0      -- une pretention plus vieille que ca n'existe plus
local BEAT = 0.5     -- on ne la reecrit pas plus souvent que ca

-- L'ORDRE DE PRIORITE EST CE TABLEAU, et il n'est nulle part ailleurs.
-- Le rang le plus BAS gagne. C'est la demande de Cedric du 2026-08-02 :
-- « si CP_Editor est ouvert, c'est le lead, ensuite CP_Sampler, enfin
-- CP_MediaExplorer ».
--
-- CP_SESSION EST LA DERNIERE, ET C'EST UNE PROPRIETE DE LA FENETRE, pas un
-- classement d'importance : elle a un transport a elle — le clic sur une case —
-- donc elle ne veut jamais de la barre d'espace. Elle est dans la liste pour
-- POUVOIR la passer, et pour rien d'autre. Sans elle, cliquer une case ouvrait
-- le clip dans CP_Editor et Space ne faisait plus rien du tout.
local RANK = { editor = 1, sampler = 2, media = 3, session = 4 }
-- Parcouru dans l'ordre pour trouver le proprietaire : une liste, parce qu'un
-- `pairs` sur RANK ne garantit pas l'ordre et que « le mieux place » est
-- exactement une question d'ordre.
local ORDER = { "editor", "sampler", "media", "session" }

function Focus.init(reaper_api) r = reaper_api end

local last_claim = 0

-- A appeler UNE FOIS PAR FRAME. Elle ne fait rien la plupart du temps.
function Focus.Claim(who)
    if not r or not RANK[who] then return end
    local now = r.time_precise()
    if now - last_claim < BEAT then return end
    last_claim = now
    r.SetExtState(SEC, "claim_" .. who, string.format("%.3f", now), false)
end

-- Le mieux place parmi ceux qui sont vivants, ou nil si personne ne pretend.
function Focus.Owner()
    if not r then return nil end
    local now = r.time_precise()
    for i = 1, #ORDER do
        local w = ORDER[i]
        local t = tonumber(r.GetExtState(SEC, "claim_" .. w) or "")
        if t and (now - t) < TTL then return w end
    end
    return nil
end

function Focus.IsOwner(who)
    local o = Focus.Owner()
    return o == nil or o == who
end

-- Deposer une frappe pour quelqu'un d'autre. Le masque voyage avec elle.
function Focus.Post(who, char, mods)
    if not r or not who then return false end
    r.SetExtState(SEC, "key_" .. who,
                  string.format("%.3f|%d|%d", r.time_precise(),
                                char or 0, mods or 0), false)
    return true
end

-- Ramasser ce qui a ete depose pour moi. Rend char, mods — ou rien.
--
-- LA DUREE DE VIE EST COURTE ET DELIBEREE. Une frappe qu'on ramasse une seconde
-- apres n'est plus un geste, c'est une surprise : si la fenetre proprietaire
-- etait occupee ailleurs, mieux vaut que la touche soit perdue que rejouee au
-- moment ou l'on ne s'y attend plus.
function Focus.Take(who)
    if not r then return nil end
    local v = r.GetExtState(SEC, "key_" .. who)
    if not v or v == "" then return nil end
    local ts, ch, md = v:match("^([^|]+)|([^|]+)|([^|]+)$")
    if not ts then return nil end
    r.DeleteExtState(SEC, "key_" .. who, false)
    if (r.time_precise() - (tonumber(ts) or 0)) > 0.5 then return nil end
    return math.floor(tonumber(ch) or 0), math.floor(tonumber(md) or 0)
end

-- Le geste complet, vu de la fenetre qui RECOIT la frappe.
--
-- Rend `true` quand la touche a ete passee a quelqu'un d'autre — l'appelant
-- n'a alors plus rien a faire qu'a la consommer. Rend `false` quand c'est a
-- lui de la traiter, ce qui est le cas courant et ne coute qu'une lecture.
function Focus.Route(me, char, mods)
    local o = Focus.Owner()
    if o == nil or o == me then return false end
    Focus.Post(o, char, mods)
    return true
end

return Focus
