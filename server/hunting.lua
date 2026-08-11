local CARGO_TABLE <const> = 'bcc_wagon_hunting_cargo'
local ActiveLoads = {}
local PendingUnloads = {}
local ButcherReservations = {}

local function encodeMetaTags(tags)
    if type(tags) ~= 'table' then return nil end
    local sanitized = {}
    for _, tag in pairs(tags) do
        if #sanitized >= 64 then break end
        if type(tag) == 'table' and tonumber(tag.drawable) then
            sanitized[#sanitized + 1] = {
                drawable = tonumber(tag.drawable) or 0,
                albedo = tonumber(tag.albedo) or 0,
                normal = tonumber(tag.normal) or 0,
                material = tonumber(tag.material) or 0,
                palette = tonumber(tag.palette) or 0,
                tint0 = tonumber(tag.tint0) or 0,
                tint1 = tonumber(tag.tint1) or 0,
                tint2 = tonumber(tag.tint2) or 0,
            }
        end
    end
    if #sanitized == 0 then return nil end
    return json.encode(sanitized)
end

local function decodeMetaTags(value)
    if type(value) == 'table' then return value end
    if type(value) ~= 'string' or value == '' then return {} end
    local success, decoded = pcall(json.decode, value)
    return success and type(decoded) == 'table' and decoded or {}
end

local function huntingSettings()
    return Config.huntingWagon or {}
end

local function cargoCapacity()
    return math.max(1, math.floor(tonumber(huntingSettings().capacity) or 6))
end

local function cargoStatus(wagonId, callback)
    MySQL.scalar(
        ('SELECT COALESCE(SUM(`cargo_units`), 0) FROM `%s` WHERE `wagon_id` = ?'):format(CARGO_TABLE),
        { wagonId },
        function(used)
            callback(math.max(0, tonumber(used) or 0), cargoCapacity())
        end
    )
end

local function getAnimalSize(modelHash)
    local settings = huntingSettings()
    local fallback = math.max(1, math.floor(tonumber(settings.defaultAnimalSize) or 1))
    local size = exports['bcc-animal-data']:GetCargoUnits(modelHash, fallback)
    return math.max(1, math.floor(tonumber(size) or fallback))
end

local function validateOwnedHuntingWagonRecord(src, charId, data, callback)
    local wagonId = type(data) == 'table' and tonumber(data.wagonId)
    if not wagonId then return callback(false) end
    local owned = exports['bcc-wagons']:GetOwnedWagon(
        src,
        wagonId,
        huntingSettings().model or 'huntercart01'
    )
    callback(owned ~= nil, wagonId)
end

local function validateOwnedHuntingWagon(src, charId, data, callback)
    validateOwnedHuntingWagonRecord(src, charId, data, function(valid, wagonId)
        if not valid then
            DBG:Warning(('Hunting cargo rejected: wagon %s is not a Hunter Cart.'):format(wagonId))
            return callback(false)
        end

        local playerPed = GetPlayerPed(src)
        if playerPed == 0 then return callback(false) end

        local playerCoords = GetEntityCoords(playerPed)
        local nearbyWagon
        for _, vehicle in ipairs(GetAllVehicles()) do
            if tonumber(Entity(vehicle).state.myWagonId) == wagonId
                and #(playerCoords - GetEntityCoords(vehicle)) <= 6.0 then
                nearbyWagon = vehicle
                break
            end
        end

        if not nearbyWagon then
            DBG:Warning(('Hunting cargo rejected: owned wagon %s was not synchronized nearby.'):format(wagonId))
            return callback(false)
        end

        callback(true, wagonId)
    end)
end

Core.Callback.Register('bcc-hunting-wagon:GetHuntingCargoStatus', function(source, cb, data)
    local _, charId = ServerUtils.getCharacter(source, 'hunting cargo status')
    if not charId then return cb(false) end

    validateOwnedHuntingWagonRecord(source, charId, data, function(valid, wagonId)
        if not valid then return cb(false) end
        cargoStatus(wagonId, function(used, capacity)
            cb({ used = used, capacity = capacity })
        end)
    end)
end)

