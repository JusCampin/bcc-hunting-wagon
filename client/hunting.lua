local NATIVE_GET_FIRST_ENTITY_PED_IS_CARRYING <const> = 0xD806CD2A4F2C2996
local NATIVE_TASK_PLACE_CARRIED_ENTITY_AT_COORD <const> = 0xC7F0B43DCDC57E3D
local NATIVE_PROMPT_HAS_HOLD_MODE_COMPLETED <const> = 0xE0F65F0640EF0617
local NATIVE_PROMPT_CONTEXT_SET_POINT <const> = 0xAE84C5EE2C384FB3
local NATIVE_PROMPT_CONTEXT_SET_RADIUS <const> = 0x0C718001B77CA468
local NATIVE_GET_PED_QUALITY <const> = 0x7BCC6087D130312A
local NATIVE_GET_PED_DAMAGE_CLEANLINESS <const> = 0x88EFFED5FE8B0B4A
local NATIVE_GET_CARCASS_PROVISION <const> = 0x31FEF6A20F00B963
local NATIVE_GET_PED_META_OUTFIT_HASH <const> = 0x30569F348D126A5A
local NATIVE_GET_NUM_COMPONENTS_IN_PED <const> = 0x90403E8107B60E81
local NATIVE_GET_META_PED_ASSET_GUIDS <const> = 0xA9C28516A6DC9D56
local NATIVE_GET_META_PED_ASSET_TINT <const> = 0xE7998FEC53A33BBE
local NATIVE_SET_META_PED_TAG <const> = 0xBC6DF00D7A4A6819
local NATIVE_FIX_PED_OUTFIT <const> = 0xAAB86462966168CE
local NATIVE_UPDATE_PED_VARIATION <const> = 0xCC8CA3E88256E58F
local NATIVE_SET_PED_QUALITY <const> = 0xCE6B874286D640BB
local NATIVE_SET_PED_DAMAGE_CLEANLINESS <const> = 0x7528720101A807A5
local NATIVE_SET_ENTITY_HEALTH <const> = 0xAC2767ED8BDFAB15
local NATIVE_SET_ENTITY_FULLY_LOOTED <const> = 0x6BCF5F3D8FFE988D
local HuntingLoadPrompt = 0
local HuntingUnloadPrompt = 0
local isLoadingCarcass = false
local huntingCargoUsed = 0
local huntingCargoCapacity = 1
local gatheredCarcasses = {}
local observedCarcassQuality = {}
local loadPromptWasEnabled = false
local unloadPromptWasEnabled = false

local function entityExists(entity)
    return entity and entity ~= 0 and DoesEntityExist(entity)
end

local function getLiveCarcassQuality(carcass)
    local pedQuality = tonumber(Citizen.InvokeNative(
        NATIVE_GET_PED_QUALITY,
        carcass,
        Citizen.ResultAsInteger()
    ))
    local damageCleanliness = tonumber(Citizen.InvokeNative(
        NATIVE_GET_PED_DAMAGE_CLEANLINESS,
        carcass,
        Citizen.ResultAsInteger()
    ))
    if pedQuality == nil or pedQuality < 0 then return nil end
    pedQuality = math.max(0, math.min(2, pedQuality))
    if damageCleanliness == nil or damageCleanliness < 0 then return pedQuality end
    return math.min(pedQuality, math.max(0, math.min(2, damageCleanliness)))
end

local function resolveCarcassQuality(carcass)
    if not entityExists(carcass) then return nil end
    local state = NetworkGetEntityIsNetworked(carcass) and Entity(carcass).state or nil
    local retainedQuality = state and tonumber(state.bccWagonQuality) or nil
    local restored = state and state.bccWagonRestored == true
    local skinned = gatheredCarcasses[carcass] == true
        or (state and state.bccWagonSkinned == true)
    if (restored or skinned) and retainedQuality ~= nil then return retainedQuality end

    local provisionHash = Citizen.InvokeNative(
        NATIVE_GET_CARCASS_PROVISION,
        carcass,
        Citizen.ResultAsInteger()
    )
    local provisionQuality = exports['bcc-animal-data']:GetQualityFromProvision(provisionHash)
    local liveQuality = getLiveCarcassQuality(carcass)
    local resolvedQuality = math.max(0, math.min(2,
        provisionQuality
            or liveQuality
            or observedCarcassQuality[carcass]
            or retainedQuality
            or 0
    ))
    return resolvedQuality
