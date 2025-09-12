--[[
    Chat module
    Handles song announcements and information logging
]]

---apply chatBox style formatting to parenthesized label text
---@param paren_text string
---@param paren_style? string options: "[]","<>", "()". default "[]"
---@param paren_color? string MoTD color code. Default: "&f"
---@return string
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
    -- Song notification in chat
    if not playerDetector then
        local label_col, artist_col, song_col = "&e", "&c", "&f&o" -- yellow, light_red, white-italic
        return chatBox.sendMessage(artist_col..artist.."&r - "..song_col..song_title, label_col.."Now Playing", "[]", label_col) -- &r : reset style
    end

    -- Fancy song notification in upper right of screen
    for i, username in ipairs(playerDetector.getOnlinePlayers()) do
        chatBox.sendToastToPlayer(song_title, "Now Playing", username, "&4&l"..artist, "()", "&c&l") -- dark_red-bold, light_red-bold
    end
    
end

--- Write text in the chat or debugging file
---@param message string|table contents to log
---@param msg_type string? One of DEBUG, ERROR, INFO, STATE. Defaults to DEBUG
function M.log_message(message, msg_type)
    msg_type = msg_type or "DEBUG"
    if type(message) == "table" then
        message = STATE.to_string(message)
    end
    
    if msg_type == "ERROR" then
        local log_msg = string.format("[%s] (%s) %s", msg_type, os.date("%Y-%m-%d %H:%M:%S"), message .. "\n")
        io.open('.logs/server.log', 'a'):write(log_msg):close()
    end
    
    local msg_col = msg_colors[msg_type] or "&0" -- defaults to black
    
    if msg_type == "ERROR" or periphemu then -- don't _actually_ send chat messages unless it's an error
        chatBox.sendMessage(message, msg_col..msg_type, "[]", "&d")
    else
        motd_to_termcolor(format_paren(msg_col..msg_type, "[]", msg_col).." "..message)
    end
end

function M.chat_loop()
    local commands_list = {'reboot', 'reload', 'update'}

    local cmds_set = {}
    for _, cmd in ipairs(commands_list) do cmds_set[cmd] = true end

    while true do
        parallel.waitForAny(
            function()
                while true do -- no interrupt
                    local ev, message, msg_type = os.pullEvent('redionet:log_message')
                    M.log_message(message, msg_type)
                end
            end,
            
            function ()
                -- access chatBox specific behavior without Advanced Peripherals mod
                local id, message = rednet.receive('PROTO_CHATBOX')
                local user, uuid = ('computer_#%d'):format(id), ('%08d-%04d-%04d-%04d-%012d'):format(0,0,0,0,id)
                local ishidden = (message:sub(1,1) == "$")
                if ishidden then message = message:sub(2) end
                os.queueEvent("chat", user, message, uuid, ishidden)
            end,

            function()
                -- fires if a real (Advanced Peripherals) chatBox is attached or imitated with PROTO_CHATBOX
                local ev, user, message, uuid, ishidden = os.pullEvent("chat")
                message = string.lower(message)
                local cmd = message:match("rn (%l+)") -- match format: "rn lowercaseletters"
                
                -- probably too rigid long term, but fine for now while few commands
                if cmds_set[cmd] then
                    M.log_message(("Command received: %s"):format(cmd), "INFO")
                    rednet.broadcast(cmd, 'PROTO_COMMAND')
                    
                    os.queueEvent(('redionet:%s'):format(cmd))
                elseif cmd then
                    M.log_message(("Unknown Command: 'rn %s'\nAvailable: rn {%s}"):format(cmd, table.concat(commands_list, ', ')), "INFO")
                end
            end
        )
    end
end

return M