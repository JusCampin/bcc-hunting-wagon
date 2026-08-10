local NATIVE_SET_PLAYER_HUNTING_WAGON <const> = 0x6A4404BDFA62CE2C
local NATIVE_ADD_ADDITIONAL_PROP_SET_FOR_VEHICLE <const> = 0x75F90E4051CC084C
local NATIVE_SET_BATCH_TARP_HEIGHT <const> = 0x31F343383F19C987

local function isValidEntity(entity)
    return entity and entity ~= 0 and DoesEntityExist(entity)
end

function IsActiveHuntingWagon()
    local settings = Config.huntingWagon
    return settings.enabled == true
        and MyWagonModel == (settings.model or 'huntercart01')
        and isValidEntity(MyWagon)
end

function SetHuntingWagonTarpHeight(height, immediately)
    if not IsActiveHuntingWagon() then return false end
    local tarpHeight = math.max(0.0, math.min(1.0, tonumber(height) or 0.0))
    Citizen.InvokeNative(NATIVE_SET_BATCH_TARP_HEIGHT, MyWagon, tarpHeight, immediately == true)
    return true, tarpHeight
end

function InitializeHuntingWagon(wagon)
    local settings = Config.huntingWagon
    if settings.enabled ~= true
        or MyWagonModel ~= (settings.model or 'huntercart01')
        or not isValidEntity(wagon) then return false end

    if settings.nativeInteractionEnabled == true then
        Citizen.InvokeNative(NATIVE_SET_PLAYER_HUNTING_WAGON, PlayerId(), wagon)
        DBG:Warning('Experimental native hunting-wagon interaction is enabled.')
    end

    Citizen.InvokeNative(
        NATIVE_ADD_ADDITIONAL_PROP_SET_FOR_VEHICLE,
        wagon,
        joaat(settings.tarpPropSet or 'pg_mp005_huntingWagonTarp01')
    )

    CreateThread(function()
        local delay = math.max(0, tonumber(settings.tarpInitializationDelayMs) or 500)
        Wait(delay)
        if MyWagon ~= wagon or not isValidEntity(wagon) then return end
        SetHuntingWagonTarpHeight(settings.initialTarpHeight or 0.0, true)
        Wait(delay)
        if MyWagon ~= wagon or not isValidEntity(wagon) then return end
        SetHuntingWagonTarpHeight(settings.initialTarpHeight or 0.0, true)
        RefreshHuntingCargo()
    end)

    DBG:Info(('Initialized hunting wagon behavior for %s.'):format(MyWagonModel))
    return true
end