end

local function refreshCarcassQuality(carcass)
    local quality = resolveCarcassQuality(carcass)
    if quality == nil then return nil end
    observedCarcassQuality[carcass] = quality
    if NetworkGetEntityIsNetworked(carcass) then
        pcall(function()
            Entity(carcass).state:set('bccWagonQuality', quality, true)
        end)
    end
    return quality
end

exports('RefreshCarcassQuality', refreshCarcassQuality)

local function markGatheredCarcass(carcass, quality)
    if not entityExists(carcass) or GetEntityType(carcass) ~= 1 or IsPedHuman(carcass) then
        return false
    end

    gatheredCarcasses[carcass] = true
    if quality ~= nil then observedCarcassQuality[carcass] = quality end
    if NetworkGetEntityIsNetworked(carcass) then
        -- A carcass may disappear during the skinning transition. Protect the
        -- event dispatcher from a state-bag write against an invalid handle.
        pcall(function()
            Entity(carcass).state:set('bccWagonSkinned', true, true)
            if quality ~= nil then
                Entity(carcass).state:set('bccWagonQuality', quality, true)
            end
        end)
    end
    return true
end

local function followGatheredReplacement(modelHash, origin, quality)
    CreateThread(function()
        for _, delay in ipairs({ 100, 400, 1000, 2000 }) do
            Wait(delay)
            local closest, closestDistance
            for _, ped in ipairs(GetGamePool('CPed')) do
                if entityExists(ped)
                    and GetEntityType(ped) == 1
                    and not IsPedHuman(ped)
                    and IsEntityDead(ped)
                    and GetEntityModel(ped) == modelHash
                then
                    local distance = #(GetEntityCoords(ped) - origin)
                    if distance <= 6.0 and (not closestDistance or distance < closestDistance) then
                        closest, closestDistance = ped, distance
                    end
                end
            end
            if closest then markGatheredCarcass(closest, quality) end
        end
    end)
end

-- EVENT_LOOT_COMPLETE is emitted after skinning or plucking. Some species
-- replace their carcass entity during this transition, so mark the event
-- entity and then follow a nearby replacement with the same model.
local function handleLootComplete(data)
    local looter = tonumber(data and data.looter) or 0
    local carcass = tonumber(data and data.carcass) or 0
    local succeeded = tonumber(data and data.succeeded) or 0

    if looter ~= PlayerPedId() or succeeded ~= 1 or not entityExists(carcass) then return end
    if GetEntityType(carcass) ~= 1 or IsPedHuman(carcass) then return end

    local ok, err = pcall(function()
        local modelHash = GetEntityModel(carcass)
        local origin = GetEntityCoords(carcass)
        local provisionHash = Citizen.InvokeNative(
            NATIVE_GET_CARCASS_PROVISION,
            carcass,
            Citizen.ResultAsInteger()
        )
        local provisionQuality = exports['bcc-animal-data']:GetQualityFromProvision(provisionHash)
        local retainedQuality = NetworkGetEntityIsNetworked(carcass)
            and tonumber(Entity(carcass).state.bccWagonQuality) or nil
        local gatheredQuality = retainedQuality
            or observedCarcassQuality[carcass]
            or provisionQuality

        markGatheredCarcass(carcass, gatheredQuality)
        followGatheredReplacement(modelHash, origin, gatheredQuality)

    end)
    if not ok and Config.development and Config.development.enabled then
        DBG:Error(('Hunting gather processing failed: %s'):format(tostring(err)))
    end
end

CreateThread(function()
    while true do
        Wait(0)
        local eventCount = GetNumberOfEvents(0)
        for index = 0, eventCount - 1 do
            if GetEventAtIndex(0, index) == 1376140891 then -- EVENT_LOOT_COMPLETE
                local eventData = EventDataView.New(24)
                local exists = Citizen.InvokeNative(
                    0x57EC5FA4D4D6AFCA, -- GET_EVENT_DATA
                    0,
                    index,
                    eventData:Buffer(),
                    3
                )
                if exists then
                    handleLootComplete({
                        looter = eventData:GetInt32(0),
                        carcass = eventData:GetInt32(8),
                        succeeded = eventData:GetInt32(16),
                    })
                end
            end
        end
    end
end)

