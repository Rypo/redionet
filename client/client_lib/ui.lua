--[[
    UI module
    Handles all screen drawing and user input.
]]

local net = require("client_lib.net")
local receiver = require("client_lib.receiver")

local M = {}


local config = {}

config.term_width, config.term_height = term.getSize()

config.colors = { -- TODO: either semantically meaningful names (e.g. text, text_active, bg, bg_active) or remove
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
    play_button = { x = 2, y = 6, width = 6, label_play = " Play ", label_stop = " Stop ", label_mute = " Mute " },
    skip_button = { x = 9, y = 6, width = 6, label = " Skip " },
    loop_button = { x = 16, y = 6, width = 11, labels = { " Loop Off ", " Loop List ", " Loop Song " } },
    volume_slider = { x = 2, y = 8, width = 25 },
    queue = { start_y = 10, height = 2 },

    -- Search Tab
    search_bar = { x = 2, y = 3, width = config.term_width - 2, height = 3 },
    search_result = { start_y = 7, height = 2 },

    -- Search Result Menu
    menu_play_now = { x = 2, y = 6, label = "Play now" },
    menu_play_next = { x = 2, y = 8, label = "Play next" },
    menu_add_to_queue = { x = 2, y = 10, label = "Add to queue" },
    menu_cancel = { x = 2, y = 13, label = "Cancel" },
}

config.client_mode_mute = false
--[[ 
Mute Mode
- Cons: Significant delay on "Play/Mute" (waiting for speaker buffer clear)
- Pros: Other clients are completely unaffected by a client's Mute/Play

Local Stop Mode
- Cons: Other clients need to stop and jump forward (speaker buffer clear) whenever a client hits "Play"
- Pros: Near instant button feedback

The Ideal Mode (TODO)
- client click "Stop", instant stop, other clients unaffected 
- client click "Play", delay (w/ "joining.." message) until other clients' speaker buffers are empty, then begin playback, other clients unaffected 
- pinning down the point of safe entry and how to delay w/o timeout until it's reached has been the key implementation challenge thus far
]]


-- UI CLIENT STATE --
M.state = {}
M.state.active_tab = 1
M.state.waiting_for_input = false
M.state.in_search_result_view = false
M.state.clicked_result_index = nil
M.state.loop_mode = 0

-- Local only
M.state.search_items_visible = math.floor((config.term_height - config.ui.search_result.start_y) / config.ui.search_result.height)
M.state.hl_idx = nil
M.state.sr_menu = {
    items = {
        config.ui.menu_play_now,
        config.ui.menu_play_next,
        config.ui.menu_add_to_queue,
        config.ui.menu_cancel
    },
    hl_idx = 3, -- add_to_queue default highlighted
}

local function set_colors(text, bg, term_redirect)
    term_redirect = term_redirect or term
    if text then term_redirect.setTextColor(text) end
    if bg then term_redirect.setBackgroundColor(bg) end
end

