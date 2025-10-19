function main()
    local explorerHWND = reaper.OpenMediaExplorer("", false)
    
    if explorerHWND then
        local action_id = 42124
        local current_state = reaper.GetExtState("MediaExplorer", "Action42124")
        
        if current_state ~= "1" then
            reaper.JS_Window_OnCommand(explorerHWND, action_id)
            reaper.SetExtState("MediaExplorer", "Action42124", "1", true)
        end
    end
end

if reaper.JS_Window_OnCommand then
    reaper.Undo_BeginBlock()
    main()
    reaper.Undo_EndBlock("Activer action Media Explorer 42124", -1)
else
    reaper.ShowMessageBox("Extension JS_ReaScriptAPI requise!\nInstallez-la via ReaPack.", "Erreur", 0)
end