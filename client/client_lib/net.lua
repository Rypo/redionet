--[[
    Client Network module
    Handles HTTP audio searching requests.
]]

local M = {}

M.config = {
    api_base_url = "https://ipod-2to6magyna-uc.a.run.app/",
    version = "2.1"
}


function M.format_search_url(query)
    if not query then return nil end
    return M.config.api_base_url .. "?v=" .. M.config.version .. "&search=" .. textutils.urlEncode(query)
end


function M.search(query)
    CSTATE.last_search_query = query
    CSTATE.search_results = nil
    http.request(M.format_search_url(query))
end

local function parse_time(artist_line)
    -- local s_i,s_j = artist_line:find('\32\183\32', 1, true) -- matching string literal " · " can fail
    local s_i,s_j = artist_line:find("%s%G+%s") -- >=1 not printable/space, surrounded by spaces

    -- keep 1 trailing whitespace in duration for gmatch 
    local duration_tws, artist = artist_line:sub(1, s_i-0), artist_line:sub(s_j+1)

    if duration_tws:sub(1,4) == "LIVE" then
        return {H = 9999, M = 59, S = 59}
    end

    local time_seg = {}
    for t in duration_tws:gmatch('(%d+)[:%s]') do table.insert(time_seg, t) end
    if #time_seg == 2 then table.insert(time_seg, 1, "0") end

    return {H = tonumber(time_seg[1]), M = tonumber(time_seg[2]), S = tonumber(time_seg[3])}
end

local function filter_results(search_results)
    -- Filter patreon message
    if #search_results > 0 and string.find(search_results[1].artist, "patreon.com") then
        table.remove(search_results, 1)
    end

    -- Filter Live streams. Leave long videos for now, but dimmed in UI
    local search_results_f = {}
    for i, result in ipairs(search_results) do
        result.duration = parse_time(result.artist)
        if result.duration.H ~= 9999 then
            table.insert(search_results_f, result)
        end
    end
    -- if nothing remains after filtering, return the original set instead
    return #search_results_f > 0 and search_results_f or search_results
end


function M.http_search_loop()
    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event:find('http') then
            local url = eventData[2]
            local last_search_url = M.format_search_url(CSTATE.last_search_query)
            
            if url == last_search_url then
                if event == "http_success" then
                    local handle = eventData[3]
                    local data = textutils.unserialiseJSON(handle.readAll())
                    if data then
                        CSTATE.search_results = filter_results(data)
                        CSTATE.error_status = false
                    else
                        CSTATE.error_status = "SEARCH_ERROR"
                    end

                elseif event == "http_failure" then
                    local err = eventData[3]
                    CSTATE.error_status = "SEARCH_ERROR"
                end
                
                os.queueEvent("redionet:redraw_screen")
            end
        end
    end
end

return M
