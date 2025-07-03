-- @description AutoColorTrackHierarchy - Lighten
-- @version 1.0
-- @author Cedric Pamalio

local CONFIG = {
    LIGHTEN_AMOUNT = 0.10,    -- Pourcentage d'Ã©claircissement par niveau (0.25 = 25% plus clair)
    DESATURATE_AMOUNT = 0.15,   -- Pourcentage de dÃ©saturation par niveau 
    BACKGROUND_MODE = true    -- true pour mode tÃ¢che de fond, false pour mode manuel
}

-- Variables globales
local lastTrackColors = {}
local lastTrackParents = {}
local last_track_count = 0

-- Fonction pour convertir une couleur RGB en HSV
function rgbToHsv(r, g, b)
    r, g, b = r/255, g/255, b/255
    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local h, s, v
    local d = max - min

    v = max
    
    if max == 0 then
        s = 0
    else
        s = d/max
    end
    
    if max == min then
        h = 0
    else
        if max == r then
            h = (g - b) / d
            if g < b then h = h + 6 end
        elseif max == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h/6
    end
    
    return h, s, v
end

-- Fonction pour convertir HSV en RGB
function hsvToRgb(h, s, v)
    local r, g, b
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    
    i = i % 6
    
    if i == 0 then r, g, b = v, t, p
    elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t
    elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t, p, v
    elseif i == 5 then r, g, b = v, p, q
    end
    
    return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

-- Fonction pour Ã©claircir une couleur
function lightenColor(r, g, b, lightenAmount, desaturateAmount)
    if r == 0 and g == 0 and b == 0 then
        local base = 144
        local value = math.floor(math.min(255, base + (255 - base) * lightenAmount))
        return value, value, value
    end
    
    if r == g and g == b then
        local value = math.floor(math.min(255, r + (255 - r) * lightenAmount))
        return value, value, value
    end
    
    local h, s, v = rgbToHsv(r, g, b)
    v = math.min(1, v * (1 + lightenAmount))
    s = s * (1 - desaturateAmount)
    return hsvToRgb(h, s, v)
 end

-- Fonctions de conversion de couleurs
function nativeToRGB(native)
    if native == 0 then return 0, 0, 0 end
    local r = (native & 0xFF0000) >> 16
    local g = (native & 0x00FF00) >> 8
    local b = native & 0x0000FF
    return r, g, b
end

function rgbToNative(r, g, b)
    return (r << 16) | (g << 8) | b
end

-- Fonction pour vÃ©rifier les changements de structure
function detectStructureChanges()
    local current_track_count = reaper.CountTracks(0)
    
    -- VÃ©rifier si le nombre de pistes a changÃ©
    if current_track_count ~= last_track_count then
        last_track_count = current_track_count
        return true
    end
    
    -- VÃ©rifier les changements de hiÃ©rarchie
    for i = 0, current_track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local guid = reaper.GetTrackGUID(track)
        local parent = reaper.GetParentTrack(track)
        local parent_guid = parent and reaper.GetTrackGUID(parent) or "none"
        
        if lastTrackParents[guid] ~= parent_guid then
            lastTrackParents[guid] = parent_guid
            return true
        end
    end
    
    return false
end

-- Fonction pour vÃ©rifier les changements de couleur
function detectColorChanges()
    local changes_detected = false
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local guid = reaper.GetTrackGUID(track)
        local currentColor = reaper.GetTrackColor(track)
        
        if lastTrackColors[guid] ~= currentColor then
            changes_detected = true
            lastTrackColors[guid] = currentColor
        end
    end
    return changes_detected
end

-- Fonction pour mettre Ã  jour toutes les couleurs
function updateAllColors()
    reaper.PreventUIRefresh(1)
    
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        if not reaper.GetParentTrack(track) then
            colorChildTracks(track, 1)
        end
    end
    
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
end

-- Fonction principale pour colorer les pistes enfants
function colorChildTracks(parentTrack, depth)
    local r, g, b = nativeToRGB(reaper.GetTrackColor(parentTrack))
    
    for i = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, i)
        local parent = reaper.GetParentTrack(track)
        
        if parent == parentTrack then
            if r == 0 and g == 0 and b == 0 then
                colorChildTracks(track, 1)
            else
                local lightenAmount = CONFIG.LIGHTEN_AMOUNT * depth
                local desaturateAmount = CONFIG.DESATURATE_AMOUNT * depth
                local newR, newG, newB = lightenColor(r, g, b, lightenAmount, desaturateAmount)
                
                reaper.SetTrackColor(track, rgbToNative(newR, newG, newB))
                colorChildTracks(track, depth + 1)
            end
        end
    end
 end

-- Fonction principale de vÃ©rification
function checkAndUpdateColors()
    local should_update = detectStructureChanges() or detectColorChanges()
    
    if should_update then
        updateAllColors()
    end
    
    if CONFIG.BACKGROUND_MODE then
        reaper.defer(checkAndUpdateColors)
    end
end

-- Fonction d'initialisation
function initializeTracking()
    last_track_count = reaper.CountTracks(0)
    
    -- Initialiser le suivi des parents et des couleurs
    for i = 0, last_track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local guid = reaper.GetTrackGUID(track)
        local parent = reaper.GetParentTrack(track)
        lastTrackParents[guid] = parent and reaper.GetTrackGUID(parent) or "none"
        lastTrackColors[guid] = reaper.GetTrackColor(track)
    end
end

function Start()
    if CONFIG.BACKGROUND_MODE then
        initializeTracking()
        updateAllColors() -- Force refresh at start
        checkAndUpdateColors()
    end
end

function Stop()
    reaper.UpdateArrange()
end

function ToggleScript()
    local _, _, sectionID, cmdID = reaper.get_action_context()
    local state = reaper.GetToggleCommandState(cmdID)
    
    if state == -1 or state == 0 then
        reaper.SetToggleCommandState(sectionID, cmdID, 1)
        reaper.RefreshToolbar2(sectionID, cmdID)
        Start()
    else
        reaper.SetToggleCommandState(sectionID, cmdID, 0)
        reaper.RefreshToolbar2(sectionID, cmdID)
        Stop()
    end
end

function Exit()
    local _, _, sectionID, cmdID = reaper.get_action_context()
    reaper.SetToggleCommandState(sectionID, cmdID, 0)
    reaper.RefreshToolbar2(sectionID, cmdID)
end

reaper.atexit(Exit)
ToggleScript()









