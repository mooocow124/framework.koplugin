local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local Framework = WidgetContainer:extend{
    name = "framework",
}

function Framework:init()
    local raw_target = nil
    if type(arg) == "table" then
        for _, v in ipairs(arg) do
            local match = string.match(v, "^%-%-fwlaunch=(.+)$")
            if match then
                raw_target = match
                break
            end
        end
    end

    if not raw_target then return end

    if G_reader_settings and G_reader_settings.saveSettings then
        G_reader_settings.saveSettings = function() end
    end

    -- Store references to patched functions
    local orig_show_ref, orig_close_ref

    local function exitFramework()
        -- Restore monkey-patched UIManager methods before exiting (there's no need to do this, I just imagined an extravagant edge case that somehow requires this)
        if orig_show_ref then UIManager.show = orig_show_ref end
        if orig_close_ref then UIManager.close = orig_close_ref end
        os.exit(0)
    end

    local function normalize(s)
        return string.lower(string.gsub(tostring(s or ""), "[%s%-_]", ""))
    end
    local target_norm = normalize(raw_target)

    local function findLauncherCallback(root_table)
        if type(root_table) ~= "table" then return nil end

        local queue = { root_table }
        local visited = {}

        while #queue > 0 do
            local node = table.remove(queue, 1)
            if type(node) == "table" and not visited[node] then
                visited[node] = true

                local label = node.text
                if not label and type(node.text_func) == "function" then
                    local ok, result = pcall(node.text_func)
                    if ok then label = result end
                end

                if label and normalize(label) == target_norm then
                    if type(node.callback) == "function" and not node.checked_func then
                        return node.callback
                    end
                end

                for k, v in pairs(node) do
                    if type(v) == "table" and k ~= "_parent" and k ~= "parent"
                       and k ~= "ui" and k ~= "plugin_management" then
                        if type(k) == "string" and normalize(k) == target_norm then
                            if type(v.callback) == "function" and not v.checked_func then
                                return v.callback
                            end
                        end
                        table.insert(queue, v)
                    end
                end

                if label == nil or normalize(label) ~= "pluginmanagement" then
                    local sub = node.sub_item_table
                    if not sub and type(node.sub_item_table_func) == "function" then
                        local ok, result = pcall(node.sub_item_table_func)
                        if ok then sub = result end
                    end
                    if type(sub) == "table" then
                        table.insert(queue, sub)
                    end
                end
            end
        end

        return nil
    end

    local launched = false
    local launch_retries = 0
    local MAX_RETRIES = 5

    local function triggerLaunch()
        if launched then return end
        local fm = self.ui
        if not fm or not fm.menu then
            -- Retry if FileManager isn't ready yet (slow ass devices)
            launch_retries = launch_retries + 1
            if launch_retries < MAX_RETRIES then
                print("[framework] FileManager not ready, retrying ("
                      .. launch_retries .. "/" .. MAX_RETRIES .. ")...")
                UIManager:scheduleIn(0.5, triggerLaunch)
            else
                print("[framework] FileManager not ready after "
                      .. MAX_RETRIES .. " retries. Exiting.") -- Look, if your device is this slow to launch KOReader, I don't think you should be using it in the first place.
                exitFramework()
            end
            return
        end

        launched = true

        if type(fm.menu.setUpdateItemTable) == "function" then
            pcall(function() fm.menu:setUpdateItemTable() end)
        end

        local harvested = {}
        if type(fm.menu.registered_widgets) == "table" then
            for _, w in pairs(fm.menu.registered_widgets) do
                if type(w) == "table" and type(w.addToMainMenu) == "function" then
                    pcall(function() w:addToMainMenu(harvested) end)
                end
            end
        end

        local callback = findLauncherCallback(harvested)
            or findLauncherCallback(fm.menu.menu_items)
            or findLauncherCallback(fm.menu.tab_item_table)

        if not callback then
            print("[framework] Launcher menu item not found: " .. tostring(raw_target))
            exitFramework()
            return
        end

        --  Blank out background widgets so their chrome never bleeds through.
        --  Only the bottom-most widget does the white fill; the rest become no-ops.
        --  Bit extreme, right?
        local base_widgets = {}
        local first_base = true
        for _, entry in ipairs(UIManager._window_stack) do
            local w = (type(entry) == "table" and entry.widget) or entry
            if type(w) == "table" then
                base_widgets[w] = true
                if first_base then
                    first_base = false
                    w.paintTo = function(self_w, bb, x, y)
                        bb:paintRect(0, 0, Screen:getWidth(), Screen:getHeight(),
                                     Blitbuffer.COLOR_WHITE)
                    end
                else
                    w.paintTo = function() end
                end
            end
        end

        -- Force fullscreen on newly shown top-level tool widgets
        -- This MAY break some hypothetical plugin that opens a dialog window. Just, remind me to update it in the future I guess?
        orig_show_ref = UIManager.show
        UIManager.show = function(mgr, widget, ...)
            if type(widget) == "table" and not base_widgets[widget] then
                if widget.dimen and widget.dimen.h
                   and widget.dimen.h < Screen:getHeight()
                   and widget.item_table then
                    widget.covers_fullscreen = true
                    widget.height = Screen:getHeight()
                    widget.dimen.h = Screen:getHeight()
                    if type(widget.init) == "function"
                       and type(widget.updateItems) == "function" then
                        local ok, err = pcall(function() widget:updateItems() end)
                        if not ok then
                            print("[framework] updateItems error: " .. tostring(err))
                        end
                    end
                end
            end
            return orig_show_ref(mgr, widget, ...)
        end

        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            print("[framework] Error launching tool:\n" .. tostring(err))
            exitFramework()
            return
        end

        -- exit watchdog on the stack
        local allow_exit = false
        UIManager:scheduleIn(0.25, function()
            allow_exit = true
        end)

        local pending_exit_check = false

        orig_close_ref = UIManager.close
        UIManager.close = function(mgr, widget, ...)
            -- Never ever let anything close the base layer
            if base_widgets[widget] then
                return
            end

            orig_close_ref(mgr, widget, ...)

            if not allow_exit then return end

            -- Debounce
            if pending_exit_check then return end
            pending_exit_check = true

            -- accommodating plugins with async view transitions
            -- I know this is a bit arbitrary time delay, but it's better than nothing. Not having one would stop tools that switch views from working.
            UIManager:scheduleIn(0.1, function()
                pending_exit_check = false

                local active_tool_windows = 0
                for _, entry in ipairs(mgr._window_stack) do
                    local w = (type(entry) == "table" and entry.widget) or entry
                    if not base_widgets[w] then
                        active_tool_windows = active_tool_windows + 1
                    end
                end

                if active_tool_windows == 0 then
                    print("[framework] All tool windows closed. Exiting.")
                    exitFramework()
                end
            end)
        end
    end

    UIManager:scheduleIn(0.35, triggerLaunch) -- Bit arbitrary, again
end

return Framework