local mod = "SUPER"

hl.monitor({
    output = "eDP-1",
    mode = "2560x1600@165.000",
    position = "auto",
    scale = 1.6,
    vrr = 1,
})

hl.monitor({
    output = "desc:GIGA-BYTE TECHNOLOGY CO., LTD. M28U 24030B004813",
    mode = "3840x2160@143.999",
    position = "0x-900",
    scale = 1.875,
})

hl.monitor({
    output = "desc:Dell Inc. DELL P2720DC H88QK53",
    mode = "2560x1440@59.951",
    position = "0x0",
    scale = 1.25,
})

hl.monitor({
    output = "desc:Dell Inc. DELL P2720D D94ZS03",
    mode = "2560x1440@59.951",
    position = "2048x0",
    scale = 1.25,
})

hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = "auto",
})

hl.config({
    input = {
        kb_layout = "pl",
        repeat_delay = 300,
        repeat_rate = 50,
        follow_mouse = 1,
        focus_on_close = 1,
        mouse_refocus = true,
        float_switch_override_focus = 0,
        sensitivity = 0.0,
        scroll_factor = 0.3,
        touchpad = {
            tap_to_click = true,
            disable_while_typing = true,
            natural_scroll = true,
            scroll_factor = 0.1,
        },
    },
    general = {
        layout = "scrolling",
        gaps_in = 24,
        gaps_out = 24,
        border_size = 0,
        no_focus_fallback = true,
        col = {
            active_border = "rgb(938056)",
            inactive_border = "rgb(717c7c)",
        },
    },
    scrolling = {
        fullscreen_on_one_column = false,
        column_width = 0.66667,
        focus_fit_method = 2,
        explicit_column_widths = "0.33333, 0.66667, 1.0",
        follow_focus = true,
        follow_min_visible = 0.4,
        direction = "right",
        wrap_focus = false,
        wrap_swapcol = false,
    },
    decoration = {
        rounding = 4,
        border_part_of_window = false,
        dim_modal = true,
        dim_inactive = false,
        blur = {
            enabled = true,
        },
        shadow = {
            enabled = true,
            range = 30,
            offset = { 0, 5 },
            color = "rgba(00000077)",
        },
    },
    cursor = {
        no_warps = false,
    },
    animations = {
        enabled = true,
        workspace_wraparound = false,
    },
    gestures = {
        workspace_swipe_create_new = false,
        workspace_swipe_use_r = false,
    },
    binds = {
        scroll_event_delay = 0,
        window_direction_monitor_fallback = false,
    },
    xwayland = {
        force_zero_scaling = false,
    },
    misc = {
        background_color = "rgb(16161d)",
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
        always_follow_on_dnd = true,
        layers_hog_keyboard_focus = true,
        focus_on_activate = false,
        middle_click_paste = false,
        mouse_move_enables_dpms = true,
        key_press_enables_dpms = true,
        on_focus_under_fullscreen = 2,
    },
    plugin = {
        overview = {
            panelColor = "rgba(16161dee)",
            panelBorderColor = "rgb(363646)",
            workspaceActiveBackground = "rgba(2d4f67dd)",
            workspaceInactiveBackground = "rgba(1f1f28dd)",
            workspaceActiveBorder = "rgb(938056)",
            workspaceInactiveBorder = "rgb(717c7c)",
            panelHeight = 250,
            panelBorderWidth = 2,
            workspaceMargin = 12,
            workspaceBorderSize = 2,
            reservedArea = 0,
            adaptiveHeight = false,
            centerAligned = true,
            onBottom = false,
            hideBackgroundLayers = false,
            hideTopLayers = false,
            hideOverlayLayers = false,
            drawActiveWorkspace = true,
            hideRealLayers = true,
            affectStrut = true,
            overrideGaps = true,
            gapsIn = 24,
            gapsOut = 24,
            autoDrag = true,
            autoScroll = true,
            exitOnClick = true,
            switchOnDrop = false,
            exitOnSwitch = true,
            showNewWorkspace = true,
            showEmptyWorkspace = true,
            showSpecialWorkspace = false,
            disableGestures = true,
            reverseSwipe = false,
            disableBlur = false,
            overrideAnimSpeed = 0.0,
            dragAlpha = 0.2,
            exitKey = "Escape",
        },
    },
})

