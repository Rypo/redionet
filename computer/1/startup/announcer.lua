if periphemu then
    periphemu.create("left", "speaker")
    periphemu.create("right", "modem")
	-- config.standardsMode = true 
end

peripheral.find("modem", rednet.open)
rednet.host('PROTO_ANNOUNCE', 'musicbox')


local chatBox = peripheral.find("chatBox")
local playerDetector = peripheral.find("playerDetector")


--[[ // filler code  ]]
if not chatBox then
    chatBox = {}
    function chatBox.sendToastToPlayer(message, title, username, paren_text, paren_style, paren_color)
        local songstring = ("@%s:\n%s\n%s%s%s %s"):format(username, title, paren_style:sub(1,1), paren_text, paren_style:sub(2,2), message)
        print(songstring)
    end
    function chatBox.sendMessage(message, paren_text, paren_style, paren_color)
        local chatmessage = ("n%s%s%s %s"):format(paren_style:sub(1,1), paren_text, paren_style:sub(2,2), message)
        print(chatmessage)
    end
end
if not playerDetector then
    playerDetector = {}
    function playerDetector.getOnlinePlayers() return {'Player1',} end
end
--[[  end filler code // ]]


local POLL_FREQ = 3.0 -- Seconds between messages to avoid announcement spam

local function announce_playing(artist, song_title)
    for _, username in ipairs(playerDetector.getOnlinePlayers()) do
        chatBox.sendToastToPlayer(song_title, "Now Playing", username, "&4&l"..artist, "()", "&c&l")
    end
end

-- https://docs.advanced-peripherals.de/latest/peripherals/chat_box/
-- https://www.digminecraft.com/lists/color_list_pc.php
local msg_colors = {DEBUG = "&8", ERROR = "&4&l", INFO = "&f", STATE="&2"}

local function announce_loop()
    print('StartLoop: Announce')
    local id, message

    while true do
        id, message = rednet.receive('PROTO_ANNOUNCE')
        local msg_type, payload = table.unpack(message)

        if msg_type == 'SONG' then
            local artist, song_title = table.unpack(payload)
            announce_playing(artist, song_title)
            sleep(POLL_FREQ)
        elseif msg_type == 'PLAYER' then
            local msg_col = "&f"
            local username, pmsg = table.unpack(payload)
            chatBox.sendMessage(pmsg, msg_col..username, "<>", "&f")
        else
            local msg_col = msg_colors[msg_type] or "&k&0" -- defaults to obfuscated black
            chatBox.sendMessage(payload, msg_col..msg_type, "[]", "&d")
        end

    end
end

parallel.waitForAny(announce_loop)