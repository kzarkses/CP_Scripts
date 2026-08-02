-- @description CP Keymap — les raccourcis et les modificateurs de la suite
-- @version 1.1
-- @author Cedric Pamalio
--
-- ---------------------------------------------------------------------------
-- LA MEME CHOSE QUE DANS LES OPTIONS D'UN MODULE, VUE DE PLUS HAUT
-- ---------------------------------------------------------------------------
-- Regler les raccourcis de l'outil qu'on a sous la main est le bon geste, et
-- c'est pour ca que le panneau vit dans `CP_Engine/KeymapUI.lua` et s'ouvre
-- depuis les options de chaque fenetre. Cette fenetre-ci ne le remplace pas :
-- elle sert a voir TOUS les modules d'un coup, ce qu'aucune fenetre de module
-- ne peut faire — et a les regler quand aucune n'est ouverte.
--
-- Elle ne redessine donc rien : elle charge les vocabulaires, choisit lequel on
-- regarde, et laisse le module faire. Une seconde mise en oeuvre serait une
-- seconde chose a corriger deux fois.

local info = debug.getinfo(1, "S")
local script_path = info.source:match("@?(.*[\\/])")
local root = script_path:match("(.*[\\/]).*[\\/]") or script_path

local UI       = dofile(root .. "CP_Toolkit/CP_Toolkit.lua")
local Keymap   = dofile(root .. "CP_Engine/Keymap.lua")
local KeymapUI = dofile(root .. "CP_Engine/KeymapUI.lua")

local r = reaper
Keymap.init(r, UI.Core, UI.Keys)
KeymapUI.init(r, UI.Core, Keymap)

-- LES MODULES CONNUS. En ajouter un est une ligne ici et un fichier dans
-- CP_Engine/Keymaps — jamais une modification de cette fenetre.
local MODULES = {
    { name = "editor", label = "CP Editor", file = "CP_Engine/Keymaps/editor.lua" },
}

local sel = 1
local panes, labels = {}, {}
local missing = nil

for i = 1, #MODULES do
    local m = MODULES[i]
    labels[i] = m.label
    local ok, rows = pcall(dofile, root .. m.file)
    if ok and type(rows) == "table" then
        Keymap.Register(m.name, rows)
        panes[i] = KeymapUI.NewState(m.name)
    else
        missing = (missing and (missing .. ", ") or "") .. m.file
    end
end

local function frame(theme)
    -- AVANT TOUT LE RESTE : une capture ouverte mange la frappe. Laisser les
    -- widgets la prendre d'abord rendrait Echap et Entree inassignables — donc
    -- l'outil mentirait sur ce qu'il sait faire.
    local S = panes[sel]
    if S then KeymapUI.PollCapture(S) end

    UI.SetWindowPadding(theme.pad_large or 10)

    if missing then
        UI.Text("A vocabulary could not be loaded:")
        UI.Text(missing)
        return
    end
    if not S then return end

    if #MODULES > 1 then
        local ch, idx = UI.Combo("mod", "Module", sel, labels)
        if ch then sel = idx end
        UI.Spacing()
    end

    KeymapUI.Panel(UI, S, theme)
end

UI.Init("CP Keymap", 780, 640, { scale = 1.0, dock = 0, persist = "CP_Keymap" })
UI.Run(frame)
UI.OnClose(function()
    -- ON N'ENREGISTRE PAS TOUT SEUL. Une carte de raccourcis se relit avant
    -- d'etre posee : un enregistrement automatique ecrirait une capture ratee
    -- sans laisser le temps de la defaire.
end)
