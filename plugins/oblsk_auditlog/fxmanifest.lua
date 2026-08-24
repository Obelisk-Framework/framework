fx_version 'cerulean'
games { 'gta5' }

name 'AuditLog'
author ''
version '1.0.0'

dependencies {
    'obelisk'
}

server_scripts {
    'server/**/*.lua'
}

client_scripts {
    'client/**/*.lua'
}

files {
    'web/*.vue',
    'web/*.js',
}
