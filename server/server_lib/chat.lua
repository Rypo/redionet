--[[
    Chat module
    Handles song announcements, information logging, and chat commands
]]

local pp = require("cc.pretty")

local w,h = term.getSize()
local monitor = peripheral.find("monitor")

local orig_term = term.current()
local term_window = window.create(orig_term, 1, 1, w, h-1)
local cmd_window = window.create(orig_term, 1, h, w, 1)
local log_window = monitor or term_window -- log to monitor if available, else sub window

local M = {}

settings.load()
M.LOG_LEVEL = settings.get('redionet.log_level', 3)

M.commands_list = {'help', 'reboot', 'reload', 'update', 'sync', }
M.command_valid = {} -- Set
for _,v in ipairs(M.commands_list) do M.command_valid[v] = true end

local command_help = {
    ['help']   = "Display this help message.",
    ['reboot'] = "Reboot server+clients, may not auto resume.",
    ['reload'] = "Attempt server+clients hot reload.",
    ['update'] = "Fetch updates from GitHub and reload.",
    ['sync']   = "Force resynchronize audio streams.",
}

M.term = log_window
term.redirect(log_window)

---temporarily redirect to dst_term and write() text
---@param text string text to write with auto wrapping and scrolling
---@param dst_term? Redirect destination term redirect or window. Default: M.term
function M.writeto(text, dst_term)
    dst_term = dst_term or M.term --or term.current()

    -- skip redirects if dst_term is already active 
    if dst_term == term.current() then return write(text) end

    local prev_term = term.redirect(dst_term)
    if dst_term.restoreCursor then dst_term.restoreCursor() end
    write(text)
    term.redirect(prev_term)
    if prev_term.restoreCursor then prev_term.restoreCursor() end
end

function M.show_help()
    local repo_url = "github.com/Rypo/redionet"
    local orig_color = term_window.getTextColor()

    -- display help in server terminal, even if monitor attached
    term_window.setTextColor(colors.yellow)
    M.writeto('rn commands\n', term_window)
    for i = 1, #M.commands_list do -- index iter to preserve ordering
        local name = M.commands_list[i]
        local desc = command_help[name]

        term_window.setTextColor(colors.lightGray)
        M.writeto(name .. ": ", term_window)

        term_window.setTextColor(colors.gray)
        M.writeto(desc .. "\n", term_window)
    end
    term_window.setTextColor(colors.white)
    M.writeto(("\nSource and more info\n> %s\n\n"):format(repo_url), term_window)

    term_window.setTextColor(orig_color)
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

--- Approximate MOTD color codes to term colors and write to console
--- @param message_string string text containing MoTD color formats
local function motd_to_termcolor(message_string)
    local initial_color = M.term.getTextColor()
    message_string = message_string:gsub("&[klmno]",""):gsub("&[r]","&f") -- remove format codes -- reset -> white

    local c_prv
    local cat_text = ""

    for c,text in string.gmatch(message_string, "(&%x)([^&]+)") do
        if not c_prv then c_prv = c end
        -- accumulate text while color is the same to avoid unnecessary writes
        if c == c_prv then
            cat_text = cat_text .. text
        else
            M.term.setTextColor(motd_to_cct[c_prv] or colors.brown) -- brown if parse fails 
            M.writeto(cat_text)
            cat_text = text
        end
        c_prv = c
    end

    M.term.setTextColor(motd_to_cct[c_prv] or colors.brown)
    M.writeto(cat_text .. '\n')

    M.term.setTextColor(initial_color)
end

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