-- Cache the final quality (base ped quality limited by damage cleanliness)
-- before skinning can replace the carcass entity, then preserve it through
-- carrying, attachment, and wagon storage.
CreateThread(function()
    while true do
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local carriedEntity = Citizen.InvokeNative(NATIVE_GET_FIRST_ENTITY_PED_IS_CARRYING, playerPed)
        local activeEntities = {}

        for _, ped in ipairs(GetGamePool('CPed')) do
            if ped ~= playerPed
                and entityExists(ped)
                and not IsPedHuman(ped)
                and (IsEntityDead(ped) or IsPedFatallyInjured(ped))
            then
                activeEntities[ped] = true
                if gatheredCarcasses[ped] ~= true then
                    local coords = GetEntityCoords(ped)
                    if #(playerCoords - coords) <= 25.0
                        and ped ~= carriedEntity
                        and not IsEntityAttached(ped)
                    then
                        local state = NetworkGetEntityIsNetworked(ped) and Entity(ped).state or nil
                        local restored = state and state.bccWagonRestored == true
                        if not restored then
                            -- Damage cleanliness can lower the displayed rating
                            -- below the animal's original ped quality.
                            observedCarcassQuality[ped] = getLiveCarcassQuality(ped) or 0
                            if NetworkGetEntityIsNetworked(ped) then
                                pcall(function()
                                    Entity(ped).state:set(
                                        'bccWagonQuality',
                                        observedCarcassQuality[ped],
                                        true
                                    )
                                end)
                            end
                        elseif observedCarcassQuality[ped] == nil then
                            observedCarcassQuality[ped] = tonumber(state.bccWagonQuality)
                        end
                    end
                end
            end
        end

        for ped in pairs(observedCarcassQuality) do
            if not activeEntities[ped] then observedCarcassQuality[ped] = nil end
        end
        for ped in pairs(gatheredCarcasses) do
            if not activeEntities[ped] then gatheredCarcasses[ped] = nil end
        end

        Wait(250)
    end
end)

local function getCarcassMetaTags(carcass)
    local tags = {}
    local count = Citizen.InvokeNative(
        NATIVE_GET_NUM_COMPONENTS_IN_PED,
        carcass,
        Citizen.ResultAsInteger()
    )

    for index = 0, math.max(0, (tonumber(count) or 0) - 1) do
        local drawable, albedo, normal, material = Citizen.InvokeNative(
            NATIVE_GET_META_PED_ASSET_GUIDS,
            carcass,
            index,
            Citizen.PointerValueInt(),
            Citizen.PointerValueInt(),
            Citizen.PointerValueInt(),
            Citizen.PointerValueInt()
        )
        local palette, tint0, tint1, tint2 = Citizen.InvokeNative(
            NATIVE_GET_META_PED_ASSET_TINT,
            carcass,
            index,
            Citizen.PointerValueInt(),
            Citizen.PointerValueInt(),
            Citizen.PointerValueInt(),
            Citizen.PointerValueInt()
        )
        tags[#tags + 1] = {
            drawable = drawable,
            albedo = albedo,
            normal = normal,
            material = material,
            palette = palette,
            tint0 = tint0,
            tint1 = tint1,
            tint2 = tint2,
        }
    end
    return tags
end

local function applyCarcassMetaTags(carcass, tags)
    if type(tags) ~= 'table' then return 0 end
    local applied = 0
    for _, tag in pairs(tags) do
        if type(tag) == 'table' and tonumber(tag.drawable) then
            Citizen.InvokeNative(
                NATIVE_SET_META_PED_TAG,
                carcass,
                tonumber(tag.drawable) or 0,
                tonumber(tag.albedo) or 0,
                tonumber(tag.normal) or 0,
                tonumber(tag.material) or 0,
                tonumber(tag.palette) or 0,
                tonumber(tag.tint0) or 0,
                tonumber(tag.tint1) or 0,
                tonumber(tag.tint2) or 0
            )
            applied = applied + 1
        end
    end
    if applied > 0 then
        Citizen.InvokeNative(NATIVE_FIX_PED_OUTFIT, carcass, true)
        Citizen.InvokeNative(
            NATIVE_UPDATE_PED_VARIATION,
            carcass,
            false,
            true,
            true,
            true,
            false
        )
    end
    return applied
