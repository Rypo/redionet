if periphemu then
    if not peripheral.find("computer") then
        shell.run("attach", "1", "computer")
        shell.run("attach", "2", "computer")
    -- else
        -- peripheral.find("computer").reboot()
         -- https://www.craftos-pc.cc/docs/periphemu#:~:text=Speaker%20playAudio%20emulation%20differences
        -- periphemu.create("left", "speaker")
        periphemu.create("right", "modem")
        -- periphemu.create("top", "monitor")
        -- config.standardsMode = true
    end

end

if not debug then debug = { debug = function () end} end

peripheral.find("modem", rednet.open)

shell.run("server")
-- BROKEN
-- Not async reading bytes? long audio takes enormous amount of time to fetch (might still crash, todo test) 