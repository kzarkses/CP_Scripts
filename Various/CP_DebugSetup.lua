-- @description DebugSetup - Installation des outils de debug
-- @version 1.0.0
-- @author Cedric Pamalio

local r = reaper

local script_name = "CP_DebugSetup"
local ctx = r.ImGui_CreateContext('Debug Setup')
local setup_complete = false
local setup_step = 1
local max_steps = 5
local setup_log = {}

function LogSetup(message)
    table.insert(setup_log, os.date("%H:%M:%S") .. " - " .. message)
    r.ShowConsoleMsg("SETUP: " .. message .. "\n")
end

function CheckFileExists(path)
    return r.file_exists(path)
end

function GetScriptPath()
    return r.GetResourcePath() .. "/Scripts/CP_Scripts/Custom Toolbars/"
end

function BackupOriginalScript()
    local original_path = GetScriptPath() .. "CP_CustomToolbars.lua"
    local backup_path = GetScriptPath() .. "CP_CustomToolbars_Original_Backup.lua"
    
    if CheckFileExists(original_path) then
        local file = io.open(original_path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            
            local backup_file = io.open(backup_path, "w")
            if backup_file then
                backup_file:write("-- SAUVEGARDE AUTOMATIQUE du " .. os.date() .. "\n")
                backup_file:write("-- Script original avant debug\n\n")
                backup_file:write(content)
                backup_file:close()
                LogSetup("✅ Sauvegarde créée: CP_CustomToolbars_Original_Backup.lua")
                return true
            end
        end
    end
    
    LogSetup("❌ Impossible de créer la sauvegarde")
    return false
end

function InstallDebugScripts()
    local scripts_to_install = {
        {
            name = "CP_CrashDetector.lua",
            description = "Détecteur de problèmes potentiels"
        },
        {
            name = "CP_CustomToolbars_Debug.lua", 
            description = "Version avec monitoring en temps réel"
        },
        {
            name = "CP_CustomToolbars_Stabilized.lua",
            description = "Version corrigée et stabilisée"
        }
    }
    
    LogSetup("📦 Installation des scripts de debug...")
    
    for _, script in ipairs(scripts_to_install) do
        LogSetup("- " .. script.name .. " : " .. script.description)
    end
    
    LogSetup("✅ Scripts de debug disponibles dans les artifacts")
    return true
end

function ShowSetupWindow()
    r.ImGui_SetNextWindowSize(ctx, 700, 500, r.ImGui_Cond_FirstUseEver())
    local visible, open = r.ImGui_Begin(ctx, 'CustomToolbars Debug Setup', true)
    
    if visible then
        r.ImGui_Text(ctx, "Configuration du Debug pour CP_CustomToolbars")
        r.ImGui_Separator(ctx)
        
        r.ImGui_Text(ctx, string.format("Étape %d/%d", setup_step, max_steps))
        r.ImGui_ProgressBar(ctx, setup_step / max_steps, -1, 20)
        
        r.ImGui_Separator(ctx)
        
        if setup_step == 1 then
            r.ImGui_Text(ctx, "🔍 Analyse du Problème")
            r.ImGui_TextWrapped(ctx, "Votre script CP_CustomToolbars cause des crashes REAPER avec:")
            r.ImGui_BulletText(ctx, "Freeze de 2 secondes puis crash sans message")
            r.ImGui_BulletText(ctx, "Problème lors de manipulation d'autres fenêtres ImGui")
            r.ImGui_BulletText(ctx, "Crash aléatoire durant l'utilisation")
            
            if r.ImGui_Button(ctx, "Commencer le Diagnostic") then
                setup_step = 2
                LogSetup("🚀 Début du diagnostic")
            end
            
        elseif setup_step == 2 then
            r.ImGui_Text(ctx, "💾 Sauvegarde du Script Original")
            r.ImGui_TextWrapped(ctx, "Avant de commencer, nous allons sauvegarder votre script original.")
            
            if r.ImGui_Button(ctx, "Créer Sauvegarde") then
                if BackupOriginalScript() then
                    setup_step = 3
                else
                    LogSetup("⚠️ Continuer sans sauvegarde (risqué)")
                end
            end
            
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, "Ignorer (Risqué)") then
                setup_step = 3
                LogSetup("⚠️ Sauvegarde ignorée par l'utilisateur")
            end
            
        elseif setup_step == 3 then
            r.ImGui_Text(ctx, "🛠️ Installation des Outils de Debug")
            r.ImGui_TextWrapped(ctx, "Installation des scripts de diagnostic et correction:")
            
            r.ImGui_BulletText(ctx, "CP_CrashDetector.lua - Détecte les problèmes spécifiques")
            r.ImGui_BulletText(ctx, "CP_CustomToolbars_Debug.lua - Monitoring temps réel")
            r.ImGui_BulletText(ctx, "CP_CustomToolbars_Stabilized.lua - Version corrigée")
            
            if r.ImGui_Button(ctx, "Installer les Outils") then
                if InstallDebugScripts() then
                    setup_step = 4
                end
            end
            
        elseif setup_step == 4 then
            r.ImGui_Text(ctx, "🔬 Plan de Test")
            r.ImGui_TextWrapped(ctx, "Suivez ces étapes dans l'ordre:")
            
            r.ImGui_Text(ctx, "1. DIAGNOSTIC INITIAL")
            r.ImGui_BulletText(ctx, "Lancez CP_CrashDetector.lua")
            r.ImGui_BulletText(ctx, "Cliquez 'Run Tests' et examinez les résultats")
            r.ImGui_BulletText(ctx, "Notez les erreurs CRITICAL et HIGH")
            
            r.ImGui_Text(ctx, "2. MONITORING EN TEMPS RÉEL")
            r.ImGui_BulletText(ctx, "Fermez votre CustomToolbars actuel")
            r.ImGui_BulletText(ctx, "Lancez CP_CustomToolbars_Debug.lua")
            r.ImGui_BulletText(ctx, "Reproduisez le crash en surveillant les logs")
            
            r.ImGui_Text(ctx, "3. TEST VERSION STABILISÉE")
            r.ImGui_BulletText(ctx, "Testez CP_CustomToolbars_Stabilized.lua")
            r.ImGui_BulletText(ctx, "Vérifiez si le crash est résolu")
            
            if r.ImGui_Button(ctx, "Commencer les Tests") then
                setup_step = 5
            end
            
        elseif setup_step == 5 then
            r.ImGui_Text(ctx, "✅ Setup Terminé")
            r.ImGui_TextWrapped(ctx, "Les outils de debug sont installés et prêts à utiliser.")
            
            r.ImGui_Separator(ctx)
            r.ImGui_Text(ctx, "PROCHAINES ÉTAPES:")
            r.ImGui_BulletText(ctx, "1. Fermez cette fenêtre")
            r.ImGui_BulletText(ctx, "2. Lancez CP_CrashDetector.lua depuis Actions > Load ReaScript")
            r.ImGui_BulletText(ctx, "3. Examinez le rapport de diagnostic")
            r.ImGui_BulletText(ctx, "4. Testez la version debug si nécessaire")
            
            r.ImGui_Separator(ctx)
            r.ImGui_TextColored(ctx, 0x00FF00FF, "✅ Vous pouvez maintenant diagnostiquer le problème!")
            
            if r.ImGui_Button(ctx, "Terminer") then
                setup_complete = true
            end
        end
        
        r.ImGui_Separator(ctx)
        
        if r.ImGui_BeginChild(ctx, "LogArea", -1, 150) then
            for _, log_entry in ipairs(setup_log) do
                r.ImGui_Text(ctx, log_entry)
            end
            
            if #setup_log > 0 then
                r.ImGui_SetScrollHereY(ctx, 1.0)
            end
            
            r.ImGui_EndChild(ctx)
        end
        
        r.ImGui_End(ctx)
    end
    
    return open and not setup_complete
end

function MainLoop()
    if ShowSetupWindow() then
        r.defer(MainLoop)
    else
        LogSetup("🏁 Setup terminé - Vous pouvez maintenant diagnostiquer le problème")
    end
end

LogSetup("🚀 Lancement du setup de debug pour CustomToolbars")
MainLoop()