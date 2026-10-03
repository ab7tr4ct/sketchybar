local colors = require("colors")
local settings = require("settings")

-- CPU per-core bars + GPU/MEM graphs. No popups.
-- NOTE: sbar.exec is the SketchyBar Lua API, NOT Node.js child_process.
-- All commands below are hardcoded strings with no user input.
local system_stats_cmd = "killall system_stats >/dev/null 2>&1; "
	.. os.getenv("CONFIG_DIR")
	.. "/helpers/system_stats/bin/system_stats system_stats_update 0.5"

sbar.exec(system_stats_cmd)

local graph_width = 80

local function make_graph(name, icon_text, graph_color, padding_right)
	return sbar.add("graph", name, graph_width, {
		position = "right",
		graph = { color = colors.with_alpha(graph_color, 1) },
		icon = {
			string = icon_text,
			color = graph_color,
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
		padding_right = padding_right or 0,
	})
end

local trailing_gap = 16
local mem = make_graph("widgets.sys.mem", "MEM", colors.teal, trailing_gap)
local gpu = make_graph("widgets.sys.gpu", "GPU", colors.mauve, 0)

-- Right-click opens Activity Monitor (hardcoded app path)
gpu:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		sbar.exec("/usr/bin/open -a 'Activity Monitor' >/dev/null 2>&1", function() end)
	end
end)

mem:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		sbar.exec("/usr/bin/open -a 'Activity Monitor' >/dev/null 2>&1", function() end)
	end
end)

--------------------------------------------------------------------------------
-- CPU PER-CORE VERTICAL BARS
--------------------------------------------------------------------------------
local ncores
do
	local p = io.popen("sysctl -n hw.ncpu")
	ncores = p and tonumber(p:read("*a"):match("(%d+)")) or 10
	if p then
		p:close()
	end
end

local max_bar_height = 28

-- Detect P/E core split (Apple Silicon; falls back to all-P on Intel)
local pcores = ncores
do
	local p = io.popen("sysctl -n hw.perflevel0.logicalcpu 2>/dev/null")
	if p then
		local n = tonumber(p:read("*a"):match("(%d+)"))
		p:close()
		if n and n > 0 and n < ncores then pcores = n end
	end
end
local bar_width = 6
local bar_gap = 2

local function color_for_load(load)
	if load >= 75 then return colors.red end
	if load >= 50 then return colors.peach end
	if load >= 25 then return colors.yellow end
	return colors.green
end

-- Spacer between GPU graph and core bars (keeps trailing_gap off the bars)
sbar.add("item", "widgets.sys.cpu.spacer", {
	position = "right",
	width = trailing_gap,
	padding_left = 0,
	padding_right = 0,
})

-- Single loop, right-to-left. Kernel order: P(0..pcores-1), E(pcores..ncores-1)
local core_items = {}
for i = ncores - 1, 0, -1 do
	core_items[i] = sbar.add("item", "widgets.sys.cpu.core_" .. i, {
		position = "right",
		width = bar_width,
		icon = { drawing = false },
		label = { drawing = false },
		background = {
			color = (i >= pcores) and colors.blue or colors.green,
			height = 3,
			corner_radius = 2,
			y_offset = -(max_bar_height - 3) / 2,
		},
		padding_left = 0,
		padding_right = bar_gap,
	})
end

-- CPU info: icon = temp (top), label = load (bottom), overlapping at same x
local cpu_info = sbar.add("item", "widgets.sys.cpu.info", {
	position = "right",
	icon = {
		string = "",
		color = colors.text,
		font = {
			family = settings.font.numbers,
			style = settings.font.style_map["Bold"],
			size = 9.0,
		},
		width = 0,
		y_offset = 6,
	},
	label = {
		string = "--",
		color = colors.text,
		font = {
			family = settings.font.numbers,
			style = settings.font.style_map["Bold"],
			size = 9.0,
		},
		y_offset = -6,
		width = 20,
	},
	padding_left = 2,
	padding_right = 3,
})

-- CPU label (leftmost, just "CPU" text)
local cpu_label = sbar.add("item", "widgets.sys.cpu.label", {
	position = "right",
	icon = {
		string = "CPU",
		color = colors.red,
		font = {
			family = settings.font.text,
			style = settings.font.style_map["Heavy"],
			size = 12.0,
		},
		padding_left = 4,
		padding_right = 2,
	},
	label = { drawing = false },
	padding_left = 0,
	padding_right = 0,
})

cpu_label:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		sbar.exec("/usr/bin/open -a 'Activity Monitor' >/dev/null 2>&1", function() end)
	end
