if periphemu then
    if not peripheral.find("computer") then
        shell.run("attach", "1", "computer")
        shell.run("attach", "2", "computer")
    
        -- https://www.craftos-pc.cc/docs/periphemu#:~:text=Speaker%20playAudio%20emulation%20differences
        -- periphemu.create("left", "speaker")
        periphemu.create("right", "modem")
        -- config.standardsMode = true 
        -- config.useDFPWM = true
    end
    peripheral.find("modem", rednet.open)
end

-- BROKEN
-- start -> Stop -> start
-- Not async reading bytes? long audio takes enormous amount of time to fetch (might still crash, todo test) 