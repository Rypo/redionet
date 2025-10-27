--[[
    Network module
    Handles HTTP requests for downloading audio.
]]

local M = {}

M.config = {
    api_base_url = "https://ipod-2to6magyna-uc.a.run.app/",
    version = "2.1",
    max_dl_attempts = 3,
}

M.state = {
    dl_attempt = 0,
    last_download_id = nil,
}

function M.format_download_url(song_id)
    if not song_id then return nil end
    return M.config.api_base_url .. "?v=" .. M.config.version .. "&id=" .. textutils.urlEncode(song_id)
end

function M.download_song(song_id)
    if M.state.last_download_id ~= song_id then M.state.dl_attempt = 0 end -- reset count if song different
    M.state.last_download_id = song_id
    STATE.data.is_loading = true
    http.request({ url = M.format_download_url(song_id), binary = true })
    os.queueEvent('redionet:broadcast_state', "network.download_song")
end


function M.handle_http_download()
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event:find('http') then
            local url = eventData[2]
            local last_download_url = M.format_download_url(M.state.last_download_id)

            if url == last_download_url then
                if event == "http_success" then
                    local handle = eventData[3]
                    STATE.data.is_loading = false
                    STATE.data.error_status = false
                    M.state.dl_attempt = 0 -- reset here as well in case looping

                    if STATE.response_handle then
                        pcall(STATE.response_handle.close) -- Buffer should have closed already, but once more for good measure
                        STATE.response_handle = nil
                    end

                    STATE.active_stream_id = M.state.last_download_id
                    STATE.response_handle = handle

                    os.queueEvent("redionet:audio_ready")

                elseif event == "http_failure" then
                    M.state.dl_attempt = M.state.dl_attempt + 1

                    STATE.active_stream_id = nil
                    STATE.data.is_loading = false
                    STATE.data.error_status = "DOWNLOAD_ERROR"

                    local severity, err_msg
                    local try_again = (M.state.dl_attempt < M.config.max_dl_attempts)

                    if try_again then
                        severity = "WARN"
                        err_msg = ("%s: %s"):format(STATE.data.error_status, eventData[3])
                    else
                        severity = "ERROR"
                        err_msg = ("%s: %s"):format(STATE.data.error_status, "Download Retry Limit")
                    end

                    os.queueEvent('redionet:log_message', ("%s | Attempt: %d/%d"):format(err_msg, M.state.dl_attempt, M.config.max_dl_attempts), severity)

                    if try_again then
                        os.queueEvent("redionet:fetch_audio")
                    else
                        STATE.data.status = 0 -- force play status = stopped
                        M.state.dl_attempt = 0 -- reset here to allow retry if dupe song or play->stop->play
                        os.queueEvent("redionet:playback_stopped")
                    end
                end
            end
        end
    end
end

return M