end)

-- Last sent height/color per core: most ticks change only a few bars, and
-- each :set is a synchronous round-trip to the daemon.
local core_last_h = {}
local core_last_color = {}

local function update_core(idx, load)
	if not core_items[idx] then return end
	local h = math.max(3, math.floor(load / 100 * max_bar_height + 0.5))
	local color = (idx >= pcores) and colors.blue or color_for_load(load)
	if core_last_h[idx] == h and core_last_color[idx] == color then return end
	core_last_h[idx] = h
	core_last_color[idx] = color
	core_items[idx]:set({
		background = {
			color = color,
			height = h,
			y_offset = -(max_bar_height - h) / 2,
		},
	})
end

--------------------------------------------------------------------------------
-- EVENT: system_stats_update
--------------------------------------------------------------------------------
local last_label = {}
local function set_label(item, key, text)
	if last_label[key] == text then return end
	last_label[key] = text
	item:set({ label = text })
end

cpu_info:subscribe("system_stats_update", function(env)
	if _G.SKETCHYBAR_SUSPENDED then
		return
	end

	local is_full = env.full_update == "1"

	-- Graphics: always update (unlimited refresh)
	-- Per-core bars
	local core_loads_str = env.cpu_core_loads or ""
	local core_idx = 0
	for load_str in core_loads_str:gmatch("([^,]+)") do
		update_core(core_idx, tonumber(load_str) or 0)
		core_idx = core_idx + 1
	end

	-- GPU graph push
	local gpu_util = tonumber(env.gpu_util)
	if gpu_util and gpu_util >= 0 then
		gpu:push({ gpu_util / 100.0 })
	end

	-- MEM graph push
	local mem_percent = tonumber(env.mem_used_percent)
	if mem_percent and mem_percent >= 0 then
		mem:push({ mem_percent / 100.0 })
	end

	-- Text labels: only on full update (~1s)
	if not is_full then
		return
	end

	-- CPU: avg temp + avg load (1s averages)
	local cpu_avg = tonumber(env.cpu_avg)
	local cpu_temp_avg = tonumber(env.cpu_temp_avg)
	local cpu_icon = (cpu_temp_avg and cpu_temp_avg >= 0) and string.format("%d\xc2\xb0", cpu_temp_avg) or ""
	local cpu_lbl = cpu_avg and cpu_avg >= 0 and string.format("%d%%", cpu_avg) or "--"
	if last_label.cpu ~= cpu_icon .. "|" .. cpu_lbl then
		last_label.cpu = cpu_icon .. "|" .. cpu_lbl
		cpu_info:set({ icon = { string = cpu_icon }, label = { string = cpu_lbl } })
	end

	-- GPU label (1s averages)
	local gpu_avg = tonumber(env.gpu_avg)
	local gpu_temp_avg = tonumber(env.gpu_temp_avg)
	if gpu_avg and gpu_avg >= 0 then
		local lbl = string.format("%d%%", gpu_avg)
		if gpu_temp_avg and gpu_temp_avg >= 0 then
			lbl = lbl .. string.format(" %d\xc2\xb0", gpu_temp_avg)
		end
		set_label(gpu, "gpu", lbl)
	else
		set_label(gpu, "gpu", "--")
	end

	-- MEM label
	local mem_used_gb = tonumber(env.mem_used_gb)
	local mem_total_gb = tonumber(env.mem_total_gb)
	if mem_percent and mem_percent >= 0 then
		local lbl = string.format("%d%%", mem_percent)
		if mem_used_gb and mem_total_gb then
			lbl = lbl .. string.format(" %.0f/%.0fG", mem_used_gb, mem_total_gb)
		end
		set_label(mem, "mem", lbl)
	else
		set_label(mem, "mem", "--")
	end
end)

--------------------------------------------------------------------------------
-- Restart helper after sleep to avoid stale/zombie process
--------------------------------------------------------------------------------
cpu_info:subscribe("system_woke", function(_)
	sbar.delay(1.5, function()
		sbar.exec(system_stats_cmd)
	end)
end)

--------------------------------------------------------------------------------
-- Keep network cache for wifi.lua
--------------------------------------------------------------------------------
_G._system_stats_net = _G._system_stats_net or { down = 0, up = 0 }

cpu_info:subscribe("network_update", function(env)
	local down = tonumber(env.download) or 0
	local up = tonumber(env.upload) or 0
	_G._system_stats_net.down = down
	_G._system_stats_net.up = up
end)
