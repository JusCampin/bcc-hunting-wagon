fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

game 'rdr3'
lua54 'yes'
name 'bcc-hunting-wagon'
description 'Hunter Cart carcass storage and transport feature for bcc-wagons'
author 'BCC Team'
version '1.0.0'

shared_scripts {
    'config.lua',
    'locales.lua',
}

client_scripts {
    'client/event_data.lua',
    'client/init.lua',
    'client/features.lua',
    'client/hunting.lua',
    'client/menu.lua',
    'client/commands.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/init.lua',
    'server/hunting.lua',
}

dependencies {
    'bcc-wagons',
    'bcc-animal-data',
    'bcc-utils',
    'feather-menu',
    'vorp_core',
    'oxmysql',
}
