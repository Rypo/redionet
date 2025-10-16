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

-- https://www.digminecraft.com/lists/color_list_pc.php
-- https://tweaked.cc/module/colors.html
local motd_to_cct = {
    ['&4'] = colors.red,        -- dark_red
    ['&c'] = colors.pink,       -- red
    ['&6'] = colors.orange,     -- gold
    ['&e'] = colors.yellow,     -- yellow
    ['&2'] = colors.green,      -- dark_green
    ['&a'] = colors.lime,       -- green
    ['&b'] = colors.lightBlue,  -- aqua (1/2)
    ['&3'] = colors.cyan,       -- dark_aqua
    ['&1'] = colors.blue,       -- dark_blue
    ['&9'] = colors.lightBlue,  -- blue (2/2)
    ['&d'] = colors.magenta,    -- light_purple
    ['&5'] = colors.purple,     -- dark_purple,
    ['&f'] = colors.white,      -- white
    ['&7'] = colors.lightGray,  -- gray
    ['&8'] = colors.gray,       -- dark_gray
    ['&0'] = colors.black,      -- black,
    -- unused: colors.brown
}

--- Crudely attempt to convert MOTD color codes to term colors and write to console
--- @param message_string string text containing MoTD color formats
local function motd_to_termcolor(message_string)
    local initial_color = term.getTextColor()
    message_string = message_string:gsub("&[klmno]",""):gsub("&[r]","&f") -- remove format codes -- reset -> white

    for c,text in string.gmatch(message_string, "(&%x)([^&]+)") do
        term.setTextColor(motd_to_cct[c] or colors.brown) -- brown to notice parse failure
        write(text) -- global write() handles word wrapping automatically, term.write does not -- https://tweaked.cc/module/_G.html#v:write , /lua/bios.lua#L58
    end
    term.setTextColor(initial_color)
    print() -- newline
end


-- --[[ // begin filler code  ]]
local _MOCK_CHAT_BOX = {
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

local _MOCK_PLAYER_DETECTOR = {getOnlinePlayers = function() return {'Player1',} end}

-- --[[  end filler code // ]]

-- AP >= 1.21.1-0.7.50b uses snake_case, older use camelCase
local chatBox = peripheral.find("chat_box") or peripheral.find("chatBox") or _MOCK_CHAT_BOX
local playerDetector = peripheral.find("player_detector") or peripheral.find("playerDetector")
-- https://docs.advanced-peripherals.de/latest/peripherals/chat_box/
-- https://docs.advanced-peripherals.de/latest/peripherals/player_detector/

local loglvl = {
    color = {DEBUG = "&8", INFO = "&f", WARN="&6&n", ERROR = "&4&l"}, -- dark_gray, white, gold-underline, dark_red-bold,
    value = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}
}

local M = {}

settings.load()
M.LOG_LEVEL = settings.get('redionet.log_level', 3)

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
---@param level string? One of DEBUG, INFO, WARN, ERROR. Defaults to DEBUG
function M.log_message(message, level)
    level = level or "DEBUG"

    if loglvl.value[level] < M.LOG_LEVEL then
        return -- no op when severity lower than setting
    end

    local msg_col = loglvl.color[level] or "&7" -- defaults to (light)gray
    
    if type(message) == "table" then
        message = STATE.to_string(message)
    end
    
    if level == "ERROR" then
        -- write to logfile
        local log_msg = string.format("[%s] (%s) %s", level, os.date("%Y-%m-%d %H:%M:%S"), message .. "\n")
        io.open('.logs/server.log', 'a'):write(log_msg):close()

        -- write in chat
        chatBox.sendMessage(message, msg_col..level, "[]", msg_col)
    else
        -- write in console if < error
        motd_to_termcolor(("%s %s"):format(format_paren(msg_col..level, "[]", msg_col), message))
    end
end

function M.chat_loop()
    local commands_list = {'reboot', 'reload', 'update', 'sync'}

    local cmds_set = {}
    for _, cmd in ipairs(commands_list) do cmds_set[cmd] = true end

    while true do
        parallel.waitForAny(
            function()
                while true do -- no interrupt
                    local ev, message, level = os.pullEvent('redionet:log_message')
                    M.log_message(message, level)
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
                    local response = ("Redionet command received: %s"):format(cmd)
                    if ishidden then
                        M.log_message(response, "INFO")
                    else
                        chatBox.sendMessage(response, '&2'..'CMD', "[]", '&f') -- dark_green, white
                    end

                    os.queueEvent('redionet:issue_command', cmd)
                    
                elseif cmd then
                    M.log_message(("Unknown Command: 'rn %s'\nAvailable: rn {%s}"):format(cmd, table.concat(commands_list, ', ')), "ERROR")
                end
            end
        )
    end
end

return M