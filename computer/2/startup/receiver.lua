if periphemu then
    periphemu.create("left", "speaker")
    periphemu.create("right", "modem")
	-- config.standardsMode = true 
end

peripheral.find("modem", rednet.open)

local host_name = 'receiver_'..os.getComputerID()

rednet.host('PROTO_AUDIO', host_name)

local speaker = peripheral.find("speaker")
local speaker_name = peripheral.getName(speaker)

-- POLL_FREQ = 0.05

local function play_audio(buffer, state)
    while not speaker.playAudio(buffer, state.volume) do
        parallel.waitForAny(
            function() repeat until select(2, os.pullEvent("speaker_audio_empty")) == speaker_name end,
            function() os.pullEvent("playback_stopped") end
        )
        if state.is_paused or state.active_stream_id ~= state.song_id then return end
    end
end


local function receive_loop()
    print('StartLoop: PROTO_AUDIO: ' .. host_name)
    local id, message

    while true do
        id, message = rednet.receive('PROTO_AUDIO')
        local msg_code, payload = table.unpack(message)

        if msg_code == 'HALT' then
            speaker.stop()
            os.queueEvent("playback_stopped")
            print(('(%s) HALT recieved'):format(os.date("%H:%M:%S")))
            
            rednet.send(id, "playback_stopped", 'PROTO_AUDIO_NEXT')

        elseif msg_code == 'PLAY' then
            local buffer, sub_state = table.unpack(payload)
            play_audio(buffer, sub_state)
            print(('(%s) chunk play complete'):format(os.date("%H:%M:%S")))
            
            rednet.send(id, "request_next_chunk", 'PROTO_AUDIO_NEXT')
        end
    end
end


local function receive_audio_loop()
    print('StartLoop: PROTO_AUDIO: ' .. host_name)
    local id, message

    while true do
        id, message = rednet.receive('PROTO_AUDIO')
        local msg_code, payload = table.unpack(message)
        if msg_code == 'PLAY' then
            local buffer, sub_state = table.unpack(payload)
            play_audio(buffer, sub_state)
            print(('(%s) chunk play complete'):format(os.date("%H:%M:%S")))
            rednet.send(id, "request_next_chunk", 'PROTO_AUDIO_NEXT')
        end
    end
end

local function receive_state_loop()
    local id, message

    while true do
        id, message = rednet.receive('PROTO_AUDIO')
        local msg_code, payload = table.unpack(message)
        if msg_code == 'HALT' then
            speaker.stop()
            os.queueEvent("playback_stopped")
            print(('(%s) HALT received'):format(os.date("%H:%M:%S")))
            rednet.send(id, "playback_stopped", 'PROTO_AUDIO_NEXT')
        end
    end
end


-- parallel.waitForAny(receive_audio_loop, receive_state_loop)
parallel.waitForAny(receive_loop)
