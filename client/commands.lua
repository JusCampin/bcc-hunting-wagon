RegisterCommand('wagonTarp', function(_, args)
    if not Config.development.enabled then return end
    local height = tonumber(args[1])
    if not height then return Core.NotifyRightTip('Usage: /wagonTarp 0.0-1.0', 4000) end
    local updated, applied = SetHuntingWagonTarpHeight(height, false)
    if not updated then return Core.NotifyRightTip('Spawn your Hunter Cart first.', 4000) end
    Core.NotifyRightTip(('Hunting wagon tarp height: %.2f'):format(applied), 3000)
end, false)

RegisterCommand('wagonHuntingClear', function()
    if not Config.development.enabled then return end
    if not ClearHuntingCargoForTesting() then
        Core.NotifyRightTip('Spawn your Hunter Cart before clearing its cargo.', 4000)
    end
end, false)
