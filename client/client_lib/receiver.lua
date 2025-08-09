local speaker = peripheral.find("speaker")
local monitor = peripheral.find("monitor")

local decoder = require("cc.audio.dfpwm").make_decoder()


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
        rednet.send(SERVER_ID, {"STATE", nil}, "PROTO_SERVER_PLAYER")
        local id,sub_state = rednet.receive('PROTO_SUB_STATE')
        CSTATE.server_state = sub_state

        -- local pretty = require("cc.pretty")
        -- io.open('.logs/client.log', 'a'):write(pretty.render(pretty.pretty(CSTATE), 20) .. "\n"):close()
    else
        os.queueEvent('sync_state')
    end
end


---@param result table metadata for song or playlist
---@param code string [NOW, NEXT, ADD]
function M.send_server_queue(result, code)
    rednet.send(SERVER_ID, {code, result},  "PROTO_SERVER_QUEUE")
    os.queueEvent('sync_state') -- server already automatically send state update response 
end

-- function M.send_play_song(meta_data)
--     rednet.send(SERVER_ID, {"PLAY", meta_data}, "PROTO_SERVER")
--     os.queueEvent('sync_state')
-- end
-- function M.send_stop_song()
--     rednet.send(SERVER_ID, {"STOP", nil}, "PROTO_SERVER")
--     os.queueEvent('sync_state')
-- end

---@param code string [TOGGLE, SKIP, LOOP, STATE]
---@param loop_mode? number loop mode [0,1,2] for server playback (only applicable for code=LOOP)
function M.send_server_player(code, loop_mode)
    rednet.send(SERVER_ID, {code, loop_mode},  "PROTO_SERVER_PLAYER")
    os.queueEvent('sync_state') -- server already automatically send state update response 
end

function M.toggle_play_pause()

    if CSTATE.is_paused or CSTATE.is_paused == nil then -- first click nil
        os.queueEvent("host_audio")
        CSTATE.is_paused = false
    else
        speaker.stop()
        CSTATE.is_paused = true
        os.queueEvent("playback_stopped")
        rednet.unhost('PROTO_AUDIO', HOST_NAME)
        
    end
    

end

local function play_audio(buffer, state)
    if not buffer then return end
    -- buffer = decoder(buffer)
    -- if monitor then 
    --     local dterm = term.current()
    --     term.redirect(monitor)
    --     print(string.format("[%s] %s", os.date("%H:%M:%S"), state.chunk_id))
    --     term.redirect(dterm)
    -- end

    while not speaker.playAudio(buffer, CSTATE.volume) do
        parallel.waitForAny(
            -- function() repeat until select(2, os.pullEvent("speaker_audio_empty")) == speaker_name end,
            function() os.pullEvent("speaker_audio_empty") end,
            function() os.pullEvent("playback_stopped") end
        )
        if CSTATE.is_paused or state.active_stream_id ~= state.song_id then return end
    end
end



function M.receive_loop()
    -- print('StartLoop: PROTO_AUDIO: ' .. host_name)
    local id, message

    while true do
        id, message = rednet.receive('PROTO_AUDIO')
        local msg_code, payload = table.unpack(message)

        if msg_code == 'HALT' then
            speaker.stop()
            os.queueEvent("playback_stopped")
            rednet.send(id, "playback_stopped", 'PROTO_AUDIO_NEXT')

        else --if msg_code == 'PLAY' then
            if not CSTATE.is_paused then
                local buffer, sub_state = table.unpack(payload)
                play_audio(buffer, sub_state)
                
                rednet.send(id, "request_next_chunk", 'PROTO_AUDIO_NEXT')
            else
                rednet.send(id, "playback_stopped", 'PROTO_AUDIO_NEXT') -- still need to respond so that the waitForAll can complete ASAP
            end
        end
    end
end


-- parallel.waitForAny(receive_audio_loop, receive_state_loop)
-- parallel.waitForAny(receive_loop)

return M