end

local function createLoadPrompt()
    if HuntingLoadPrompt ~= 0 then return end

    local settings = Config.huntingWagon or {}
    HuntingLoadPrompt = UiPromptRegisterBegin()
    UiPromptSetControlAction(HuntingLoadPrompt, settings.loadPromptControl or 0x760A9C6F)
    UiPromptSetText(HuntingLoadPrompt, CreateVarString(10, 'LITERAL_STRING', _U('huntingCargoPrompt')))
    UiPromptSetVisible(HuntingLoadPrompt, true)
    UiPromptSetEnabled(HuntingLoadPrompt, true)
    UiPromptSetHoldMode(HuntingLoadPrompt, tonumber(settings.loadPromptHoldMs) or 1000)
    Citizen.InvokeNative(NATIVE_PROMPT_CONTEXT_SET_POINT, HuntingLoadPrompt, 0.0, 0.0, 0.0)
    Citizen.InvokeNative(
        NATIVE_PROMPT_CONTEXT_SET_RADIUS,
        HuntingLoadPrompt,
        tonumber(settings.interactionDistance) or 2.0
    )
    UiPromptRegisterEnd(HuntingLoadPrompt)

    HuntingUnloadPrompt = UiPromptRegisterBegin()
    UiPromptSetControlAction(HuntingUnloadPrompt, settings.loadPromptControl or 0x760A9C6F)
    UiPromptSetText(HuntingUnloadPrompt, CreateVarString(10, 'LITERAL_STRING', _U('huntingCargoUnloadPrompt')))
    UiPromptSetVisible(HuntingUnloadPrompt, true)
    UiPromptSetEnabled(HuntingUnloadPrompt, true)
    UiPromptSetHoldMode(HuntingUnloadPrompt, tonumber(settings.loadPromptHoldMs) or 1000)
    Citizen.InvokeNative(NATIVE_PROMPT_CONTEXT_SET_POINT, HuntingUnloadPrompt, 0.0, 0.0, 0.0)
    Citizen.InvokeNative(
        NATIVE_PROMPT_CONTEXT_SET_RADIUS,
        HuntingUnloadPrompt,
        tonumber(settings.interactionDistance) or 2.0
    )
    UiPromptRegisterEnd(HuntingUnloadPrompt)
end

local function setHuntingPromptState(loadEnabled, unloadEnabled)
    if not loadEnabled and loadPromptWasEnabled then
        UiPromptRestartModes(HuntingLoadPrompt)
        Citizen.InvokeNative(
            NATIVE_PROMPT_CONTEXT_SET_POINT,
            HuntingLoadPrompt,
            0.0,
            0.0,
            -1000.0
        )
    end
    if not unloadEnabled and unloadPromptWasEnabled then
        UiPromptRestartModes(HuntingUnloadPrompt)
        Citizen.InvokeNative(
            NATIVE_PROMPT_CONTEXT_SET_POINT,
            HuntingUnloadPrompt,
            0.0,
            0.0,
            -1000.0
        )
    end
    UiPromptSetEnabled(HuntingLoadPrompt, loadEnabled)
    UiPromptSetVisible(HuntingLoadPrompt, loadEnabled)
    UiPromptSetEnabled(HuntingUnloadPrompt, unloadEnabled)
    UiPromptSetVisible(HuntingUnloadPrompt, unloadEnabled)
    loadPromptWasEnabled = loadEnabled
    unloadPromptWasEnabled = unloadEnabled
end

function ResetHuntingPrompts()
    if HuntingLoadPrompt == 0 or HuntingUnloadPrompt == 0 then return end
    loadPromptWasEnabled = true
    unloadPromptWasEnabled = true
    setHuntingPromptState(false, false)
end

local function carriedDeadAnimal(playerPed)
    local carried = Citizen.InvokeNative(
        NATIVE_GET_FIRST_ENTITY_PED_IS_CARRYING,
        playerPed,
        Citizen.ResultAsInteger()
    )

    if not entityExists(carried) or not IsEntityAPed(carried) then return 0 end
    if IsPedAPlayer(carried) or IsPedHuman(carried) or not IsEntityDead(carried) then return 0 end
    return carried