Core.Callback.Register('bcc-hunting-wagon:LoadHuntingCarcass', function(source, cb, data)
    local src = source
    local _, charId = ServerUtils.getCharacter(src, 'hunting carcass load')
    if not charId or type(data) ~= 'table' then return cb(false, 'invalid') end

    local modelHash = tonumber(data.modelHash)
    local carcassKey = type(data.carcassKey) == 'string' and data.carcassKey or nil
    if not modelHash or not carcassKey or #carcassKey < 1 or #carcassKey > 64 then
        return cb(false, 'invalid')
    end
    local animal = exports['bcc-animal-data']:GetAnimal(modelHash)
    if type(animal) == 'table' and animal.wagonStorable == false then
        return cb(false, 'unsupported')
    end

    validateOwnedHuntingWagon(src, charId, data, function(valid, wagonId)
        if not valid then return cb(false, 'invalid') end
        if ActiveLoads[wagonId] then return cb(false, 'busy') end
        ActiveLoads[wagonId] = true

        cargoStatus(wagonId, function(used, capacity)
            local units = getAnimalSize(modelHash)
            local quality = math.max(0, math.min(2, math.floor(tonumber(data.quality) or 0)))
            local isSkinned = data.isSkinned == true and 1 or 0
            local outfitHash = tonumber(data.outfitHash) or 0
            local metaTags = encodeMetaTags(data.metaTags)
            if used + units > capacity then
                ActiveLoads[wagonId] = nil
                return cb(false, 'full', { used = used, capacity = capacity })
            end

            MySQL.insert(
                ('INSERT IGNORE INTO `%s` (`wagon_id`, `carcass_key`, `model_hash`, `cargo_units`, `quality`, `is_skinned`, `outfit_hash`, `meta_tags`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'):format(CARGO_TABLE),
                { wagonId, carcassKey, modelHash, units, quality, isSkinned, outfitHash, metaTags },
                function(insertId)
                    ActiveLoads[wagonId] = nil
                    if not insertId or insertId <= 0 then
                        DBG:Warning(('Hunting cargo insert rejected: wagon=%s key=%s model=%s used=%s units=%s capacity=%s'):format(
                            tostring(wagonId),
                            tostring(carcassKey),
                            tostring(modelHash),
                            tostring(used),
                            tostring(units),
                            tostring(capacity)
                        ))
                        return cb(false, 'duplicate')
                    end
                    cb(true, nil, { used = used + units, capacity = capacity })
                end
            )
        end)
    end)
end)

local function restorePendingUnload(pending, callback)
    MySQL.insert(
        ('INSERT IGNORE INTO `%s` (`wagon_id`, `carcass_key`, `model_hash`, `cargo_units`, `quality`, `is_skinned`, `outfit_hash`, `meta_tags`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'):format(CARGO_TABLE),
        {
            pending.wagonId,
            pending.carcassKey,
            pending.modelHash,
            pending.units,
            pending.quality,
            pending.isSkinned and 1 or 0,
            pending.outfitHash,
            pending.metaTagsJson,
        },
        function()
            if callback then callback() end
        end
    )
end

Core.Callback.Register('bcc-hunting-wagon:ReserveHuntingCarcassUnload', function(source, cb, data)
    local src = source
    local _, charId = ServerUtils.getCharacter(src, 'hunting carcass unload')
    if not charId then return cb(false) end

    validateOwnedHuntingWagon(src, charId, data, function(valid, wagonId)
        if not valid or ActiveLoads[wagonId] then return cb(false) end
        ActiveLoads[wagonId] = true

        local cargoId = type(data) == 'table' and tonumber(data.cargoId) or nil
        local selectSql
        local selectParams
        if cargoId then
            selectSql = ('SELECT `id`, `carcass_key`, `model_hash`, `cargo_units`, `quality`, `is_skinned`, `outfit_hash`, `meta_tags` FROM `%s` WHERE `wagon_id` = ? AND `id` = ? LIMIT 1'):format(CARGO_TABLE)
            selectParams = { wagonId, cargoId }
        else
            selectSql = ('SELECT `id`, `carcass_key`, `model_hash`, `cargo_units`, `quality`, `is_skinned`, `outfit_hash`, `meta_tags` FROM `%s` WHERE `wagon_id` = ? ORDER BY `id` DESC LIMIT 1'):format(CARGO_TABLE)
            selectParams = { wagonId }
        end

        MySQL.single(
            selectSql,
            selectParams,
            function(row)
                if not row then
                    ActiveLoads[wagonId] = nil
                    return cb(false)
                end

                MySQL.update(
                    ('DELETE FROM `%s` WHERE `id` = ? AND `wagon_id` = ?'):format(CARGO_TABLE),
                    { row.id, wagonId },
                    function(rowsAffected)
                        ActiveLoads[wagonId] = nil
                        if not rowsAffected or rowsAffected <= 0 then return cb(false) end

                        local token = ('%d:%d:%d:%d'):format(
                            src,
                            wagonId,
                            GetGameTimer(),
                            math.random(100000, 999999)
                        )
                        local pending = {
                            source = src,
                            wagonId = wagonId,
                            carcassKey = row.carcass_key,
                            modelHash = tonumber(row.model_hash),
                            units = math.max(1, tonumber(row.cargo_units) or 1),
                            quality = math.max(0, math.min(2, tonumber(row.quality) or 0)),
                            isSkinned = row.is_skinned == true
                                or tonumber(row.is_skinned) == 1,
                            outfitHash = tonumber(row.outfit_hash) or 0,
                            metaTagsJson = row.meta_tags,
                            metaTags = decodeMetaTags(row.meta_tags),
                        }
                        PendingUnloads[token] = pending

                        cargoStatus(wagonId, function(used, capacity)
                            cb(true, {
                                token = token,
                                modelHash = pending.modelHash,
                                quality = pending.quality,
                                isSkinned = pending.isSkinned,
                                outfitHash = pending.outfitHash,
                                metaTags = pending.metaTags,
                                status = { used = used, capacity = capacity },
                            })
                        end)

                        SetTimeout(15000, function()
                            if PendingUnloads[token] ~= pending then return end
                            PendingUnloads[token] = nil
                            restorePendingUnload(pending)
                        end)
                    end
                )
            end
        )
    end)
end)

