
--[[
    Network module
    Handles all HTTP requests for searching and downloading audio.
]]
local util = require('lib_music.util')

local M = {}

M.config = {
    api_base_url = "https://ipod-2to6magyna-uc.a.run.app/",
    version = "2.1"
}


function M.format_search_url(query)
    if not query then return nil end
    return M.config.api_base_url .. "?v=" .. M.config.version .. "&search=" .. textutils.urlEncode(query)
end

function M.format_download_url(song_id)
    if not song_id then return nil end
    return M.config.api_base_url .. "?v=" .. M.config.version .. "&id=" .. textutils.urlEncode(song_id)
end

function M.search(query)
    STATE.last_search_query = query
    STATE.search_results = nil
    http.request(M.format_search_url(query))
end

function M.download_song(song_id)
    STATE.last_download_id = song_id
    STATE.is_loading = true
    http.request({ url = M.format_download_url(song_id), binary = true })
    os.queueEvent("redraw_screen")
end

local function filter_results(search_results)
    if #search_results > 1 and string.find(search_results[1].artist, "patreon") then -- Filter out patreon message
        table.remove(search_results, 1)
    end
    return search_results
end

function M.handle_http_events()
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event:find('http') then
            local url = eventData[2]
            local last_search_url = M.format_search_url(STATE.last_search_query)
            local last_download_url = M.format_download_url(STATE.last_download_id)

            if event == "http_success" then
                local handle = eventData[3]
                if url == last_search_url then
                    local data = textutils.unserialiseJSON(handle.readAll())
                    if data then
                        STATE.search_results = filter_results(data)
                        STATE.error_status = false
                    else
                        STATE.error_status = "SEARCH_ERROR"
                    end
                    -- os.queueEvent("redraw_screen")
                elseif url == last_download_url then
                    STATE.is_loading = false
                    STATE.error_status = false

                    if STATE.response_handle then
                        pcall(STATE.response_handle.close)
                        STATE.response_handle = nil
                    end

                    STATE.active_stream_id = STATE.last_download_id
                    local h_pos = handle.seek()
                    STATE.response_handle = handle
                    os.queueEvent("audio_chunk_ready") -- Events params ONLY work with primitive types (boolean, number, string) and tables

                    debug.debug()
                    -- os.queueEvent("redraw_screen")
                end
            elseif event == "http_failure" then
                local err = eventData[3]
                if url == last_search_url then
                    STATE.error_status = "SEARCH_ERROR"
                    -- os.queueEvent("redraw_screen")
                
                elseif url == last_download_url then
                    STATE.is_loading = false
                    STATE.error_status = "DOWNLOAD_ERROR"
                    
                    STATE.active_stream_id = nil
                    os.queueEvent("redraw_screen")
                    os.queueEvent("fetch_audio")
                end
                util.chat_message(STATE.error_status .. ": " .. err, "ERROR")
            end
            os.queueEvent("redraw_screen")
        end
    end
end

return M
