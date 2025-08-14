
--[[
    Audio module
    Manages audio transmission, queue, and decoding.
]]


local network = require("server_lib.network")
local chat = require('server_lib.chat')
--[[
    The returned decoder is itself a function. This function accepts a string and returns a table of amplitudes, each value between -128 and 127.

    Note: Decoders have lots of internal state which tracks the state of the current stream.
    If you reuse an decoder for multiple streams, or use different decoders for the same stream, the resulting audio may not sound correct.
]]
local dfpwm = require("cc.audio.dfpwm")
local AUDIO_CHUNK_DURATION = 2.75 -- exact is (2^7 * 2^10) samples / 48000kHz = 2.730666.. but ticks round to nearest 0.05

local M = {}

local speakers = { } -- { peripheral.find("speaker") }
-- if #speakers == 0 then
--     error("No speakers attached.", 0)
-- end

-- open up rednet communication
peripheral.find("modem", rednet.open)


-- local receivers = { rednet.lookup("PROTO_AUDIO") }


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
        destroyed = false,
    }
    
    self.buffer = {}
    self.decoder = dfpwm.make_decoder()

    -- for i = 1, self.size, self.chunk_size do
    --     table.insert(self.buffer, string.sub(data, i, i + (self.chunk_size-1)))
    -- end

    function self:next()
        if self.done_write then return end

        if #self.buffer == 0 then -- first call occurs before parallel, will need to read
            self:read()
        end

        if self.done_read and #self.buffer == 0 then
            self.done_write = true
            self.song_id = "NULL" -- avoid setting nil because of the nil == nil behavior
            return
        end


        local next = self.buffer[1]
        table.remove(self.buffer, 1)

        self.total_write.chunks = self.total_write.chunks + 1
        self.total_write.bytes = self.total_write.bytes + #next

        -- chat.log_message(
        os.queueEvent("log_message",
            string.format('<%02d|%03d/%03d> [\25%0.1f\24%0.1f] KiB',
                #self.buffer, self.total_read.chunks, self.total_write.chunks,
                self.total_read.bytes / 1024, self.total_write.bytes / 1024),
            "INFO")

        
        return next
        
    end

    function self:read()
        if self.done_read or #self.buffer > self.max_buffer_length then
            return
        end

        local ok, data = pcall(self.handle.read, self.chunk_size)
        if not ok or data == nil and self.total_read.chunks > 0 then
            self.done_read = true
            pcall(self.handle.close)
            return 0
        end

        local dsz = #data

        -- table.insert(self.buffer, data)
        table.insert(self.buffer, self.decoder(data))
        --[[
        Server side decoding:
        Pros: 
        - Can cache serveral chunks ahead of time
        - transmitted data can be immediately used by speakers
        - eliminates a time variable to consider for client halt/join
        Cons:
        - 8x Larger rednet transmissions (table with 131k int8s)
        - Doesn't solve the "1 audio chunk ahead on rejoin" problem
        
        Client side decoding
        Pros: 
        - 8x Smaller rednet transmissions (string with 16k chars)
        - Decoder state is local to the client which might be important?
        Cons:
        - None of the server side Pros
        - locally blocking
        - Doesn't solve the "1 audio chunk ahead on rejoin" problem
        ]]
        
        self.total_read.chunks = self.total_read.chunks + 1
        self.total_read.bytes = self.total_read.bytes + dsz

        return dsz
    end

    function self:read_n(n)
        for i=1,n do self:read() end
    end
    
    function self:destroy()
        self.destroyed = true
        self.done_read = true
        pcall(self.handle.close)
        self.done_write = true
        self.song_id = "NULL" -- avoid setting nil because of the nil == nil behavior
        self.buffer = nil
        return nil
    end

    function self:stream_complete()
        return not self.destroyed and self.done_write and self.done_read
    end

    return self
end


-- debug.debug()

-- 1 minute Countup Timer - with Ai counting voice
-- https://www.youtube.com/watch?v=TWR9zT1USTQ

-- 100 Second Timer with Voice Countdown
-- https://www.youtube.com/watch?v=d6mfvYmSKI8


--- Plays audio from a given speaker
---@param ccspeaker speaker The name of the speaker peripheral.
---@param buffer table audio data, a list of numerical amplitudes between -128 and 127.
---@param song_id string id of the song that the buffer chunk belongs to.
local function play_audio_buffer(ccspeaker, buffer, song_id)
    local speaker_name = peripheral.getName(ccspeaker)
    while not ccspeaker.playAudio(buffer, STATE.data.volume) do
        parallel.waitForAny(
            function() repeat until select(2, os.pullEvent("speaker_audio_empty")) == speaker_name end,
            function() os.pullEvent("playback_stopped") end
        )
        if STATE.data.status<1 or STATE.data.active_stream_id ~= song_id then return end

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

    -- announce.log_message(string.format('chunk type: %s, len: %s / type buffer: %s, maxn: %s', type(chunk), string.len(chunk), type(buffer), table.maxn(buffer)))
    local play_tasks = {}

    -- rednet.broadcast({ "PLAY", buffer }, 'PROTO_AUDIO')

    for i, speaker in ipairs(speakers) do
        play_tasks[i] = function() play_audio_buffer(speaker, buffer, song_id) end
    end

    local ok, err = pcall(parallel.waitForAll, table.unpack(play_tasks))
    if not ok then
        STATE.data.error_status = "PLAYBACK_ERROR" -- redundant, now set in playback_stopped

        STATE.data.active_stream_id=nil
        chat.log_message(STATE.data.error_status .. ": " .. err, "ERROR")
        os.queueEvent("playback_stopped", STATE.data.error_status)
    else
        os.queueEvent("request_next_chunk")
    end
end


--  broadcasts the decoded audio buffer data over PROTO_AUDIO
local function transmit_audio(data_buffer)
    local buffer = data_buffer:next()
    local sub_state = {
        active_stream_id = STATE.data.active_stream_id,
        song_id = data_buffer.song_id, -- add in local song_id for interrupts
        chunk_id = data_buffer.total_write.chunks
    }

    -- debug.debug()
    local receivers = { rednet.lookup("PROTO_AUDIO") }
    -- TODO: expensive, can/should async? 
    -- OR better yet, maintain a list of active clients based on # replies in previous iters. 3 consec timeout = client dead
    local n_receivers = #receivers
    rednet.broadcast({ "PLAY", {buffer, sub_state} }, 'PROTO_AUDIO')
    -- local send_tasks = {}
    -- for i, recv_id in ipairs(receivers) do
    --     send_tasks[i] = function () rednet.send(recv_id, { "PLAY", {buffer, sub_state} }, 'PROTO_AUDIO') end
    -- end
    -- pcall(parallel.waitForAll, table.unpack(send_tasks)) -- TODO: prefer over broadcast ?
    
    local play_tasks = {}
    local timeout = AUDIO_CHUNK_DURATION + 0.15 -- 3 extra ticks / 150ms 

    local replies = {}
    
    for i, recv_id in ipairs(receivers) do
        play_tasks[i] = function()
            while #replies < n_receivers do 
                local id,msg = rednet.receive("PROTO_AUDIO_NEXT", timeout)
                if id then -- weak check. Doesn't care who replied, only number received
                    local timestamp_ms = os.epoch("local")
                    table.insert(replies, timestamp_ms)
                    
                    -- os.queueEvent("log_message", string.format('(%s) %d %s | n=%d/%d', ("%0.3f"):format(timestamp_ms/1000):sub(6), id, msg, #replies, #receivers), "DEBUG")
                    chat.log_message(string.format('(%s) %d %s | n=%d/%d', ("%0.3f"):format(timestamp_ms/1000):sub(6), id, msg, #replies, n_receivers), "DEBUG")
                else
                    n_receivers = n_receivers - 1 -- assume connection lost on timeout; lookup too disruptive
                end
            end
        end
    end
    
    local prefill_buffer = function () data_buffer:read_n(2) end
    -- THIS is where we can sneak in pre-populate -- while waiting on speakers. 
    -- as long as prepop takes < ~2.75 seconds, it should never cause any delay 
    local ok, err = pcall(parallel.waitForAll, table.unpack(play_tasks), prefill_buffer)

    local desync_ms = (math.max(table.unpack(replies)) - math.min(table.unpack(replies)))
    chat.log_message(string.format('client desync: %dms | n=%d/%d', desync_ms, #replies, #receivers), "INFO")

    if not ok then
        STATE.data.error_status = "PLAYBACK_ERROR" -- redundant, now set in playback_stopped

        STATE.data.active_stream_id=nil
        chat.log_message(STATE.data.error_status .. ": " .. err, "ERROR")
        os.queueEvent("playback_stopped", STATE.data.error_status)
    else
        os.queueEvent("request_next_chunk")
    end
end

---@param data_buffer Buffer holds data
local function process_audio_data(data_buffer)
    -- while (not data_buffer.done_write) and STATE.data.active_stream_id == data_buffer.song_id do
    while STATE.data.active_stream_id == data_buffer.song_id and STATE.data.status==1 do
        -- play_audio_chunk(data_buffer:next(), data_buffer.song_id)
        -- transmit_audio_chunk(data_buffer:next(), data_buffer.song_id, data_buffer.total_write.chunks)
        transmit_audio(data_buffer)
        parallel.waitForAny(
        -- function () play_audio_chunk(data_buffer:next(), data_buffer.song_id) end,
            function() os.pullEvent("request_next_chunk") end,
            function() os.pullEvent("playback_stopped") end
        )
        if STATE.data.status<1 or STATE.data.active_stream_id==nil then break end
    end

    return data_buffer:stream_complete()
end


local function set_state_queue_empty()
    if STATE.data.status ~= 0 then
        STATE.data.status = -1 -- TODO: does this prevent maintaining "Stopped" status?  
    end
    
    STATE.data.active_song_meta = nil

    STATE.data.is_loading = false
    STATE.data.error_status = false
    STATE.data.active_stream_id = nil
end

---Moves the queue forward 1 song. Accounts for loop_mode state.   
---@return table? song_meta_data meta data of next queued song or nil if queue empty  
local function advance_queue()
    if STATE.data.loop_mode > 0 and STATE.data.active_song_meta then
        if STATE.data.loop_mode == 1 then     -- Loop Queue
            table.insert(STATE.data.queue, STATE.data.active_song_meta)
        elseif STATE.data.loop_mode == 2 then -- Loop song
            table.insert(STATE.data.queue, 1, STATE.data.active_song_meta)
        end
    end

    local up_next

    if #STATE.data.queue > 0 then
        up_next = STATE.data.queue[1]
        table.remove(STATE.data.queue, 1)
    else
        set_state_queue_empty()
    end

    return up_next
end

function M.play_song(song_meta)
    local state = STATE.to_string()
    local smeta = song_meta and STATE.to_string(song_meta)
    if song_meta and song_meta.id then
        if STATE.data.active_stream_id and STATE.data.active_stream_id ~= song_meta.id then
            debug.debug()
            M.stop_song() -- if different song currently streaming, stop
        end
            
        STATE.data.active_song_meta = song_meta -- overwrite current meta (may be identical)
    end
    
    debug.debug()
    STATE.data.status = 1      -- needs to be at end to overwrite stop_song()
    -- STATE.data.active_stream_id = nil -- whenever this is nil, we will trigger a download on fetch_audio
    -- os.queueEvent("redraw_screen", "audio.play_song")
    os.queueEvent("fetch_audio")
end

function M.stop_song()
    rednet.broadcast({"HALT", {nil, nil}}, 'PROTO_AUDIO')

    -- for _, speaker in ipairs(speakers) do
    --     speaker.stop()
    --     os.queueEvent("playback_stopped")
    -- end
    os.queueEvent("playback_stopped") -- pulled by process_audio_data
    STATE.data.active_stream_id = nil
    STATE.data.status = 0
    -- os.queueEvent("redraw_screen", "audio.stop_song")
end

function M.skip_song()
    -- cannot rely on nil/fetch_audio behaviour because of looping
    local up_next_meta = advance_queue()
    M.play_song(up_next_meta)
end

function M.toggle_play_pause()
    local state_begin = STATE.to_string()

    -- if STATE.data.is_paused or STATE.data.is_paused == nil then -- first click nil
    if STATE.data.status < 1 then
        M.play_song()
    else
        M.stop_song()
    end

    local state_end = STATE.to_string()

    -- debug.debug()
end

function M.audio_loop()
    local event_filter = {
        -- ["audio_update"] = true,
        ["fetch_audio"] = true,
        ["audio_chunk_ready"] = true,
        ["playback_stopped"] = true,
    }
    local dbuffer -- data buffer, need out of loop body to properly destroy in the event of early termination
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event_filter[event] then
            if STATE.data.active_song_meta == nil then
                STATE.data.active_song_meta = advance_queue()
            end

            local can_play = STATE.data.active_song_meta ~= nil -- if still nil after advance_queue, then queue empty, nothing to play
            local should_play     = STATE.data.status ~= 0 -- if it's -1 or +1, play as soon as data is available
            
            
            if not can_play then
                event = "event_cancelled" -- skip the event handling below
                os.queueEvent("redraw_screen", "audio.audio_loop(event_cancelled)")
            end


            local state              = STATE.to_string()

            debug.debug()
            
            STATE.broadcast("audio_loop - ".. event) -- may trigger more than strictly necessary, but centeralizing eliminates need for a patchwork of calls elsewhere

            if event == "fetch_audio" then
                local has_data_stream    = (STATE.data.active_stream_id ~= nil)
                local has_correct_stream = has_data_stream and (STATE.data.active_stream_id == STATE.data.active_song_meta.id)
                
                debug.debug()
                -- This will always execute if queued properly and should_play==true, but keep as safety check to avoid re-downloading an actively streaming song
                if should_play and not has_correct_stream then
                    network.download_song(STATE.data.active_song_meta.id)
                end
                
            elseif event == "audio_chunk_ready" then
                
                local handle = STATE.data.response_handle
                if not handle then error('bad state: read handle is nil', 0) end -- appease the linter (state should be unreachable)
                local h_pos = handle.seek()

                debug.debug()

                if should_play then
                    -- makes more sense to announce here since this is the last moment before audio actually plays
                    chat.announce_song(STATE.data.active_song_meta.artist, STATE.data.active_song_meta.name)
                    if dbuffer then
                        dbuffer = dbuffer:destroy() -- if it still exists, the song didn't complete. cannot guarantee clean state
                    end
                    dbuffer = Buffer.new(handle, STATE.data.active_song_meta.id)

                    -- debug.debug()
                    local song_completed = process_audio_data(dbuffer)
                    if song_completed then
                        -- EDGE CASE?: click skip song just as a song ends => skips over a song
                        STATE.data.active_song_meta = advance_queue() -- can't set active_song_meta = nil in case of looping
                        dbuffer = nil -- if completed, don't need to destroy, file handle will have already been closed
                    end
                    STATE.data.active_stream_id = nil -- (re)download on next play, regardless of if finished
                    -- debug.debug()
                    
                    os.queueEvent('fetch_audio') -- needed to auto play next song
                    
                end
            elseif event == "playback_stopped" then
                STATE.data.active_stream_id = nil
                STATE.data.is_loading = false
                STATE.data.error_status = eventData[2] or false -- PLAYBACK_ERROR or false

            end
        end
    end
end

return M