Core.Callback.Register('bcc-hunting-wagon:FinalizeHuntingCarcassUnload', function(source, cb, data)
    local token = type(data) == 'table' and data.token
    local pending = token and PendingUnloads[token]
    if not pending or pending.source ~= source then return cb(false) end
    PendingUnloads[token] = nil

    if data.spawned == true then
        return cargoStatus(pending.wagonId, function(used, capacity)
            cb(true, { used = used, capacity = capacity })
        end)
    end

    restorePendingUnload(pending, function()
        cargoStatus(pending.wagonId, function(used, capacity)
            cb(false, { used = used, capacity = capacity })
        end)
    end)
end)

Core.Callback.Register('bcc-hunting-wagon:ClearHuntingCargoForTesting', function(source, cb, data)
    if not Config.development.enabled then return cb(false) end
    local _, charId = ServerUtils.getCharacter(source, 'hunting cargo test reset')
    if not charId then return cb(false) end

    validateOwnedHuntingWagon(source, charId, data, function(valid, wagonId)
        if not valid then return cb(false) end
        MySQL.update(
            ('DELETE FROM `%s` WHERE `wagon_id` = ?'):format(CARGO_TABLE),
            { wagonId },
            function()
                cb(true, { used = 0, capacity = cargoCapacity() })
            end
        )
    end)
end)

