---apply chatBox style formatting to parenthesized label text
---@param paren_text string
---@param paren_style? string options: "[]","<>", "()". default "[]"
---@param paren_color? string MoTD color code. Default: "&f"
---@return unknown
local function format_paren(paren_text, paren_style, paren_color)
    paren_color = paren_color or "&f"
    paren_style = paren_style or "[]"
    return paren_color..paren_style:sub(1,1)..paren_text..paren_color..paren_style:sub(2,2)
    
end
--- Crudely attempt to convert MOTD color codes to term colors and write to console
--- @param message_string string text containing MoTD color formats
local function motd_to_termcolor(message_string)
    local initial_color = term.getTextColor()
    message_string = message_string:gsub("&[klmno]",""):gsub("&[r]","&f") -- remove format codes -- reset -> white

    for c,text in string.gmatch(message_string, "(&%x)([^&]+)") do
        -- motd white = hex_f, cc white = hex_0, invert scale for very rough translation
        local invcol = ("%x"):format(15-tonumber("0x"..c:sub(2,2)))
        term.setTextColor(colors.fromBlit(invcol))
        write(text) -- global write() handles word wrapping automatically, term.write does not -- https://tweaked.cc/module/_G.html#v:write , /lua/bios.lua#L58
    end
    term.setTextColor(initial_color)
    print() -- newline
end


-- --[[ // begin filler code  ]]
_MOCK_CHAT_BOX = {
    sendToastToPlayer =
    function (message, title, username, paren_text, paren_style, paren_color)
        local paren_label = format_paren(paren_text, paren_style, paren_color)
        local song_string = ("@%s:\n%s\n%s %s"):format(username, title, paren_label, message)
        motd_to_termcolor(song_string)
    end,

    sendMessage =
    function (message, paren_text, paren_style, paren_color)
        local paren_label = format_paren(paren_text, paren_style, paren_color)
        local message_string = paren_label.." "..message
        motd_to_termcolor(message_string)
    end
}

_MOCK_PLAYER_DETECTOR = {getOnlinePlayers = function() return {'Player1',} end}

-- --[[  end filler code // ]]


local chatBox = peripheral.find("chatBox") or _MOCK_CHAT_BOX
local playerDetector = peripheral.find("playerDetector") --or _MOCK_PLAYER_DETECTOR


local msg_colors = {DEBUG = "&8", ERROR = "&4&l", INFO = "&f", STATE="&2"} -- dark_gray, dark_red-bold, white, dark_green
-- https://docs.advanced-peripherals.de/latest/peripherals/chat_box/
-- https://www.digminecraft.com/lists/color_list_pc.php


local M = {}



function M.announce_song(artist, song_title)
    if not playerDetector then
        local label_col, artist_col, song_col = "&e", "&c", "&f&o" -- yellow, light_red, white-italic
        return chatBox.sendMessage(artist_col..artist.."&r - "..song_col..song_title, label_col.."Now Playing", "[]", label_col) -- &r : reset style
    end

    local toasts = {}
    for i, username in ipairs(playerDetector.getOnlinePlayers()) do
        toasts[i] = function () chatBox.sendToastToPlayer(song_title, "Now Playing", username, "&4&l"..artist, "()", "&c&l") end -- dark_red-bold, light_red-bold
    end
    pcall(parallel.waitForAll, table.unpack(toasts))
    
    -- for i, username in ipairs(playerDetector.getOnlinePlayers()) do
    --     chatBox.sendToastToPlayer(song_title, "Now Playing", username, "&4&l"..artist, "()", "&c&l") -- dark_red-bold, light_red-bold
    -- end
    
end


--- Write text in the chat or debugging file
---@param message [string|table] contents to log
---@param msg_type string? One of DEBUG, ERROR, INFO, STATE. Defaults to DEBUG
function M.log_message(message, msg_type)
    msg_type = msg_type or "DEBUG"
    if type("message") == "table" then
        message = STATE.format_state(message)
    end
    if msg_type ~= "INFO" then
        local log_msg = string.format("[%s] (%s) %s", msg_type, os.date("%Y-%m-%d %H:%M:%S"), message .. "\n")
        io.open('.logs/server.log', 'a'):write(log_msg):close()
    end
    local msg_col = msg_colors[msg_type] or "&0&k" -- defaults to obfuscated black
    
    if periphemu or msg_type == "ERROR" then -- don't _actually_ send chat messages unless it's an error
        chatBox.sendMessage(message, msg_col..msg_type, "[]", "&d")
    else
        motd_to_termcolor(format_paren(msg_col..msg_type, "[]", msg_col).." "..message)
    end
end


function M.announce_loop()
    print('StartLoop: Announce')
    local id, message
    local cooldown_song_announce = 3.0 -- Seconds between messages to avoid announcement spam
    while true do
        id, message = rednet.receive('PROTO_ANNOUNCE')
        local msg_type, payload = table.unpack(message)

        if msg_type == 'SONG' then
            local artist, song_title = table.unpack(payload)
            M.announce_song(artist, song_title)
            sleep(cooldown_song_announce)
        elseif msg_type == 'PLAYER' then
            local msg_col = "&f"
            local username, pmsg = table.unpack(payload)
            chatBox.sendMessage(pmsg, msg_col..username, "<>", "&f")
        else
            M.log_message(payload, msg_type)
        end

    end
end


return M