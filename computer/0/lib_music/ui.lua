--[[
    UI module
    Handles all screen drawing and user input.
]]


-- local state = require("lib_music.state")
local network = require("lib_music.network")
local audio = require("lib_music.audio")

local M = {}


local config = {}

config.term_width, config.term_height = term.getSize()

config.colors = {
    black = colors.black,
    white = colors.white,
    gray = colors.gray,
    lightGray = colors.lightGray,
    red = colors.red,
}

config.tabs = { " Now Playing ", " Search " }

-- UI layout constants
config.ui = {
    -- Now Playing Tab
    play_button = { x = 2, y = 6, width = 6, label_play = " Play ", label_stop = " Stop " },
    skip_button = { x = 9, y = 6, width = 6, label = " Skip " },
    -- loop_button = { x = 16, y = 6, width = 12, labels = { " Loop Off ", " Loop Queue ", " Loop Song " } },
    loop_button = { x = 16, y = 6, width = 11, labels = { " Loop Off ", " Loop List ", " Loop Song " } },
    volume_slider = { x = 2, y = 8, width = 25 },

    -- Search Tab
    search_bar = { x = 2, y = 3, width = config.term_width - 2, height = 3 },
    search_result = { start_y = 7, height = 2 },

    -- Search Result Menu
    menu_play_now = { x = 2, y = 6, label = "Play now" },
    menu_play_next = { x = 2, y = 8, label = "Play next" },
    menu_add_to_queue = { x = 2, y = 10, label = "Add to queue" },
    menu_cancel = { x = 2, y = 13, label = "Cancel" },
}


