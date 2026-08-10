Core = exports.vorp_core:GetCore()
FeatherMenu = exports['feather-menu'].initiate()
local utils = exports['bcc-utils'].initiate()
DBG = utils.Debug:Get('bcc-hunting-wagon', Config.development.enabled)
if DBG then DBG:Enable() end

MyWagon, MyWagonId, MyWagonModel = 0, nil, nil

exports['bcc-wagons']:RegisterWagonFeature(Config.huntingWagon.model or 'huntercart01', {
    resource = GetCurrentResourceName(),
    persistentWhenDistant = true,
})

local function syncActiveWagon(data)
    if type(data) ~= 'table' then
        MyWagon, MyWagonId, MyWagonModel = 0, nil, nil
        return false
    end
    MyWagon = tonumber(data.entity) or 0
    MyWagonId = tonumber(data.id)
    MyWagonModel = data.model
    return MyWagon ~= 0 and DoesEntityExist(MyWagon)
end

function LoadModel(modelHash, label)
    if HasModelLoaded(modelHash) then return true end
    RequestModel(modelHash)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(modelHash) and GetGameTimer() < deadline do Wait(25) end
    if HasModelLoaded(modelHash) then return true end
    DBG:Error(('Failed to load model: %s'):format(tostring(label or modelHash)))
    return false
end

AddEventHandler('bcc-wagons:client:wagonSpawned', function(data)
    if syncActiveWagon(data) then InitializeHuntingWagon(MyWagon) end
end)

AddEventHandler('bcc-wagons:client:wagonStreamedIn', function(data)
    if syncActiveWagon(data) then InitializeHuntingWagon(MyWagon) end
end)

AddEventHandler('bcc-wagons:client:wagonReturning', function(data)
    if type(data) == 'table' and tonumber(data.id) == tonumber(MyWagonId) then
        MyWagon, MyWagonId, MyWagonModel = 0, nil, nil
    end
end)

CreateThread(function()
    Wait(500)
    local active = exports['bcc-wagons']:GetActiveWagon()
    if syncActiveWagon(active) then InitializeHuntingWagon(MyWagon) end
end)
