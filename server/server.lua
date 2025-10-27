--[[
    Main application file for the music server.
    This file loads all the necessary modules and starts the main server application loops.
]]

peripheral.find("modem", rednet.open)
if not rednet.isOpen() then error("Failed to establish rednet connection. Attach a modem to continue.", 0) end

SERVER_ID = os.getComputerID()
-- note: _could_ support multi-server where clients choose "station" via ID..but seems more trouble than it's worth
rednet.host('PROTO_SERVER', 'server')

local original_term = term.current() -- chat module will redirect term to designated windows. Store it now for reset on reload


local chat = require('server_lib.chat')
local audio = require("server_lib.audio")
local network = require("server_lib.network")


--[[ Global Server State ]]

STATE = {
    -- Audio Network State
    active_stream_id = nil,     -- The MOST important server state value. active_stream_id ~= nil <=> active audio transmission. Excluded from STATE.data to avoid clients ever having stale copy
    response_handle = nil,      -- ReadHandle from http.request containing binary song data. Non-serializable object

    -- state that clients receive
    data = {
        -- Playback State
        status = -1,            -- -1=cannot_play/empty/waiting, 0=stopped, 1=streaming 
        queue = {},             -- song queue, list of objects like active_song_meta
        active_song_meta = nil, -- Metadata for the song in the player {id=str, name=str, artist=str, duration={H=int, M=int, S=int}}
        loop_mode = 0,          -- 0: Off, 1: Queue/List, 2: Song

        -- Network Status Info
        is_loading = false,     -- set in `network`, get in client.ui
        error_status = false,   -- PLAYBACK_ERROR, DOWNLOAD_ERROR, false
    }
}


---broadcast server state data over PROTO_SERVER_STATE protocol
---@param caller_info? string origin debugging info to log
local function broadcast_state(caller_info)
    chat.log_message(('broadcast_state: %s'):format(caller_info), 'DEBUG')
    -- event data is always copied, client-side mutability not a concern
    rednet.broadcast(STATE.data, 'PROTO_SERVER_STATE')
end

local function dump_state(filename)
    filename = filename or '.redionet.state'
    local state_str = textutils.serialize(STATE.data, {allow_repetitions = true})
    local handle, err = fs.open(filename, 'w')
    handle.write(state_str)
    handle.close()
end

local function restore_state(filename)
    filename = filename or '.redionet.state'
    local handle, err = fs.open(filename, 'r')
    if handle then
        local state_data = textutils.unserialize(handle.readAll())
        handle.close()

        -- stop if was playing. Need time for clients to re-connect
        if state_data.status == 1 then state_data.status = 0 end

        STATE.data.status           = state_data.status
        STATE.data.queue            = state_data.queue
        STATE.data.active_song_meta = state_data.active_song_meta
        STATE.data.loop_mode        = state_data.loop_mode
        -- network status info ignored, irrelevant after reset

        pcall(function() fs.delete(filename) end) -- allow fail without compromising restore
    end
end

--[[ Server Loops ]]

