local translations = {
    en = {
        huntingCargoFull = 'The hunting wagon is full.',
        huntingCargoLoadFailed = 'The carcass could not be loaded.',
        huntingCargoLoaded = 'Carcass loaded. Hunting cargo: %s/%s',
        huntingCargoPrompt = 'Load Carcass',
        huntingCargoTitle = 'Hunting Wagon',
        huntingCargoUnloadFailed = 'The carcass could not be unloaded.',
        huntingCargoUnloaded = 'Carcass unloaded. Hunting cargo: %s/%s',
        huntingCargoUnloadPrompt = 'Unload Carcass',
        huntingCargoWrongItem = 'Only dead animals can be loaded.',
        huntingCargoMenuCapacity = 'Cargo: %s/%s',
        huntingCargoMenuEmpty = 'The hunting wagon is empty.',
        huntingCargoMenuBack = 'Back',
        huntingCargoMenuClose = 'Close',
        huntingCargoMenuCondition = 'Condition: ',
        huntingCargoMenuRefresh = 'Refresh',
        huntingCargoMenuSkinned = 'Skinned',
        huntingCargoMenuUnits = 'Cargo units: %s',
        huntingCargoMenuUnload = 'Unload selected carcass',
        huntingCargoMenuUnknownAnimal = 'Unknown Animal',
        huntingCargoMenuUnavailable = 'The hunting cargo could not be opened.',
    },
}

function _U(key, ...)
    local locale = translations[Config.locale] or translations.en
    local value = locale[key] or translations.en[key] or key
    if select('#', ...) > 0 then return value:format(...) end
    return value
end
