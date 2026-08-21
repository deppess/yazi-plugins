local get_path = ya.sync(function()
  local hovered = cx.active.current.hovered
  if not hovered then return nil end
  return tostring(hovered.url)
end)

local function set_awww(path, namespace)
  return Command("awww")
      :arg("img"):arg(path)
      :arg("--namespace"):arg(namespace)
      :arg("--transition-type"):arg("grow")
      :arg("--transition-pos"):arg("0.5,0.5")
      :arg("--transition-duration"):arg("1.2")
      :arg("--transition-fps"):arg("60")
      :output()
end

local function save_last(path)
  local f = io.open(os.getenv("HOME") .. "/.local/state/awww/last", "w")
  if f then f:write(path) f:close() end
end

return {
  entry = function()
    local path = get_path()
    if not path then
      ya.notify { title = "Wallpaper", content = "No file hovered", level = "warn", timeout = 3 }
      return
    end

    local out1, err1 = set_awww(path, "wallpaper")
    local out2, err2 = set_awww(path, "backdrop")

    if out1 and out1.status.success and out2 and out2.status.success then
      save_last(path)
      ya.notify { title = "Wallpaper Set", content = path:match("([^/]+)$"), level = "info", timeout = 3 }
    elseif not (out1 and out1.status.success) then
      ya.notify { title = "Wallpaper Failed", content = "wallpaper daemon: " .. tostring(err1), level = "error", timeout = 5 }
    else
      ya.notify { title = "Wallpaper Failed", content = "backdrop daemon: " .. tostring(err2), level = "error", timeout = 5 }
    end
  end
}
