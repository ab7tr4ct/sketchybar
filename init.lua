-- Add the sketchybar module to the package cpath
package.cpath = package.cpath .. ";" .. os.getenv("HOME") .. "/.local/share/sketchybar_lua/?.so"

local function file_exists(path)
  local file = io.open(path, "r")
  if not file then return false end
  file:close()
  return true
end

local function helpers_ready()
  local root = os.getenv("HOME") .. "/.config/sketchybar/helpers"
  local required = {
    root .. "/aerospace_events/bin/aerospace_events",
    root .. "/battery_info/bin/battery_info",
    root .. "/network_load/bin/network_load",
    root .. "/network_info/bin/SketchyBarNetworkInfoHelper.app/Contents/MacOS/SketchyBarNetworkInfoHelper",
    root .. "/popup_context/bin/popup_context",
    root .. "/system_stats/bin/system_stats",
    root .. "/menus/bin/menus",
  }

  for _, path in ipairs(required) do
    if not file_exists(path) then return false end
  end
  return true
end

if not helpers_ready() then
  -- Run make asynchronously to avoid blocking the event loop if compilation hangs
  local helpers_dir = os.getenv("HOME") .. "/.config/sketchybar/helpers"
  os.execute("(cd '" .. helpers_dir .. "' && make) >/dev/null 2>&1 &")
end

-- Require the sketchybar module
sbar = require("sketchybar")

-- Make reloads idempotent: clear any existing items from a previous load so
-- `sbar.add(...)` doesn't spam "Item already exists" messages.
do
  local guard_name = "__reload_guard_" .. tostring({}):gsub("[^%w]", "")
  sbar.add("item", guard_name, {
    drawing = false,
    updates = false,
    icon = { drawing = false },
    label = { drawing = false },
    background = { drawing = false },
  })
  sbar.remove("/.*/")
end

-- Bundle the entire initial configuration into a single message to sketchybar
sbar.begin_config()
require("bar")
require("default")
require("mission_control")
require("items")
sbar.end_config()

-- Run the event loop of the sketchybar module (without this there will be no
-- callback functions executed in the lua module)
sbar.event_loop()
