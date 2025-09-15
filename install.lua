--[[
_ _  _ ____ ___ ____ _    _    ____ ____
| |\ | [__   |  |__| |    |    |___ |__/
| | \| ___]  |  |  | |___ |___ |___ |  \

Github Repository: https://github.com/Rypo/redionet

]]
-- Install script based on: https://github.com/CC-YouCube/installer/blob/main/src/installer.lua
-- License: GPL-3.0
-- OpenInstaller v1.0.0 (based on wget)
local prog_args = { ... }


local BASE_URL = "https://raw.githubusercontent.com/Rypo/redionet/refs/heads/main/"

local filemap = {}

filemap["server"] = {
    ["./server.lua"] = BASE_URL ..              "server/server.lua",
    ["./server_lib/audio.lua"] = BASE_URL ..    "server/server_lib/audio.lua",
    ["./server_lib/chat.lua"] = BASE_URL ..     "server/server_lib/chat.lua",
    ["./server_lib/network.lua"] = BASE_URL ..  "server/server_lib/network.lua",
}

filemap["client"] = {
    ["./client.lua"] = BASE_URL ..              "client/client.lua",
    ["./client_lib/net.lua"] = BASE_URL ..      "client/client_lib/net.lua",
    ["./client_lib/receiver.lua"] = BASE_URL .. "client/client_lib/receiver.lua",
    ["./client_lib/ui.lua"] = BASE_URL ..       "client/client_lib/ui.lua",
}

local function load_settings(verbose)
    settings.define("redionet.device_type", {
        description = "Designation for this computer. 'client' or 'server'",
        type = "string",
    })
    settings.define("redionet.run_on_boot", {
        description = "Whether to autorun on computer startup",
        type = "boolean",
    })
    settings.define("redionet.log_level", {
        description = "Minimum severity to show in server console. 1=DEBUG, 2=INFO, 3=WARN, 4=ERROR. (default=3)",
        default = 3,
        type = "number",
    })
    -- *very* important to load before calling settings.save
    -- save overwrites the file, deleting anything not defined. 
    settings.load()

    if not verbose then return end

    -- print config if verbose
    local key_values = {}

    for _,option in ipairs(settings.getNames()) do
        local i_end = select(2, string.find(option, 'redionet'))
        if i_end then
            table.insert(key_values, {(" %s"):format(option:sub(i_end+1)), ("= %s"):format(settings.get(option))})
        end
    end
    if #key_values > 0 then
        term.setTextColor(colors.cyan)
        print('Redionet Settings') -- \149 

        term.setTextColor(colors.lightGray)
        print('redionet')
        textutils.tabulate(table.unpack(key_values))
        
        term.setTextColor(colors.white)
        write('press any key to continue..')
        term.setCursorBlink(true)
        os.pullEvent('key')
        write('\n')
        term.setCursorBlink(false)
    end
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

local function tf_question(message)
    local previous_colour = term.getTextColour()

    writeColoured(message .. " ", colors.cyan)
    term.blit("[Y/n] ", "050e0f", "ffffff") -- 0-white, 5-lime, e-red; f-black
    -- Reset colour
    term.setTextColour(colors.white)
    local c_x, c_y = term.getCursorPos()
    local input_char = read():sub(1, 1):lower()
    
    local accept_chars = { "o", "k", "y", "" }
    if input_char=="" then -- show the default
        term.setCursorPos(c_x, c_y)
        term.blit("Y", "5", "f")
        term.setCursorPos(1, c_y+1)
    end
    term.setTextColour(previous_colour)

    return tableContains(accept_chars, input_char)
end

