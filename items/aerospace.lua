local colors = require("colors")
local settings = require("settings")
local app_icons = require("app_icons")

-- Aerospace workspaces: show all workspaces that contain windows,
-- each with a workspace-ID pill and app icons for its windows.
-- Focused workspace is highlighted in lavender; others in surface0.
-- All sbar.exec() calls use hardcoded strings with no user input.

sbar.add("event", "aerospace_workspace_change")
sbar.add("event", "aerospace_focus_change")

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

-- Parse `aerospace list-windows --all` output into workspace -> window list map
local function parse_all_windows(output)
	local workspaces = {} -- ws_name -> { {app, win_id}, ... }
	local ws_seen = {}
	local ws_order = {}

	for line in output:gmatch("[^\r\n]+") do
		local ws, app, win_id = line:match("^(.-)|||(.-)|||(.-)$")
		if ws and app then
			ws = ws:match("^%s*(.-)%s*$")
			app = app:match("^%s*(.-)%s*$")
			win_id = win_id and win_id:match("^%s*(.-)%s*$") or ""
			if ws ~= "" and app ~= "" then
				if not ws_seen[ws] then
					ws_seen[ws] = true
					ws_order[#ws_order + 1] = ws
					workspaces[ws] = {}
				end
				workspaces[ws][#workspaces[ws] + 1] = { app = app, win_id = win_id }
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
					local is_focused = (win.win_id ~= "" and win.win_id == focused_win_id)
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

-- Single combined shell command. Usually 2 aerospace calls (~70ms each):
-- the focused window also tells us the focused workspace; the extra
-- list-workspaces call only runs when the focused workspace is empty.
-- Each call is capped at 2s so a hung CLI can't stall updates, and gets
-- stdin from /dev/null: the aerospace CLI reads stdin when it's not a TTY
-- and would otherwise wait forever on an open pipe.
local T = "/usr/bin/perl -e 'alarm 2; exec @ARGV' aerospace "
local Q = " </dev/null 2>/dev/null"
local WINDOWS_CMD = T .. "list-windows --all --format '%{workspace}|||%{app-name}|||%{window-id}'" .. Q
local QUERY_CMD = "echo '---WINDOWS---'; "
	.. WINDOWS_CMD .. "; "
	.. "F=$(" .. T .. "list-windows --focused --format '%{window-id}|||%{workspace}'" .. Q .. "); "
	.. "echo '---FOCUSED_WIN---'; echo \"$F\"; "
	.. "echo '---FOCUSED_WS---'; "
	.. "[ -z \"$F\" ] && " .. T .. "list-workspaces --focused" .. Q .. "; true"

-- Parse the combined output into its 3 sections
local function parse_combined(raw)
	local lines = {}
	local focused_ws = ""
	local focused_win_id = ""

	local section = nil
	for line in raw:gmatch("[^\r\n]+") do
		if line == "---WINDOWS---" then
			section = "w"
		elseif line == "---FOCUSED_WS---" then
			section = "fw"
		elseif line == "---FOCUSED_WIN---" then
			section = "fwin"
		elseif section == "w" then
			lines[#lines + 1] = line
		elseif section == "fw" then
			focused_ws = line:match("^%s*(.-)%s*$") or ""
		elseif section == "fwin" then
			local id, ws = line:match("^%s*(.-)|||(.-)%s*$")
			if id then
				focused_win_id = id
				focused_ws = ws
			end
		end
	end

	return table.concat(lines, "\n"), focused_ws, focused_win_id
end

-- Coalesced async update. Switching a window fires up to three events
-- (front_app_switched, aerospace_focus_change, aerospace_workspace_change);
-- they are merged into one query, and only one query runs at a time so
-- out-of-order results can't render a stale state.
local DEBOUNCE_S = 0.03
local STUCK_S = 10.0
local scheduled = false
local in_flight = false
local dirty = false
local query_token = 0
local last_windows_block = nil
local last_workspaces = nil
local last_ws_order = nil

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

	sbar.exec(QUERY_CMD, function(raw)
		if token ~= query_token then
			return
		end
		in_flight = false
		local windows_block, focused_ws, focused_win_id = parse_combined(tostring(raw or ""))
		last_windows_block = windows_block
		local workspaces, ws_order = parse_all_windows(windows_block)
		-- Cache copies: ensure_focused mutates the tables in place.
		last_workspaces = {}
		for name, wins in pairs(workspaces) do
			last_workspaces[name] = wins
		end
		last_ws_order = { table.unpack(ws_order) }
		ensure_focused(workspaces, ws_order, focused_ws)
		render(workspaces, ws_order, focused_ws, focused_win_id)
		if dirty then
			request_update()
		end
	end)
end

request_update()

-- Optimistic render: the workspace-change event already names the new
-- workspace, so move the highlight right away from cached data; the real
-- query follows ~130ms later and corrects window details.
local function render_focused_ws(ws)
	if not ws or ws == "" or not last_workspaces then
		return
	end
	local workspaces = {}
	for name, wins in pairs(last_workspaces) do
		workspaces[name] = wins
	end
	local ws_order = { table.unpack(last_ws_order) }
	ensure_focused(workspaces, ws_order, ws)
	render(workspaces, ws_order, ws, nil)
end

ws_groups[1].pill:subscribe("aerospace_workspace_change", function(env)
	render_focused_ws(env.FOCUSED_WORKSPACE)
	request_update()
end)

ws_groups[1].pill:subscribe({ "aerospace_focus_change", "front_app_switched" }, function(_)
	request_update()
end)

-- Fallback poll for changes AeroSpace has no callback for (a window opened
-- or closed in the background, an app quitting). Bindings and focus changes
-- trigger events, so this only runs the cheap window listing and asks for a
-- full update when the window set actually changed.
local POLL_S = 2
local poller = sbar.add("item", "aerospace.poller", {
	drawing = false,
	update_freq = POLL_S,
})
poller:subscribe("routine", function(_)
	if in_flight or scheduled or _G.SKETCHYBAR_SUSPENDED then
		return
	end
	sbar.exec(WINDOWS_CMD, function(raw)
		local lines = {}
		for line in tostring(raw or ""):gmatch("[^\r\n]+") do
			lines[#lines + 1] = line
		end
		if table.concat(lines, "\n") ~= last_windows_block then
			request_update()
		end
	end)
end)
