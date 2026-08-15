fx_version 'cerulean'
games { 'gta5' }

name 'CharacterSelection'
author 'AndiLfl'
version '1.0.0'

dependencies {
    'obelisk'
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

-- The Vue UI is compiled into the core bundle at build time via core's
-- router/global-element glob (plugins/*/web/{routes,globalElements}.js), so
-- this plugin does not declare its own ui_page. These files are listed only
-- so they ship with the resource.
files {
    'web/*.vue',
    'web/controls/*.vue',
    'web/routes.js',
    'web/globalElements.js',
}