local function mc_question(prompt_text, options, active_idx)
    active_idx = active_idx or 1
    local x,y = term.getCursorPos()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.clearLine()
    write(prompt_text)
    
    for i,opt in ipairs(options) do
        term.setCursorPos(2, y+i)
        if i == active_idx then
            term.setBackgroundColor(colors.white)
            term.setTextColour(colors.gray)
        else
            term.setBackgroundColor(colors.black)
            term.setTextColour(colors.white)
        end
        term.clearLine()
        write(opt)
    end

    local key_name
    repeat
        local ev, key, is_held = os.pullEvent("key")
        key_name = keys.getName(key)
        if key_name == "up" then
            active_idx = active_idx > 1 and active_idx-1 or #options
            term.setCursorPos(1, y)
            return mc_question(prompt_text, options, active_idx)
        elseif key_name == "down" then
            active_idx = 1 + (active_idx % #options)
            term.setCursorPos(1, y)
            return mc_question(prompt_text, options, active_idx)
        end
    until key_name == "enter"

    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, y + #options + 1)

    return active_idx
end

local function check_requirements()
    if not http then
        printError("OpenInstaller requires the http API")
        printError("Set http.enabled to true in the ComputerCraft config")
        error("http disabled.", 0)
    end

    local ok, dfpwm = pcall(require, "cc.audio.dfpwm")
    if not ok then
        printError("DFPWM required (CC version: 0.100.0 and later)")
        printError("Version found: ".._HOST)

        if not tf_question("Download anyway?") then
            error("Aborted.", 0)
        end
    end
    
end

local function http_get(url)
    local valid_url, error_message = http.checkURL(url)
    if not valid_url then
        printError(('"%s" %s.'):format(url, error_message or "Invalid URL"))
        return
    end

    local response, http_error_message = http.get(url, nil, true)
    if not response then
        printError(('Failed to download "%s" (%s).'):format(url, http_error_message or "Unknown error"))
        return
    end

    local response_body = response.readAll()
    response.close()

    if not response_body then
        printError(('Failed to download "%s" (Empty response).'):format(url))
    end

    return response_body
end

local function write_file(response_body, resolved_path)
    local file, file_open_error_message = fs.open(resolved_path, "wb")
    if not file then
        error(('Failed to save "%s" (%s).'):format(resolved_path, file_open_error_message or "Unknown error"), 0)
    end

    file.write(response_body)
    file.close()
end


local function check_peripherals(device_type)
    -- https://www.reddit.com/r/ComputerCraft/comments/1cc2y94/cc_character_cheat_sheet/#lightbox
    local function locate(peripheral_type)
        if peripheral.find(peripheral_type) then
            writeColoured(('ok - %s: Detected\n'):format(peripheral_type), colors.lime) --\215 )\16
            return true
        end
        return false
    end

    if not locate("modem") then
        writeColoured(('\19 - %s: Missing. Attach before running!\n'):format("modem"), colors.red)
    end

    if device_type == 'server' then
        if not locate("chatBox") then
            writeColoured(('\186 - %s: Missing (optional)\n'):format("chatBox"), colors.lightBlue)
            -- Attach for song announcements. (requires Advanced Peripherals mod) \21
        end
        if not locate("playerDetector") then
            writeColoured(('\186 - %s: Missing (optional)\n'):format("playerDetector"), colors.lightBlue)
            -- Attach for fancy song announcements. (requires Advanced Peripherals mod) \177
        end
    else
        local pocket_client = pocket and not pocket.equipBottom
        if pocket_client then
            writeColoured(('Pocket Client (no audio)\n'), colors.green)
        elseif not locate("speaker") then
            writeColoured(('\15 - %s: Missing. Attach to play music.\n'):format("speaker"), colors.orange)
        end
    end
end



local function fresh_install()
    term.clear()
    term.setCursorPos(1, 1)
    check_requirements()

    local choice_idx = mc_question('Assign this computer as', {'Client', 'Server   \4 only set one per world \4'})
    local device_type = ({'client', 'server'})[choice_idx]
    settings.set('redionet.device_type', device_type)
    
    local files = filemap[device_type]
    
    local run_on_boot = tf_question('Run on startup?')
    settings.set('redionet.run_on_boot', run_on_boot)

    if run_on_boot then
        files["./startup/init.lua"] = BASE_URL ..  device_type ..  "/startup/init.lua"
    end

    for path, download_url in pairs(files) do
        local resolved_path = shell.resolve(path)
        local can_write = true
        
        if fs.exists(resolved_path) then
            term.setTextColour(colors.yellow)
            print(("'%s' already exists."):format(path))
            can_write = tf_question(('\187 Overwrite?'):format(path))
        end
        
        if can_write then
            local response_body = http_get(download_url)

            write_file(response_body, resolved_path)

            term.setTextColour(colors.lime)
            print(('Downloaded "%s"'):format(path))
        end
    end

    term.setTextColor(colors.white)
    print("Done! Checking peripherals..")
    check_peripherals(device_type)

    term.setTextColor(colors.lightGray)
    print('\n' .. 'To execute program: ' .. (run_on_boot and "Reboot computer now" or ("Run `%s` in terminal"):format(device_type)))

    settings.save()
end

local function update(device_type)
    local files = filemap[device_type]
    
    local run_on_boot = settings.get('redionet.run_on_boot', fs.exists(shell.resolve("./startup/init.lua")))

    if run_on_boot then
        files["./startup/init.lua"] = BASE_URL ..  device_type ..  "/startup/init.lua"
    end
    
    local files_updated = false

    for path, download_url in pairs(files) do
        local resolved_path = shell.resolve(path)
        local response_body = http_get(download_url)

        local file, fopen_error = fs.open(resolved_path, 'rb')
        local cur_contents
        if file then
            cur_contents = file.readAll()
            file.close()
        end
        
        if cur_contents and cur_contents == response_body then
            writeColoured(('Up to date: "%s"\n'):format(path), colors.lightGray)
        else
            write_file(response_body, resolved_path)
            writeColoured(('Updated: "%s"\n'):format(path), colors.lime)
            files_updated = true
        end
    end

    return files_updated
end

local function parse_cli_flags()
    local flags = {
        force = false,
        verbose = false,
    }
    for _, value in pairs(prog_args) do
        if value == "-f" or value == "--force-reinstall" then flags.force = true
        elseif value == "-v" or value == "--verbose" then flags.verbose = true
        end
    end
    return flags
end

local function main()
    local flags = parse_cli_flags()

    load_settings(flags.verbose)
    local device_type = settings.get('redionet.device_type')

    local file_changes = true
    if flags.force or not device_type then
        fresh_install()
    else
        file_changes = update(device_type)
    end

    os.queueEvent('redionet:update_complete', file_changes)
end

main()