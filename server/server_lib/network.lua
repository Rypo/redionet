--[[
    Network module
    Handles HTTP requests for downloading audio.
]]

local chat = require('server_lib.chat')

local M = {}

M.config = {
    api_base_url = "https://ipod-2to6magyna-uc.a.run.app/",
    version = "2.1",
    max_dl_attempts = 3,
}

local dl_attempt = 0

function M.format_download_url(song_id)
    if not song_id then return nil end
    return M.config.api_base_url .. "?v=" .. M.config.version .. "&id=" .. textutils.urlEncode(song_id)
end

function M.download_song(song_id)
    if STATE.data.last_download_id ~= song_id then dl_attempt = 0 end -- reset count if song different
    STATE.data.last_download_id = song_id
    STATE.data.is_loading = true
    http.request({ url = M.format_download_url(song_id), binary = true })
    os.queueEvent("redionet:redraw_screen", "network.download_song")
end


function M.handle_http_download()
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event:find('http') then
            local url = eventData[2]
            local last_download_url = M.format_download_url(STATE.data.last_download_id)

            if url == last_download_url then
                if event == "http_success" then
                    local handle = eventData[3]
                    STATE.data.is_loading = false
                    STATE.data.error_status = false
                    dl_attempt = 0 -- reset here as well in case looping
                    
                    if STATE.data.response_handle then
                        pcall(STATE.data.response_handle.close) -- Buffer should have closed already, but once more for good measure
                        STATE.data.response_handle = nil
                    end

                    STATE.data.active_stream_id = STATE.data.last_download_id
                    STATE.data.response_handle = handle

                    os.queueEvent("redionet:audio_chunk_ready")
                    
                elseif event == "http_failure" then
                    local err = eventData[3]
                    STATE.data.is_loading = false
                    STATE.data.error_status = "DOWNLOAD_ERROR"
                    dl_attempt = dl_attempt + 1
                    
                    STATE.data.active_stream_id = nil
                    if dl_attempt < M.config.max_dl_attempts then
                        os.queueEvent("redionet:fetch_audio")
                    else
                        err = "Download Retry Limit"
                        STATE.data.status = 0
                        os.queueEvent("redionet:playback_stopped", STATE.data.error_status)
                    end

                    local log_lvl = (dl_attempt == M.config.max_dl_attempts and "ERROR" or "WARN")
                    chat.log_message(("%s: %s | Attempt: %d/%d"):format(STATE.data.error_status, err, dl_attempt, M.config.max_dl_attempts), log_lvl)
                    
                    if dl_attempt == M.config.max_dl_attempts then
                        dl_attempt = 0 -- allow to go another round of max_attempts if queue up identical song or play->stop->play
                    end
                end
            end
        end
    end
end

return M