end

local function huntingWagonRequest()
    if not IsActiveHuntingWagon() or not MyWagonId then return nil end
    local wagonNetId = NetworkGetNetworkIdFromEntity(MyWagon)
    if not wagonNetId or wagonNetId == 0 then return nil end
    return { wagonId = MyWagonId, wagonNetId = wagonNetId }
end

local function applyCargoStatus(status)
    if type(status) ~= 'table' then return end
    local used = math.max(0, tonumber(status.used) or 0)
    local capacity = math.max(1, tonumber(status.capacity) or 1)
    huntingCargoUsed = used
    huntingCargoCapacity = capacity
    SetHuntingWagonTarpHeight(used / capacity, false)
end

function GetHuntingWagonRequest()
    return huntingWagonRequest()
end

function ApplyHuntingCargoStatus(status)
    applyCargoStatus(status)
end

function IsHuntingCargoBusy()
    return isLoadingCarcass
end

function RefreshHuntingCargo()
    local request = huntingWagonRequest()
    if not request then return end

    Core.Callback.TriggerAsync('bcc-hunting-wagon:GetHuntingCargoStatus', function(status)
        if not IsActiveHuntingWagon() then return end
        applyCargoStatus(status)
    end, request)
end

RegisterNetEvent('bcc-hunting-wagon:client:RefreshCargo', function()
    RefreshHuntingCargo()
end)

function ClearHuntingCargoForTesting()
    local request = huntingWagonRequest()
    if not request then return false end

    Core.Callback.TriggerAsync('bcc-hunting-wagon:ClearHuntingCargoForTesting', function(success, status)
        if not success then
            Core.NotifyRightTip(_U('huntingCargoLoadFailed'), 4000)
            return
        end
        applyCargoStatus(status)
        Core.NotifyRightTip('Hunting cargo cleared for testing.', 4000)
    end, request)
    return true
end

local function deleteLoadedCarcass(playerPed, carcass)
    local settings = Config.huntingWagon or {}
    local rear = settings.rearOffset or {}
    local destination = GetOffsetFromEntityInWorldCoords(
        MyWagon,
        tonumber(rear.x) or 0.0,
        tonumber(rear.y) or -2.25,
        tonumber(rear.z) or 0.0
    )

    Citizen.InvokeNative(
        NATIVE_TASK_PLACE_CARRIED_ENTITY_AT_COORD,
        playerPed,
        carcass,
        destination.x,
        destination.y,
        destination.z,
        1.0,
        0
    )
    Wait(math.max(500, tonumber(settings.loadAnimationMs) or 1600))

    if not entityExists(carcass) then return end
    gatheredCarcasses[carcass] = nil
    observedCarcassQuality[carcass] = nil
    NetworkRequestControlOfEntity(carcass)
    local deadline = GetGameTimer() + 1000
    while not NetworkHasControlOfEntity(carcass) and GetGameTimer() < deadline do
        Wait(0)
        NetworkRequestControlOfEntity(carcass)
    end

    SetEntityAsMissionEntity(carcass, true, true)
    DetachEntity(carcass, true, true)
    DeleteEntity(carcass)
end

