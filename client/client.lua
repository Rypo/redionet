--[[
    Main application file for the music client.
    This file loads all the necessary modules and starts the main client application loops.
]]

peripheral.find("modem", rednet.open)
if not rednet.isOpen() then error("Failed to establish rednet connection. Attach a modem to continue.", 0) end

SERVER_ID = nil     -- set in setup_server_connection

CLIENT_ID = os.getComputerID()
HOST_NAME = 'client_'..CLIENT_ID

local ui = require("client_lib.ui")
local receiver = require("client_lib.receiver")
local net = require('client_lib.net')


--[[ Global Client State]]
CSTATE = {
    last_search_query = nil,    -- set in `net`, used in `net` and `ui`  
    search_results = nil,       -- list of at most 21 song_meta tables
    is_paused = false,          -- if true, client stops processing music data transmissions
    volume = 1.5,               -- value between 0 and 3
    is_muted = false,
    error_status = false,       -- SEARCH_ERROR, false
    server_state = {
        active_song_meta = nil,
        queue = {},
        is_loading = false,
        loop_mode = 0,
        status = -1,
        error_status = false,
    }
}


-- Global Client Utils
UTIL = {
    dbgmon = function (message) end, -- replaced if debug conditions are met, else remains no op
}


local speaker = peripheral.find("speaker")
local monitor = peripheral.find("monitor")


local function warn_speaker()
    -- Recent CC:tweaked versions may support two peripherals on pocket 
    -- https://github.com/cc-tweaked/CC-Tweaked/commit/0a0c80d
    local no_warn = pocket and not pocket.equipBottom
    if no_warn then
        print('Pocket Client (no audio)')
    else
        local prev_color = term.getTextColor()
        term.setTextColor(colors.orange)
        print('WARN: No speaker attached. To receive audio on this device, attach speaker and reboot.')
        term.setTextColor(prev_color)
    end
end

local function setup_server_connection()
    write('Waiting for server connection... ')
    local id, server_settings

    parallel.waitForAny(ui.loading_animation(), function ()
        local payload, code
        repeat
            id = rednet.lookup('PROTO_SERVER')
            if id then
                rednet.send(id, "CONFIG", 'PROTO_SERVER')

                id, payload = rednet.receive('PROTO_SERVER:REPLY')
                code, server_settings = table.unpack(payload)
            end
        until code == "CONFIG"
    end)

    SERVER_ID = id

    return server_settings
end

if speaker then rednet.host('PROTO_AUDIO', HOST_NAME) else warn_speaker() end
-- check speaker before connect to server to extend time warning visible
local server_settings = setup_server_connection()


-- redefine global util if monitor available and server log level == debug
if (monitor and server_settings['redionet.log_level'] == 1) then
    local pp = require('cc.pretty')
    monitor.setTextScale(0.5)

    function UTIL.dbgmon(message)
        if type(message) == "table" then
            message = pp.render(pp.pretty(message), 20)
        end

        local time_ms = os.epoch("local")
        local time_ms_fmt = ('%s,%03d'):format(os.date("%H:%M:%S", time_ms/1000), time_ms%1000)
        local log_msg = ("[DBG] (%s) %s"):format(time_ms_fmt, message)

        local bterm = term.current()
        term.redirect(monitor)
        print(log_msg)
        term.redirect(bterm)
    end
end



--[[ Client Loops ]]

local function client_loop()
    speaker = peripheral.find("speaker")
    while true do
        parallel.waitForAny(
            --[[
                Server Message -> Client Event
            ]]
            function ()
                rednet.receive('PROTO_UI')
                os.queueEvent('redionet:redraw_screen')
            end,
            function ()
                local id, sub_state = rednet.receive('PROTO_SUB_STATE')
                CSTATE.server_state = sub_state or CSTATE.server_state -- avoid setting nil
                os.queueEvent('redionet:redraw_screen')
            end,
            function ()
                local id, command = rednet.receive('PROTO_COMMAND')

                if command == 'sync' then
                    -- no op, 
                    -- server broadcasts PROTO_CLIENT_SYNC
                
                elseif command == 'reboot' then
                    if monitor then monitor.clear() end
                    os.queueEvent('redionet:reboot')
                
                elseif command == 'reload' then
                    os.queueEvent('redionet:reload')
                
                elseif command == 'update' then
                    local install_url = "https://raw.githubusercontent.com/Rypo/redionet/refs/heads/main/install.lua"
                    local tabid = shell.openTab('wget run ' .. install_url)
                    shell.switchTab(tabid)

                    local _, file_changes = os.pullEvent('redionet:update_complete') -- Queued by install script
                    rednet.send(SERVER_ID, file_changes, "PROTO_UPDATED")
                    
                    if file_changes then
                        os.queueEvent('redionet:reload')
                    end
                end
            end,
            --[[
                Client Event -> Server Message 
            ]]
            function ()
                os.pullEvent('redionet:sync_state')
                rednet.send(SERVER_ID, {"STATE", nil}, "PROTO_SERVER_PLAYER")
            end,
            --[[
                (Peer|Server) Message -> Client Event 
            ]]
            function ()
                -- flush the other speaker buffers whenever a client resumes play
                -- this forces all clients to remain in sync
                local id = rednet.receive('PROTO_CLIENT_SYNC')
                if speaker then
                    speaker.stop()
                    os.queueEvent("redionet:playback_stopped")
                end
            end
        )

    end

end

receiver.update_server_state(true) -- get initial server state before proceeding

local reload = false
local function system_stop_event()
    -- The only events that should allow the program to terminate
    parallel.waitForAny(
        function ()
            os.pullEvent('redionet:reload')
            reload = true
            term.setCursorPos(1, 1)
            term.setBackgroundColor(colors.black)
            term.clear()
        end,
        function ()
            os.pullEvent('redionet:reboot')
            os.reboot()
        end
    )
end

local client_functions = {
    system_stop_event,
    client_loop,
    ui.ui_loop,
    net.http_search_loop
}
-- Only start receiver loop if there is a speaker to play audio
if speaker then table.insert(client_functions, receiver.receive_loop) end


parallel.waitForAny(table.unpack(client_functions))

if reload then shell.run('client') end