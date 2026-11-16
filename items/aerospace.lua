local colors = require("colors")
local settings = require("settings")
local app_icons = require("app_icons")

-- Aerospace workspaces: show all workspaces that contain windows,
-- each with a workspace-ID pill and app icons for its windows.
-- Focused workspace is highlighted in lavender; others in surface0.
-- All sbar.exec() calls use hardcoded strings with no user input.
--
-- Where the data comes from:
--   * Focus (window + workspace) is pushed by AeroSpace: the aerospace_events
--     helper keeps an `aerospace subscribe` connection open and turns every
--     event into the sketchybar event "aerospace_event".
--   * The window list is one `aerospace list-windows --all` call, re-run after
--     every event and by a slow fallback poll.

sbar.add("event", "aerospace_event")

local MAX_WORKSPACES = 10
local MAX_WINDOWS_PER_WS = 5

-- Track which workspace name is assigned to each slot (for click handling)
local slot_ws_name = {}

-- Pre-create workspace groups (pill + window icon slots)
local ws_groups = {}
for w = 1, MAX_WORKSPACES do
	local pill = sbar.add("item", "aerospace.ws." .. w .. ".pill", {
		position = "left",
		icon = {
			font = {
				family = settings.font.numbers,
				style = settings.font.style_map["Bold"],
				size = 13.0,
			},
			string = "?",
			padding_left = 8,
			padding_right = 8,
			color = colors.base,
		},
		label = { drawing = false },
		padding_left = w == 1 and 2 or 6,
		padding_right = 2,
		background = {
			height = 22,
			corner_radius = 6,
			color = colors.lavender,
		},
		drawing = false,
	})

	local icons = {}
	for i = 1, MAX_WINDOWS_PER_WS do
		icons[i] = sbar.add("item", "aerospace.ws." .. w .. ".win." .. i, {
			position = "left",
			icon = {
				font = {
					family = "sketchybar-app-font",
					style = "Regular",
					size = 16.0,
				},
				string = "",
				color = colors.overlay0,
			},
			label = { drawing = false },
			drawing = false,
			padding_left = 1,
			padding_right = 1,
			background = { drawing = false },
		})
	end

	-- Click a workspace pill to switch to it
	local slot = w
	pill:subscribe("mouse.clicked", function(_)
		local name = slot_ws_name[slot]
		if name then
			sbar.exec("aerospace workspace " .. name)
		end
	end)

	ws_groups[w] = { pill = pill, icons = icons }
end

local function trim(s)
	return (s:match("^%s*(.-)%s*$"))
end