local function loadCarcass(carcass)
    if isLoadingCarcass then return end
    local request = huntingWagonRequest()
    if not request then return end

    isLoadingCarcass = true
    local modelHash = GetEntityModel(carcass)
    local netId = NetworkGetNetworkIdFromEntity(carcass)
    request.modelHash = modelHash
    request.quality = refreshCarcassQuality(carcass) or 0
    local restoredSkinnedState = NetworkGetEntityIsNetworked(carcass)
        and Entity(carcass).state.bccWagonSkinned == true
    request.isSkinned = gatheredCarcasses[carcass] == true or restoredSkinnedState
    request.metaTags = request.isSkinned and getCarcassMetaTags(carcass) or nil
    request.outfitHash = Citizen.InvokeNative(
        NATIVE_GET_PED_META_OUTFIT_HASH,
        carcass,
        Citizen.ResultAsInteger()
    )
    -- Network IDs are recycled by RedM and are therefore not durable cargo
    -- identifiers. Include the entity handle and load time so a new carcass
    -- cannot collide with an older row that used the same network ID.
    local loadNonce = GetGameTimer()
    request.carcassKey = netId and netId ~= 0
        and ('net:%d:%d:%d'):format(netId, carcass, loadNonce)
        or ('local:%d:%d:%d'):format(modelHash, carcass, loadNonce)

    Core.Callback.TriggerAsync('bcc-hunting-wagon:LoadHuntingCarcass', function(success, reason, status)
        if not success then
            if Config.development and Config.development.enabled then
                DBG:Warning(('Hunting carcass load rejected: reason=%s key=%s model=%s'):format(
                    tostring(reason),
                    tostring(request.carcassKey),
                    tostring(request.modelHash)
                ))
            end
            Core.NotifyRightTip(
                reason == 'full' and _U('huntingCargoFull') or _U('huntingCargoLoadFailed'),
                4000
            )
            applyCargoStatus(status)
            isLoadingCarcass = false
            return
        end

        deleteLoadedCarcass(PlayerPedId(), carcass)
        applyCargoStatus(status)
        Core.NotifyRightTip(_U('huntingCargoLoaded', status.used, status.capacity), 4000)
        isLoadingCarcass = false
    end, request)
end

local function finalizeUnload(token, spawned, unloadedCarcass)
    Core.Callback.TriggerAsync('bcc-hunting-wagon:FinalizeHuntingCarcassUnload', function(success, status)
        applyCargoStatus(status)
        if not success then
            if entityExists(unloadedCarcass) then DeleteEntity(unloadedCarcass) end
            Core.NotifyRightTip(_U('huntingCargoUnloadFailed'), 4000)
            isLoadingCarcass = false
            return
        end

        Core.NotifyRightTip(
            _U('huntingCargoUnloaded', huntingCargoUsed, huntingCargoCapacity),
            4000
        )
        isLoadingCarcass = false
    end, { token = token, spawned = spawned })
end

function UnloadHuntingCarcass(cargoId)
    if isLoadingCarcass then return end
    local request = huntingWagonRequest()
    if not request then return end
    request.cargoId = tonumber(cargoId)
    isLoadingCarcass = true

    Core.Callback.TriggerAsync('bcc-hunting-wagon:ReserveHuntingCarcassUnload', function(success, reservation)
        if not success or type(reservation) ~= 'table' then
            Core.NotifyRightTip(_U('huntingCargoUnloadFailed'), 4000)
            isLoadingCarcass = false
            return
        end

        local modelHash = tonumber(reservation.modelHash)
        if not modelHash or not LoadModel(modelHash, tostring(modelHash)) then
            finalizeUnload(reservation.token, false)
            return
        end

        local settings = Config.huntingWagon or {}
        local rear = settings.rearOffset or {}
        local spawnCoords = GetOffsetFromEntityInWorldCoords(
            MyWagon,
            tonumber(rear.x) or 0.0,
            (tonumber(rear.y) or -2.25) - 0.75,
            (tonumber(rear.z) or 0.0) + 0.25
        )
        local carcass = CreatePed(
            modelHash,
            spawnCoords.x,
            spawnCoords.y,
            spawnCoords.z,
            GetEntityHeading(MyWagon),
            true,
            true
        )
        SetModelAsNoLongerNeeded(modelHash)

        if not entityExists(carcass) then
            finalizeUnload(reservation.token, false)
            return
        end

        local reservationIsSkinned = reservation.isSkinned == true
            or tonumber(reservation.isSkinned) == 1

        SetEntityAsMissionEntity(carcass, true, true)
        local outfitHash = tonumber(reservation.outfitHash) or 0
        if not reservationIsSkinned then
            Citizen.InvokeNative(0x283978A15512B2FE, carcass, true) -- SetRandomOutfitVariation
            Wait(0)
            if outfitHash ~= 0 and EquipMetaPedOutfit then
                EquipMetaPedOutfit(carcass, outfitHash)
                Citizen.InvokeNative(NATIVE_FIX_PED_OUTFIT, carcass, true)
                Citizen.InvokeNative(
                    NATIVE_UPDATE_PED_VARIATION,
                    carcass,
                    false,
                    true,
                    true,
                    true,
                    false
                )
            end
        end

        SetEntityVisible(carcass, true, false)
        ResetEntityAlpha(carcass)
        local nativeQuality = math.max(0, math.min(2, tonumber(reservation.quality) or 0))

        -- Quality must be present while the living ped transitions into a
        -- carcass. Setting it only after death can leave the interaction UI
        -- without a star rating even though the native later reads correctly.
        -- Quality remains in the game's native 0=poor, 1=good, 2=perfect
        -- format throughout storage and restoration.
        Citizen.InvokeNative(NATIVE_SET_PED_QUALITY, carcass, nativeQuality)
        Citizen.InvokeNative(NATIVE_SET_PED_DAMAGE_CLEANLINESS, carcass, nativeQuality)
        -- Do not attribute the reconstructed death to the player. The wrapper's
        -- damage-source argument makes the game evaluate a fresh kill and can
        -- immediately reduce the restored quality by one star.
        Citizen.InvokeNative(NATIVE_SET_ENTITY_HEALTH, carcass, 0)
        Wait(0)
        Citizen.InvokeNative(NATIVE_SET_PED_QUALITY, carcass, nativeQuality)
        Citizen.InvokeNative(NATIVE_SET_PED_DAMAGE_CLEANLINESS, carcass, nativeQuality)

        if NetworkGetEntityIsNetworked(carcass) then
            Entity(carcass).state:set('bccWagonQuality', nativeQuality, true)
            Entity(carcass).state:set('bccWagonRestored', true, true)
        end

        if reservationIsSkinned then
            Wait(1000)
            Citizen.InvokeNative(NATIVE_SET_ENTITY_FULLY_LOOTED, carcass, true)
            applyCarcassMetaTags(carcass, reservation.metaTags)

            -- Preserve the logical state if this reconstructed entity is loaded
            -- into the wagon again before it is removed by the game.
            if NetworkGetEntityIsNetworked(carcass) then
                Entity(carcass).state:set('bccWagonSkinned', true, true)
            end
        end
        PlaceEntityOnGroundProperly(carcass, true)
        finalizeUnload(reservation.token, true, carcass)
    end, request)