-- Keep the resource safe if the hunting table has not been imported yet.
-- database/schema.sql remains the canonical clean-install definition.
CreateThread(function()
    MySQL.query.await(([=[
        CREATE TABLE IF NOT EXISTS `%s` (
            `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `wagon_id` INT UNSIGNED NOT NULL,
            `carcass_key` VARCHAR(64) NOT NULL,
            `model_hash` BIGINT NOT NULL,
            `cargo_units` TINYINT UNSIGNED NOT NULL DEFAULT 1,
            `quality` TINYINT UNSIGNED NOT NULL DEFAULT 0,
            `is_skinned` TINYINT(1) NOT NULL DEFAULT 0,
            `outfit_hash` BIGINT NOT NULL DEFAULT 0,
            `meta_tags` LONGTEXT NULL,
            `stored_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `uq_bcc_hunting_carcass` (`wagon_id`, `carcass_key`),
            KEY `idx_bcc_hunting_wagon` (`wagon_id`),
            CONSTRAINT `fk_bcc_hunting_wagon`
                FOREIGN KEY (`wagon_id`) REFERENCES `bcc_player_wagons` (`id`)
                ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]=]):format(CARGO_TABLE))
end)

Core.Callback.Register('bcc-hunting-wagon:GetHuntingCargoContents', function(source, cb, data)
    local _, charId = ServerUtils.getCharacter(source, 'hunting cargo contents')
    if not charId then return cb(false) end

    validateOwnedHuntingWagonRecord(source, charId, data, function(valid, wagonId)
        if not valid then return cb(false) end
        MySQL.query(
            ('SELECT `id`, `model_hash`, `cargo_units`, `quality`, `is_skinned` FROM `%s` WHERE `wagon_id` = ? ORDER BY `id` DESC'):format(CARGO_TABLE),
            { wagonId },
            function(rows)
                cargoStatus(wagonId, function(used, capacity)
                    local items = {}
                    for _, row in ipairs(rows or {}) do
                        items[#items + 1] = {
                            id = tonumber(row.id),
                            modelHash = tonumber(row.model_hash),
                            units = math.max(1, tonumber(row.cargo_units) or 1),
                            quality = math.max(0, math.min(2, tonumber(row.quality) or 0)),
                            isSkinned = row.is_skinned == true or tonumber(row.is_skinned) == 1,
                        }
                    end
                    cb(true, { items = items, used = used, capacity = capacity })
                end)
            end
        )
    end)
end)

local function publicButcherItem(row)
    return {
        id = tonumber(row.id),
        modelHash = tonumber(row.model_hash),
        units = math.max(1, tonumber(row.cargo_units) or 1),
        quality = math.max(0, math.min(2, tonumber(row.quality) or 0)),
        isSkinned = row.is_skinned == true or tonumber(row.is_skinned) == 1,
        storedAt = row.stored_at,
    }
end

local function restoreButcherRows(rows, callback)
    if type(rows) ~= 'table' or #rows == 0 then
        if callback then callback(true) end
        return
    end

    local remaining = #rows
    local restored = true
    for _, row in ipairs(rows) do
        MySQL.insert(
            ('INSERT IGNORE INTO `%s` (`wagon_id`, `carcass_key`, `model_hash`, `cargo_units`, `quality`, `is_skinned`, `outfit_hash`, `meta_tags`, `stored_at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'):format(CARGO_TABLE),
            {
                row.wagon_id,
                row.carcass_key,
                row.model_hash,
                row.cargo_units,
                row.quality,
                row.is_skinned,
                row.outfit_hash,
                row.meta_tags,
                row.stored_at,
            },
            function(insertId)
                if not insertId or insertId <= 0 then restored = false end
                remaining = remaining - 1
                if remaining == 0 and callback then callback(restored) end
            end
        )
    end
end

local function validateButcherRequest(sourceId, wagonId, callback)
    local _, charId = ServerUtils.getCharacter(sourceId, 'butcher wagon cargo')
    if not charId then return callback(false) end
    validateOwnedHuntingWagonRecord(sourceId, charId, { wagonId = wagonId }, function(valid, ownedWagonId)
        if not valid then return callback(false) end
        local playerPed = GetPlayerPed(sourceId)
        if playerPed == 0 then return callback(false) end

        local playerCoords = GetEntityCoords(playerPed)
        local maximumDistance = tonumber(huntingSettings().butcherInteractionDistance) or 15.0
        for _, vehicle in ipairs(GetAllVehicles()) do
            if tonumber(Entity(vehicle).state.myWagonId) == ownedWagonId
                and #(playerCoords - GetEntityCoords(vehicle)) <= maximumDistance then
                return callback(true, ownedWagonId)
            end
        end
        callback(false)
    end)
end

exports('GetButcherCargo', function(sourceId, wagonId, callback)
    sourceId = tonumber(sourceId)
    wagonId = tonumber(wagonId)
    DBG:Info(('Butcher cargo export called: player=%s wagon=%s callback=%s'):format(
        tostring(sourceId), tostring(wagonId), type(callback)
    ))
    if not sourceId or not wagonId or callback == nil then return false end

    validateButcherRequest(sourceId, wagonId, function(valid)
        DBG:Info(('Butcher cargo validation completed: player=%s wagon=%s valid=%s'):format(
            tostring(sourceId), tostring(wagonId), tostring(valid)
        ))
        if not valid then return callback(false, 'invalid_wagon') end
        MySQL.query(
            ('SELECT `id`, `model_hash`, `cargo_units`, `quality`, `is_skinned`, `stored_at` FROM `%s` WHERE `wagon_id` = ? ORDER BY `id` ASC'):format(CARGO_TABLE),
            { wagonId },
            function(rows)
                DBG:Info(('Butcher cargo query completed: wagon=%s rows=%s'):format(
                    tostring(wagonId), tostring(rows and #rows or 0)
                ))
                local items = {}
                for _, row in ipairs(rows or {}) do items[#items + 1] = publicButcherItem(row) end
                cargoStatus(wagonId, function(used, capacity)
                    callback(true, { wagonId = wagonId, used = used, capacity = capacity, items = items })
                end)
            end
        )
    end)
    return true
end)

exports('ReserveButcherCargo', function(sourceId, wagonId, cargoIds, callback)
    local invokingResource = GetInvokingResource()
    sourceId = tonumber(sourceId)
    wagonId = tonumber(wagonId)
    if not invokingResource or not sourceId or not wagonId or callback == nil then
        return false
    end

    local selectedIds = {}
    local seenIds = {}
    if type(cargoIds) == 'table' then
        for _, value in ipairs(cargoIds) do
            local id = tonumber(value)
            if id and not seenIds[id] then
                seenIds[id] = true
                selectedIds[#selectedIds + 1] = id
            end
        end
    end

    validateButcherRequest(sourceId, wagonId, function(valid)
        if not valid then return callback(false, 'invalid_wagon') end
        if ActiveLoads[wagonId] then return callback(false, 'busy') end
        ActiveLoads[wagonId] = true

        local selectSql
        local selectParams = { wagonId }
        if #selectedIds > 0 then
            local placeholders = {}
            for _, id in ipairs(selectedIds) do
                placeholders[#placeholders + 1] = '?'
                selectParams[#selectParams + 1] = id
            end
            selectSql = ('SELECT * FROM `%s` WHERE `wagon_id` = ? AND `id` IN (%s) ORDER BY `id` ASC'):format(
                CARGO_TABLE,
                table.concat(placeholders, ',')
            )
        else
            selectSql = ('SELECT * FROM `%s` WHERE `wagon_id` = ? ORDER BY `id` ASC'):format(CARGO_TABLE)
        end

        MySQL.query(selectSql, selectParams, function(rows)
            rows = rows or {}
            if #rows == 0 or (#selectedIds > 0 and #rows ~= #selectedIds) then
                ActiveLoads[wagonId] = nil
                return callback(false, 'cargo_changed')
            end

            local deletePlaceholders = {}
            local deleteParams = { wagonId }
            for _, row in ipairs(rows) do
                deletePlaceholders[#deletePlaceholders + 1] = '?'
                deleteParams[#deleteParams + 1] = tonumber(row.id)
            end
            local deleteSql = ('DELETE FROM `%s` WHERE `wagon_id` = ? AND `id` IN (%s)'):format(
                CARGO_TABLE,
                table.concat(deletePlaceholders, ',')
            )

            MySQL.update(deleteSql, deleteParams, function(rowsAffected)
                ActiveLoads[wagonId] = nil
                if tonumber(rowsAffected) ~= #rows then
                    return restoreButcherRows(rows, function()
                        callback(false, 'cargo_changed')
                    end)
                end

                local token = ('butcher:%s:%d:%d:%d'):format(
                    invokingResource,
                    wagonId,
                    GetGameTimer(),
                    math.random(100000, 999999)
                )
                local items = {}
                for _, row in ipairs(rows) do items[#items + 1] = publicButcherItem(row) end
                local reservation = {
                    resource = invokingResource,
                    source = sourceId,
                    wagonId = wagonId,
                    rows = rows,
                }
                ButcherReservations[token] = reservation
                callback(true, { token = token, wagonId = wagonId, items = items })

                SetTimeout(30000, function()
                    if ButcherReservations[token] ~= reservation then return end
                    ButcherReservations[token] = nil
                    restoreButcherRows(reservation.rows, function()
                        TriggerClientEvent('bcc-hunting-wagon:client:RefreshCargo', reservation.source)
                    end)
                end)
            end)
        end)
    end)
    return true
end)

exports('FinalizeButcherCargo', function(token, consumed, callback)
    local invokingResource = GetInvokingResource()
    local reservation = type(token) == 'string' and ButcherReservations[token] or nil
    if not reservation or reservation.resource ~= invokingResource then
        if callback ~= nil then callback(false, 'invalid_reservation') end
        return false
    end

    ButcherReservations[token] = nil
    if consumed == true then
        TriggerClientEvent('bcc-hunting-wagon:client:RefreshCargo', reservation.source)
        if callback ~= nil then callback(true) end
        return true
    end

    restoreButcherRows(reservation.rows, function(restored)
        TriggerClientEvent('bcc-hunting-wagon:client:RefreshCargo', reservation.source)
        if callback ~= nil then
            callback(restored, restored and nil or 'restore_failed')
        end
    end)
    return true
end)

AddEventHandler('onResourceStop', function(resourceName)
    for token, reservation in pairs(ButcherReservations) do
        if reservation.resource == resourceName or resourceName == GetCurrentResourceName() then
            ButcherReservations[token] = nil
            restoreButcherRows(reservation.rows, function()
                TriggerClientEvent('bcc-hunting-wagon:client:RefreshCargo', reservation.source)
            end)
        end
    end
end)
