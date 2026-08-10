Core = exports.vorp_core:GetCore()
local utils = exports['bcc-utils'].initiate()
DBG = utils.Debug:Get('bcc-hunting-wagon', Config.development.enabled)
if DBG then DBG:Enable() end

ServerUtils = {}

function ServerUtils.getCharacter(sourceId, context)
    local user = Core.getUser(sourceId)
    local character = user and user.getUsedCharacter
    local charId = character and tonumber(character.charIdentifier)
    if not charId then
        DBG:Error(('Character unavailable for %s. Source: %s'):format(context, sourceId))
        return nil, nil
    end
    return character, charId
end
