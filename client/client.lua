--[[
    Main application file for the music client.
    This file loads all the necessary modules and starts the main client application loops.
]]

peripheral.find("modem", rednet.open)
if not rednet.isOpen() then error("Failed to establish rednet connection. Attach a modem to continue.", 0) end

CLIENT_ID = os.getComputerID()
HOST_NAME = 'client_'..CLIENT_ID

local monitor = peripheral.find('monitor')
if monitor then monitor.setTextScale(0.5) end

function DBGMON(message)
    if not monitor then return end

    if type(message) == "table" then
        local pp = require('cc.pretty')
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

local function loading_animation(x,y)
    -- TODO: move to ui
    local _x,_y = term.getCursorPos()
    x,y = x or _x, y or _y
    local function animation()
        local p_tl, p_tr, p_br, p_bl = 129, 130, 136, 132 -- points
        local l_t,  l_r,  l_b,  l_l  = 131, 138, 140, 133 -- lines
        local c_tl, c_tr, c_br, c_bl = 135, 139, 142, 141 -- corners
        local sym_loop = { l_t, c_tr, l_r, c_br, l_b, c_bl, l_l, c_tl, l_t, p_tr, p_br, p_bl, p_tl, }
        while true do
            for _, c in ipairs(sym_loop) do
                term.setCursorPos(x,y)
                term.write(string.char(c))
                os.sleep(0.15)
            end
        end
    end
    return animation
end

local function wait_server_connection()
    write('Waiting for server connection... ')
    local server_id
    parallel.waitForAny(loading_animation(), function ()
        local id, response
        repeat
            server_id =  rednet.lookup('PROTO_SERVER')
            if server_id then
                rednet.send(server_id, {"PING", {}}, 'PROTO_SERVER')
                id, response = rednet.receive(2)
            end
        until response == "PONG"
        server_id = id
    end)
    return server_id
end

local function check_speaker()
    if peripheral.find("speaker") then
        rednet.host('PROTO_AUDIO', HOST_NAME)
        return true
    end
    -- Recent CC:tweaked versions may support two peripherals on pocket 
    -- https://github.com/cc-tweaked/CC-Tweaked/commit/0a0c80d
    local no_warn = pocket and not pocket.equipBottom
    if no_warn then
        print('Pocket Client (communication only)')
    else
        local prev_color = term.getTextColor()
        term.setTextColor(colors.orange)
        print('WARN: No speaker attached. To receive audio on this device, attach speaker and reboot.')
        term.setTextColor(prev_color)
    end
    return false
end



local has_speaker = check_speaker()
SERVER_ID = wait_server_connection()

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



--[[ Client Loops ]]

local function client_loop()
    local speaker = peripheral.find("speaker")
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
                rednet.receive('PROTO_REBOOT')
                if monitor then monitor.clear() end
                os.queueEvent('redionet:reboot')
            end,
            function ()
                rednet.receive('PROTO_UPDATE')
                local install_url = "https://raw.githubusercontent.com/Rypo/redionet/refs/heads/main/install.lua"
                local tabid = shell.openTab('wget run ' .. install_url)
                shell.switchTab(tabid)

                local _, file_changes = os.pullEvent('redionet:update_complete')
                rednet.send(SERVER_ID, file_changes, "PROTO_UPDATED")
                
                if file_changes then
                    os.queueEvent('redionet:reload')
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
                Peer Message -> Client Event 
            ]]
            function ()
                -- flush the other speaker buffers whenever a client resumes play
                -- this forces all clients to remain in sync
                local id = rednet.receive('PEER_SYNC')
                if id ~= CLIENT_ID and speaker then
                    speaker.stop()
                    os.queueEvent("redionet:playback_stopped")
                end
            end
        )

    end

end

receiver.update_server_state(true) -- get initial server state before proceeding

local function system_stop_event()
    -- The only events that should allow the program to terminate
    parallel.waitForAny(
        function ()
            os.pullEvent('redionet:reload')
            local tabid = shell.openTab('client')
            shell.exit()
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
if has_speaker then table.insert(client_functions, receiver.receive_loop) end


parallel.waitForAny(table.unpack(client_functions))