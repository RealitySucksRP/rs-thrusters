fx_version 'cerulean'
game 'gta5'
author 'Reality Sucks Scripts'
description 'RS Thrusters - installable cold-gas propulsion, flight assist and stunt physics'
version '0.1.83'

shared_scripts { 'config.lua' }
client_scripts { 'client/main.lua' }
server_scripts { 'server/main.lua', 'server/buyback.lua' }

ui_page 'html/index.html'
files { 'html/index.html', 'html/style.css', 'html/app.js' }
