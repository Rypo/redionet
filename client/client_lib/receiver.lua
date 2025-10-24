--[[
    Receiver module
    Handles server communications and audio playback.
]]

local speaker = peripheral.find("speaker")


local dbgmon = function (message) end -- debugging func is no op unless conditions are met

local function debug_init()
    settings.load() -- lazy to allow client to inherit from server config as needed
    local monitor = peripheral.find("monitor")

    -- dbgmon redefine conditions: monitor available and log level == debug
    if (monitor and settings.get('redionet.log_level', 3) == 1) then
        local pp = require('cc.pretty')
        monitor.setTextScale(0.5)

        dbgmon = function (message)
            if type(message) == "table" then
                message = pp.render(pp.pretty(message))
            end

            local time_ms = os.epoch("local")
            local time_ms_fmt = ('%s,%03d'):format(os.date("%H:%M:%S", time_ms/1000), time_ms%1000)
            local log_msg = ("[DBG] (%s) %s"):format(time_ms_fmt, message)

            local prev_term = term.redirect(monitor)
            print(log_msg)
            term.redirect(prev_term)
        end
    end
end


local M = {}

---Update local server state cache
---@param blocking? boolean if true, force an update before proceeding, otherwise queue event 
function M.update_server_state(blocking)
    if blocking then
        -- get current server state on join
        rednet.send(SERVER_ID, {"STATE", nil}, "PROTO_SERVER_PLAYER")
        local id,sub_state = rednet.receive('PROTO_SUB_STATE')
        CSTATE.server_state = sub_state

    else
        os.queueEvent('redionet:sync_state')
    end
end


---@param result table metadata for song or playlist
---@param code string [NOW, NEXT, ADD]
function M.send_server_queue(result, code)
    CSTATE.is_paused = false -- queue manipulation = join session if not already
    rednet.send(SERVER_ID, {code, result},  "PROTO_SERVER_QUEUE")
    os.queueEvent('redionet:sync_state')
end

---@param code string [TOGGLE, SKIP, LOOP, STATE]
---@param loop_mode? number loop mode [0,1,2] for server playback (only applicable for code=LOOP)
function M.send_server_player(code, loop_mode)
    rednet.send(SERVER_ID, {code, loop_mode},  "PROTO_SERVER_PLAYER")
    os.queueEvent('redionet:sync_state')
end

function M.toggle_play_local()
    if CSTATE.is_paused or CSTATE.is_paused == nil then -- first click nil
        CSTATE.is_paused = false
        local status = speaker and 1 or 0 -- speakerless = special case: 0. Syncs but doesn't start receiving
        rednet.send(SERVER_ID, status, 'PROTO_AUDIO_CONNECTION')
    else
        CSTATE.is_paused = true
        if speaker then
            rednet.send(SERVER_ID, -1, 'PROTO_AUDIO_CONNECTION') -- TODO: -1 for special case, 0 for paused
            os.queueEvent("redionet:playback_stopped")
            speaker.stop()
         end
    end
end

local function play_audio(buffer, state)
    if not buffer or CSTATE.is_paused or state.active_stream_id ~= state.song_id then return end

    dbgmon(('- %ds - chunk: %d, song: %s, vol: %0.2f'):format(state.audio_position_sec, state.chunk_id, state.song_id, CSTATE.volume))
    os.queueEvent("redionet:audio_timestamp", state.audio_position_sec)

    while not speaker.playAudio(buffer, CSTATE.volume) do
        -- local t_full = os.epoch('local')
        local t_full = os.epoch('ingame')
        dbgmon('SPEAKER FULL')
        parallel.waitForAny(
            function()
                os.pullEvent("speaker_audio_empty")
                -- dbgmon(('>>> SPEAKER EMPTY (%sms)'):format(os.epoch('local')-t_full))
                dbgmon(('>>> SPEAKER EMPTY (%sms)'):format((os.epoch('ingame')-t_full)/72)) -- ingame 72ms : 1ms
            end,
            function()
                os.pullEvent("redionet:playback_stopped")
                state.active_stream_id="HALT" -- a way to breakout when interrupted but not paused
            end
        )
        if CSTATE.is_paused or state.active_stream_id ~= state.song_id then return end
    end
end



function M.receive_loop()
    -- prevent audio loop entry if no speaker attached 
    if not speaker then
        while true do
            local ev, side = os.pullEvent('peripheral')
            if peripheral.hasType(side, 'speaker') then
                os.queueEvent('redionet:reload')
            end
        end
    end

    debug_init()

    local id, message

    rednet.send(SERVER_ID, CSTATE.is_paused and -1 or 1, 'PROTO_AUDIO_CONNECTION')

    while true do
        parallel.waitForAny(
            function ()
                -- interruptible.
                id, message = rednet.receive('PROTO_AUDIO')

                if CSTATE.is_paused then
                    rednet.send(id, "playback_stopped", 'PROTO_AUDIO_NEXT') -- still need to respond to differentiate from connection lost
                else
                    local buffer, sub_state = table.unpack(message)
                    play_audio(buffer, sub_state)
                    -- need to check is_paused instead of returning bool because CLIENT_SYNC queues playback_stopped.
                    -- want be able to stop playback, but then immediately get next chunk in this case
                    rednet.send(id, (not CSTATE.is_paused) and "request_next_chunk" or "playback_stopped", 'PROTO_AUDIO_NEXT')
                end
            end,
            
            function ()
                -- interrupts. This returns faster than PROTO_AUDIO, if received while speakers yielding, it will interrupt 
                id, message = rednet.receive('PROTO_AUDIO_HALT')
                speaker.stop()
                os.queueEvent("redionet:playback_stopped")
                rednet.send(id, "playback_interrupted", 'PROTO_AUDIO_NEXT') -- prevent server timeout warnings
            end,
            function ()
                while true do -- no interrupt
                    id, message = rednet.receive('PROTO_AUDIO_STATUS')
                    rednet.send(id, CSTATE.is_paused and -1 or 1, 'PROTO_AUDIO_CONNECTION')
                end
            end
        )
    end
end

return M
