local pretty = require("cc.pretty")

local M = {}


M.HOST_announcer = rednet.lookup("PROTO_ANNOUNCE", "musicbox")

function M.announce_song(active_song_meta)
    rednet.send(M.HOST_announcer, {"SONG", { active_song_meta.artist, active_song_meta.name }}, "PROTO_ANNOUNCE")
end

--- Write text in the chat
---@param message string The name of the speaker peripheral.
---@param msg_type string? One of DEBUG, ERROR, INFO, STATE defaults to DEBUG
function M.chat_message(message, msg_type)
    msg_type = msg_type or "DEBUG"
    local log_msg = string.format("[%s] (%s) %s", msg_type, os.date("%H:%M:%S"), message .. "\n")
    if msg_type ~= "INFO" then
        io.open('debug.log', 'a'):write(log_msg):close()
    end
    rednet.send(M.HOST_announcer, {msg_type, message}, "PROTO_ANNOUNCE")
end

function M.format_state(state, as_pdoc)
    local d_state = {}
    for k,v in pairs(state) do
        if not string.find(k, 'handle') then
            if type(v) ~= "table" or #v < 10 then d_state[k] = v end
        end
    end
    local pdoc = pretty.pretty(d_state)
    if as_pdoc then
        return pdoc
    end
    -- local ser_d_state = textutils.serializeJSON(d_state)
    return pretty.render(pdoc, 20)
end

function M.dump_state(state, in_chat)
    local ser_d_state = M.format_state(state, false)
    if in_chat then
        M.chat_message(ser_d_state, "STATE")
    end

    io.open('debug.log', 'a'):write(ser_d_state .. "\n"):close()
end


return M