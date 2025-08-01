
--[[
    Audio module
    Manages audio playback, queue, and decoding.
]]

-- local config = require("lib_music.config")
-- local state = require("lib_music.state")
local network = require("lib_music.network")
local util = require("lib_music.util")
--[[
    The returned decoder is itself a function. This function accepts a string and returns a table of amplitudes, each value between -128 and 127.

    Note: Decoders have lots of internal state which tracks the state of the current stream.
    If you reuse an decoder for multiple streams, or use different decoders for the same stream, the resulting audio may not sound correct.
]]
local decoder = require("cc.audio.dfpwm").make_decoder()

local M = {}

local speakers = { peripheral.find("speaker") }
-- if #speakers == 0 then
--     error("No speakers attached.", 0)
-- end

-- open up rednet communication
peripheral.find("modem", rednet.open)


local receivers = { rednet.lookup("PROTO_AUDIO") }


--[[- Buffers Data
    @type Buffer
]]
local Buffer = {}

--- Create's a new Buffer instance.
---@param handle Handle read handle returned by http.request
---@param song_id string expected song id of data buffered
---@treturn Buffer instance
function Buffer.new(handle, song_id)
    local self = {
        handle = handle,
        index = 0,
        song_id = song_id or "INVALID",
        max_buffer_length = 8,
        chunk_size = 16 * 1024,
        total_read = { bytes = 0, chunks = 0 },
        total_write = { bytes = 0, chunks = 0 },
        done_read = false,
        done_write = false,
    }
    
    self.buffer = {}

    -- for i = 1, self.size, self.chunk_size do
    --     table.insert(self.buffer, string.sub(data, i, i + (self.chunk_size-1)))
    -- end

    function self:next()
        if self.done_write then return end

        while #self.buffer == 0 and not self.done_read do
            os.pullEvent("playback_stopped")
            -- os.pullEvent()
            -- self:read()
        end -- Wait until next is available

        if self.done_read and #self.buffer == 0 then
            self.done_write = true
            self.song_id = "NULL" -- avoid setting nil because of the nil == nil behavior
            return
        end


        local next = self.buffer[1]
        table.remove(self.buffer, 1)

        self.total_write.chunks = self.total_write.chunks + 1
        self.total_write.bytes = self.total_write.bytes + #next

        util.chat_message(
            string.format('(%s / %s / %s ) Bytes: read: %s / write: %s',
                #self.buffer, self.total_read.chunks, self.total_write.chunks,
                self.total_read.bytes, self.total_write.bytes),
            "INFO")

        return next
    end

    function self:read()
        if self.done_read and self.done_write then return end

        while #self.buffer > self.max_buffer_length or self.done_read do
            os.pullEvent("playback_stopped")
        end

        local ok, data = pcall(self.handle.read, self.chunk_size)
        if not ok or data == nil and self.total_read.chunks > 0 then
            self.done_read = true
            pcall(self.handle.close)
            return 0
        end


        local dsz = #data
        table.insert(self.buffer, data)

        self.total_read.chunks = self.total_read.chunks + 1
        self.total_read.bytes = self.total_read.bytes + dsz

        return dsz
    end

    function self:is_done()
        -- make *aggresively* sure it's done
        return self.done_write and self.done_read and #self.buffer == 0 and
        (self.total_read.chunks == self.total_write.chunks)
    end

    return self
end

-- local DBuffer -- Buffer instance, holds current song data

debug.debug()




--- Plays audio from a given speaker
---@param ccspeaker speaker The name of the speaker peripheral.
---@param buffer table audio data, a list of numerical amplitudes between -128 and 127.
---@param song_id string id of the song thatxmus the buffer chunk belongs to.
local function play_audio_buffer(ccspeaker, buffer, song_id)
    local speaker_name = peripheral.getName(ccspeaker)
    while not ccspeaker.playAudio(buffer, STATE.volume) do
        parallel.waitForAny(
            function() repeat until select(2, os.pullEvent("speaker_audio_empty")) == speaker_name end,
            function() os.pullEvent("playback_stopped") end
        )
        if STATE.is_paused or STATE.active_stream_id ~= song_id then return end

        -- local event, name = os.pullEvent("speaker_audio_empty")
        -- if name ~= speaker_name then return end
    end
