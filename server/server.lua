-- https://pastebin.com/kkMXs0aY
--[[
    Main application file for the music player.
    This file loads all the necessary modules and starts the main application loops.
]]

peripheral.find("modem", rednet.open)
if not rednet.isOpen() then error("Failed to establish rednet connection. Attach a modem to continue.", 0) end

rednet.host('PROTO_SERVER', 'server')

local monitor = peripheral.find("monitor")
if monitor then
    term.redirect(monitor)
end


local chat = require('server_lib.chat')
local audio = require("server_lib.audio")
local network = require("server_lib.network")

STATE = require("server_lib.state")



local function server_loop()
    print('[PROTO_SERVER] Server ID: ' .. os.getComputerID())
    local initial_clients = { rednet.lookup('PROTO_AUDIO') }
    if #initial_clients > 0 then
        print('Pending connection clients IDs:', table.unpack(initial_clients))
    end

    local id, message

    while true do
        parallel.waitForAny(
            function()
                id, message = rednet.receive('PROTO_SERVER') -- General utilities
                local code, payload = table.unpack(message)

                if code == "PING" then
                    rednet.send(id, "PONG")
                elseif code == "LOG" then
                    chat.log_message(payload, "INFO")
                end
            end,
            
            function()
                id, message = rednet.receive('PROTO_SERVER_QUEUE') -- Song queue management
                local code, payload = table.unpack(message)

                if code == "ADD" then
                    if payload.type == "playlist" then
                        for _, item in ipairs(payload.playlist_items) do table.insert(STATE.data.queue, item) end
                    else
                        table.insert(STATE.data.queue, payload)
                    end
                elseif code == "NEXT" then
                    if payload.type == "playlist" then
                        for i = #payload.playlist_items, 1, -1 do table.insert(STATE.data.queue, 1, payload.playlist_items[i]) end
                    else
                        table.insert(STATE.data.queue, 1, payload)
                    end
                elseif code == "NOW" then
                    if payload.type == "playlist" then
                        -- play the first song on the list now, enqueue the rest for up next
                        for i = #payload.playlist_items, 2, -1 do table.insert(STATE.data.queue, 1, payload.playlist_items[i]) end
                        audio.play_song(payload.playlist_items[1])
                    else
                        audio.play_song(payload)
                    end
                    -- STATE.send_state()
                end

                -- always auto play on Queue update unless stopped
                if STATE.data.status == -1 then
                    STATE.data.status = 1
                    os.queueEvent('fetch_audio') -- TODO: monitor for interaction with Play Now
                end

                STATE.send_state()
            end,

            function()
                id, message = rednet.receive('PROTO_SERVER_PLAYER') -- server playback state management 
                local code, payload = table.unpack(message)

                -- if code == "PLAY" then
                --     audio.play_song(payload)
                --     STATE.send_state()

                -- elseif code == "STOP" then
                --     audio.stop_song()
                --     STATE.send_state()
                if code == "STATE" then
                    STATE.send_state()
                elseif code == "TOGGLE" then
                    audio.toggle_play_pause()
                    STATE.send_state()
                elseif code == "SKIP" then
                    audio.skip_song()
                    STATE.send_state()
                elseif code == "LOOP" then
                    STATE.data.loop_mode = payload
                    STATE.send_state()
                end
            end
        )
    end
end

local function server_event_loop()
    while true do
        parallel.waitForAny(
            function()
                local ev, origin = os.pullEvent('redraw_screen')
                print('trigger redraw: ' .. tostring(origin))
                rednet.broadcast('redraw_screen', 'PROTO_UI')
            end,
            function()
                local ev, message, msg_type = os.pullEvent('log_message')
                chat.log_message(message, msg_type)
            end,
            function()
                local ev, user, message, uuid, ishidden = os.pullEvent("chat") -- only fires if a *real* chatBox is peripheral is attached
                chat.log_message("Client reboot issued", "INFO")
                if message == 'reboot' then rednet.broadcast('reboot', 'PROTO_REBOOT') end
            end
        )
    end
end


-- Start the main loops
parallel.waitForAny(
    server_loop,
    server_event_loop,
    audio.audio_loop,
    network.handle_http_download
)