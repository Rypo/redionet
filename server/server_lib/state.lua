--[[
    State management module
]]
local pretty = require("cc.pretty")

local M = {}

M.data = {}
-- UI State
-- M.active_tab = 1
-- M.waiting_for_input = false
-- M.in_search_result_view = false
-- M.clicked_result_index = nil

-- Search State -- now client side
-- M.data.last_search_query = nil
-- M.last_search_url = nil
-- M.data.search_results = nil

-- Playback State
-- M.data.is_paused = nil -- true once hit Play, only false again when user click Stop button
M.data.status = -1 -- -1=cannot_play/empty/waiting, 0=stopped, 1=streaming 
-- M.data.is_paused = false -- false once hit Play, only true again when user click Stop button

M.data.queue = {}
M.data.active_song_meta = nil -- Metadata for the song in the player
M.data.loop_mode = 0          -- 0: Off, 1: Queue, 2: Song
M.data.volume = 1.5           -- value between 0 and 3

-- Audio Network State
M.data.active_stream_id = nil -- The MOST important server state value. This ~= nil IFF there is sound coming out of the speakers (aka song is playing).

M.data.last_download_id = nil -- only accessed by `network`
M.data.is_loading = false     -- set in `network`, get in `ui`

M.data.error_status = false   -- PLAYBACK_ERROR, SEARCH_ERROR, DOWNLOAD_ERROR

M.data.response_handle = nil  -- since filehandles cannot be easily shared via events or rednet, set a state to read from


-- state functions

---format as string or pretty.pretty doc
---@param state? table
---@param as_pdoc? boolean
---@return unknown
function M.format_state(state, as_pdoc)
    state = state or M.data
    local d_state = {}
    for k,v in pairs(state) do
        if not string.find(k, 'handle') then
            if type(v) ~= "table" or #v < 10 then d_state[k] = v end
        end
    end
    local pdoc = pretty.pretty(d_state)
    if as_pdoc then
        return pdoc
    end
    -- local ser_d_state = textutils.serializeJSON(d_state)
    return pretty.render(pdoc, 20)
end

---dump server state to log file
---@param state? table
function M.dump_state(state)
    state = state or M.data
    local ser_d_state = M.format_state(state, false)

    io.open('.logs/server.log', 'a'):write(ser_d_state .. "\n"):close()
end


---Get a minimal sub state for audio receivers to use,
---@return table
function M.sub_state()
    return {
        active_song_meta = M.data.active_song_meta,
        queue = M.data.queue,
        is_loading = M.data.is_loading,
        loop_mode = M.data.loop_mode,
        status = M.data.status,
        error_status = M.data.error_status
    }
end


function M.send_state(id)
    if id then
        rednet.send(id, M.sub_state(), 'PROTO_SUB_STATE')
    else
        rednet.broadcast(M.sub_state(), 'PROTO_SUB_STATE')
    end

    os.queueEvent('redraw_screen', "state.send_state")

end

return M
