local CargoMenu

local function animalLabel(modelHash)
    local animal = exports['bcc-animal-data']:GetAnimal(modelHash)
    return type(animal) == 'table' and animal.label or _U('huntingCargoMenuUnknownAnimal')
end

local function qualityStars(quality)
    return string.rep('★', math.max(1, math.min(3, tonumber(quality) or 1)))
end

local function itemLabel(item)
    local label = ('%s  %s'):format(item.animalLabel, qualityStars(item.quality))
    if item.isSkinned then label = label .. '  ·  ' .. _U('huntingCargoMenuSkinned') end
    return label
end

local function sortCargoItems(items)
    for _, item in ipairs(items) do item.animalLabel = animalLabel(item.modelHash) end
    table.sort(items, function(left, right)
        local leftLabel = left.animalLabel:lower()
        local rightLabel = right.animalLabel:lower()
        if leftLabel ~= rightLabel then return leftLabel < rightLabel end
        if tonumber(left.quality) ~= tonumber(right.quality) then
            return tonumber(left.quality) > tonumber(right.quality)
        end
        if left.isSkinned ~= right.isSkinned then return left.isSkinned == false end
        return tonumber(left.id) < tonumber(right.id)
    end)
end

local function registerDetailsPage(listPage, item)
    local details = CargoMenu:RegisterPage('bcc-hunting-wagon:cargo:item:' .. tostring(item.id))
    details:RegisterElement('header', {
        value = item.animalLabel, slot = 'header', style = { ['color'] = '#999' },
    })
    details:RegisterElement('subheader', {
        value = qualityStars(item.quality), slot = 'header', style = { ['color'] = '#CC9900' },
    })
    details:RegisterElement('line', { slot = 'header' })
    details:RegisterElement('textdisplay', {
        value = _U('huntingCargoMenuUnits', item.units), slot = 'content',
    })
    if item.isSkinned then
        details:RegisterElement('textdisplay', {
            value = _U('huntingCargoMenuCondition') .. _U('huntingCargoMenuSkinned'),
            slot = 'content',
        })
    end
    details:RegisterElement('line', { slot = 'content' })
    details:RegisterElement('button', {
        label = _U('huntingCargoMenuUnload'), slot = 'content',
        style = { ['color'] = '#A94442' },
    }, function()
        CargoMenu:Close()
        UnloadHuntingCarcass(item.id)
    end)
    details:RegisterElement('line', { slot = 'footer' })
    details:RegisterElement('button', {
        label = _U('huntingCargoMenuBack'), slot = 'footer',
    }, function()
        listPage:RouteTo()
    end)
    return details
end

local function buildCargoMenu(cargo)
    if CargoMenu then CargoMenu:Close() end

    CargoMenu = FeatherMenu:RegisterMenu('bcc-hunting-wagon:cargo', {
        top = '3%', left = '3%',
        ['720width'] = '400px', ['1080width'] = '500px',
        ['2kwidth'] = '600px', ['4kwidth'] = '800px',
        contentslot = { style = { ['height'] = '420px', ['min-height'] = '300px' } },
        draggable = true, canclose = true,
    })

    local page = CargoMenu:RegisterPage('bcc-hunting-wagon:cargo:list')
    page:RegisterElement('header', {
        value = _U('huntingCargoTitle'), slot = 'header', style = { ['color'] = '#999' },
    })
    page:RegisterElement('subheader', {
        value = _U('huntingCargoMenuCapacity', cargo.used, cargo.capacity),
        slot = 'header', style = { ['color'] = '#CC9900' },
    })
    page:RegisterElement('line', { slot = 'header' })

    local items = type(cargo.items) == 'table' and cargo.items or {}
    sortCargoItems(items)
    if #items == 0 then
        page:RegisterElement('textdisplay', {
            value = _U('huntingCargoMenuEmpty'), slot = 'content',
        })
    else
        for _, cargoItem in ipairs(items) do
            local item = cargoItem
            local details = registerDetailsPage(page, item)
            page:RegisterElement('button', {
                id = tostring(item.id), label = itemLabel(item), slot = 'content',
            }, function()
                details:RouteTo()
            end)
        end
    end

    page:RegisterElement('line', { slot = 'footer' })
    page:RegisterElement('button', {
        label = _U('huntingCargoMenuRefresh'), slot = 'footer',
    }, function()
        CargoMenu:Close()
        OpenHuntingCargoMenu()
    end)
    page:RegisterElement('button', {
        label = _U('huntingCargoMenuClose'), slot = 'footer',
    }, function()
        CargoMenu:Close()
    end)
    CargoMenu:Open({ startupPage = page })
end

function OpenHuntingCargoMenu()
    if IsHuntingCargoBusy() then return end
    local request = GetHuntingWagonRequest()
    if not request then return end

    Core.Callback.TriggerAsync('bcc-hunting-wagon:GetHuntingCargoContents', function(success, cargo)
        if not success or type(cargo) ~= 'table' or not IsActiveHuntingWagon() then
            Core.NotifyRightTip(_U('huntingCargoMenuUnavailable'), 4000)
            return
        end
        ApplyHuntingCargoStatus(cargo)
        buildCargoMenu(cargo)
    end, request)
end