hl.curve("niriOpen", {
    type = "bezier",
    points = { { 0.155022, 1.056612 }, { 0.360227, 0.981250 } },
})
hl.curve("niriClose", {
    type = "bezier",
    points = { { 0.333333, 0.666667 }, { 0.666667, 1.000000 } },
})
hl.curve("niriSpring", {
    type = "bezier",
    points = { { 0.326467, 0.688594 }, { 0.114413, 1.000000 } },
})

hl.animation({ leaf = "global", enabled = true, speed = 1.5, bezier = "niriClose" })
hl.animation({ leaf = "windows", enabled = true, speed = 3.2564, bezier = "niriSpring" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 1.5, bezier = "niriOpen", style = "popin 50%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.5, bezier = "niriClose", style = "popin 80%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.5, bezier = "niriOpen" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.5, bezier = "niriClose" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 1.5, bezier = "niriOpen", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "niriClose", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.5, bezier = "niriOpen" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.5, bezier = "niriClose" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.9126, bezier = "niriSpring", style = "slidevert" })

hl.gesture({ fingers = 3, direction = "horizontal", action = "scroll_move" })
hl.gesture({ fingers = 3, direction = "vertical", action = "workspace" })

local workspaceNames = { "web", "code", "chat", "notes", "music" }
for index, name in ipairs(workspaceNames) do
    hl.workspace_rule({
        workspace = tostring(index),
        persistent = true,
        default_name = name,
    })
end

hl.window_rule({
    name = "default-window-appearance",
    match = { class = ".*" },
    border_size = 0,
    rounding = 4,
    idle_inhibit = "fullscreen",
})

hl.window_rule({
    name = "browser-workspace",
    match = { title = ".*(Firefox|Zen).*" },
    workspace = "name:web",
})

hl.window_rule({
    name = "cursor-workspace",
    match = { title = ".*Cursor.*" },
    workspace = "name:code",
})

hl.window_rule({
    name = "telegram-workspace",
    match = { title = ".*Telegram.*" },
    workspace = "name:chat",
    scrolling_width = 0.3,
})

hl.window_rule({
    name = "slack-workspace",
    match = { title = ".*Slack.*" },
    workspace = "name:chat",
    scrolling_width = 0.7,
})

hl.window_rule({
    name = "obsidian-workspace",
    match = { title = ".*Obsidian.*" },
    workspace = "name:notes",
})

hl.window_rule({
    name = "spotify-workspace",
    match = { title = ".*Spotify.*" },
    workspace = "name:music",
})

local function dispatch(dispatcher)
    return hl.dispatch(dispatcher)
end

