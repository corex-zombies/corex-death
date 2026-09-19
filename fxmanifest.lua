fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'corex-death'
description 'COREX Death & Respawn System'
author 'ABUGIZA'
version '1.0.0'

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    'server/inventory_bridge.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}

-- corex-zones was declared and never called. The only effect of leaving it here
-- was that death handling went down whenever zones did.
dependencies {
    'corex-core'
}
