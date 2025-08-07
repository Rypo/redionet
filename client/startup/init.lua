if periphemu then
    periphemu.create("left", "speaker")
    periphemu.create("right", "modem")
    -- periphemu.create("top", "monitor")
	-- config.standardsMode = true
end

peripheral.find("modem", rednet.open)



shell.run("client")