end



-- Decodes the audio chunk, broadcasts the decoded audio buffer over PROTO_AUDIO, and plays on all connected speakers
---@param chunk string a block of 16KiB encoded audio data to feed to the decoder
---@param song_id string id of the song that the chunk belongs to.
local function play_audio_chunk(chunk, song_id)
    if not chunk then return end

    -- local chunk, volume =  rednet.receive('PROTO_AUDIO') -- THIS WILL PROB NOT WOKR
    local buffer = decoder(chunk)

    -- util.chat_message(string.format('chunk type: %s, len: %s / type buffer: %s, maxn: %s', type(chunk), string.len(chunk), type(buffer), table.maxn(buffer)))
    local play_tasks = {}

    -- rednet.broadcast({ "PLAY", buffer }, 'PROTO_AUDIO')

    for i, speaker in ipairs(speakers) do
        play_tasks[i] = function() play_audio_buffer(speaker, buffer, song_id) end
    end

    local ok, err = pcall(parallel.waitForAll, table.unpack(play_tasks))
    if not ok then
        STATE.error_status = "PLAYBACK_ERROR" -- redundant, now set in playback_stopped

        STATE.active_stream_id=nil
        util.chat_message(STATE.error_status .. ": " .. err, "ERROR")
        os.queueEvent("playback_stopped", STATE.error_status)
    else
        os.queueEvent("request_next_chunk")
    end
end


-- Decodes the audio chunk, broadcasts the decoded audio buffer over PROTO_AUDIO, and plays on all connected speakers
---@param chunk string a block of 16KiB encoded audio data to feed to the decoder
---@param song_id string id of the song that the chunk belongs to.
local function transmit_audio_chunk(chunk, song_id)
    if not chunk then return end

    local buffer = decoder(chunk) -- TODO: decode in buffer:read() ??

    -- util.chat_message(string.format('chunk type: %s, len: %s / type buffer: %s, maxn: %s', type(chunk), string.len(chunk), type(buffer), table.maxn(buffer)))
    local play_tasks = {}
    
    local sub_state = STATE.sub_state({song_id = song_id}) -- add in local song_id for interrupts

    -- debug.debug()
    rednet.broadcast({ "PLAY", {buffer, sub_state} }, 'PROTO_AUDIO')

    -- rednet.receive("PROTO_AUDIO_NEXT", 5)

    for i, receiver_id in ipairs(receivers) do
        play_tasks[i] = function() repeat until select(1, rednet.receive("PROTO_AUDIO_NEXT")) == receiver_id end
    end

    local ok, err = pcall(parallel.waitForAll, table.unpack(play_tasks))
    if not ok then
        STATE.error_status = "PLAYBACK_ERROR" -- redundant, now set in playback_stopped

        STATE.active_stream_id=nil
        util.chat_message(STATE.error_status .. ": " .. err, "ERROR")
        os.queueEvent("playback_stopped", STATE.error_status)
    else
        os.queueEvent("request_next_chunk")
    end
end

---@param data_buffer Buffer holds data
local function process_audio_data(data_buffer)
    while (not data_buffer.done_write) and STATE.active_stream_id == data_buffer.song_id do
        -- play_audio_chunk(data_buffer:next(), data_buffer.song_id)
        transmit_audio_chunk(data_buffer:next(), data_buffer.song_id)
        parallel.waitForAny(
        -- function () play_audio_chunk(data_buffer:next(), data_buffer.song_id) end,
            function() os.pullEvent("request_next_chunk") end,
            function() os.pullEvent("playback_stopped") end,
            function() repeat data_buffer:read() until data_buffer.done_read end
        )
        -- if STATE.is_paused or not STATE.is_currently_playing then break end
        if STATE.is_paused or STATE.active_stream_id==nil then break end
    end
    -- STATE.is_currently_playing = false
    return data_buffer:is_done()
end



local function set_state_queue_empty()
    STATE.active_song_meta = nil

    STATE.is_loading = false
    STATE.error_status = false
    STATE.active_stream_id = nil
end

