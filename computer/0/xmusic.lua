--[[
    Main application file for the music player.
    This file loads all the necessary modules and starts the main application loops.
]]


-- if periphemu then
-- 	-- https://www.craftos-pc.cc/docs/periphemu#:~:text=Speaker%20playAudio%20emulation%20differences
--     periphemu.create("left", "speaker")
--     periphemu.create("right", "modem")
-- 	-- config.standardsMode = true 
--     -- config.useDFPWM = true
-- end

local ui = require("lib_music.ui")
local audio = require("lib_music.audio")
local network = require("lib_music.network")

STATE = require("lib_music.state")

if not debug then
    debug = { debug = function () end}
end
-- Start the main loops
parallel.waitForAny(
    ui.ui_loop,
    audio.audio_loop,
    network.handle_http_events
)