-- Parse `aerospace list-windows --all` output into workspace -> window list map.
--
-- The list isn't trusted verbatim: a long-running AeroSpace 0.17 repeated the
-- same window-id several times and kept windows of processes that had already
-- exited. Windows of dead processes are dropped by the shell side of
-- WINDOWS_CMD; repeated window-ids are dropped here.
local function parse_all_windows(output)
	local workspaces = {} -- ws_name -> { {app, win_id}, ... }
	local ws_order = {}
	local seen_id = {}

	for line in output:gmatch("[^\r\n]+") do
		-- Fields: app-pid, workspace, app-name, window-id.
		local ws, app, win_id = line:match("^.-|||(.-)|||(.-)|||(.-)$")
		if ws then
			ws, app, win_id = trim(ws), trim(app), trim(win_id)
			if ws ~= "" and app ~= "" and not seen_id[win_id] then
				if win_id ~= "" then
					seen_id[win_id] = true
				end
				local wins = workspaces[ws]
				if not wins then
					wins = {}
					workspaces[ws] = wins
					ws_order[#ws_order + 1] = ws
				end
				wins[#wins + 1] = { app = app, win_id = win_id }
			end
		end
	end

	table.sort(ws_order)
	return workspaces, ws_order
end

-- Ensure the focused workspace appears in the list (even if empty)
local function ensure_focused(workspaces, ws_order, focused_ws)
	if focused_ws == "" or workspaces[focused_ws] then
		return
	end
	workspaces[focused_ws] = {}
	local inserted = false
	for idx, name in ipairs(ws_order) do
		if focused_ws < name then
			table.insert(ws_order, idx, focused_ws)
			inserted = true
			break
		end
	end
	if not inserted then
		ws_order[#ws_order + 1] = focused_ws
	end
end

-- Only send properties that changed since the last render. Every :set is a
-- synchronous round-trip to the daemon, so skipping no-op updates matters.
local last_sig = {}
local function set_if_changed(item, sig, props)
	if last_sig[item.name] == sig then
		return
	end
	last_sig[item.name] = sig
	item:set(props)
end

local HIDDEN = { drawing = false }

-- Apply workspace data to pre-created sketchybar items
local function render(workspaces, ws_order, focused_ws, focused_win_id)
	for w = 1, MAX_WORKSPACES do
		local ws_name = ws_order[w]
		slot_ws_name[w] = ws_name

		if ws_name then
			local is_focused_ws = (ws_name == focused_ws)
			set_if_changed(ws_groups[w].pill, ws_name .. (is_focused_ws and "|f" or "|"), {
				drawing = true,
				icon = {
					string = ws_name,
					color = is_focused_ws and colors.base or colors.text,
				},
				background = {
					color = is_focused_ws and colors.lavender or colors.surface0,
				},
			})

			local wins = workspaces[ws_name] or {}
			for i = 1, MAX_WINDOWS_PER_WS do
				local win = wins[i]
				if win then
					local icon_str = app_icons[win.app] or app_icons["Default"] or ":default:"
					local is_app_font = icon_str:match("^:.*:$")
					-- The focused window id can lag one event behind the focused
					-- workspace (e.g. on an empty workspace), so require both.
					local is_focused = is_focused_ws and win.win_id ~= "" and win.win_id == focused_win_id
					set_if_changed(ws_groups[w].icons[i], icon_str .. (is_focused and "|f" or "|"), {
						drawing = true,
						icon = {
							string = icon_str,
							font = {
								family = is_app_font and "sketchybar-app-font" or settings.font.icons,
								style = "Regular",
								size = 16.0,
							},
							color = is_focused and colors.text or colors.overlay0,
						},
					})
				else
					set_if_changed(ws_groups[w].icons[i], "", HIDDEN)
				end
			end
		else
			set_if_changed(ws_groups[w].pill, "", HIDDEN)
			for i = 1, MAX_WINDOWS_PER_WS do
				set_if_changed(ws_groups[w].icons[i], "", HIDDEN)
			end
		end
	end
end

-- The window list: one aerospace call (~70ms), capped at 2s so a hung CLI
-- can't stall updates, with stdin from /dev/null because the aerospace CLI
-- reads stdin when it's not a TTY and would otherwise wait forever on an open
-- pipe. "---OK---" is printed only when the call succeeded, so a timeout isn't
-- mistaken for "no windows". The read loop keeps only windows whose app
-- process is still alive (the pid is the first field; `kill -0` is a shell
-- builtin, so no extra processes).
local WINDOWS_CMD = "W=$(/usr/bin/perl -e 'alarm 2; exec @ARGV' aerospace list-windows --all"
	.. " --format '%{app-pid}|||%{workspace}|||%{app-name}|||%{window-id}'"
	.. " </dev/null 2>/dev/null) && { echo '---OK---'; printf '%s\\n' \"$W\""
	.. " | while IFS= read -r l; do kill -0 \"${l%%|||*}\" 2>/dev/null && printf '%s\\n' \"$l\"; done; }"

-- Focus as last reported by AeroSpace, and the last window list we fetched.
local focused_ws = ""
local focused_win_id = ""
local last_workspaces = nil
local last_ws_order = nil

-- Render the cached window list with the current focus.
local function draw()
	if not last_workspaces then
		return
	end
	-- Copies: ensure_focused mutates the tables in place.
	local workspaces = {}
	for name, wins in pairs(last_workspaces) do
		workspaces[name] = wins
	end
	local ws_order = { table.unpack(last_ws_order) }
	ensure_focused(workspaces, ws_order, focused_ws)
	render(workspaces, ws_order, focused_ws, focused_win_id)
end

-- Coalesced async refresh of the window list. One user action fires several
-- events (focus-changed, focused-workspace-changed, ...); they are merged into
-- one query, and only one query runs at a time so out-of-order results can't
-- render a stale state.
local DEBOUNCE_S = 0.03
local STUCK_S = 10.0
local scheduled = false
local in_flight = false
local dirty = false
local query_token = 0

local run_query

local function request_update()
	if scheduled then
		return
	end
	scheduled = true
	sbar.delay(DEBOUNCE_S, function()
		scheduled = false
		run_query()
	end)
end

run_query = function()
	if in_flight then
		dirty = true
		return
	end
	if _G.SKETCHYBAR_SUSPENDED then
		-- Don't drop the update; retry once the bar resumes.
		sbar.delay(0.5, request_update)
		return
	end

	in_flight = true
	dirty = false
	query_token = query_token + 1
	local token = query_token

	-- Safety net: never let a lost callback block updates forever.
	sbar.delay(STUCK_S, function()
		if in_flight and token == query_token then
			in_flight = false
			request_update()
		end
	end)

	sbar.exec(WINDOWS_CMD, function(raw)
		if token ~= query_token then
			return
		end
		in_flight = false
		raw = tostring(raw or "")
		-- No marker: the CLI timed out or AeroSpace is down. Keep what we show.
		if raw:find("---OK---", 1, true) then
			last_workspaces, last_ws_order = parse_all_windows(raw)
			draw()
		end
		if dirty then
			request_update()
		end
	end)
end

request_update()

local POLL_S = 5
-- Hidden item that only receives events; `updates` must be on explicitly,
-- because a hidden item gets no events by default.
local watcher = sbar.add("item", "aerospace.watcher", {
	drawing = false,
	updates = true,
	update_freq = POLL_S,
})

watcher:subscribe("aerospace_event", function(env)
	local event = env.EVENT
	if event == "focus-changed" then
		focused_ws = env.WORKSPACE or focused_ws
		focused_win_id = env.WINDOW_ID or ""
	elseif event == "focused-workspace-changed" or event == "focused-monitor-changed" then
		focused_ws = env.WORKSPACE or focused_ws
	end
	-- Move the highlight right away using the cached list; the query that
	-- follows picks up windows that were opened, closed or moved.
	draw()
	request_update()
end)

-- Fallback poll for the one change AeroSpace has no event for: a window that
-- goes away without the focus changing (closed in the background, app quit).
watcher:subscribe("routine", function(_)
	if in_flight or scheduled or _G.SKETCHYBAR_SUSPENDED then
		return
	end
	request_update()
end)

-- (Re)start the event bridge. It is started from the event loop, i.e. after
-- the initial config (and with it the subscription above) has reached
-- sketchybar; otherwise the focus AeroSpace sends on connect could arrive
-- before anyone listens.
sbar.delay(0.1, function()
	sbar.exec(
		"killall aerospace_events >/dev/null 2>&1; "
			.. "$CONFIG_DIR/helpers/aerospace_events/bin/aerospace_events aerospace_event"
	)
end)