local function advance_queue()
    if STATE.loop_mode > 0 and STATE.active_song_meta then
        if STATE.loop_mode == 1 then     -- Loop Queue
            table.insert(STATE.queue, STATE.active_song_meta)
        elseif STATE.loop_mode == 2 then -- Loop song
            table.insert(STATE.queue, 1, STATE.active_song_meta)
        end
    end

    local up_next

    if #STATE.queue > 0 then
        up_next = STATE.queue[1]
        table.remove(STATE.queue, 1)
        util.announce_song(up_next)
    else
        set_state_queue_empty()
    end
    return up_next
end

function M.play_song(song_meta)
    if song_meta then
        if STATE.active_song_meta ~= song_meta then
            -- if STATE.is_currently_playing then
            if STATE.active_stream_id ~= nil then
                M.stop_song()
            end
        end
        STATE.active_song_meta = song_meta
    -- elseif STATE.active_song_meta == nil then
    --     STATE.active_song_meta = advance_queue() -- Now done in the audio event loop
    end

    STATE.is_paused = false      -- needs to be at end to overwrite stop_song()
    STATE.active_stream_id = nil -- whenever this is nil, we will trigger a download on fetch_audio
    os.queueEvent("redraw_screen")
    os.queueEvent("fetch_audio")
end

function M.stop_song()
    rednet.broadcast({"HALT", {nil, nil}}, 'PROTO_AUDIO')

    for _, speaker in ipairs(speakers) do
        speaker.stop()
        os.queueEvent("playback_stopped")
    end

    -- rednet.broadcast({"HALT", nil}, 'PROTO_AUDIO')

    -- STATE.is_currently_playing = false
    STATE.active_stream_id = nil
    STATE.is_paused = true
    os.queueEvent("redraw_screen")
end

function M.skip_song()
    local up_next_meta = advance_queue()
    M.play_song(up_next_meta)
end

function M.toggle_play_pause()
    local state_begin = util.format_state(STATE)

    if STATE.is_paused or STATE.is_paused == nil then -- first click nil
        M.play_song()
    else
        M.stop_song()
    end

    local state_end = util.format_state(STATE)

    debug.debug()
end

function M.audio_loop()
    local event_filter = {
        -- ["audio_update"] = true,
        ["fetch_audio"] = true,
        ["audio_chunk_ready"] = true,
        ["playback_stopped"] = true,
    }
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event_filter[event] then
            -- local can_play = STATE.active_song_meta or #STATE.queue > 0
            if STATE.active_song_meta == nil then
                STATE.active_song_meta = advance_queue()
            end

            local can_play = STATE.active_song_meta ~= nil -- if still nil after advance_queue, then queue empty, nothing to play
            local should_play     = not STATE.is_paused
            
            
            if not can_play then
                event = "event_cancelled" -- skip the event handling below
                os.queueEvent("redraw_screen")
            end


            local state              = util.format_state(STATE)

            -- debug.debug()

            if event == "fetch_audio" then
                local has_data_stream    = (STATE.active_stream_id ~= nil) --and STATE.is_currently_playing -- redundancy check
                local has_correct_stream = has_data_stream and (STATE.active_stream_id == STATE.active_song_meta.id)
                
                debug.debug()
                -- If queued properly, this will always execute if not paused
                if should_play and not has_correct_stream then
                    network.download_song(STATE.active_song_meta.id)
                end
            elseif event == "audio_chunk_ready" then
                local handle = STATE.response_handle
                local h_pos = handle.seek()

                debug.debug()

                if should_play then
                    local dbuffer = Buffer.new(handle, STATE.active_song_meta.id)
                    local first_read_bytes = dbuffer:read() -- need to read once for init queue data
                    
                    local song_completed = process_audio_data(dbuffer)
                    if song_completed then
                        STATE.active_song_meta = advance_queue() -- might have EDGE CASE: click skip song just as a song ends => skips over a song
                    end
                    STATE.active_stream_id = nil -- (re)download on next play
                    debug.debug()
                    -- needed to auto play next
                    os.queueEvent('fetch_audio')
                    os.queueEvent("redraw_screen")
                    
                end
            elseif event == "playback_stopped" then
                STATE.active_stream_id = nil
                STATE.is_loading = false
                STATE.error_status = eventData[2] or false -- PLAYBACK_ERROR or false

            end
        end
    end
end

return M
