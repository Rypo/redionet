--[[
    State management module
]]

local M = {}

-- UI State
M.active_tab = 1
M.waiting_for_input = false
M.in_search_result_view = false
M.clicked_result_index = nil

-- Search State
M.last_search_query = nil
-- M.last_search_url = nil
M.search_results = nil

-- Playback State
M.is_paused = nil -- true once hit Play, only false again when user click Stop button

M.queue = {}
M.active_song_meta = nil -- Metadata for the song in the player
M.loop_mode = 0 -- 0: Off, 1: Queue, 2: Song
M.volume = 1.5 -- value between 0 and 3

-- Audio Network State
M.active_stream_id = nil -- The MOST important state value. This ~= nil IFF there is sound coming out of the speakers (aka song is playing).

M.last_download_id = nil -- only accessed by `network`
M.is_loading = false -- set in `network`, get in `ui`

M.error_status = false -- PLAYBACK_ERROR, SEARCH_ERROR, DOWNLOAD_ERROR

M.response_handle = nil  -- since filehandles cannot be easily shared via events or rednet, set a state to read from



---Get a minimal sub state for audio receivers to use,
---@param xkwargs table? extra kewords to insert into the sub state  
---@return table
function M.sub_state(xkwargs)
    local pseduo_state = {
        is_paused = M.is_paused,
        volume = M.volume,
        active_stream_id = M.active_stream_id
    }
    if xkwargs then
        for k,v in pairs(xkwargs) do pseduo_state[k] = v end
    end
    return pseduo_state
end

return M
