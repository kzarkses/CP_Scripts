-- @description CP ChordLab — suggestion panel
-- @author Cedric Pamalio

-- Renders state.suggestions (Suggest.For output) as one CollapsingHeader per
-- category, each with a BeginWrap of chip Buttons. Open state persists in
-- cfg.cat_open. Interactions:
--   click chip        → preview + arm
--   double-click chip → ReplaceSegment on the selected segment
--   tooltip           → item.detail
-- Context is the selected segment (prev/next = neighbors) or the armed
-- fretboard chord when nothing is selected — App builds it in RecomputeSuggestions.
--
-- Signature: Draw(state, deps, theme).

local M = {}

function M.Draw(state, deps, theme)
    local UI = deps.UI
    local App = deps.App

    UI.BeginChild("cl_suggest", 0, 0, {
        scrollable = true, border = true, padding = theme.pad_small,
        bg = theme.colors.surface,
    })

    local sugg = state.suggestions
    if not sugg or #sugg == 0 then
        UI.SetFontCaption()
        UI.Text("Aucune suggestion. Selectionnez un accord ou construisez-en un sur le manche.",
            { disabled = true })
        UI.SetFontBody()
        UI.EndChild()
        return
    end

    local seg = App.SelectedSegment()
    local can_replace = (seg ~= nil and not seg.empty)
    local cat_open = state.cfg.cat_open

    -- Deterministic order: iterate the dense category array as returned by
    -- Suggest.For (fixed order); never pairs().
    for ci = 1, #sugg do
        local cat = sugg[ci]
        local items = cat.items
        if items and #items > 0 then
            local key = cat.key
            -- Default open state if this category key is not yet in cfg.
            local is_open = cat_open[key]
            if is_open == nil then is_open = true end

            local toggled, new_open = UI.CollapsingHeader(
                "cl_cat_" .. key, cat.title or key, is_open)
            if toggled then
                cat_open[key] = new_open
                App.SaveCfg()  -- persist open state (explicit change, not hot path)
                is_open = new_open
            end

            if is_open then
                UI.Indent(theme.pad_small)
                UI.BeginWrap("cl_wrap_" .. key, { gap = theme.gap })
                for ii = 1, #items do
                    local item = items[ii]
                    local lbl = item.label or "?"
                    local bid = "cl_chip_" .. key .. "_" .. ii
                    local clicked = UI.Button(bid, lbl)

                    -- Tooltip = detail text.
                    if item.detail and item.detail ~= "" and UI.IsItemHovered() then
                        UI.Tooltip(item.detail)
                    end

                    -- Double-click → replace on selection; single → preview + arm.
                    if UI.IsItemDoubleClicked() then
                        if can_replace and item.chord then
                            App.ReplaceSelected(item.chord)
                        elseif item.chord then
                            App.ArmChord(item.chord, "suggest")
                        end
                    elseif clicked then
                        if item.chord then
                            App.ArmChord(item.chord, "suggest")
                        end
                    end
                end
                UI.EndWrap()
                UI.Unindent(theme.pad_small)
                UI.Spacing(theme.gap)
            end
        end
    end

    UI.EndChild()
end

return M
