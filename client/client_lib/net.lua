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


local function filter_results(search_results)
    if #search_results > 1 and string.find(search_results[1].artist, "patreon.com") then -- Filter out patreon message
        table.remove(search_results, 1)
    end
    return search_results
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
                
                os.queueEvent("redraw_screen")
            end
        end
    end
end

return M
