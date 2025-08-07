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
rednet.host('PROTO_AUDIO', HOST_NAME)
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
                rednet.host('PROTO_AUDIO', HOST_NAME) -- suprisingly expensive, too disruptive for sync call between UI 
            end
        )

    end

end

local function client_event_loop()
    while true do
        -- eventData = { os.pullEvent() }
        -- if eventData[1] == 'sync_state' then
        --     local id, sub_state = rednet.receive('PROTO_SUB_STATE', timeout)
        --     if sub_state then
        --         CSTATE.server_state = sub_state -- avoid setting nil
        --     end
        -- end
        
        --[[
            Client Event -> Server Message 
        ]]
        parallel.waitForAny(
            function ()
                os.pullEvent('sync_state')
                rednet.send(SERVER_ID, {"STATE", nil}, "PROTO_SERVER_PLAYER")
            end,
            function ()
                os.pullEvent('host_audio')
                rednet.host('PROTO_AUDIO', HOST_NAME) -- suprisingly expensive, too disruptive for sync call between UI 
            end
        )
        -- os.pullEvent('sync_state')
        -- rednet.send(SERVER_ID, {"STATE", nil}, "PROTO_STATE")
        -- local id, sub_state = rednet.receive('PROTO_SUB_STATE')
        -- if sub_state then
        --     CSTATE.server_state = sub_state -- avoid setting nil
        --     os.queueEvent('redraw_screen')
        -- end
    end
end

receiver.update_server_state(true) -- get initial server state before proceeding



parallel.waitForAny(
    client_loop,
    -- client_event_loop,
    ui.ui_loop,
    receiver.receive_loop,
    net.http_search_loop
)