local function draw_tabs()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(config.colors.gray)
    term.clearLine()

    for i, tab_label in ipairs(config.tabs) do
        if STATE.active_tab == i then
            term.setTextColor(config.colors.black)
            term.setBackgroundColor(config.colors.white)
        else
            term.setTextColor(config.colors.white)
            term.setBackgroundColor(config.colors.gray)
        end
        local x = math.floor((config.term_width / #config.tabs) * (i - 0.5)) - math.ceil(#tab_label / 2) + 1
        term.setCursorPos(x, 1)
        term.write(tab_label)
    end
end

local function draw_now_playing_tab()
    -- Song info
    term.setBackgroundColor(config.colors.black)
    if STATE.active_song_meta then
        term.setTextColor(config.colors.white)
        term.setCursorPos(2, 3)
        term.write(STATE.active_song_meta.name)
        term.setTextColor(config.colors.lightGray)
        term.setCursorPos(2, 4)
        term.write(STATE.active_song_meta.artist)
    else
        term.setTextColor(config.colors.lightGray)
        term.setCursorPos(2, 3)
        term.write("Not playing")
    end

    -- Status message
    if STATE.is_loading then
        term.setTextColor(config.colors.gray)
        term.setCursorPos(2, 5)
        term.write("Loading...")
    elseif STATE.error_status then
        term.setTextColor(config.colors.red)
        term.setCursorPos(2, 5)
        term.write("Network error: " .. STATE.error_status)
    end

    -- Buttons
    local btn_cfg
    local can_interact = STATE.active_song_meta or #STATE.queue > 0
    local btn_color = can_interact and config.colors.white or config.colors.lightGray
    term.setBackgroundColor(config.colors.gray)

    -- Play/Stop
    btn_cfg = config.ui.play_button
    term.setTextColor(btn_color)
    term.setCursorPos(btn_cfg.x, btn_cfg.y)
    term.write((STATE.is_paused == false) and btn_cfg.label_stop or btn_cfg.label_play) -- STATE.is_paused==nil should show play label, no falsy eval

    -- Skip
    btn_cfg = config.ui.skip_button
    term.setTextColor(btn_color)
    term.setCursorPos(btn_cfg.x, btn_cfg.y)
    term.write(btn_cfg.label)

    -- Loop
    btn_cfg = config.ui.loop_button
    if STATE.loop_mode ~= 0 then
        term.setTextColor(config.colors.black)
        term.setBackgroundColor(config.colors.white)
    else
        term.setTextColor(config.colors.white)
        term.setBackgroundColor(config.colors.gray)
    end
    term.setCursorPos(btn_cfg.x, btn_cfg.y)
    term.write(btn_cfg.labels[STATE.loop_mode + 1])

    -- Volume slider
    local vol_cfg = config.ui.volume_slider
    paintutils.drawBox(vol_cfg.x, vol_cfg.y, vol_cfg.x + vol_cfg.width - 1, vol_cfg.y, config.colors.gray)
    local handle_width = math.floor((vol_cfg.width - 1) * (STATE.volume / 3) + 0.5)
    if handle_width > 0 then
        paintutils.drawBox(vol_cfg.x, vol_cfg.y, vol_cfg.x + handle_width - 0, vol_cfg.y, config.colors.white)
    end
    local percent_str = math.floor(100 * (STATE.volume / 3) + 0.5) .. "%"
    if handle_width > #percent_str + 2 then
        term.setBackgroundColor(config.colors.white)
        term.setTextColor(config.colors.black)
        term.setCursorPos(vol_cfg.x + handle_width - #percent_str - 1, vol_cfg.y)
    else
        term.setBackgroundColor(config.colors.gray)
        term.setTextColor(config.colors.white)
        term.setCursorPos(vol_cfg.x + handle_width + 1, vol_cfg.y)
    end
    term.write(percent_str)


    -- Queue
    if #STATE.queue > 0 then
        term.setBackgroundColor(config.colors.black)
        for i, song in ipairs(STATE.queue) do
            term.setTextColor(config.colors.white)
            term.setCursorPos(2, 10 + (i - 1) * 2)
            term.write(song.name)
            term.setTextColor(config.colors.lightGray)
            term.setCursorPos(2, 11 + (i - 1) * 2)
            term.write(song.artist)
        end
    end
end

local function draw_search_tab()
    -- Search bar
    local sbar = config.ui.search_bar
    paintutils.drawFilledBox(sbar.x, sbar.y, sbar.x + sbar.width - 1, sbar.y + sbar.height - 1, config.colors.lightGray)
    term.setBackgroundColor(config.colors.lightGray)
    term.setCursorPos(sbar.x + 1, sbar.y + 1)
    term.setTextColor(config.colors.black)
    term.write(STATE.last_search_query or "Search...")

    -- Search results
    term.setBackgroundColor(config.colors.black)
    if STATE.search_results then
        for i, result in ipairs(STATE.search_results) do
            local y = config.ui.search_result.start_y + (i - 1) * config.ui.search_result.height

            term.setTextColor(config.colors.white)
            term.setCursorPos(2, y)
            term.write(result.name)
            term.setTextColor(config.colors.lightGray)
            term.setCursorPos(2, y + 1)
            term.write(result.artist)
        end
    else
        term.setCursorPos(2, config.ui.search_result.start_y)
        if STATE.error_status == "SEARCH_ERROR" then
            term.setTextColor(config.colors.red)
            term.write("Network error: Search")
        elseif STATE.last_search_query then
            term.setTextColor(config.colors.lightGray)
            term.write("Searching...")
        else
            term.setTextColor(config.colors.lightGray)
            print("Tip: You can paste YouTube video or playlist links.")
        end
    end
end

local function draw_search_result_menu()
    term.setBackgroundColor(config.colors.black)
    term.clear() -- temp removes tabs: [Now Playing ] [ Search ]

    local result = STATE.search_results[STATE.clicked_result_index]
    term.setCursorPos(2, 2)
    term.setTextColor(config.colors.white)
    term.write(result.name)
    term.setCursorPos(2, 3)
    term.setTextColor(config.colors.lightGray)
    term.write(result.artist)

    term.setBackgroundColor(config.colors.gray)
    term.setTextColor(config.colors.white)

    local menu_items = {
        config.ui.menu_play_now,
        config.ui.menu_play_next,
        config.ui.menu_add_to_queue,
        config.ui.menu_cancel
    }
    for _, item in ipairs(menu_items) do
        term.setCursorPos(item.x, item.y)
        term.clearLine() -- Write full length of term
        term.write(item.label)
    end
end

function M.redraw_screen()
    if STATE.waiting_for_input then return end

    term.setCursorBlink(false)
    term.setBackgroundColor(config.colors.black)
    term.clear()

    draw_tabs()

    if STATE.in_search_result_view then
        draw_search_result_menu()
    elseif STATE.active_tab == 1 then
        draw_now_playing_tab()
    elseif STATE.active_tab == 2 then
        draw_search_tab()
    end
end

local function handle_search_input()
    local sbar = config.ui.search_bar
    paintutils.drawFilledBox(sbar.x, sbar.y, sbar.x + sbar.width - 1, sbar.y + sbar.height - 1, colors.white)
    term.setBackgroundColor(config.colors.white)

    term.setCursorPos(sbar.x + 1, sbar.y + 1)

    term.setTextColor(config.colors.black)
    term.setCursorBlink(true)
    -- term.clearLine() --- This was cause of long skinny bar problem

    local input = read()
    term.setCursorBlink(false)

    if input and #input > 0 then
        network.search(input)
    else
        STATE.last_search_query = nil
        STATE.search_results = nil
        STATE.error_status = false
    end

    STATE.waiting_for_input = false
    M.redraw_screen()
end

local function is_in_box(x, y, box)
    return x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + (box.height or 1)
end

local function delay_flash(menu_button)
    -- Click feedback - turn line white breifly on click
    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)
    term.setCursorPos(2, menu_button.y)
    term.clearLine()
    term.write(menu_button.label)
    sleep(0.2)
end

local function handle_click(button, x, y)
    if button ~= 1 then return end

    if STATE.in_search_result_view then
        -- Handle clicks in the search result menu
        local result = STATE.search_results[STATE.clicked_result_index]

        local btn_clicked

        if y == config.ui.menu_play_now.y then -- Play now
            btn_clicked = config.ui.menu_play_now
            -- audio.stop_song()
            -- STATE.is_playback_active = true
            if result.type == "playlist" then
                audio.play_song(result.playlist_items[1])
                -- STATE.active_song_meta = result.playlist_items[1]
                -- STATE.queue = {}
                for i = 2, #result.playlist_items do table.insert(STATE.queue, result.playlist_items[i]) end
            else
                audio.play_song(result)
                -- STATE.active_song_meta = result
                -- STATE.queue = {}
            end
        elseif y == config.ui.menu_play_next.y then -- Play next
            btn_clicked = config.ui.menu_play_next
            if result.type == "playlist" then
                for i = #result.playlist_items, 1, -1 do table.insert(STATE.queue, 1, result.playlist_items[i]) end
            else
                table.insert(STATE.queue, 1, result)
            end
        elseif y == config.ui.menu_add_to_queue.y then -- Add to queue
            btn_clicked = config.ui.menu_add_to_queue
            if result.type == "playlist" then
                for _, item in ipairs(result.playlist_items) do table.insert(STATE.queue, item) end
            else
                table.insert(STATE.queue, result)
            end
        end

        if btn_clicked then
            delay_flash(btn_clicked)
            -- os.queueEvent('audio_update')
        end

        STATE.in_search_result_view = false

        M.redraw_screen()
        return
    end

    -- Tab clicks
    if y == 1 then
        STATE.active_tab = x < config.term_width / 2 and 1 or 2
        M.redraw_screen()
        return
    end

    if STATE.active_tab == 1 then -- Now Playing Tab
        
        if y == config.ui.play_button.y then
            local buttons_enabled = STATE.active_song_meta ~= nil or #STATE.queue > 0

            if is_in_box(x, y, config.ui.play_button) and buttons_enabled then
                audio.toggle_play_pause()
            
            elseif is_in_box(x, y, config.ui.skip_button) and buttons_enabled then
                audio.skip_song()
            
            elseif is_in_box(x, y, config.ui.loop_button) then
                STATE.loop_mode = (STATE.loop_mode + 1) % 3
            end
        elseif y == config.ui.volume_slider.y then
            if is_in_box(x, y, config.ui.volume_slider) then
                STATE.volume = (x - config.ui.volume_slider.x) / (config.ui.volume_slider.width - 1) * 3
            end
        end
        M.redraw_screen()
        -- return
    elseif STATE.active_tab == 2 then -- Search Tab
        if is_in_box(x, y, config.ui.search_bar) then
            STATE.waiting_for_input = true
            return
        end

        if STATE.search_results then
            for i, _ in ipairs(STATE.search_results) do
                local sr_cfg = config.ui.search_result
                local box = { x = 2, y = sr_cfg.start_y + (i - 1) * sr_cfg.height, width = config.term_width - 2, height = sr_cfg.height }
                if is_in_box(x, y, box) then
                    STATE.in_search_result_view = true
                    STATE.clicked_result_index = i
                    M.redraw_screen()
                    return
                end
            end
        end
    end
end

local function handle_click_out()
    while STATE.waiting_for_input do
        local event, button, x, y = os.pullEvent("mouse_click")
        if not is_in_box(x, y, config.ui.search_bar) then
            STATE.waiting_for_input = false
            handle_click(button, x, y)
        end
    end
end

function M.ui_loop()
    M.redraw_screen()
    while true do
        if STATE.waiting_for_input then
            parallel.waitForAny(handle_search_input, handle_click_out)
        else
            -- local eventData = {os.pullEvent()}
            -- local event = eventData[1]
            local event, button, x, y = os.pullEvent()

            if event == "mouse_click" then
                -- local button, x, y = table.unpack(eventData, 2)
                handle_click(button, x, y)
            elseif event == "mouse_drag" and STATE.active_tab == 1 and y == config.ui.volume_slider.y then
                -- local button, x, y = table.unpack(eventData, 2)
                if is_in_box(x, y, config.ui.volume_slider) then
                    STATE.volume = (x - config.ui.volume_slider.x) / (config.ui.volume_slider.width - 1) * 3
                    M.redraw_screen()
                end
            elseif event == "redraw_screen" then
                M.redraw_screen()
            end
        end
    end
end

return M
