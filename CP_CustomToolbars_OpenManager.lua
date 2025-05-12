-- CP_CustomToolbars_OpenManager.lua
-- Script pour ouvrir le gestionnaire de barres d'outils personnalisées

local r = reaper

-- Définir le drapeau pour ouvrir le gestionnaire
r.SetExtState("CP_MULTI_TOOLBAR", "open_manager", "1", false)

-- Forcer l'actualisation lors du prochain frame
r.SetExtState("CP_MULTI_TOOLBAR", "refresh_toolbars", "1", false)