local colors = require("colors")
local settings = require("settings")

-- Network widget with hover popup attached directly to the graph item.
-- NOTE: sbar.exec is the SketchyBar Lua API, NOT Node.js child_process.
-- All commands below are hardcoded strings with no user input.
local network_load_cmd =
	"killall network_load >/dev/null 2>&1; $CONFIG_DIR/helpers/network_load/bin/network_load auto network_update 0.5"
sbar.exec(network_load_cmd)

local wifi_interface = os.getenv("WIFI_INTERFACE") or "en0"

local graph_width = 80
local trailing_gap = 16
local popup_width = 300
local name_width = 120
local value_width = popup_width - name_width

local wifi_net = sbar.add("graph", "widgets.wifi.net", graph_width, {
	position = "right",
	graph = { color = colors.with_alpha(colors.blue, 1) },
	icon = {
		string = "NET",
		color = colors.blue,
		font = {
			family = settings.font.text,
			style = settings.font.style_map["Heavy"],
			size = 12.0,
		},
		padding_left = 4,
		padding_right = 0,
	},
	label = {
		string = "--",
		color = colors.text,
		font = {
			family = settings.font.numbers,
			style = settings.font.style_map["Bold"],
			size = 9.0,
		},
		align = "right",
		padding_left = 2,
		padding_right = 6,
		width = 0,
		y_offset = 4,
	},
	padding_left = 0,
	padding_right = trailing_gap,
	popup = {
		align = "center",
		height = 24,
		blur_radius = 30,
		background = {
			color = colors.popup.bg,
			border_color = colors.with_alpha(colors.blue, 0.4),
			border_width = 1,
			corner_radius = 10,
		},
	},
})

local popup_pos = "popup." .. wifi_net.name

local function add_row(key, title)
	return sbar.add("item", "wifi.popup." .. key, {
		position = popup_pos,
		width = popup_width,
		icon = {
			align = "left",
			string = title,
			width = name_width,
			font = { family = settings.font.text, style = settings.font.style_map["Semibold"], size = 11.0 },
			color = colors.text,
		},
		label = {
			align = "right",
			string = "-",
			width = value_width,
			font = { family = settings.font.numbers, style = settings.font.style_map["Regular"], size = 11.0 },
			color = colors.text,
		},
		background = { drawing = false },
	})
end

local row_status = add_row("status", "Status")
local row_ssid = add_row("ssid", "SSID")
local row_ip = add_row("ip", "IP")
local row_mask = add_row("mask", "Subnet")
local row_router = add_row("router", "Router")
local row_download = add_row("download", "Download")
local row_upload = add_row("upload", "Upload")

local close_btn = sbar.add("item", "wifi.popup.close", {
	position = popup_pos,
	width = popup_width,
	icon = {
		string = "✕  Close",
		align = "center",
		width = popup_width,
		font = {
			family = settings.font.text,
			style = settings.font.style_map["Bold"],
			size = 11.0,
		},
		color = colors.with_alpha(colors.blue, 0.8),
	},
	label = { drawing = false },
	background = { drawing = false },
})

local function round_int(n)
	n = tonumber(n) or 0
	if n < 0 then
		n = 0
	end
	return math.floor(n + 0.5)
end

local function format_rate(mbps)
	local n = tonumber(mbps) or 0
	if n < 0 then
		n = 0
	end
	if n >= 1000 then
		return string.format("%.1fG", n / 1000)
	elseif n >= 1 then
		return string.format("%dM", round_int(n))
	else
		return string.format("%dK", round_int(n * 1000))
	end
end

local function format_rate_row(mbps)
	local n = tonumber(mbps) or 0
	if n < 0 then
		n = 0
	end
	return string.format("%d Mbps", round_int(n))
end

local graph_peak = 10
local current_connected = false
local current_down_mbps = 0
local current_up_mbps = 0
local wifi_popup_visible = false

local function update_popup_rates()
	if not wifi_popup_visible then
		return
	end
	row_download:set({ label = { string = format_rate_row(current_down_mbps) } })
	row_upload:set({ label = { string = format_rate_row(current_up_mbps) } })
