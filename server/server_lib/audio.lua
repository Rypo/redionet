--[[
    Audio module
    Manages audio decoding, transmission, and song queue.
]]

local dfpwm = require("cc.audio.dfpwm")

local network = require("server_lib.network")
local chat = require('server_lib.chat')

local AUDIO_CHUNK_DURATION = 2.75 -- exact is (2^7 * 2^10) samples / 48000kHz = 2.730666.. but ticks round to nearest 0.05

local M = {}


---@class Buffer
local Buffer = {}

--- Creates a new Buffer instance.
---@class ReadHandle
---@param handle ReadHandle read handle returned by http.request
---@param song_id string expected song id of data buffered
---@return Buffer instance
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
        self.total_write.bytes = self.total_write.bytes + #next -- decoded length

        -- chat.log_message(
        os.queueEvent("redionet:log_message",
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
            return
        end

        local dsz = #data -- encoded length

        -- table.insert(self.buffer, data)
        table.insert(self.buffer, self.decoder(data))
        --[[
        Preliminary testing shows desynchronization issues worsen when decoding is done
        by the client. Server decode, cache, transmit seems to be the best approach.
        For posterity, it's worth noting the main downside is larger rednet transmissions.
        The decoded message is a table of 131k ints compared to encoded 16k chars. 
        ]]
        
        self.total_read.chunks = self.total_read.chunks + 1
        self.total_read.bytes = self.total_read.bytes + dsz
        
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

local last_chunktime = {}

--  broadcasts the decoded audio buffer data over PROTO_AUDIO
local function transmit_audio(data_buffer)
    local buffer = data_buffer:next()
    local sub_state = {
        active_stream_id = STATE.data.active_stream_id,
        song_id = data_buffer.song_id, -- add in local song_id for interrupts
        chunk_id = data_buffer.total_write.chunks
    }

    -- debug.debug()
    local receivers = { rednet.lookup("PROTO_AUDIO") } -- this takes a minimum of 2 seconds. But delay this seems to help with sync issues?
    -- https://github.com/cc-tweaked/CC-Tweaked/blob/9e233a9/projects/core/src/main/resources/data/computercraft/lua/rom/apis/rednet.lua#L422
    
    if #receivers == 0 then
        chat.log_message('No visible client connections... Stopping', 'INFO')
        return M.stop_song()
    end
    
    rednet.broadcast({buffer, sub_state}, 'PROTO_AUDIO') -- takes ~ 36-38 ms, must come after lookup


    local timeout = AUDIO_CHUNK_DURATION + 0.2 -- 4 extra ticks / 200ms 

    local replies_id = {}
    local replies_time = {}

    local num_resp, num_next = 0, 0
    local function play_task()
        local n_receivers = #receivers

        while num_resp < n_receivers do -- weak check. Doesn't care who replied, only number received
            local id,msg = rednet.receive("PROTO_AUDIO_NEXT", timeout)
            if id then
                num_resp = num_resp + 1

                if msg == "request_next_chunk" then
                    num_next = num_next + 1
                    local timestamp_ms = os.epoch("local")

                    table.insert(replies_id, id)
                    table.insert(replies_time, timestamp_ms)
                    local play_duration = timestamp_ms - (last_chunktime[id] or timestamp_ms)
                
                    -- os.queueEvent("redionet:log_message", string.format('(%s) %d %s | n=%d/%d', ("%0.3f"):format(timestamp_ms/1000):sub(7), id, msg, #replies, n_receivers), "DEBUG")
                    chat.log_message(string.format('(%s, %dms) %d | n=%d/%d', ("%0.3f"):format(timestamp_ms/1000):sub(7), play_duration, id, #replies_id, n_receivers ), "DEBUG")

                    last_chunktime[id] = timestamp_ms
                
                --elseif msg==... do not use message==playback_stopped to decrement n_receivers. Causes unexpected behavior. 
                end

            else
                n_receivers = n_receivers - 1 -- assume connection lost on timeout; lookup too disruptive
                print('client timed out')
            end
        end
    end
    


    local prefill_buffer = function () data_buffer:read_n(2) end
    
    -- THIS is where we can sneak in pre-populate -- while waiting on speakers. 
    -- as long as prepop takes < ~2.75 seconds, it should never cause any delay
    -- alternatively, could do in parallel with lookup, which we know will take a fixed 2s
    local ok, err = pcall(parallel.waitForAll, play_task, prefill_buffer)
    if num_next == 0 then
        chat.log_message('No remaining listeners... Stopping', 'INFO')
        return M.stop_song()
    end

    if #replies_time > 1 then
        local desync_ms = (math.max(table.unpack(replies_time)) - math.min(table.unpack(replies_time)))
        -- os.queueEvent("redionet:log_message", string.format('client desync: %dms | n=%d/%d', desync_ms, #replies, #receivers), "INFO")
        chat.log_message(string.format('client desync: %dms | n=%d/%d', desync_ms, #replies_time, #receivers), "INFO")
        if desync_ms > 100 then -- more than 100ms lag time, dig deeper
            local id_order,delay = {},{}
            for i,id in ipairs(replies_id) do
                id_order[i] = ("[%d] %d"):format(i, id)
                delay[i] = ("%dms"):format((i<#replies_time and replies_time[i+1] - replies_time[i]) or 0)
            end
            textutils.tabulate(colors.white, id_order, colors.pink, delay)
        end
    end



    if not ok then
        STATE.data.error_status = "PLAYBACK_ERROR" -- redundant, now set in playback_stopped

        STATE.data.active_stream_id=nil
        chat.log_message(STATE.data.error_status .. ": " .. err, "ERROR")
        os.queueEvent("redionet:playback_stopped", STATE.data.error_status)
    else
        os.queueEvent("redionet:request_next_chunk")
    end
end

---@param data_buffer Buffer holds data
local function process_audio_data(data_buffer)
    while STATE.data.active_stream_id == data_buffer.song_id and STATE.data.status==1 do
        transmit_audio(data_buffer)
        parallel.waitForAny(
            function() os.pullEvent("redionet:request_next_chunk") end,
            function() os.pullEvent("redionet:playback_stopped") end
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
    if song_meta and song_meta.id then
        if STATE.data.active_stream_id and STATE.data.active_stream_id ~= song_meta.id then
            M.stop_song() -- if different song currently streaming, stop
        end
            
        STATE.data.active_song_meta = song_meta -- overwrite current meta (may be identical)
    end
    
    STATE.data.status = 1      -- needs to be at end to overwrite stop_song()

    os.queueEvent("redionet:fetch_audio")
end

function M.stop_song()
    rednet.broadcast("audio.stop_song", 'PROTO_AUDIO_HALT')
    os.queueEvent("redionet:playback_stopped") -- pulled by process_audio_data
    STATE.data.active_stream_id = nil
    STATE.data.status = 0
end

function M.skip_song()
    -- cannot rely on nil/fetch_audio behaviour because of looping
    local up_next_meta = advance_queue()
    M.play_song(up_next_meta)
end

function M.toggle_play_pause()
    if STATE.data.status < 1 then
        M.play_song()
    else
        M.stop_song()
    end
end

function M.audio_loop()
    local event_filter = {
        ["redionet:fetch_audio"] = true,
        ["redionet:audio_chunk_ready"] = true,
        ["redionet:playback_stopped"] = true,
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
                event = "redionet:event_cancelled" -- skip the event handling below
                os.queueEvent("redionet:redraw_screen", "audio.audio_loop(event_cancelled)")
            end
            
            STATE.broadcast("audio_loop - ".. event) -- may trigger more than strictly necessary, but centeralizing eliminates need for a patchwork of calls elsewhere

            if event == "redionet:fetch_audio" then
                local has_data_stream    = (STATE.data.active_stream_id ~= nil)
                local has_correct_stream = has_data_stream and (STATE.data.active_stream_id == STATE.data.active_song_meta.id)
                
                -- debug.debug()
                -- This will always execute if queued properly and should_play==true, but keep as safety check to avoid re-downloading an actively streaming song
                if should_play and not has_correct_stream then
                    network.download_song(STATE.data.active_song_meta.id)
                end
                
            elseif event == "redionet:audio_chunk_ready" then
                
                local handle = STATE.data.response_handle
                if not handle then error('bad state: read handle is nil', 0) end -- appease the linter (state should be unreachable)
                -- local h_pos = handle.seek()

                -- debug.debug()

                if should_play then
                    -- announce here, last moment before audio actually plays
                    chat.announce_song(STATE.data.active_song_meta.artist, STATE.data.active_song_meta.name)
                    if dbuffer then
                        dbuffer = dbuffer:destroy() -- if it still exists, the song didn't complete. cannot guarantee clean state
                    end
                    dbuffer = Buffer.new(handle, STATE.data.active_song_meta.id)

                    local song_completed = process_audio_data(dbuffer)
                    if song_completed then
                        -- EDGE CASE?: click skip song just as a song ends => skips over a song
                        STATE.data.active_song_meta = advance_queue() -- can't set active_song_meta = nil in case of looping
                        dbuffer = nil -- if completed, don't need to destroy, file handle will have already been closed
                    end
                    STATE.data.active_stream_id = nil -- (re)download on next play, regardless of if finished
                    
                    os.queueEvent('redionet:fetch_audio') -- needed to auto play next song
                    
                end
            elseif event == "redionet:playback_stopped" then
                STATE.data.active_stream_id = nil
                STATE.data.is_loading = false
                STATE.data.error_status = eventData[2] or false -- PLAYBACK_ERROR or false

            end
        end
    end
end

return M