-- --[[ // begin filler code  ]]
local _MOCK_CHAT_BOX = {
    sendToast =
    function (options)
        local paren_text, paren_style, paren_color = options.prefix, options.brackets, options.bracketsColor
        local paren_label = format_paren(paren_text, paren_style, paren_color)
        local song_string = ("@%s:\n%s\n%s %s"):format(options.player, options.title, paren_label, options.message)
        motd_to_termcolor(song_string)
    end,

    sendMessage =
    function (message, options)
        local paren_text, paren_style, paren_color = options.prefix, options.brackets, options.bracketsColor
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


-- Helper code to operate chat box on both 0.7 and 0.8
-- --[[ // begin helper code  ]]

local is_ap_0_8 = false
if advancedperipherals and advancedperipherals.getAPVersion then
    local major, minor = advancedperipherals.getAPVersion():match('^(%d+)%.(%d+)%.')
    if major ~= nil and (tonumber(major) > 0 or tonumber(minor) >= 8) then
        is_ap_0_8 = true
    end
end

local function sendChatBoxToast(chatBox, options)
    if is_ap_0_8 or chatBox == _MOCK_CHAT_BOX then
        return chatBox.sendToast(options)
    end
    return chatBox.sendToastToPlayer(
        options.message,
        options.title,
        options.player,
        options.prefix,
        options.brackets,
        options.bracketsColor
    )
end

local function sendChatBoxMessage(chatBox, message, options)
    if is_ap_0_8 or chatBox == _MOCK_CHAT_BOX then
        return chatBox.sendMessage(message, options)
    end
    return chatBox.sendMessage(
        message,
        options.prefix,
        options.brackets,
        options.bracketsColor
    )
end

-- --[[  end helper code // ]]

function M.announce_song(artist, song_title)
    -- Song notification in chat
    if not playerDetector then
        local label_col, artist_col, song_col = "&e", "&c", "&f&o" -- yellow, light_red, white-italic
        return sendChatBoxMessage(
            chatBox,
            artist_col..artist.."&r - "..song_col..song_title, -- &r : reset style
            {
                prefix = label_col.."Now Playing",
                brackets = "[]",
                bracketsColor = label_col,
            }
        )
    end

    -- Fancy song notification in upper right of screen
    for i, username in ipairs(playerDetector.getOnlinePlayers()) do
        sendChatBoxToast(chatBox, {
            message = song_title,
            title = "Now Playing",
            player = username,
            prefix = "&4&l"..artist, -- dark_red-bold
            brackets = "()",
            bracketsColor = "&c&l" -- light_red-bold
        })
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
        message = pp.render(pp.pretty(message))
    end
    
    if level == "ERROR" then
        -- write to logfile
        local log_msg = string.format("[%s] (%s) %s", level, os.date("%Y-%m-%d %H:%M:%S"), message .. "\n")
        pcall(function() io.open('.logs/server.log', 'a'):write(log_msg):close() end) -- ignore io failures

        -- write in chat
        sendChatBoxMessage(
            chatBox,
            message,
            {
                prefix = msg_col..level,
                brackets = "[]",
                bracketsColor = msg_col,
            }
        )
    else
        -- write in console if < error
        motd_to_termcolor(("%s %s"):format(format_paren(msg_col..level, "[]", msg_col), message))
    end
end


local function command_line()
    local completion = require("cc.completion")

    local history = {}

    local input_active = false

    local function read_timeout(timeout)
        timeout = timeout or 10
        local msg = ""
        local timer, tid = os.startTimer(timeout), nil

        parallel.waitForAny(
            function () msg = read(nil, history, function(text) return completion.choice(text, M.commands_list) end) end,
            function () repeat _, tid = os.pullEvent('timer') until tid == timer end,
            function ()
                while true do
                    os.pullEvent('key') -- reset timer on key press
                    os.cancelTimer(timer)
                    timer = os.startTimer(timeout)
                end
            end
        )
        os.cancelTimer(timer)
        cmd_window.setCursorBlink(false)
        return msg
    end

    local function set_prompt()
        cmd_window.setCursorPos(1, 1)
        cmd_window.clearLine()
        cmd_window.setTextColor(colors.yellow)
        cmd_window.write("CMD> rn ")
    end

    set_prompt()

    while true do
        local event = os.pullEvent()
        if not input_active and (event == "mouse_click" or event == "key") then
            input_active = true

            set_prompt()

            local prev_term = term.redirect(cmd_window)
            local cmd_name = read_timeout(10) -- writeto expensive when cmd_window focused; release focus after 10s inactivity
            term.redirect(prev_term)

            if #cmd_name == 0 then -- timeout or user press enter w/o writing
                set_prompt()
            else
                cmd_window.setCursorPos(1,1)
                cmd_window.clearLine()

                if M.command_valid[cmd_name] then
                    if history[#history] ~= cmd_name then table.insert(history, cmd_name) end
                    cmd_window.setTextColor(colors.lime)
                    cmd_window.write(("[OK] rn %s."):format(cmd_name))

                    os.queueEvent('redionet:issue_command', cmd_name)
                else
                    cmd_window.setTextColor(colors.red)
                    cmd_window.write(("[ERR] rn `%s` \149 rn help - to show commands"):format(cmd_name))
                end
            end

            input_active = false
        end
    end
end

function M.chat_loop()
    while true do
        parallel.waitForAny(
            command_line,

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
                if M.command_valid[cmd] then
                    local response = ("Redionet command received: %s"):format(cmd)
                    if ishidden then
                        M.log_message(response, "INFO")
                    else
                        sendChatBoxMessage(
                            chatBox,
                            response,
                            {
                                prefix = '&2'..'CMD', -- dark_green
                                brackets = "[]",
                                bracketsColor = '&f', -- white
                            }
                        )
                    end

                    os.queueEvent('redionet:issue_command', cmd)
                elseif cmd then
                    M.log_message(("Unknown Command: 'rn %s'\nAvailable: rn {%s}"):format(cmd, table.concat(M.commands_list, ', ')), "ERROR")
                end
            end
        )
    end
end

return M