end

-- Hardcoded ipconfig command
local function update_connection_state()
	if _G.SKETCHYBAR_SUSPENDED then
		return
	end
	-- Hardcoded path, no user input
	sbar.exec("/usr/sbin/ipconfig getifaddr " .. wifi_interface .. " 2>/dev/null", function(ip)
		ip = tostring(ip or ""):gsub("%s+$", "")
		current_connected = (ip ~= "")
		if wifi_popup_visible then
			row_status:set({ label = { string = current_connected and "Connected" or "Disconnected" } })
			row_ip:set({ label = { string = (ip ~= "") and ip or "-" } })
			update_popup_rates()
		end
	end)
end

wifi_net:subscribe({ "forced", "routine", "wifi_change", "system_woke" }, function(_)
	update_connection_state()
end)

local last_net_label = nil

wifi_net:subscribe("network_update", function(env)
	if _G.SKETCHYBAR_SUSPENDED then
		return
	end
	current_down_mbps = tonumber(env.download) or 0
	current_up_mbps = tonumber(env.upload) or 0

	-- Graph: always push (unlimited refresh)
	local total_mbps = current_down_mbps + current_up_mbps
	if total_mbps > graph_peak then
		graph_peak = total_mbps
	end
	local normalized = math.min(total_mbps / graph_peak, 1.0)
	wifi_net:push({ normalized })

	-- Label + popup: only on full update (~1s)
	if env.full_update ~= "1" then
		return
	end
	update_popup_rates()

	local label = format_rate(current_down_mbps) .. "\xe2\x86\x93 " .. format_rate(current_up_mbps) .. "\xe2\x86\x91"
	if label ~= last_net_label then
		last_net_label = label
		wifi_net:set({ label = label })
	end
end)

-- Hardcoded helper binary path
local function fetch_wifi_info()
	sbar.exec(
		"$CONFIG_DIR/helpers/network_info/bin/SketchyBarNetworkInfoHelper.app/Contents/MacOS/SketchyBarNetworkInfoHelper auto",
		function(info)
			if type(info) ~= "table" then
				return
			end
			if info.interface and info.interface ~= "" then
				wifi_interface = tostring(info.interface)
			end
			if info.ip and info.ip ~= "" then
				current_connected = true
			elseif info.ip == "" then
				current_connected = false
			end
			row_status:set({ label = { string = current_connected and "Connected" or "Disconnected" } })
			row_ssid:set({ label = { string = (info.ssid and info.ssid ~= "") and tostring(info.ssid) or "-" } })
			row_ip:set({ label = { string = (info.ip and info.ip ~= "") and tostring(info.ip) or "-" } })
			row_mask:set({
				label = { string = (info.subnet_mask and info.subnet_mask ~= "") and tostring(info.subnet_mask) or "-" },
			})
			row_router:set({ label = { string = (info.router and info.router ~= "") and tostring(info.router) or "-" } })
			update_popup_rates()
		end
	)
end

local function show_popup()
	wifi_popup_visible = true
	update_popup_rates()
	fetch_wifi_info()
	wifi_net:set({ popup = { drawing = true } })
end

local function hide_popup()
	wifi_popup_visible = false
	wifi_net:set({ popup = { drawing = false } })
end

-- Click to toggle popup; right-click opens Network preferences
wifi_net:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		sbar.exec(
			"/usr/bin/open 'x-apple.systempreferences:com.apple.preference.network' >/dev/null 2>&1",
			function() end
		)
		return
	end
	if wifi_popup_visible then
		hide_popup()
	else
		show_popup()
	end
end)

close_btn:subscribe("mouse.clicked", function()
	hide_popup()
end)

-- Restart helper after sleep to avoid stale/zombie process
wifi_net:subscribe("system_woke", function(_)
	sbar.delay(1.5, function()
		sbar.exec(network_load_cmd)
	end)
end)

update_connection_state()
