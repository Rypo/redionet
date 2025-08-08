--[[
_ _  _ ____ ___ ____ _    _    ____ ____
| |\ | [__   |  |__| |    |    |___ |__/
| | \| ___]  |  |  | |___ |___ |___ |  \

Github Repository: https://github.com/Rypo/redionet

]]
-- Install script based on: https://github.com/CC-YouCube/installer/blob/main/src/installer.lua
-- License: GPL-3.0
-- OpenInstaller v1.0.0 (based on wget)

local BASE_URL = "https://raw.githubusercontent.com/Rypo/redionet/refs/heads/main/"

local filemap = {}

filemap["server"] = {
    ["./server.lua"] = BASE_URL ..              "server/server.lua",
    ["./server_lib/audio.lua"] = BASE_URL ..    "server/server_lib/audio.lua",
    ["./server_lib/chat.lua"] = BASE_URL ..     "server/server_lib/chat.lua",
    ["./server_lib/network.lua"] = BASE_URL ..  "server/server_lib/network.lua",
    ["./server_lib/state.lua"] = BASE_URL ..    "server/server_lib/state.lua",
}

filemap["client"] = {
    ["./client.lua"] = BASE_URL ..              "client/client.lua",
    ["./client_lib/net.lua"] = BASE_URL ..      "client/client_lib/net.lua",
    ["./client_lib/receiver.lua"] = BASE_URL .. "client/client_lib/receiver.lua",
    ["./client_lib/ui.lua"] = BASE_URL ..       "client/client_lib/ui.lua",
}

if not http then
    printError("OpenInstaller requires the http API")
    printError("Set http.enabled to true in the ComputerCraft config")
    return
end



local function tableContains(_table, element)
    for _, value in pairs(_table) do
        if value == element then
            return true
        end
    end
    return false
end

local function writeColoured(text, colour)
    term.setTextColour(colour)
    write(text)
end

local function question(message)
    local previous_colour = term.getTextColour()

    writeColoured(message .. " ", colors.cyan)
    -- writeColoured("Y", colors.lime) -- 5	
    -- writeColoured("/", colors.orange) -- 1	
    -- writeColoured("n", colors.red) -- e
    -- writeColoured("] ", colors.orange)
    term.blit("[Y/n] ", "050e0f", "ffffff") -- 0-white, 5-lime, e-red; f-black
    -- Reset colour
    term.setTextColour(colors.white)

    local input_char = read():sub(1, 1):lower()
    local accept_chars = { "o", "k", "y", "" }
    
    term.setTextColour(previous_colour)

    return tableContains(accept_chars, input_char)
end

local function test_requirements()
    local ok, dfpwm = pcall(require, "cc.audio.dfpwm")
    if not ok then
        printError("DFPWM required (CC version: 0.100.0 and later)")
        printError("Version found: ".._HOST)

        if not question("Download anyway?") then
            error("Aborted.", 0)
        end
    end
    
end

local unknown_error = "Unknown error"

local function http_get(url)
    local valid_url, error_message = http.checkURL(url)
    if not valid_url then
        printError(('"%s" %s.'):format(url, error_message or "Invalid URL"))
        return
    end

    local response, http_error_message = http.get(url, nil, true)
    if not response then
        printError(('Failed to download "%s" (%s).'):format(url, http_error_message or unknown_error))
        return
    end

    local response_body = response.readAll()
    response.close()

    if not response_body then
        printError(('Failed to download "%s" (Empty response).'):format(url))
    end

    return response_body
end

local function check_peripherals(device_type)
    -- https://www.reddit.com/r/ComputerCraft/comments/1cc2y94/cc_character_cheat_sheet/#lightbox
    local function locate(peripheral_type)
        if peripheral.find(peripheral_type) then
            writeColoured(('\16 - %s : Detected\n'):format(peripheral_type), colors.lime)
            return true
        end
        return false
    end

    if not locate("modem") then
        writeColoured(('\215 - %s : Missing - Required. Attach before running.\n'):format("modem"), colors.red)
    end

    if device_type == 'server' then
        if not locate("chatBox") then
            writeColoured(('\21 - %s : Missing - Optional\n'):format("chatBox"), colors.yellow)
            -- Attach for song announcements. (requires Advanced Peripherals mod)
        end
        if not locate("playerDetector") then
            writeColoured(('\21 - %s : Missing - Optional\n'):format("playerDetector"), colors.yellow)
            -- Attach for fancy song announcements. (requires Advanced Peripherals mod)
        end
    else
        if not locate("speaker") then
            writeColoured(('\19 - %s : Missing - Recommended. Attach or device cannot play music!\n'):format("speaker"), colors.orange)
        end
    end
end

local function main()
    test_requirements()

    local is_client = question('Assign Client? ("n" to assign Server.. only do this once!)')
    local device_type = is_client and 'client' or 'server'


    local files = filemap[device_type]

    local run_on_start = question('Run on startup?')
    if run_on_start then
        files["./startup/init.lua"] = BASE_URL ..  device_type ..  "/startup/init.lua"
    end

    for path, download_url in pairs(files) do
        local resolved_path = shell.resolve(path)
        local can_write = true
        
        if fs.exists(resolved_path) then
            can_write = question(('"%s" already exists.\n\187 Overwrite?'):format(path))
        end
        
        if can_write then
            local response_body = http_get(download_url)

            local file, file_open_error_message = fs.open(resolved_path, "wb")
            if not file then
                error(('Failed to save "%s" (%s).'):format(path, file_open_error_message or unknown_error), 0)
            end

            file.write(response_body)
            file.close()

            term.setTextColour(colors.lime)
            print(('Downloaded "%s"'):format(path))
        end
    end

    print("Done!")
    check_peripherals(device_type)
    term.setTextColor(colors.lightGray)
    print( 'To execute program: ' .. (run_on_start and "Reboot computer now" or ("Run `%s`"):format(device_type)))


end


main()