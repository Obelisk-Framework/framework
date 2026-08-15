fx_version 'cerulean'
games { 'gta5' }

name 'Barber'
author ''
version '1.0.0'

dependencies {
    'obelisk',
    'oblsk_character-selection'
}

shared_scripts {
    'shared/**/*.lua'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/routes.js',
    'web/globalElements.js',
}
