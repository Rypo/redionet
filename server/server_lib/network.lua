--[[
    Network module
    Handles HTTP requests for downloading audio.
]]

local chat = require('server_lib.chat')

local M = {}

M.config = {
    api_base_url = "https://ipod-2to6magyna-uc.a.run.app/",
    version = "2.1"
}


function M.format_download_url(song_id)
    if not song_id then return nil end
    return M.config.api_base_url .. "?v=" .. M.config.version .. "&id=" .. textutils.urlEncode(song_id)
end

function M.download_song(song_id)
    STATE.data.last_download_id = song_id
    STATE.data.is_loading = true
    http.request({ url = M.format_download_url(song_id), binary = true })
    os.queueEvent("redraw_screen", "network.download_song")
end


function M.handle_http_download()
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event:find('http') then
            local url = eventData[2]
            local last_download_url = M.format_download_url(STATE.data.last_download_id)

            if event == "http_success" then
                local handle = eventData[3]

                if url == last_download_url then
                    STATE.data.is_loading = false
                    STATE.data.error_status = false
                    
                    if STATE.data.response_handle then
                        pcall(STATE.data.response_handle.close) -- Buffer should have closed already, but once more for good measure
                        STATE.data.response_handle = nil
                    end

                    STATE.data.active_stream_id = STATE.data.last_download_id
                    local h_pos = handle.seek()
                    STATE.data.response_handle = handle

                    os.queueEvent("audio_chunk_ready")
                end
            elseif event == "http_failure" then
                local err = eventData[3]
                
                if url == last_download_url then
                    STATE.data.is_loading = false
                    STATE.data.error_status = "DOWNLOAD_ERROR"
                    
                    STATE.data.active_stream_id = nil

                    os.queueEvent("fetch_audio")
                    chat.log_message(STATE.data.error_status .. ": " .. tostring(err), "ERROR")
                end
                
            end
            
        end
    end
end

return M
