peripheral.find("modem", rednet.open)
if not rednet.isOpen() then error("Failed to establish rednet connection. Attach a modem to continue.", 0) end

local function wait_heartbeat()
    local server_id =  rednet.lookup('PROTO_SERVER')
    if server_id then
        -- if server gets restarted, lookup table is insufficent 
        rednet.send(server_id, {"PING", {}}, 'PROTO_SERVER')
        local id, response = rednet.receive(10)

        if response == "PONG" then
            SERVER_ID = id
            return SERVER_ID
        end
    else
        sleep(3)
    end
    print('Waiting for server connection...')
    return wait_heartbeat()
end


HOST_NAME = 'client_'..os.getComputerID()

local has_speaker = peripheral.find("speaker")
if has_speaker then
    rednet.host('PROTO_AUDIO', HOST_NAME)
else
    -- Recent CC:tweaked versions may support two peripherals on pocket - https://github.com/cc-tweaked/CC-Tweaked/commit/0a0c80d
    local no_warn = pocket and not pocket.equipBottom
    if no_warn then
        print('Pocket Client (communication only)')
    else
        local prev_color = term.getTextColor()
        term.setTextColor(colors.orange)
        print('WARN: No speaker attached. To receive audio on this device, attach speaker and reboot.')
        term.setTextColor(prev_color)
    end
end

-- rednet.host('PROTO_UI', HOST_NAME)

SERVER_ID = wait_heartbeat()
print('Server Id: ', SERVER_ID)

local ui = require("client_lib.ui")
local receiver = require("client_lib.receiver")
local net = require('client_lib.net')



-- client state
CSTATE = {
    last_search_query = nil,
    search_results = nil,
    is_paused = false,
    volume = 1.5,
    error_status = false,
    server_state = {
        active_song_meta = nil,
        queue = {},
        is_loading = false,
        loop_mode = 0,
        status = -1,
        error_status = false,
    }
}




local function client_loop()
    
    while true do

        parallel.waitForAny(
            --[[
                Server Message -> Client Event
            ]]
            function ()
                rednet.receive('PROTO_UI')
                os.queueEvent('redraw_screen')
            end,
            function ()
                local id, sub_state = rednet.receive('PROTO_SUB_STATE')
                CSTATE.server_state = sub_state or CSTATE.server_state -- avoid setting nil
                os.queueEvent('redraw_screen')
            end,
            function ()
                rednet.receive('PROTO_REBOOT')
                os.reboot()
            end,
            --[[
                Client Event -> Server Message 
            ]]
            function ()
                os.pullEvent('sync_state')
                rednet.send(SERVER_ID, {"STATE", nil}, "PROTO_SERVER_PLAYER")
            end,
            function ()
                os.pullEvent('host_audio')
                if has_speaker then
                    rednet.host('PROTO_AUDIO', HOST_NAME) -- suprisingly expensive, too disruptive for sync call between UI 
                end
                
            end
        )

    end

end

receiver.update_server_state(true) -- get initial server state before proceeding


local client_functions = {
    client_loop,
    ui.ui_loop,
    net.http_search_loop
}
if has_speaker then table.insert(client_functions, receiver.receive_loop) end


parallel.waitForAny(table.unpack(client_functions))