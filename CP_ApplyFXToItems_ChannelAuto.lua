-- @description CP_ApplyFXToItems_ChannelAuto
-- @version 1.0
-- @author Claude
-- @about
--   Applique les effets de piste/take aux items avec détection automatique du nombre de canaux

local r = reaper

function Main()
  -- Vérification de l'extension JS_ReaScriptAPI
  if not r.APIExists("JS_Window_GetTitle") then
    r.ShowMessageBox("Ce script nécessite l'extension JS_ReaScriptAPI.\nMerci de l'installer via ReaPack.", "Erreur", 0)
    return
  end

  -- Vérification des items sélectionnés
  local selectedItemCount = r.CountSelectedMediaItems(0)
  if selectedItemCount == 0 then return end
  
  -- Stocker les items sélectionnés
  local selectedItems = {}
  for i = 0, selectedItemCount - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    selectedItems[i + 1] = item
  end
  
  r.Undo_BeginBlock()
  
  -- Pour chaque item sélectionné
  for i = 1, #selectedItems do
    local item = selectedItems[i]
    local take = r.GetActiveTake(item)
    
    if take and not r.TakeFX_GetCount(take) then
      -- Obtenir le nombre de canaux de la source originale
      local source = r.GetMediaItemTake_Source(take)
      local sourceChannels = r.GetMediaSourceNumChannels(source)
      
      -- Optimisation: Si la source est déjà en stéréo, pas besoin d'analyse
      if sourceChannels >= 2 then
        -- Désélectionner tous les items sauf celui-ci
        r.SelectAllMediaItems(0, false)
        r.SetMediaItemSelected(item, true)
        
        -- Exécuter la commande standard pour appliquer les FX
        r.Main_OnCommand(40209, 0) -- Item: Apply track/take FX to items
      else
        -- Pour les sources mono, faire une analyse pour détecter si le rendu doit être en stéréo
        
        -- Sauvegarder les paramètres actuels de rendu
        local origRenderSettings = SaveRenderSettings()
        
        -- Première passe : Render temporaire pour analyse
        r.PreventUIRefresh(1)
        
        -- Désélectionner tous les items sauf celui-ci
        r.SelectAllMediaItems(0, false)
        r.SetMediaItemSelected(item, true)
        
        -- Forcer le rendu en stéréo pour l'analyse
        SetRenderSettings(true) -- Force stereo
        
        -- Créer un take temporaire
        r.Main_OnCommand(40361, 0) -- Item: New take
        local tempTake = r.GetActiveTake(item)
        
        -- Appliquer les FX sur ce take temporaire
        r.Main_OnCommand(40209, 0) -- Item: Apply track/take FX to items
        
        -- Analyser si le résultat est vraiment stéréo
        local isStereo = false
        if tempTake then
            local tempSource = r.GetMediaItemTake_Source(tempTake)
            isStereo = AnalyzeSourceStereo(tempSource)
            
            -- Supprimer le take temporaire
            r.DeleteTake(item, r.GetMediaItemTakeInfo_Value(tempTake, "IP_TAKENUMBER"))
        end
        
        -- Deuxième passe : Rendu final avec le bon nombre de canaux
        -- Restaurer le take original comme take actif
        take = r.GetActiveTake(item)
        
        -- Appliquer les effets avec le bon nombre de canaux
        SetRenderSettings(isStereo) -- Utiliser le nombre de canaux déterminé
        
        -- Exécuter la commande standard pour appliquer les FX
        r.Main_OnCommand(40209, 0) -- Item: Apply track/take FX to items
        
        -- Restaurer les paramètres de rendu
        RestoreRenderSettings(origRenderSettings)
        r.PreventUIRefresh(-1)
      end
    end
  end
  
  -- Resélectionner les items
  r.SelectAllMediaItems(0, false)
  for i = 1, #selectedItems do
    r.SetMediaItemSelected(selectedItems[i], true)
  end
  
  r.Undo_EndBlock("Appliquer FX avec détection auto des canaux", -1)
  r.UpdateArrange()
end

-- Fonction pour sauvegarder les paramètres de rendu actuels
function SaveRenderSettings()
  local settings = {}
  settings.channels = r.SNM_GetIntConfigVar("renderchannels", 0)
  return settings
end

-- Fonction pour configurer les paramètres de rendu
function SetRenderSettings(forceStereo)
  -- Configurer le nombre de canaux (1=mono, 2=stereo)
  r.SNM_SetIntConfigVar("renderchannels", forceStereo and 2 or 1)
end

-- Fonction pour restaurer les paramètres de rendu originaux
function RestoreRenderSettings(settings)
  r.SNM_SetIntConfigVar("renderchannels", settings.channels)
end

-- Analyse une source audio pour déterminer si elle est vraiment stéréo
function AnalyzeSourceStereo(source)
  if not source then return false end
  
  -- Obtenir la longueur et la fréquence d'échantillonnage
  local sampleRate = r.GetMediaSourceSampleRate(source)
  local length = r.GetMediaSourceLength(source)
  local numChannels = r.GetMediaSourceNumChannels(source)
  
  -- Si la source n'est pas stéréo, pas besoin d'analyse
  if numChannels < 2 then return false end
  
  local numSamples = math.floor(length * sampleRate)
  
  -- Créer des tampons pour les canaux gauche et droit
  local bufferSize = math.min(numSamples, 44100) -- Analyser max 1 seconde (ou moins si le fichier est plus court)
  local leftBuffer = r.new_array(bufferSize)
  local rightBuffer = r.new_array(bufferSize)
  
  -- Lire les échantillons audio
  local accessOK = r.PCM_Source_GetSamples(source, 0, 0, sampleRate, bufferSize, 0, leftBuffer, rightBuffer)
  
  if not accessOK then
    return false
  end
  
  -- Calculer la corrélation entre les canaux
  local sumProd = 0
  local sumLeftSq = 0
  local sumRightSq = 0
  local diffSum = 0
  
  for i = 0, bufferSize - 1 do
    local left = leftBuffer[i]
    local right = rightBuffer[i]
    
    sumProd = sumProd + (left * right)
    sumLeftSq = sumLeftSq + (left * left)
    sumRightSq = sumRightSq + (right * right)
    diffSum = diffSum + math.abs(left - right)
  end
  
  -- Calculer coefficient de corrélation de Pearson
  local correlation = 0
  if sumLeftSq > 0 and sumRightSq > 0 then
    correlation = sumProd / math.sqrt(sumLeftSq * sumRightSq)
  end
  
  -- Calculer la différence moyenne (indice de largeur stéréo)
  local avgDiff = diffSum / bufferSize
  
  -- Déterminer si le signal est vraiment stéréo
  -- Un signal mono aura une corrélation proche de 1 et une différence moyenne proche de 0
  return correlation < 0.98 or avgDiff > 0.01
end

Main()