end

CreateThread(function()
    createLoadPrompt()
    setHuntingPromptState(false, false)

    while true do
        local sleep = 750
        local loadPromptEnabled = false
        local unloadPromptEnabled = false
        if not isLoadingCarcass and IsActiveHuntingWagon() and GetEntitySpeed(MyWagon) < 0.5 then
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local carcass = carriedDeadAnimal(playerPed)
            if carcass ~= 0 or huntingCargoUsed > 0 then
                local settings = Config.huntingWagon or {}
                local rear = settings.rearOffset or {}
                local rearCoords = GetOffsetFromEntityInWorldCoords(
                    MyWagon,
                    tonumber(rear.x) or 0.0,
                    tonumber(rear.y) or -2.25,
                    tonumber(rear.z) or 0.0
                )

                if #(playerCoords - rearCoords)
                    <= (tonumber(settings.interactionDistance) or 2.25) then
                    sleep = 0
                    Citizen.InvokeNative(
                        NATIVE_PROMPT_CONTEXT_SET_POINT,
                        HuntingLoadPrompt,
                        rearCoords.x,
                        rearCoords.y,
                        rearCoords.z
                    )
                    Citizen.InvokeNative(
                        NATIVE_PROMPT_CONTEXT_SET_POINT,
                        HuntingUnloadPrompt,
                        rearCoords.x,
                        rearCoords.y,
                        rearCoords.z
                    )
                    if carcass ~= 0 then
                        loadPromptEnabled = true
                        if Citizen.InvokeNative(NATIVE_PROMPT_HAS_HOLD_MODE_COMPLETED, HuntingLoadPrompt) then
                            loadCarcass(carcass)
                        end
                    else
                        unloadPromptEnabled = true
                        if Citizen.InvokeNative(NATIVE_PROMPT_HAS_HOLD_MODE_COMPLETED, HuntingUnloadPrompt) then
                        OpenHuntingCargoMenu()
                        end
                    end
                end
            end
        end
        setHuntingPromptState(loadPromptEnabled, unloadPromptEnabled)
        Wait(sleep)
    end
end)
