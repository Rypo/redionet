--[[
    Receiver module
    Handles server communications and audio playback.
]]

local speaker = peripheral.find("speaker")

if not speaker then
    -- stub for coms only pocket. TODO: Sensible coms only api.
    speaker = {
        stop = function () end
    }
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
    os.queueEvent('redionet:sync_state') -- server already automatically send state update response, might be redundant  
end

---@param code string [TOGGLE, SKIP, LOOP, STATE]
---@param loop_mode? number loop mode [0,1,2] for server playback (only applicable for code=LOOP)
function M.send_server_player(code, loop_mode)
    rednet.send(SERVER_ID, {code, loop_mode},  "PROTO_SERVER_PLAYER")
    os.queueEvent('redionet:sync_state') -- server already automatically send state update response, might be redundant 
end

function M.toggle_play_local(mute_mode)
    if mute_mode then
        CSTATE.is_paused = false
        CSTATE.is_muted = not CSTATE.is_muted
        return
    end

    if CSTATE.is_paused or CSTATE.is_paused == nil then -- first click nil
        CSTATE.is_paused = false
        rednet.broadcast('sync', 'PEER_SYNC')

    else
        CSTATE.is_paused = true
        speaker.stop()
        os.queueEvent("redionet:playback_stopped")
    end
end

local function play_audio(buffer, state)
    if not buffer or CSTATE.is_paused or state.active_stream_id ~= state.song_id then return end
    DBGMON(('play_audio - chunk: %d, song: %s, vol: %0.2f'):format(state.chunk_id, state.song_id, CSTATE.volume))

    while not speaker.playAudio(buffer, CSTATE.is_muted and 0 or CSTATE.volume) do
        DBGMON('SPEAKER FULL')
        parallel.waitForAny(
            function()
                os.pullEvent("speaker_audio_empty")
                DBGMON('>>> SPEAKER EMPTY')
            end,
            function()
                os.pullEvent("redionet:playback_stopped")
                state.active_stream_id="HALT" -- mute doesn't use is_paused, need a way to breakout 
            end
        )
        if CSTATE.is_paused or state.active_stream_id ~= state.song_id then return end
    end
end



function M.receive_loop()
    local id, message
    
    rednet.broadcast('sync', 'PEER_SYNC') -- clients that late join may be ahead, needs peer sync

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
                rednet.send(id, "playback_stopped", 'PROTO_AUDIO_NEXT') -- prevent server timeout warnings
            end,
            function ()
                while true do -- no interrupt
                    id, message = rednet.receive('PROTO_AUDIO_STATUS')
                    rednet.send(id, (not CSTATE.is_paused), 'PROTO_AUDIO_STATUS:REPLY')
                end
            end
        )
    end
end

return M