local function server_loop()
    term.setTextColor(colors.white)
    chat.writeto(('[READY] Server ID: %d\n'):format(os.getComputerID()))
    local initial_clients = { rednet.lookup('PROTO_AUDIO') }
    if #initial_clients > 0 then
        chat.writeto(('Known client IDs: <%s>\n'):format(table.concat(initial_clients, ',\t')))
    end

    settings.load()
    local rn_config = { -- redionet settings to pass to clients
        ['redionet.log_level'] = settings.get('redionet.log_level', 3),
    }

    pcall(restore_state) -- restore pre-reboot/reload state, if any

    local id, message

    while true do
        parallel.waitForAny(
            function()
                while true do
                    id, message = rednet.receive('PROTO_SERVER') -- General utilities
                    local code, payload
                    if type(message) == "table" then
                        code, payload = table.unpack(message)
                    else
                        code = message
                    end

                    if code == "CONFIG" then
                        rednet.send(id, {code, rn_config}, 'PROTO_SERVER:REPLY')
                    elseif code == "PING" then
                        rednet.send(id, {code, "PONG"}, 'PROTO_SERVER:REPLY')
                    elseif code == "LOG" then
                        chat.log_message(payload, "INFO")
                    end
                end
            end,
            -- TODO: PROTO_SERVER_QUEUE / PROTO_SERVER_PLAYER - race condition possible?
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
                end

                -- always auto play on Queue update unless stopped
                if STATE.data.status == -1 then
                    STATE.data.status = 1
                    os.queueEvent('redionet:fetch_audio') -- TODO: monitor for interaction with Play Now
                end
            end,

            function()
                id, message = rednet.receive('PROTO_SERVER_PLAYER') -- server playback state management 
                local code, payload = table.unpack(message)
                
                if code then
                    if code == "STATE" then
                        broadcast_state('PROTO__PLAYER: STATE')
                    elseif code == "TOGGLE" then
                        audio.toggle_play_pause()
                    elseif code == "SKIP" then
                        audio.skip_song()
                    elseif code == "LOOP" then
                        STATE.data.loop_mode = payload
                    end
                end
            end,
            
            -- Misc Client Communication
            function ()
                local cid, client_file_changes = rednet.receive('PROTO_UPDATED')
                local prev_color = term.getTextColor()

                if client_file_changes then
                    term.setTextColor(colors.lime)
                    print(('Client #%d: Updated'):format(cid))
                else
                    term.setTextColor(colors.lightGray)
                    print(('Client #%d: Already up to date'):format(cid))
                end
                term.setTextColor(prev_color)
            end
        )
    end
end

local function server_event_loop()
    while true do
        parallel.waitForAny(
            function ()
                while true do
                    local ev, origin = os.pullEvent('redionet:broadcast_state')
                    broadcast_state(origin)
                end
            end,

            function()
                local ev, cmd = os.pullEvent('redionet:issue_command')
                -- need to be cautious about when sync occurs. If timing is off, it will *grow* the speaker buffer rather than clear it
                if cmd == 'sync' then
                    audio.state.need_sync = true
                else
                    rednet.broadcast(cmd, 'PROTO_COMMAND')
                    os.queueEvent(('redionet:%s'):format(cmd))
                end
            end,
            
            function()
                os.pullEvent('redionet:sync') -- Queued by command `rn sync`
                audio.state.speaker_cache = 0 -- stopping speakers wipes any buffered audio
                rednet.broadcast('sync', 'PROTO_CLIENT_SYNC')
            end,

            function ()
                os.pullEvent('redionet:update') -- Queued by command `rn update`

                print('Updating...')
                local install_url = "https://raw.githubusercontent.com/Rypo/redionet/refs/heads/main/install.lua"
                local tabid = shell.openTab('wget run ' .. install_url)
                shell.switchTab(tabid)
            end,

            function ()
                local _, file_changes = os.pullEvent('redionet:update_complete') -- Queued by install script
                local prev_color = term.getTextColor()

                if file_changes then
                    term.setTextColor(colors.lime)
                    print('Server: Updated')

                    os.queueEvent('redionet:reload')
                else
                    term.setTextColor(colors.lightGray)
                    print('Server: Already up to date')
                    term.setTextColor(prev_color)
                end
            end
        )
    end
end

local on_exit
local function system_stop_event()
    -- The only events that should allow the program to terminate
    parallel.waitForAny(
        function ()
            os.pullEvent('redionet:reload')
            term.redirect(original_term) -- reset so term.current() points to root term
            on_exit = 'reload'
        end,
        function ()
            os.pullEvent('redionet:reboot')
            on_exit = 'reboot'
        end
    )
    pcall(dump_state) -- write state to disk for auto restore
end

-- Start the main loops
parallel.waitForAny(
    system_stop_event,
    server_loop,
    server_event_loop,
    audio.audio_loop,
    chat.chat_loop,
    network.handle_http_download
)

if     on_exit == 'reload' then shell.run('server')
elseif on_exit == 'reboot' then os.reboot()
end