local function draw_tabs()
    term.setCursorPos(1, 1)
    term.setBackgroundColor(config.colors.gray)
    term.clearLine()

    for i, tab_label in ipairs(config.tabs) do
        if M.state.active_tab == i then
            set_colors(config.colors.black, config.colors.white)
        else
            set_colors(config.colors.white, config.colors.gray)
        end
        local x = math.floor((config.term_width / #config.tabs) * (i - 0.5)) - math.ceil(#tab_label / 2) + 1
        term.setCursorPos(x, 1)
        term.write(tab_label)
    end
end

local function draw_now_playing_tab()
    
    -- Song info
    local active_song_meta = CSTATE.server_state.active_song_meta
    term.setBackgroundColor(config.colors.black)
    if active_song_meta then
        term.setTextColor(config.colors.white)
        term.setCursorPos(2, 3)
        term.write(active_song_meta.name)
        term.setTextColor(config.colors.lightGray)
        term.setCursorPos(2, 4)
        term.write(active_song_meta.artist)
    else
        term.setTextColor(config.colors.lightGray)
        term.setCursorPos(2, 3)
        term.write("Server: ")
        if CSTATE.server_state.status == -1 then
            term.write("waiting..")
        elseif CSTATE.server_state.status == 0 then
            term.write("stopped")
        else
            term.write("loading..")
        -- elseif CSTATE.server_state.status == 1 then
        --     term.write("Streaming")
        end
        
        term.setCursorPos(2, 4)

        term.write("Client: ")
        if CSTATE.is_paused then
            term.write("paused")
        else
            term.write("ready")
        end
        
    end
    
    
    -- Status message
    local is_loading = CSTATE.server_state.is_loading
    local error_status = CSTATE.server_state.error_status or CSTATE.error_status
    if is_loading then
        term.setTextColor(config.colors.gray)
        term.setCursorPos(2, 5)
        term.write("Loading...")
    elseif error_status then
        term.setTextColor(config.colors.red)
        term.setCursorPos(2, 5)
        term.write("Network error: " .. error_status)
    end


    -- Buttons
    local btn_cfg

    -- Play/Stop
    btn_cfg = config.ui.play_button

    -- Server playing marker tab
    local status_color = (CSTATE.server_state.status == -1 and colors.orange) or (CSTATE.server_state.status == 1 and colors.red) or (CSTATE.server_state.status == 0 and colors.green)
    paintutils.drawBox(btn_cfg.x-1, btn_cfg.y, btn_cfg.x-1, btn_cfg.y, status_color)
    
    if CSTATE.server_state.status > -1 then
        term.setTextColor(config.colors.white)
        term.setCursorPos(btn_cfg.x-1, btn_cfg.y)
        term.write(status_color == colors.red and '\120' or status_color == colors.green and '\16')
    end

    set_colors(config.colors.white, config.colors.gray) -- reset after box draw
    term.setCursorPos(btn_cfg.x, btn_cfg.y)

    if config.client_mode_mute then
        term.write((CSTATE.is_muted == false) and btn_cfg.label_mute or btn_cfg.label_play)
    else
        term.write((CSTATE.is_paused == false) and btn_cfg.label_stop or btn_cfg.label_play) -- STATE.is_paused==nil should show play label, no falsy eval
    end

    -- Skip
    local skip_enabled = CSTATE.server_state.status > -1 --active_song_meta or #queue > 0
    local btn_color = skip_enabled and config.colors.white or config.colors.lightGray
    
    btn_cfg = config.ui.skip_button
    term.setTextColor(btn_color) -- skip button will depend on if there are song available to play
    term.setCursorPos(btn_cfg.x, btn_cfg.y)
    term.write(btn_cfg.label)

    -- Loop
    M.state.loop_mode = CSTATE.server_state.loop_mode -- sync up with server state  
    btn_cfg = config.ui.loop_button
    if M.state.loop_mode ~= 0 then
        set_colors(config.colors.black, config.colors.white)
    else
        set_colors(config.colors.white, config.colors.gray)
    end
    term.setCursorPos(btn_cfg.x, btn_cfg.y)
    term.write(btn_cfg.labels[M.state.loop_mode + 1])

    -- Volume slider
    local vol_cfg = config.ui.volume_slider
    paintutils.drawBox(vol_cfg.x, vol_cfg.y, vol_cfg.x + vol_cfg.width - 1, vol_cfg.y, config.colors.gray)
    local handle_width = math.floor((vol_cfg.width - 1) * (CSTATE.volume / 3) + 0.5)
    if handle_width > 0 then
        paintutils.drawBox(vol_cfg.x, vol_cfg.y, vol_cfg.x + handle_width - 0, vol_cfg.y, config.colors.white)
    end
    local percent_str = math.floor(100 * (CSTATE.volume / 3) + 0.5) .. "%"
    if handle_width > #percent_str + 2 then
        set_colors(config.colors.black, config.colors.white)
        term.setCursorPos(vol_cfg.x + handle_width - #percent_str - 1, vol_cfg.y)
    else
        set_colors(config.colors.white, config.colors.gray)
        term.setCursorPos(vol_cfg.x + handle_width + 1, vol_cfg.y)
    end
    term.write(percent_str)

    
    -- Queue
    local queue = CSTATE.server_state.queue
    if #queue > 0 then
        term.setBackgroundColor(config.colors.black)

        local y = config.ui.queue.start_y - 1 -- -1 for cleaner +1s
        for i, song in ipairs(queue) do
            if y+2 > config.term_height then break end -- only write visible 

            y = y+1
            term.setTextColor(config.colors.white)
            term.setCursorPos(2, y)
            term.write(song.name)

            y = y+1
            term.setTextColor(config.colors.lightGray)
            term.setCursorPos(2, y)
            term.write(song.artist)
        end
    end
end


local function search_result_subset()
    local idx_start = 0
    local n_items = M.state.search_items_visible
    -- local n_items = math.floor((config.term_height - config.ui.search_result.start_y) / config.ui.search_result.height)

    if M.state.hl_idx then
        idx_start = math.floor((M.state.hl_idx-1) / n_items) * n_items
    end
    local idx_end = math.min(idx_start+n_items, #CSTATE.search_results)

    local sr_subset = {} -- TODO: this could be simplifed to an offset and length
    for i= 1+idx_start, idx_end do
        -- sr_subset[i] = CSTATE.search_results[i]
        table.insert(sr_subset, i)
    end
    return sr_subset

end


local function write_search_results()
    local sr_cfg = config.ui.search_result
    local orig_term = term.current()
    local sr_window = window.create(term.current(), 1, sr_cfg.start_y, config.term_width, config.term_height-sr_cfg.start_y)

    set_colors(config.colors.white, config.colors.black, sr_window)
    sr_window.clear()
    -- term.redirect(sr_window)

    -- for i = 1+idx_start, idx_end, 1 do
    local sr_subset = search_result_subset()
    -- rednet.send(SERVER_ID, {"LOG", pretty.render(pretty.pretty(sr_subset))}, 'PROTO_SERVER')
    -- for i,result in ipairs(sr_subset) do
    local y = 1
    -- for k,result in pairs(sr_subset) do
    for _,k in pairs(sr_subset) do
        -- if i == M.state.hl_idx then bg_color, song_color = song_color, bg_color end

        -- local y =1 + (i - 1) * sr_cfg.height
        -- local y = sr_cfg.start_y + (i - 1) * sr_cfg.height
        -- local y = sr_cfg.start_y + ((i - 1) % n_display) * sr_cfg.height
        -- local y = ((k - 1) % n_display) * sr_cfg.height
        local result = CSTATE.search_results[k]
        if k == M.state.hl_idx then -- invert colors
            set_colors(config.colors.black, config.colors.white, sr_window)
        else
            set_colors(config.colors.white, config.colors.black, sr_window)
        end

        -- sr_window.setCursorPos(2, y)
        sr_window.setCursorPos(2, y)
        sr_window.clearLine()
        sr_window.write(result.name)
        y = y + 1
        -- if result then term.write(result.name) end
        
        sr_window.setTextColor(config.colors.lightGray)
        -- sr_window.setCursorPos(2, y + 1)
        sr_window.setCursorPos(2, y)
        sr_window.clearLine()

        sr_window.write(result.artist)
        y = y + 1
        -- if result then term.write(result.artist) end
        
        -- if i == M.state.hl_idx then bg_color, song_color = song_color, bg_color end -- swap back
    end
    -- sr_window.setVisible(false)
    -- term.setBackgroundColor(config.colors.black)
    -- term.redirect(orig_term)
end

local function draw_search_tab()
    -- Search bar
    local sbar = config.ui.search_bar
    paintutils.drawFilledBox(sbar.x, sbar.y, sbar.x + sbar.width - 1, sbar.y + sbar.height - 1, config.colors.lightGray)

    set_colors(config.colors.black, config.colors.lightGray)
    term.setCursorPos(sbar.x + 1, sbar.y + 1)
    term.write(CSTATE.last_search_query or "Search...")

    -- Search results
    term.setBackgroundColor(config.colors.black)
    if CSTATE.search_results then
        write_search_results()
    else
        term.setCursorPos(2, config.ui.search_result.start_y)
        if CSTATE.error_status == "SEARCH_ERROR" then
            term.setTextColor(config.colors.red)
            term.write("Network error: Search")
        elseif CSTATE.last_search_query then
            term.setTextColor(config.colors.lightGray)
            term.write("Searching...")
        else
            term.setTextColor(config.colors.lightGray)
            print("Tip: You can paste YouTube video or playlist links.")
        end
    end
end

local function write_play_options()
    for i, item in ipairs(M.state.sr_menu.items) do
        if i == M.state.sr_menu.hl_idx then
            set_colors(config.colors.black, config.colors.white)
        else
            set_colors(config.colors.white, config.colors.gray)
        end
        term.setCursorPos(item.x, item.y)
        term.clearLine() -- Write full length of term
        term.write(item.label)
    end
end

local function draw_search_result_menu()
    term.setBackgroundColor(config.colors.black)
    term.clear() -- temp removes tabs: [Now Playing ] [ Search ]

    local result = CSTATE.search_results[M.state.clicked_result_index]
    term.setCursorPos(2, 2)
    term.setTextColor(config.colors.white)
    term.write(result.name)
    -- write(result.name .. '\n') -- can't wrap or throws off click index
    term.setCursorPos(2, 3)
    term.setTextColor(config.colors.lightGray)
    term.write(result.artist)

    write_play_options()
end

---refresh client ui
function M.redraw_screen()
    if M.state.waiting_for_input then return end

    term.setCursorBlink(false)
    term.setBackgroundColor(config.colors.black)
    term.clear()

    draw_tabs()

    if M.state.in_search_result_view then
        draw_search_result_menu()
    elseif M.state.active_tab == 1 then
        draw_now_playing_tab()
    elseif M.state.active_tab == 2 then
        draw_search_tab()
    end
end

local function handle_search_input()
    local sbar = config.ui.search_bar
    paintutils.drawFilledBox(sbar.x, sbar.y, sbar.x + sbar.width - 1, sbar.y + sbar.height - 1, colors.white)

    set_colors(config.colors.black, config.colors.white)
    term.setCursorPos(sbar.x + 1, sbar.y + 1)
    term.setCursorBlink(true)

    local input = read()
    term.setCursorBlink(false)

    if input and #input > 0 then
        M.state.hl_idx = nil -- reset highlighted index, if any
        net.search(input)
    -- else
    --     CSTATE.last_search_query = nil
    --     CSTATE.search_results = nil
    --     CSTATE.error_status = false
    end

    M.state.waiting_for_input = false
    M.redraw_screen()
end

local function is_in_box(x, y, box)
    return x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + (box.height or 1)
end

local function delay_flash(menu_button)
    -- Click feedback - turn line white breifly on click
    set_colors(config.colors.black, config.colors.white)
    term.setCursorPos(2, menu_button.y)
    term.clearLine()
    term.write(menu_button.label)
    os.sleep(0.2) -- note: thread events discarded during sleep, okay?  -- https://tweaked.cc/module/_G.html#v:sleep
end

local function handle_click(button, x, y)
    -- 1: Lclick, 2: Rclick | 0: custom, "fake" click
    if button > 1 then return end

    if M.state.in_search_result_view then
        -- Handle clicks in the search result menu
        local result = CSTATE.search_results[M.state.clicked_result_index]

        local btn_clicked, code

        if y == config.ui.menu_play_now.y then -- Play now
            btn_clicked = config.ui.menu_play_now
            code = "NOW"

        elseif y == config.ui.menu_play_next.y then -- Play next
            btn_clicked = config.ui.menu_play_next
            code = "NEXT"

        elseif y == config.ui.menu_add_to_queue.y then -- Add to queue
            btn_clicked = config.ui.menu_add_to_queue
            code = "ADD"
        
        elseif y == config.ui.menu_cancel.y then -- Cancel
            btn_clicked = config.ui.menu_cancel
            code = nil
        else
            return -- no op
        end

        if btn_clicked and button~=0 then -- no flash for hotkey
            delay_flash(btn_clicked)
        end

        M.state.in_search_result_view = false
        M.state.sr_menu.hl_idx = 3 -- reset back to default

        M.redraw_screen()

        if code then
            receiver.send_server_queue(result, code)
        end
        
        return
    end

    -- Tab clicks
    if y == 1 then
        M.state.active_tab = x < config.term_width / 2 and 1 or 2
        M.redraw_screen()
        return
    end

    if M.state.active_tab == 1 then -- Now Playing Tab
        
        if x == 1 and y == config.ui.play_button.y then -- click server play status tab
            receiver.send_server_player("TOGGLE") -- global play/pause

        elseif y == config.ui.play_button.y then
            local buttons_enabled = CSTATE.server_state.status > -1
            
            if is_in_box(x, y, config.ui.play_button) then
                if config.client_mode_mute then
                    receiver.toggle_play_mute()
                else
                    receiver.toggle_play_pause() -- local play/pause
                end
            
            elseif is_in_box(x, y, config.ui.skip_button) and buttons_enabled then
                receiver.send_server_player("SKIP")
            
            elseif is_in_box(x, y, config.ui.loop_button) then
                M.state.loop_mode = (M.state.loop_mode + 1) % 3
                receiver.send_server_player("LOOP", M.state.loop_mode)
            end
        elseif y == config.ui.volume_slider.y then
            if is_in_box(x, y, config.ui.volume_slider) then
                CSTATE.volume = (x - config.ui.volume_slider.x) / (config.ui.volume_slider.width - 1) * 3
            end
        end
        
        M.redraw_screen()
        
    elseif M.state.active_tab == 2 then -- Search Tab
        if is_in_box(x, y, config.ui.search_bar) then
            M.state.waiting_for_input = true
            return
        end

        if CSTATE.search_results then
            -- for i, _ in ipairs(CSTATE.search_results) do
            local sr_cfg = config.ui.search_result
            for i, k in ipairs(search_result_subset()) do
                
                local box = { x = 2, y = sr_cfg.start_y + (i - 1) * sr_cfg.height, width = config.term_width - 2, height = sr_cfg.height }
                if is_in_box(x, y, box) then
                    M.state.in_search_result_view = true
                    -- M.state.clicked_result_index = i
                    M.state.clicked_result_index = k
                    M.redraw_screen()
                    return
                end
            end
        end
    end
end

local function handle_drag(button, x, y)
    if button > 1 then return end
    if M.state.active_tab == 1 and y == config.ui.volume_slider.y and is_in_box(x, y, config.ui.volume_slider) then
        CSTATE.volume = (x - config.ui.volume_slider.x) / (config.ui.volume_slider.width - 1) * 3
        M.redraw_screen()
    end
end

local function handle_key_press(key, is_held)
    local key_name = keys.getName(key)
    if M.state.active_tab == 1 then -- Now Playing Tab Hotkeys
        if key_name == "right" then
            M.state.active_tab = 2
            M.redraw_screen()
        end
        
    elseif M.state.active_tab == 2 then -- Search Tab Hotkeys
        if key_name == "left" and not M.state.in_search_result_view then
            M.state.active_tab = 1
            M.redraw_screen()
        
        elseif key_name == "enter" and M.state.hl_idx == nil and not M.state.in_search_result_view then -- enter into search_bar by pressing enter provided nothing is selected
            M.state.waiting_for_input = true
            return

        
        elseif CSTATE.search_results then -- Search results navigation
            local n_options = #M.state.sr_menu.items -- [Now, Next, Add queue, Cancel] 
            
            if key_name == "down" then
                if M.state.in_search_result_view then
                    M.state.sr_menu.hl_idx = 1 + (M.state.sr_menu.hl_idx % n_options)
                    write_play_options()
                else
                    M.state.hl_idx = (M.state.hl_idx == nil and 1) or math.min(M.state.hl_idx+1, #CSTATE.search_results)
                    write_search_results()
                end
            
            elseif key_name == "up" then
                if M.state.in_search_result_view then
                    M.state.sr_menu.hl_idx = M.state.sr_menu.hl_idx > 1 and (M.state.sr_menu.hl_idx-1) or n_options
                    write_play_options()
                elseif M.state.hl_idx ~= nil then
                    -- if M.state.hl_idx > 1 then M.state.hl_idx = M.state.hl_idx-1 else M.state.hl_idx = nil end
                    M.state.hl_idx = M.state.hl_idx > 1 and M.state.hl_idx-1 or nil
                    write_search_results()
                end
                
            elseif key_name == "enter" then 
                if M.state.in_search_result_view then
                    local menu_item = M.state.sr_menu.items[M.state.sr_menu.hl_idx]
                    handle_click(0, menu_item.x, menu_item.y)
                    
                elseif M.state.hl_idx ~= nil then
                    M.state.in_search_result_view = true
                    M.state.clicked_result_index = M.state.hl_idx
                    M.redraw_screen()
                end

            elseif key_name == "backspace" then
                if M.state.in_search_result_view then 
                    local menu_cancel = M.state.sr_menu.items[4]
                    handle_click(0, menu_cancel.x, menu_cancel.y) -- cancel
                
                elseif M.state.hl_idx ~= nil then 
                    handle_click(0, config.ui.search_bar.x, config.ui.search_bar.y) -- go back into search bar
                end


            end
        end
    end
end


local function handle_click_out()
    while M.state.waiting_for_input do
        local event, button, x, y = os.pullEvent("mouse_click")
        if not is_in_box(x, y, config.ui.search_bar) then
            M.state.waiting_for_input = false
            handle_click(button, x, y)
        end
    end
end


function M.ui_loop()
    M.redraw_screen()
    while true do
        if M.state.waiting_for_input then
            parallel.waitForAny(handle_search_input, handle_click_out)
        else
            parallel.waitForAny(
                function ()
                    local ev, button, x, y  = os.pullEvent("mouse_click")
                    handle_click(button, x, y)
                end,

                function ()
                    -- drag interferes with click events, ignore on search tab
                    local evname = M.state.active_tab == 1 and "mouse_drag" or "IGNORE_mouse_drag"
                    local ev, button, x, y  = os.pullEvent(evname)
                    handle_drag(button, x, y)
                end,

                function ()
                    local ev, key, is_held = os.pullEvent("key")
                    handle_key_press(key, is_held)
                end,

                function ()
                    os.pullEvent("redraw_screen")
                    M.redraw_screen()
                end
            )
        end
    end
end




return M