local function orderedWorkspaces(monitor)
    local workspaces = {}
    for _, workspace in ipairs(hl.get_workspaces()) do
        if not workspace.special and workspace.monitor == monitor then
            workspaces[#workspaces + 1] = workspace
        end
    end
    table.sort(workspaces, function(left, right)
        return (left.index or left.id) < (right.index or right.id)
    end)
    return workspaces
end

local function nextWorkspaceId()
    local used = {}
    for _, workspace in ipairs(hl.get_workspaces()) do
        if workspace.id > 0 then
            used[workspace.id] = true
        end
    end

    local id = 1
    while used[id] do
        id = id + 1
    end
    return id
end

local function workspaceTargetAt(index, monitor)
    if index < 1 then
        return nil
    end

    local workspaces = orderedWorkspaces(monitor or hl.get_active_monitor())
    if workspaces[index] then
        return workspaces[index]
    end

    local last = workspaces[#workspaces]
    if not last or last.windows > 0 then
        return tostring(nextWorkspaceId())
    end
    return last
end

local function focusWorkspaceAt(index)
    local monitor = hl.get_active_monitor()
    local target = workspaceTargetAt(index, monitor)
    if target then
        dispatch(hl.dsp.focus({ workspace = target }))
    end
end

local function focusWorkspaceRelative(offset)
    local current = hl.get_active_workspace()
    if not current or not current.index then
        return
    end
    local target = workspaceTargetAt(current.index + offset, current.monitor)
    if target then
        dispatch(hl.dsp.focus({ workspace = target }))
    end
end

local function activeColumn()
    local window = hl.get_active_window()
    local layout = window and window.layout
    local column = layout and layout.name == "scrolling" and layout.column
    if not column then
        return window, nil
    end
    return window, column
end

local function focusFloating(direction, edge)
    local active = hl.get_active_window()
    if not active or not active.floating or not active.workspace then
        return
    end

    local activeCenterX = active.at.x + active.size.x / 2
    local activeCenterY = active.at.y + active.size.y / 2
    local candidate
    local candidateScore

    for _, window in ipairs(active.workspace:get_windows()) do
        if window ~= active and window.floating and window.mapped and not window.hidden then
            local centerX = window.at.x + window.size.x / 2
            local centerY = window.at.y + window.size.y / 2
            local primary
            local cross

            if direction == "left" and centerX < activeCenterX then
                primary = activeCenterX - centerX
                cross = math.abs(activeCenterY - centerY)
            elseif direction == "right" and centerX > activeCenterX then
                primary = centerX - activeCenterX
                cross = math.abs(activeCenterY - centerY)
            elseif direction == "up" and centerY < activeCenterY then
                primary = activeCenterY - centerY
                cross = math.abs(activeCenterX - centerX)
            elseif direction == "down" and centerY > activeCenterY then
                primary = centerY - activeCenterY
                cross = math.abs(activeCenterX - centerX)
            end

            if primary then
                local score = edge and -primary or primary * primary + cross * cross * 0.25
                if not candidateScore or score < candidateScore then
                    candidate = window
                    candidateScore = score
                end
            end
        end
    end

    if candidate then
        dispatch(hl.dsp.focus({ window = candidate }))
    end
end

local function focusDirection(direction)
    local active = hl.get_active_window()
    if active and active.floating then
        focusFloating(direction, false)
    elseif direction == "left" or direction == "right" then
        dispatch(hl.dsp.layout(direction == "left" and "move -col" or "move +col"))
    else
        dispatch(hl.dsp.focus({ direction = direction }))
    end
end

local function moveDirection(direction)
    local active = hl.get_active_window()
    if active and active.floating then
        local delta = {
            left = { x = -50, y = 0 },
            right = { x = 50, y = 0 },
            up = { x = 0, y = -50 },
            down = { x = 0, y = 50 },
        }
        dispatch(hl.dsp.window.move({
            window = active,
            x = delta[direction].x,
            y = delta[direction].y,
            relative = true,
        }))
    elseif direction == "left" or direction == "right" then
        dispatch(hl.dsp.layout(direction == "left" and "swapcol l" or "swapcol r"))
    else
        dispatch(hl.dsp.window.move({ direction = direction }))
    end
end

local setColumnHeights

local function moveColumnToWorkspace(target)
    local focused, column = activeColumn()
    if not focused or not target or focused.workspace == target then
        return
    end

    if focused.floating then
        dispatch(hl.dsp.window.move({ window = focused, workspace = target, follow = true }))
        return
    end
    if not column then
        return
    end

    local insertionIndex = 0
    if type(target) == "userdata" and target.last_window then
        local targetLayout = target.last_window.layout
        local targetColumn = targetLayout and targetLayout.name == "scrolling" and targetLayout.column
        if targetColumn then
            insertionIndex = targetColumn.index + 1
        end
    end

    local windows = {}
    local heights = {}
    for index, window in ipairs(column.windows) do
        windows[index] = window
        local layout = window.layout
        heights[index] = layout and layout.column and layout.column.height or (1 / #column.windows)
    end

    for _, window in ipairs(windows) do
        dispatch(hl.dsp.window.move({
            window = window,
            workspace = target,
            follow = false,
        }))
    end

    dispatch(hl.dsp.focus({ window = windows[1] }))
    for _ = 2, #windows do
        dispatch(hl.dsp.layout("consume"))
    end
    dispatch(hl.dsp.layout(string.format("colresize %.8f", column.width)))
    setColumnHeights(windows, heights, focused)

    for _ = 1, 128 do
        local _, moved = activeColumn()
        if not moved or moved.index <= insertionIndex then
            break
        end
        dispatch(hl.dsp.layout("swapcol l"))
    end
end

local function moveColumnToWorkspaceAt(index)
    moveColumnToWorkspace(workspaceTargetAt(index))
end

local function moveColumnToWorkspaceRelative(offset)
    local workspace = hl.get_active_workspace()
    if workspace and workspace.index then
        moveColumnToWorkspace(workspaceTargetAt(workspace.index + offset, workspace.monitor))
    end
end

local function moveColumnToMonitor(direction)
    local monitor = hl.get_monitor(direction)
    if monitor then
        moveColumnToWorkspace(monitor.active_workspace)
    end
end

local function switchFloatingFocus()
    local active = hl.get_active_window()
    if not active or not active.workspace then
        return
    end

    local candidate
    for _, window in ipairs(active.workspace:get_windows()) do
        if
            window.floating ~= active.floating
            and (not candidate or window.focus_history_id < candidate.focus_history_id)
        then
            candidate = window
        end
    end
    if candidate then
        dispatch(hl.dsp.focus({ window = candidate }))
    end
end

setColumnHeights = function(windows, heights, focused)
    local values = {}
    for index = 1, #windows do
        values[index] = string.format("%.8f", heights[index])
    end
    dispatch(hl.dsp.focus({ window = focused }))
    dispatch(hl.dsp.layout("rowresize all " .. table.concat(values, ",")))
end

local function switchPresetWindowHeight()
    local focused, column = activeColumn()
    if not focused then
        return
    end

    local presets = { 1 / 3, 1 / 2, 2 / 3 }
    local monitor = focused.monitor
    local logicalHeight = monitor and monitor.height / monitor.scale - 48 or focused.size.y
    local current = column and column.height or focused.size.y / logicalHeight
    local target = presets[1]
    for _, preset in ipairs(presets) do
        if preset > current + 0.001 then
            target = preset
            break
        end
    end

    if focused.floating then
        dispatch(hl.dsp.window.resize({ window = focused, x = focused.size.x, y = logicalHeight * target }))
        return
    end

    local windows = column.windows
    local heights = {}
    local otherTotal = 1 - current
    for index, window in ipairs(windows) do
        local layout = window.layout
        local height = layout and layout.column and layout.column.height or (1 / #windows)
        if window == focused then
            heights[index] = target
        elseif otherTotal > 0 then
            heights[index] = height * (1 - target) / otherTotal
        else
            heights[index] = (1 - target) / math.max(1, #windows - 1)
        end
    end
    setColumnHeights(windows, heights, focused)
end

local function resetWindowHeights()
    local focused, column = activeColumn()
    if not focused or not column then
        return
    end
    local heights = {}
    for index = 1, #column.windows do
        heights[index] = 1 / #column.windows
    end
    setColumnHeights(column.windows, heights, focused)
end

local function switchPresetColumnWidth()
    local focused, column = activeColumn()
    if not focused then
        return
    end
    if column then
        dispatch(hl.dsp.layout("colresize +conf"))
        return
    end

    local monitor = focused.monitor
    if not monitor then
        return
    end

    local logicalWidth = monitor.width / monitor.scale
    local current = focused.size.x / logicalWidth
    local presets = { 1 / 3, 2 / 3, 1 }
    local target = presets[1]
    for _, preset in ipairs(presets) do
        if preset > current + 0.001 then
            target = preset
            break
        end
    end
    dispatch(hl.dsp.window.resize({ window = focused, x = logicalWidth * target, y = focused.size.y }))
end

local function centerColumn()
    local focused, column = activeColumn()
    if not focused then
        return
    end
    if column then
        dispatch(hl.dsp.layout("center"))
        return
    end

    local monitor = focused.monitor
    if monitor then
        local x = monitor.x + (monitor.width / monitor.scale - focused.size.x) / 2
        dispatch(hl.dsp.window.move({ window = focused, x = x, y = focused.at.y }))
    end
end

local function resizeWindowHeight(amount)
    local monitor = hl.get_active_monitor()
    if monitor then
        local logicalHeight = monitor.height / monitor.scale - 48
        dispatch(hl.dsp.window.resize({ x = 0, y = logicalHeight * amount, relative = true }))
    end
end

local function updateFocusRings()
    local activeMonitor = hl.get_active_monitor()
    for _, window in ipairs(hl.get_windows({ mapped = true })) do
        dispatch(hl.dsp.window.set_prop({ window = window, prop = "border_size", value = "0" }))
    end

    for _, monitor in ipairs(hl.get_monitors()) do
        local workspace = monitor.active_workspace
        local window = workspace and workspace.last_window
        if window then
            local color = window.urgent and "rgb(e46876)"
                or (monitor == activeMonitor and "rgb(938056)" or "rgb(717c7c)")
            dispatch(hl.dsp.window.set_prop({ window = window, prop = "border_size", value = "2" }))
            dispatch(hl.dsp.window.set_prop({ window = window, prop = "active_border_color", value = color }))
            dispatch(hl.dsp.window.set_prop({ window = window, prop = "inactive_border_color", value = color }))
        end
    end
end

local eventSubscriptions = {}
for _, event in ipairs({
    "hyprland.start",
    "monitor.focused",
    "window.active",
    "window.open",
    "window.close",
    "window.urgent",
    "workspace.active",
}) do
    eventSubscriptions[#eventSubscriptions + 1] = hl.on(event, updateFocusRings)
end

local function triggerBlackout()
    dispatch(hl.dsp.exec_cmd("qs -c wave ipc call blackout trigger"))
end
for _, event in ipairs({ "monitor.added", "monitor.removed" }) do
    eventSubscriptions[#eventSubscriptions + 1] = hl.on(event, triggerBlackout)
end

local workspaceWheelReady = true
local workspaceWheelTimer
local function withWorkspaceWheelCooldown(action)
    if not workspaceWheelReady then
        return
    end

    workspaceWheelReady = false
    action()
    workspaceWheelTimer = hl.timer(function()
        workspaceWheelReady = true
        workspaceWheelTimer = nil
    end, { timeout = 150, type = "oneshot" })
end

hl.bind(mod .. " + RETURN", hl.dsp.exec_cmd("ghostty"))
hl.bind(mod .. " + SPACE", hl.dsp.exec_cmd("vicinae toggle"))
hl.bind(mod .. " + ALT + L", hl.dsp.exec_cmd("loginctl lock-session"))
hl.bind(mod .. " + W", hl.dsp.window.close())

hl.bind(mod .. " + left", function()
    focusDirection("left")
end)
hl.bind(mod .. " + H", function()
    focusDirection("left")
end)
hl.bind(mod .. " + right", function()
    focusDirection("right")
end)
hl.bind(mod .. " + L", function()
    focusDirection("right")
end)
hl.bind(mod .. " + down", function()
    focusDirection("down")
end)
hl.bind(mod .. " + J", function()
    focusDirection("down")
end)
hl.bind(mod .. " + up", function()
    focusDirection("up")
end)
hl.bind(mod .. " + K", function()
    focusDirection("up")
end)

hl.bind(mod .. " + CTRL + left", function()
    moveDirection("left")
end)
hl.bind(mod .. " + CTRL + H", function()
    moveDirection("left")
end)
hl.bind(mod .. " + CTRL + right", function()
    moveDirection("right")
end)
hl.bind(mod .. " + CTRL + L", function()
    moveDirection("right")
end)
hl.bind(mod .. " + CTRL + down", function()
    moveDirection("down")
end)
hl.bind(mod .. " + CTRL + J", function()
    moveDirection("down")
end)
hl.bind(mod .. " + CTRL + up", function()
    moveDirection("up")
end)
hl.bind(mod .. " + CTRL + K", function()
    moveDirection("up")
end)

for _, direction in ipairs({ "left", "down", "up", "right" }) do
    local key = direction
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.focus({ monitor = direction }))
    hl.bind(mod .. " + SHIFT + CTRL + " .. key, function()
        moveColumnToMonitor(direction)
    end)
end
for key, direction in pairs({ H = "left", J = "down", K = "up", L = "right" }) do
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.focus({ monitor = direction }))
    hl.bind(mod .. " + SHIFT + CTRL + " .. key, function()
        moveColumnToMonitor(direction)
    end)
end

hl.bind(mod .. " + CTRL + Page_Down", function()
    moveColumnToWorkspaceRelative(1)
end)
hl.bind(mod .. " + CTRL + U", function()
    moveColumnToWorkspaceRelative(1)
end)
hl.bind(mod .. " + CTRL + Page_Up", function()
    moveColumnToWorkspaceRelative(-1)
end)
hl.bind(mod .. " + CTRL + I", function()
    moveColumnToWorkspaceRelative(-1)
end)

hl.bind(mod .. " + mouse_down", function()
    withWorkspaceWheelCooldown(function()
        focusWorkspaceRelative(1)
    end)
end)
hl.bind(mod .. " + mouse_up", function()
    withWorkspaceWheelCooldown(function()
        focusWorkspaceRelative(-1)
    end)
end)
hl.bind(mod .. " + CTRL + mouse_down", function()
    withWorkspaceWheelCooldown(function()
        moveColumnToWorkspaceRelative(1)
    end)
end)
hl.bind(mod .. " + CTRL + mouse_up", function()
    withWorkspaceWheelCooldown(function()
        moveColumnToWorkspaceRelative(-1)
    end)
end)
hl.bind(mod .. " + mouse_right", function()
    focusDirection("right")
end)
hl.bind(mod .. " + mouse_left", function()
    focusDirection("left")
end)
hl.bind(mod .. " + CTRL + mouse_right", function()
    moveDirection("right")
end)
hl.bind(mod .. " + CTRL + mouse_left", function()
    moveDirection("left")
end)
hl.bind(mod .. " + SHIFT + mouse_down", function()
    focusDirection("right")
end)
hl.bind(mod .. " + SHIFT + mouse_up", function()
    focusDirection("left")
end)
hl.bind(mod .. " + CTRL + SHIFT + mouse_down", function()
    moveDirection("right")
end)
hl.bind(mod .. " + CTRL + SHIFT + mouse_up", function()
    moveDirection("left")
end)

for index = 1, 9 do
    local workspaceIndex = index
    hl.bind(mod .. " + " .. index, function()
        focusWorkspaceAt(workspaceIndex)
    end)
    hl.bind(mod .. " + CTRL + " .. index, function()
        moveColumnToWorkspaceAt(workspaceIndex)
    end)
end

hl.bind(mod .. " + comma", hl.dsp.layout("consume"))
hl.bind(mod .. " + period", hl.dsp.layout("expel"))

hl.bind(mod .. " + R", switchPresetColumnWidth)
hl.bind(mod .. " + SHIFT + R", switchPresetWindowHeight)
hl.bind(mod .. " + CTRL + R", resetWindowHeights)
hl.bind(mod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind(mod .. " + C", centerColumn)
hl.bind(mod .. " + minus", hl.dsp.layout("colresize -0.1"))
hl.bind(mod .. " + equal", hl.dsp.layout("colresize +0.1"))
hl.bind(mod .. " + SHIFT + minus", function()
    resizeWindowHeight(-0.1)
end)
hl.bind(mod .. " + SHIFT + equal", function()
    resizeWindowHeight(0.1)
end)

hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + SHIFT + V", switchFloatingFocus)

local screenshotOutput = '-o "$HOME/media/screenshots" -f "$(date +%Y-%m-%d_%H-%M-%S).png"'
hl.bind("Print", hl.dsp.exec_cmd("hyprshot -m region " .. screenshotOutput))
hl.bind("CTRL + Print", hl.dsp.exec_cmd("hyprshot -m output -m active " .. screenshotOutput))
hl.bind("ALT + Print", hl.dsp.exec_cmd("hyprshot -m window -m active " .. screenshotOutput))

hl.bind(mod .. " + SHIFT + P", hl.dsp.dpms({ action = "disable" }))

hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
